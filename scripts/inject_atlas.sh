#!/bin/bash

# =============================================================================
# ODS Player OS Atlas — Image Injection Script
# =============================================================================
# Adapted from Legacy: utils/esper/simple_inject.sh
# Loop-mounts base Armbian image, injects firstboot script + systemd service
# Run on jdl-mini-box (Linux build environment)
# =============================================================================

set -e

# ─── Configuration ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths — update these for the build environment
SOURCE_IMAGE="${1:-$HOME/atlas-build/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img}"
OUTPUT_IMAGE="${2:-$HOME/atlas-build/ods-atlas-rpi5-golden.img}"
WORK_DIR="/tmp/atlas-inject"

# ─── Helpers ────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

cleanup() {
    log "🧹 Cleaning up..."
    umount "$WORK_DIR/rootfs" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
}

trap cleanup EXIT

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    log "🚀 ODS Player OS Atlas — Image Injection"
    log "📋 Source: $SOURCE_IMAGE"
    log "📋 Output: $OUTPUT_IMAGE"

    # Verify source files
    if [ ! -f "$SOURCE_IMAGE" ]; then
        log "❌ ERROR: Source image not found: $SOURCE_IMAGE"
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/atlas_firstboot.sh" ]; then
        log "❌ ERROR: atlas_firstboot.sh not found in $SCRIPT_DIR"
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/atlas-firstboot.service" ]; then
        log "❌ ERROR: atlas-firstboot.service not found in $SCRIPT_DIR"
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/atlas_secrets.conf" ]; then
        log "❌ ERROR: atlas_secrets.conf not found in $SCRIPT_DIR"
        log "   This file contains credentials needed at first boot."
        exit 1
    fi

    # Setup workspace
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$(dirname "$OUTPUT_IMAGE")"

    # Copy source image → output
    log "📋 Copying base Armbian image..."
    cp "$SOURCE_IMAGE" "$OUTPUT_IMAGE"

    # Mount image
    log "📋 Setting up loop device..."
    LOOP_DEV=$(losetup --find --show --partscan "$OUTPUT_IMAGE")
    log "📋 Loop device: $LOOP_DEV"

    # Check filesystem (p2 = rootfs on RPi images, p1 = FAT32 boot)
    log "📋 Checking filesystem..."
    e2fsck -fy "${LOOP_DEV}p2" || true

    # Mount rootfs (p2 for RPi, p1 for OPi)
    log "📋 Mounting rootfs..."
    mkdir -p "$WORK_DIR/rootfs"
    mount "${LOOP_DEV}p2" "$WORK_DIR/rootfs"

    # Verify mount
    if [ ! -d "$WORK_DIR/rootfs/usr" ] || [ ! -d "$WORK_DIR/rootfs/etc" ]; then
        log "❌ ERROR: Mount failed or not a valid Linux filesystem"
        exit 1
    fi
    log "✅ Rootfs mounted"

    # Inject firstboot script
    log "📋 Injecting atlas_firstboot.sh → /usr/local/bin/"
    mkdir -p "$WORK_DIR/rootfs/usr/local/bin"
    cp "$SCRIPT_DIR/atlas_firstboot.sh" "$WORK_DIR/rootfs/usr/local/bin/"
    chmod +x "$WORK_DIR/rootfs/usr/local/bin/atlas_firstboot.sh"

    # Inject systemd service
    log "📋 Injecting atlas-firstboot.service → /etc/systemd/system/"
    mkdir -p "$WORK_DIR/rootfs/etc/systemd/system"
    cp "$SCRIPT_DIR/atlas-firstboot.service" "$WORK_DIR/rootfs/etc/systemd/system/"

    # Inject secrets config
    log "📋 Injecting atlas_secrets.conf → /usr/local/etc/"
    mkdir -p "$WORK_DIR/rootfs/usr/local/etc"
    cp "$SCRIPT_DIR/atlas_secrets.conf" "$WORK_DIR/rootfs/usr/local/etc/"
    chmod 600 "$WORK_DIR/rootfs/usr/local/etc/atlas_secrets.conf"

    # Symlink for enrollment boot (reads from /etc/ods/)
    log "📋 Creating /etc/ods/ secrets symlink"
    mkdir -p "$WORK_DIR/rootfs/etc/ods"
    ln -sf /usr/local/etc/atlas_secrets.conf "$WORK_DIR/rootfs/etc/ods/atlas_secrets.conf"

    # Enable the service via symlink (can't use systemctl on a mounted image)
    log "📋 Enabling service at multi-user.target..."
    mkdir -p "$WORK_DIR/rootfs/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/atlas-firstboot.service \
        "$WORK_DIR/rootfs/etc/systemd/system/multi-user.target.wants/"

    # ─── SAFEGUARD: Create ODS gate file ────────────────────────────────
    # The service uses ConditionPathExists=/var/lib/ods/atlas_firstboot_pending
    # This file is created here at inject time and deleted by atlas_firstboot.sh
    # when it completes, preventing double-runs.
    log "📋 Creating ODS firstboot gate file..."
    mkdir -p "$WORK_DIR/rootfs/var/lib/ods"
    touch "$WORK_DIR/rootfs/var/lib/ods/atlas_firstboot_pending"

    # ─── SAFEGUARD: Disable Armbian first-login (prevents race condition) ──
    # Armbian's first-login scripts delete /root/.not_logged_in_yet and prompt
    # for interactive password setup on tty, which blocked our firstboot from
    # running in v9-1-0-ORIGIN. Masking these services at inject time prevents
    # the race entirely.
    log "📋 Disabling Armbian first-login services..."

    # Mask armbian-firstrun (SSH key regeneration + first-run tweaks)
    ln -sf /dev/null "$WORK_DIR/rootfs/etc/systemd/system/armbian-firstrun.service"
    log "   ✅ armbian-firstrun.service masked"

    # Remove Armbian's gate file so first-login never triggers on tty
    rm -f "$WORK_DIR/rootfs/root/.not_logged_in_yet"
    log "   ✅ Armbian gate file removed"

    # Pre-set root password from secrets (so bypass_firstlogin isn't needed at boot)
    log "📋 Pre-setting root password..."
    local ROOT_PW
    ROOT_PW=$(grep -oP 'ROOT_PASSWORD="\K[^"]+' "$SCRIPT_DIR/atlas_secrets.conf" 2>/dev/null || echo "")
    if [ -n "$ROOT_PW" ]; then
        local HASH
        HASH=$(openssl passwd -6 "$ROOT_PW")
        sed -i "s|^root:[^:]*:|root:${HASH}:|" "$WORK_DIR/rootfs/etc/shadow"
        log "   ✅ Root password set from atlas_secrets.conf"
    else
        log "   ⚠️  ROOT_PASSWORD not found in secrets — will be set at firstboot"
    fi

    # Patch boot partition cmdline.txt (prevents screen sleep during firstboot)
    log "📋 Patching boot partition cmdline.txt..."
    mkdir -p "$WORK_DIR/boot"
    if mount "${LOOP_DEV}p1" "$WORK_DIR/boot" 2>/dev/null; then
        if [ -f "$WORK_DIR/boot/cmdline.txt" ]; then
            local cmdline
            cmdline=$(cat "$WORK_DIR/boot/cmdline.txt")
            local patched=false

            # Add consoleblank=0 (prevent screen blank during firstboot)
            if ! echo "$cmdline" | grep -q "consoleblank=0"; then
                cmdline="$cmdline consoleblank=0"
                patched=true
            fi
            # Add splash quiet (Plymouth boot splash)
            if ! echo "$cmdline" | grep -q "splash"; then
                cmdline="$cmdline splash quiet"
                patched=true
            fi
            # Add plymouth.ignore-serial-consoles
            if ! echo "$cmdline" | grep -q "plymouth.ignore-serial-consoles"; then
                cmdline="$cmdline plymouth.ignore-serial-consoles"
                patched=true
            fi
            # Add vt.global_cursor_default=0 (hide cursor)
            if ! echo "$cmdline" | grep -q "vt.global_cursor_default=0"; then
                cmdline="$cmdline vt.global_cursor_default=0"
                patched=true
            fi
            # Upgrade loglevel to 3
            if echo "$cmdline" | grep -q "loglevel="; then
                cmdline=$(echo "$cmdline" | sed 's/loglevel=[0-9]*/loglevel=3/')
                patched=true
            fi

            if [ "$patched" = true ]; then
                echo "$cmdline" > "$WORK_DIR/boot/cmdline.txt"
                log "   ✅ cmdline.txt patched (consoleblank=0, splash quiet, etc.)"
            else
                log "   ℹ️  cmdline.txt already has all required params"
            fi
        else
            log "   ⚠️  No cmdline.txt found in boot partition"
        fi
        umount "$WORK_DIR/boot"
    else
        log "   ⚠️  Could not mount boot partition (p1) — cmdline.txt not patched"
    fi

    # Sync and unmount
    log "📋 Syncing..."
    sync

    log "📋 Unmounting..."
    umount "$WORK_DIR/rootfs"
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    # Results
    OUTPUT_SIZE=$(ls -lh "$OUTPUT_IMAGE" | awk '{print $5}')
    log ""
    log "═══════════════════════════════════════════════════════"
    log "✅ ODS Atlas Golden Image — INJECTION COMPLETE"
    log "═══════════════════════════════════════════════════════"
    log "📦 Output: $OUTPUT_IMAGE"
    log "📊 Size:   $OUTPUT_SIZE"
    log ""
    log "🔧 INJECTED:"
    log "   ✅ atlas_firstboot.sh → /usr/local/bin/"
    log "   ✅ atlas-firstboot.service → /etc/systemd/system/"
    log "   ✅ atlas_secrets.conf → /usr/local/etc/ (chmod 600)"
    log "   ✅ Service enabled at multi-user.target"
    log "   ✅ cmdline.txt patched (consoleblank=0, splash quiet)"
    log ""
    log "📝 On first boot, atlas_firstboot.sh will:"
    log "   → Install packages (chromium, xorg, node, etc.)"
    log "   → Create users (signage, otter)"
    log "   → Clone & deploy Atlas app"
    log "   → Deploy 6 systemd services + 3 player scripts"
    log "   → Install Plymouth ODS theme"
    log "   → Enroll Esper MDM"
    log "   → Install RustDesk remote access"
    log "   → Reboot to production player"
    log ""
    log "🚀 Ready to flash!"
}

# Root check
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (for losetup/mount)"
    exit 1
fi

main "$@"
