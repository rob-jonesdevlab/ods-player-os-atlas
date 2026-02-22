#!/bin/bash
# ODS Enrollment Boot — Phase 2: Sealed-in-splash Esper enrollment
# Pipeline: Plymouth (5s) → FBI bridge → Enrollment attempt → Success/Retry/Fail
# NEVER launches Chromium/Xorg — everything via framebuffer
# DO NOT add set -e

LOG_DIR="/home/signage/ODS/logs/boot"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/enrollment_$(date +%Y%m%d_%H%M%S).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [ENROLL] $1" | tee -a "$LOG_FILE"; }

ANIM_DIR="/usr/share/plymouth/themes/ods"
ATTEMPT_FILE="/etc/ods/enrollment_attempts"
ENROLLED_FLAG="/etc/ods/esper_enrolled.flag"
SECRETS_FILE="/etc/ods/atlas_secrets.conf"
MAX_ATTEMPTS=3

# Show a splash frame on the framebuffer
show_frame() {
    local raw_file="$1"
    if [ -f "$raw_file" ]; then
        dd if="$raw_file" of=/dev/fb0 bs=65536 2>/dev/null
    fi
}

# ── STAGE 1: VT BLACKOUT ─────────────────────────────────────────────
log "Starting ODS enrollment boot (Phase 2)..."

for i in $(seq 1 30); do [ -e /dev/dri/card1 ] && break; sleep 0.1; done
log "DRM device ready"

for tty in /dev/tty1 /dev/tty2 /dev/tty3; do
    printf '\033[2J\033[H\033[?25l' > "$tty" 2>/dev/null || true
    setterm --foreground black --background black --cursor off > "$tty" 2>/dev/null || true
done
dd if=/dev/zero of=/dev/fb0 bs=65536 count=512 conv=notrunc 2>/dev/null || true
log "VT blackout complete"

# ── STAGE 2: PLYMOUTH QUIT ───────────────────────────────────────────
dmesg -D 2>/dev/null || true
echo 0 > /proc/sys/kernel/printk 2>/dev/null || true
sleep 5
plymouth quit --retain-splash 2>/dev/null || true
log "Plymouth quit (held 5s)"

# ── STAGE 3: FBI BRIDGE ANIMATION ────────────────────────────────────
STOP_FBI="/tmp/ods-stop-enroll-fbi"
rm -f "$STOP_FBI"
(
    while [ ! -f "$STOP_FBI" ]; do
        show_frame "$ANIM_DIR/enroll_fbi_1.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.15
        show_frame "$ANIM_DIR/enroll_fbi_2.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.175
        show_frame "$ANIM_DIR/enroll_fbi_3.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.20
        show_frame "$ANIM_DIR/enroll_fbi_4.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.25
        show_frame "$ANIM_DIR/enroll_fbi_5.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.25
        show_frame "$ANIM_DIR/enroll_fbi_6.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.30
        show_frame "$ANIM_DIR/enroll_fbi_7.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.30
        show_frame "$ANIM_DIR/enroll_fbi_8.raw"; [ -f "$STOP_FBI" ] && break; sleep 0.30
    done
) &
FBI_PID=$!
log "FBI enrollment bridge animation started"

# ── STAGE 4: WAIT FOR NETWORK ────────────────────────────────────────
NET_TIMEOUT=60
NET_ELAPSED=0
log "Waiting for network..."

while ! ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; do
    sleep 1
    NET_ELAPSED=$((NET_ELAPSED + 1))
    if [ $NET_ELAPSED -ge $NET_TIMEOUT ]; then
        log "WARN: No network after ${NET_TIMEOUT}s — proceeding anyway"
        break
    fi
done
[ $NET_ELAPSED -lt $NET_TIMEOUT ] && log "Network ready (${NET_ELAPSED}s)"

# ── STAGE 5: READ ATTEMPT COUNTER ────────────────────────────────────
mkdir -p /etc/ods
ATTEMPTS=$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)
ATTEMPTS=$((ATTEMPTS + 1))
echo "$ATTEMPTS" > "$ATTEMPT_FILE"
log "Enrollment attempt $ATTEMPTS/$MAX_ATTEMPTS"

# Stop FBI bridge — switch to enrollment progress animation
touch "$STOP_FBI"
kill $FBI_PID 2>/dev/null || true
log "FBI bridge stopped"

# ── STAGE 6: ENROLLMENT PROGRESS ANIMATION ───────────────────────────
STOP_PROGRESS="/tmp/ods-stop-enroll-progress"
rm -f "$STOP_PROGRESS"
(
    while [ ! -f "$STOP_PROGRESS" ]; do
        for _f in 1 2 3 4 5; do
            [ -f "$STOP_PROGRESS" ] && break 2
            show_frame "$ANIM_DIR/enroll_progress_${_f}.raw"
            sleep 0.3
        done
    done
) &
PROGRESS_PID=$!
log "Enrollment progress animation started"

# ── STAGE 7: RUN ESPER ENROLLMENT ────────────────────────────────────
ENROLL_SUCCESS=false

# Load secrets
if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
    log "Secrets loaded from $SECRETS_FILE"
else
    log "ERROR: Secrets file not found at $SECRETS_FILE"
fi

# Download and run Esper setup
cd /tmp
if curl -sS --connect-timeout 15 --max-time 120 \
    https://artifacthub.esper.cloud/linux/scripts/prod/setup.sh \
    -o /tmp/esper_setup.sh 2>&1 | tee -a "$LOG_FILE"; then

    chmod +x /tmp/esper_setup.sh
    log "Esper setup script downloaded"

    if bash /tmp/esper_setup.sh \
        --tenant "${ESPER_TENANT}" \
        --token "${ESPER_TOKEN}" \
        --blueprint "${ESPER_BLUEPRINT}" \
        --group "${ESPER_GROUP}" 2>&1 | tee -a "$LOG_FILE"; then

        # Verify enrollment by checking if Esper agent starts
        sleep 5
        systemctl start esper-cmse 2>/dev/null || true
        sleep 3

        if systemctl is-active --quiet esper-cmse 2>/dev/null; then
            ENROLL_SUCCESS=true
            log "Esper enrollment SUCCEEDED — agent running"
        else
            log "WARN: Esper setup ran but agent not active"
        fi
    else
        log "ERROR: Esper setup script failed"
    fi
    rm -f /tmp/esper_setup.sh
else
    log "ERROR: Failed to download Esper setup script"
fi

# Stop progress animation
touch "$STOP_PROGRESS"
kill $PROGRESS_PID 2>/dev/null || true
log "Progress animation stopped"

# ── STAGE 8: RESULT HANDLING ─────────────────────────────────────────
if [ "$ENROLL_SUCCESS" = true ]; then
    # ── SUCCESS ──────────────────────────────────────────────────────
    log "ENROLLMENT SUCCESS — resetting counter, setting flag"
    echo 0 > "$ATTEMPT_FILE"
    touch "$ENROLLED_FLAG"

    show_frame "$ANIM_DIR/enroll_success.raw"
    log "Success splash displayed — rebooting in 10s"

    for i in $(seq 10 -1 1); do
        log "Rebooting in ${i}s..."
        sleep 1
    done
    reboot

elif [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    # ── 3RD FAILURE — SAFE MODE ──────────────────────────────────────
    log "ENROLLMENT FAILED after $MAX_ATTEMPTS attempts — entering safe mode"

    # Show downloading logs splash
    show_frame "$ANIM_DIR/enroll_downloading.raw"
    log "Downloading logs splash displayed"

    # Archive all diagnostic logs
    ERROR_DIR="/root/error_logs/enrollment_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ERROR_DIR"
    log "Archiving logs to $ERROR_DIR"

    cp "$LOG_FILE" "$ERROR_DIR/" 2>/dev/null || true
    cp /var/log/ods-enrollment.log "$ERROR_DIR/" 2>/dev/null || true
    cp /var/log/esper-cmse.log "$ERROR_DIR/" 2>/dev/null || true
    cp /var/log/esper-telemetry.log "$ERROR_DIR/" 2>/dev/null || true
    cp /var/lib/esper/device_config.json "$ERROR_DIR/" 2>/dev/null || true
    cp /var/lib/esper/system-config.json "$ERROR_DIR/" 2>/dev/null || true
    journalctl -b --no-pager > "$ERROR_DIR/journal_full.log" 2>/dev/null || true
    dmesg > "$ERROR_DIR/dmesg.log" 2>/dev/null || true
    ip addr > "$ERROR_DIR/network.log" 2>/dev/null || true
    ip route > "$ERROR_DIR/routes.log" 2>/dev/null || true
    cat /etc/resolv.conf > "$ERROR_DIR/dns.log" 2>/dev/null || true
    cat /etc/ods/*.conf > "$ERROR_DIR/ods_config.log" 2>/dev/null || true
    cat "$ATTEMPT_FILE" > "$ERROR_DIR/attempt_count.log" 2>/dev/null || true

    # Copy all boot logs
    cp "$LOG_DIR"/enrollment_*.log "$ERROR_DIR/" 2>/dev/null || true
    cp "$LOG_DIR"/boot_*.log "$ERROR_DIR/" 2>/dev/null || true

    log "Log archival complete: $(ls "$ERROR_DIR" | wc -l) files saved"
    sleep 2

    # Show contact support splash and halt
    show_frame "$ANIM_DIR/enroll_support.raw"
    log "Contact support splash displayed — system halted"

    # Halt (don't reboot — wait for tech)
    while true; do sleep 3600; done

else
    # ── RETRY — WIPE AND REBOOT ──────────────────────────────────────
    log "ENROLLMENT FAILED — attempt $ATTEMPTS/$MAX_ATTEMPTS, wiping state and rebooting"

    show_frame "$ANIM_DIR/enroll_retry_${ATTEMPTS}.raw"
    log "Retry splash displayed (attempt $ATTEMPTS)"

    # Wipe Esper state for clean retry
    rm -f /var/lib/esper/device_config.json /var/lib/esper/serial.dat 2>/dev/null
    systemctl stop esper-cmse esper-telemetry 2>/dev/null || true
    log "Esper state wiped"

    sleep 5
    log "Rebooting for retry..."
    reboot
fi
