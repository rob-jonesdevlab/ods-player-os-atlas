#!/bin/bash

# =============================================================================
# ODS Player OS Atlas — Automated First Boot
# =============================================================================
# Adapted from Legacy: utils/automated_firstboot.sh
# Transforms bare Armbian 26.2.1 trixie into production ODS Player OS Atlas
# Runs once on first boot via atlas-firstboot.service (systemd oneshot)
# =============================================================================

# DO NOT use set -e in provisioning scripts — it causes silent aborts when
# any command returns non-zero (dpkg locks, systemctl disable of non-existent
# services, optional config steps, etc.). Instead we use explicit checks.
set -o pipefail

# Trap errors and log them instead of silently dying
trap 'echo "[$(date "+%H:%M:%S")] ⚠️ WARNING: Command failed at line $LINENO (exit code $?)" | tee -a /tmp/atlas_firstboot.log > /dev/tty1 2>/dev/null' ERR

# ─── Configuration ──────────────────────────────────────────────────────────
# Secrets are loaded from a separate config file injected into the image
# by inject_atlas.sh. This file is NOT committed to git.

SECRETS_FILE="/usr/local/etc/atlas_secrets.conf"
if [ ! -f "$SECRETS_FILE" ]; then
    echo "❌ FATAL: Secrets file not found: $SECRETS_FILE" >&2
    echo "   The golden image was not built correctly — atlas_secrets.conf is missing." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$SECRETS_FILE"

# ─── Logging ────────────────────────────────────────────────────────────────

LOG_FILE="/tmp/atlas_firstboot.log"

# ISSUE 2 FIX: Force all output to /dev/tty1 so the user can see every step
# (Previously steps 1-2 were invisible — only /dev/console was used which
# doesn't display on the physical screen during early boot)
setup_console() {
    # Clear tty1 and enable echo so log messages display
    stty echo -F /dev/tty1 2>/dev/null || true
    setterm --foreground white --background black --cursor on > /dev/tty1 2>/dev/null || true

    # Prevent console from blanking during firstboot (screen was turning off)
    export TERM=linux
    setterm --blank 0 --powersave off > /dev/tty1 2>/dev/null || true
    echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null || true
    # Also write to kernel param immediately (backup)
    echo 0 > /proc/sys/kernel/consoleblank 2>/dev/null || true

    # Redirect script stdout/stderr to tty1 as well
    exec > >(tee -a "$LOG_FILE" > /dev/tty1) 2>&1
}

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%H:%M:%S')] ❌ ERROR: $1"
}

# ─── Step 1: Armbian First-Login Bypass ─────────────────────────────────────

bypass_firstlogin() {
    log "🔧 Step 1: Verifying Armbian first-login bypass..."

    # NOTE: The heavy lifting is now done at inject time (inject_atlas.sh):
    #   - Root password pre-set via /etc/shadow
    #   - armbian-firstrun.service masked
    #   - /root/.not_logged_in_yet removed
    # This step is kept as a safety net in case inject missed something.

    # Remove Armbian gate file (if somehow still present)
    rm -f /root/.not_logged_in_yet

    # Set root password (idempotent — already set at inject)
    echo "root:$ROOT_PASSWORD" | chpasswd
    log "  ✅ Root password verified"

    # Disable Armbian first-login services (idempotent)
    systemctl disable armbian-firstlogin 2>/dev/null || true
    systemctl disable armbian-first-run 2>/dev/null || true
    systemctl mask armbian-firstrun 2>/dev/null || true

    log "  ✅ First-login bypass confirmed"
}
# ─── Step 1b: Wait for Network ──────────────────────────────────────────────
# Service no longer depends on network-online.target (it blocked forever on
# fresh Pi without ethernet). Instead we wait here with visible countdown.

wait_for_network() {
    log "🌐 Step 1b: Waiting for network connectivity..."
    local MAX_WAIT=120
    local INTERVAL=5
    local elapsed=0

    while [ $elapsed -lt $MAX_WAIT ]; do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log "  ✅ Network is online (waited ${elapsed}s)"

            # CRITICAL: Force NTP clock sync before apt runs
            # Without correct time, apt signature checks fail with
            # "Not live until <future date>" → stale index → package 404s
            log "  🕐 Syncing system clock via NTP..."
            systemctl restart systemd-timesyncd 2>/dev/null || true
            local ntp_wait=0
            while [ $ntp_wait -lt 30 ]; do
                if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
                    log "  ✅ Clock synced: $(date)"
                    return 0
                fi
                ntp_wait=$((ntp_wait + 2))
                sleep 2
            done
            # Even if NTP didn't confirm, clock may be close enough after timesyncd restart
            log "  ⚠️  NTP sync timeout — current time: $(date)"
            return 0
        fi
        elapsed=$((elapsed + INTERVAL))
        log "  ⏳ No network yet... (${elapsed}/${MAX_WAIT}s)"
        sleep $INTERVAL
    done

    log "  ⚠️  Network not available after ${MAX_WAIT}s — proceeding anyway"
    log "  ⚠️  apt install and git clone will likely fail without network"
    return 1
}



install_packages() {
    log "📦 Step 2: Installing packages..."

    # Wait for any existing apt locks
    local wait_count=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log "  ⏳ Waiting for dpkg lock ($wait_count)..."
        sleep 5
        wait_count=$((wait_count + 1))
        if [ $wait_count -ge 24 ]; then
            error "dpkg lock timeout after 2 minutes"
            break
        fi
    done

    export DEBIAN_FRONTEND=noninteractive

    # apt update with retry (transient DNS failures common on fresh Pi)
    log "  → apt update (with retry)..."
    local apt_tries=0
    while [ $apt_tries -lt 3 ]; do
        if apt-get update -y 2>&1 | tee -a "$LOG_FILE"; then
            log "  ✅ apt update succeeded"
            break
        fi
        apt_tries=$((apt_tries + 1))
        log "  ⚠️  apt update failed (attempt $apt_tries/3) — retrying in 10s..."
        sleep 10
    done

    # ── Batch 1: Critical infrastructure (must succeed for deploy_atlas) ──
    log "  → Batch 1: Critical infrastructure (git, node, npm, curl, wifi tools)..."
    apt-get install -y --fix-missing \
        git \
        nodejs \
        npm \
        curl \
        wget \
        jq \
        bc \
        dnsutils \
        iw \
        wpasupplicant \
        wireless-tools \
        rfkill \
        sudo \
        2>&1 | tee -a "$LOG_FILE"

    if command -v git &>/dev/null && command -v node &>/dev/null; then
        log "  ✅ Batch 1 complete (git, node, npm installed)"
    else
        log "  ❌ Batch 1 FAILED — git/node not installed. deploy_atlas will fail."
    fi

    # ── Batch 2a: Display stack (xorg, openbox — no chromium yet) ──
    log "  → Batch 2a: Display stack (xorg, openbox)..."
    apt-get install -y --fix-missing \
        xserver-xorg \
        x11-xserver-utils \
        openbox \
        xdotool \
        xterm \
        gnome-themes-extra \
        unclutter \
        2>&1 | tee -a "$LOG_FILE" || \
        log "  ⚠️  Batch 2a partial failure"

    # ── Batch 2b: Chromium (separated — most failure-prone package) ──
    log "  → Batch 2b: Chromium browser..."
    if ! apt-get install -y --fix-missing chromium 2>&1 | tee -a "$LOG_FILE"; then
        log "  ⚠️  Chromium install failed — refreshing package index and retrying..."
        # Clock should be synced by now; re-run apt update for fresh indices
        apt-get update -y 2>&1 | tee -a "$LOG_FILE"
        if ! apt-get install -y --fix-missing chromium 2>&1 | tee -a "$LOG_FILE"; then
            log "  ❌ Chromium install failed after retry"
        fi
    fi

    if command -v chromium &>/dev/null || [ -f /usr/bin/chromium ]; then
        log "  ✅ Chromium installed"
    else
        log "  ❌ Chromium NOT installed — display will not work"
    fi

    # ── Batch 3: Build tools & boot UI ──
    log "  → Batch 3: Build tools & boot UI..."
    apt-get install -y --fix-missing \
        imagemagick \
        plymouth \
        plymouth-themes \
        2>&1 | tee -a "$LOG_FILE" || \
        log "  ⚠️  Batch 3 partial failure"

    # ── Verify critical packages ──
    log "  → Verifying critical packages..."
    local all_ok=true
    for pkg in git node npm chromium; do
        if command -v "$pkg" &>/dev/null; then
            log "    ✅ $pkg: $(command -v $pkg)"
        else
            log "    ❌ $pkg: NOT FOUND"
            all_ok=false
        fi
    done

    if [ "$all_ok" = true ]; then
        log "  ✅ All critical packages installed"
    else
        log "  ⚠️  Some critical packages missing"
    fi
}

# ─── Step 3: Create Users ──────────────────────────────────────────────────

create_users() {
    log "👥 Step 3: Creating users..."

    # Create signage player user (no password, minimal shell)
    if ! id signage >/dev/null 2>&1; then
        useradd -m -s /bin/bash signage
        passwd -d signage
        log "  ✅ signage user created"
    else
        log "  ℹ️  signage user already exists"
    fi

    # Create sudoers file for signage — server.js needs these for WiFi, reboot, etc.
    cat > /etc/sudoers.d/signage << 'SUDOEOF'
# ODS Player OS — signage user privileges
# server.js runs as signage and needs passwordless sudo for:
#   WiFi: ip link, iw, wpa_cli
#   System: reboot, shutdown, systemctl
#   Auth: ods-auth-check.sh
# Cover all binary path variants (Armbian symlinks /sbin→/usr/bin)
signage ALL=(ALL) NOPASSWD: /usr/bin/ip link set wlan0 *
signage ALL=(ALL) NOPASSWD: /usr/sbin/ip link set wlan0 *
signage ALL=(ALL) NOPASSWD: /sbin/ip link set wlan0 *
signage ALL=(ALL) NOPASSWD: /usr/bin/iw dev wlan0 *
signage ALL=(ALL) NOPASSWD: /usr/sbin/iw dev wlan0 *
signage ALL=(ALL) NOPASSWD: /usr/bin/wpa_cli *
signage ALL=(ALL) NOPASSWD: /usr/sbin/wpa_cli *
signage ALL=(ALL) NOPASSWD: /usr/sbin/reboot
signage ALL=(ALL) NOPASSWD: /usr/sbin/shutdown *
signage ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
signage ALL=(ALL) NOPASSWD: /usr/local/bin/ods-auth-check.sh *
SUDOEOF
    chmod 0440 /etc/sudoers.d/signage
    log "  ✅ signage sudoers created (WiFi, reboot, systemctl)"

    # Create otter admin user with sudo
    if ! id otter >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo otter
        echo "otter:$OTTER_PASSWORD" | chpasswd
        log "  ✅ otter user created with sudo"
    else
        log "  ℹ️  otter user already exists"
    fi

    # Create ODS directory structure
    mkdir -p /home/signage/ODS/{bin,logs,pids}
    chown -R signage:signage /home/signage/ODS

    log "  ✅ Users configured"
}

# ─── Step 3b: Set Three-Word Hostname ──────────────────────────────────────

set_hostname() {
    log "🏷️  Step 3b: Setting MAC-based three-word hostname..."
    if [ -x /usr/local/bin/ods-hostname.sh ]; then
        local THREE_WORD=$(/usr/local/bin/ods-hostname.sh generate)
        hostnamectl set-hostname "$THREE_WORD"
        echo "$THREE_WORD" > /etc/hostname
        # Add to /etc/hosts for local resolution
        sed -i "s/127.0.1.1.*/127.0.1.1\t$THREE_WORD/" /etc/hosts 2>/dev/null || \
            echo "127.0.1.1	$THREE_WORD" >> /etc/hosts
        log "  ✅ Hostname set to: $THREE_WORD"
    else
        log "  ⚠️  ods-hostname.sh not found — hostname not changed"
    fi
}

# ─── Step 4: Clone & Install Atlas ─────────────────────────────────────────

deploy_atlas() {
    log "📂 Step 4: Cloning ODS Player OS Atlas..."

    # Clone repository
    cd /tmp
    git clone "https://$GITHUB_USERNAME:$GITHUB_TOKEN@github.com/rob-jonesdevlab/ods-player-os-atlas.git" atlas_repo 2>&1 | tee -a "$LOG_FILE"

    # Copy application files to /home/signage/ODS
    cp -r atlas_repo/public /home/signage/ODS/
    cp atlas_repo/server.js /home/signage/ODS/
    cp atlas_repo/package.json /home/signage/ODS/
    cp atlas_repo/package-lock.json /home/signage/ODS/ 2>/dev/null || true

    # Copy player modules (cloud-sync, cache-manager)
    if [ -d "atlas_repo/player" ]; then
        mkdir -p /home/signage/ODS/player
        cp -r atlas_repo/player/* /home/signage/ODS/player/
        log "  ✅ player/ modules deployed (cloud-sync, cache-manager)"
    fi

    # Copy bin scripts (health monitor, etc.)
    if [ -d "atlas_repo/bin" ]; then
        cp -r atlas_repo/bin/* /home/signage/ODS/bin/ 2>/dev/null || true
        chmod +x /home/signage/ODS/bin/*.sh 2>/dev/null || true
        log "  ✅ bin/ scripts deployed"
    fi

    # Install Node.js dependencies
    log "  → npm install..."
    cd /home/signage/ODS
    npm install --production 2>&1 | tee -a "$LOG_FILE"

    # Fix ownership
    chown -R signage:signage /home/signage/ODS

    # NOTE: Don't rm atlas_repo yet — Plymouth step needs brand/ assets

    log "  ✅ Atlas application deployed"
}

# ─── Step 5: Deploy Systemd Services ───────────────────────────────────────

deploy_services() {
    log "⚙️  Step 5: Deploying systemd services..."

    # --- ods-player-ATLAS.service ---
    # Phase selector gates between Phase 2 (enrollment) and Phase 3 (production)
    cat > /etc/systemd/system/ods-player-ATLAS.service << 'EOF'
[Unit]
Description=ODS Player Boot (Phase Selector)
# Start after webserver is up. Do NOT wait for plymouth-hold.
# Phase selector routes to enrollment boot or production wrapper.
After=ods-webserver.service
Wants=ods-webserver.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ods-phase-selector.sh
Restart=always
RestartSec=10
StartLimitIntervalSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # --- ods-webserver.service ---
    cat > /etc/systemd/system/ods-webserver.service << 'EOF'
[Unit]
Description=ODS Player Web Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=signage
WorkingDirectory=/home/signage/ODS
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

    # --- ods-health-monitor.service ---
    cat > /etc/systemd/system/ods-health-monitor.service << 'EOF'
[Unit]
Description=ODS Health Monitor
After=ods-player-ATLAS.service

[Service]
Type=simple
User=root
ExecStart=/home/signage/ODS/bin/ods_health_monitor.sh start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # --- ods-plymouth-hold.service ---
    # CRITICAL: This service BLOCKS plymouth-quit.service from killing Plymouth
    # until the boot wrapper signals it's taken over the display.
    # Without this, plymouth-quit kills Plymouth at ~10s, leaving a 26s gap
    # of bare TTY before Xorg starts.
    cat > /etc/systemd/system/ods-plymouth-hold.service << 'EOF'
[Unit]
Description=ODS Plymouth Hold - Block plymouth-quit until player is ready
DefaultDependencies=no
After=plymouth-start.service
Before=plymouth-quit.service plymouth-quit-wait.service getty@tty1.service

[Service]
Type=oneshot
# Wait for boot wrapper to signal it has taken over the display
# /tmp/ods-player-os-starting-ATLAS is touched by the wrapper AFTER VT1 blackout
# Max wait 90s to prevent boot hang
ExecStart=/bin/bash -c 'for i in $(seq 1 180); do [ -f /tmp/ods-player-os-starting-ATLAS ] && break; sleep 0.5; done'
RemainAfterExit=yes
TimeoutStartSec=95

[Install]
WantedBy=sysinit.target
EOF

    # --- ods-dpms-enforce.service (Issue #4 fix: Layer 5a — periodic DPMS kill) ---
    cat > /etc/systemd/system/ods-dpms-enforce.service << 'EOF'
[Unit]
Description=ODS DPMS Enforcement (Layer 5a - periodic sleep prevention)

[Service]
Type=oneshot
User=root
Environment=DISPLAY=:0
ExecStart=/bin/bash -c "xset -dpms; xset s off; xset s noblank; xdotool key ctrl 2>/dev/null || true"
EOF

    cat > /etc/systemd/system/ods-dpms-enforce.timer << 'EOF'
[Unit]
Description=Enforce DPMS off every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

    # --- ods-display-config.service (Upgrade B: dual-monitor + portrait) ---
    cat > /etc/systemd/system/ods-display-config.service << 'EOF'
[Unit]
Description=ODS Display Configuration (xrandr)
After=ods-player-ATLAS.service

[Service]
Type=oneshot
User=root
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/ods-display-config.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

    # --- ods-hide-tty.service ---
    cat > /etc/systemd/system/ods-hide-tty.service << 'EOF'
[Unit]
Description=Hide TTY1 text (player mode)
DefaultDependencies=no
After=local-fs.target
Before=getty@tty1.service ods-player-ATLAS.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hide-tty.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

    # --- ods-shutdown-splash.service ---
    cat > /etc/systemd/system/ods-shutdown-splash.service << 'EOF'
[Unit]
Description=ODS Plymouth Shutdown Splash Hold
DefaultDependencies=no
Before=systemd-poweroff.service systemd-reboot.service systemd-halt.service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "plymouth show-splash 2>/dev/null || true; sleep 4"
TimeoutStartSec=10
RemainAfterExit=yes

[Install]
WantedBy=poweroff.target reboot.target halt.target
EOF
    # --- ods-enrollment-retry.service (Issue #5 fix: persistent enrollment) ---
    # Adapted from legacy ods_esper_mgr.sh enrollment persistence pattern
    cat > /etc/systemd/system/ods-enrollment-retry.service << 'EOF'
[Unit]
Description=ODS Enrollment Retry (Issue #5 - persistent cloud registration)
After=network-online.target ods-webserver.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ ! -f /var/lib/ods/enrollment.flag ]; then curl -s -X POST http://localhost:8080/api/enroll | tee -a /var/log/ods-enrollment.log; fi'
EOF

    cat > /etc/systemd/system/ods-enrollment-retry.timer << 'EOF'
[Unit]
Description=Retry ODS Cloud enrollment every 30 minutes until registered

[Timer]
OnBootSec=120
OnUnitActiveSec=1800

[Install]
WantedBy=timers.target
EOF

    # Create /var/lib/ods/ for enrollment state (owned by signage — server.js writes here)
    mkdir -p /var/lib/ods
    chown signage:signage /var/lib/ods

    # Enable all services
    systemctl daemon-reload
    systemctl enable ods-player-ATLAS.service
    systemctl enable ods-webserver.service
    systemctl enable ods-health-monitor.service
    systemctl enable ods-plymouth-hold.service
    systemctl enable ods-hide-tty.service
    systemctl enable ods-shutdown-splash.service
    systemctl enable ods-dpms-enforce.timer
    systemctl enable ods-display-config.service
    systemctl enable ods-enrollment-retry.timer

    log "  ✅ All 9 services deployed and enabled"
}

# ─── Step 6: Deploy Player Scripts ─────────────────────────────────────────

deploy_player_scripts() {
    log "🖥️  Step 6: Deploying player scripts (ATLAS)..."

    local REPO_SCRIPTS="/tmp/atlas_repo/scripts"

    # --- start-player-ATLAS.sh (--app mode for overlay compatibility) ---
    cat > /usr/local/bin/start-player-ATLAS.sh << 'SCRIPT'
#!/bin/bash
# ODS Player OS ATLAS — Start Player
# Uses --app mode so overlay can stay above
# Openbox handles maximization and decoration removal
export DISPLAY=:0
export HOME=/home/signage

xhost +local: 2>/dev/null || true
chown -R signage:signage /home/signage/.config/chromium 2>/dev/null
rm -f /home/signage/.config/chromium/SingletonLock 2>/dev/null

exec chromium --no-sandbox \
  --app="http://localhost:8080/network_setup.html" \
  --start-maximized \
  --noerrdialogs \
  --disable-infobars \
  --disable-translate \
  --no-first-run \
  --disable-features=TranslateUI \
  --disable-session-crashed-bubble \
  --disable-component-update \
  --check-for-update-interval=31536000 \
  --autoplay-policy=no-user-gesture-required \
  --force-device-scale-factor=${ODS_SCALE:-1} \
  --remote-debugging-port=9222 \
  --password-store=basic \
  --credentials-enable-service=false \
  --disable-save-password-bubble \
  --disable-autofill-keyboard-accessory-view \
  --default-background-color=000000 \
  --force-dark-mode \
  --disable-gpu-compositing
SCRIPT
    chmod +x /usr/local/bin/start-player-ATLAS.sh

    # --- Chromium managed policy (suppresses password popup + autofill) ---
    mkdir -p /etc/chromium/policies/managed
    cat > /etc/chromium/policies/managed/ods-player-ATLAS.json << 'EOF'
{
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "ImportSavedPasswords": false,
  "CredentialProviderPromoEnabled": false,
  "BrowserSignin": 0,
  "CommandLineFlagSecurityWarningsEnabled": false
}
EOF
    log "  ✅ Chromium managed policy deployed"

    # --- ods-player-boot-wrapper.sh ---
    # Copy from repo scripts/ instead of inline heredoc for maintainability
    if [ -f "$REPO_SCRIPTS/ods-player-boot-wrapper.sh" ]; then
        cp "$REPO_SCRIPTS/ods-player-boot-wrapper.sh" /usr/local/bin/ods-player-boot-wrapper.sh
        log "  ✅ ods-player-boot-wrapper.sh deployed (from repo)"
    else
        log "  ⚠️  ods-player-boot-wrapper.sh not found in repo"
    fi
    chmod +x /usr/local/bin/ods-player-boot-wrapper.sh


    # --- ods-phase-selector.sh (Phase 2/3 boot gate) ---
    cat > /usr/local/bin/ods-phase-selector.sh << 'SCRIPT'
#!/bin/bash
# ODS Phase Selector — Gates between Phase 2 (enrollment) and Phase 3 (production)
ENROLLED_FLAG="/etc/ods/esper_enrolled.flag"
LOG="/home/signage/ODS/logs/boot/phase_selector.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [PHASE] $1" | tee -a "$LOG"; }
if [ -f "$ENROLLED_FLAG" ]; then
    log "Phase 3: Enrolled flag found — launching production boot"
    exec /usr/local/bin/ods-player-boot-wrapper.sh
else
    log "Phase 2: No enrolled flag — launching enrollment boot"
    exec /usr/local/bin/ods-enrollment-boot.sh
fi
SCRIPT
    chmod +x /usr/local/bin/ods-phase-selector.sh
    log "  ✅ ods-phase-selector.sh deployed"

    # --- ods-enrollment-boot.sh (Phase 2: sealed splash enrollment) ---
    if [ -f "$REPO_SCRIPTS/ods-enrollment-boot.sh" ]; then
        cp "$REPO_SCRIPTS/ods-enrollment-boot.sh" /usr/local/bin/ods-enrollment-boot.sh
        log "  ✅ ods-enrollment-boot.sh deployed (from repo)"
    fi
    chmod +x /usr/local/bin/ods-enrollment-boot.sh 2>/dev/null || true

    # --- Enrollment state directory ---
    mkdir -p /etc/ods
    echo 0 > /etc/ods/enrollment_attempts

    # --- hide-tty.sh ---
    cat > /usr/local/bin/hide-tty.sh << 'SCRIPT'
#!/bin/bash
# Completely suppress tty1 output to prevent ANSI escape leaks
exec > /dev/tty1 2>&1
stty -echo -F /dev/tty1 2>/dev/null || true
setterm --foreground black --background black --cursor off > /dev/tty1 2>/dev/null || true
printf "\033[2J\033[H" > /dev/tty1 2>/dev/null || true
printf "\033[?25l" > /dev/tty1 2>/dev/null || true
SCRIPT
    chmod +x /usr/local/bin/hide-tty.sh

    # --- ods-auth-check.sh (Admin auth via su/PAM — yescrypt compatible) ---
    # Python crypt+spwd removed in 3.13. openssl doesn't support yescrypt ($y$).
    # su uses PAM which natively handles yescrypt. Tested working on live device.
    cat > /usr/local/bin/ods-auth-check.sh << 'SCRIPT'
#!/bin/bash
# ODS Admin Auth — validates credentials via su (PAM-native, yescrypt-safe)
USER="$1"; PASS="$2"
[ -z "$USER" ] || [ -z "$PASS" ] && { echo "FAIL"; exit 1; }
# su invokes PAM which handles any hash algorithm including yescrypt ($y$)
if echo "$PASS" | su -c "echo OK" "$USER" 2>/dev/null | grep -q "^OK$"; then
    echo "OK"
else
    echo "FAIL"
fi
SCRIPT
    chmod +x /usr/local/bin/ods-auth-check.sh
    # Allow signage user to run auth check as root (needed to read /etc/shadow)
    echo "signage ALL=(root) NOPASSWD: /usr/local/bin/ods-auth-check.sh" > /etc/sudoers.d/ods-auth
    chmod 440 /etc/sudoers.d/ods-auth

    # --- ods-hostname.sh (MAC-based three-word hostname generator) ---
    cat > /usr/local/bin/ods-hostname.sh << 'SCRIPT'
#!/bin/bash
# ODS Three-Word Hostname — deterministic MAC-to-words encoding
# 256 words × 3 positions = 16,777,216 unique devices
# Usage: ods-hostname.sh [generate|decode <name>]
WORDS=(
  # 0-63: Adjectives
  brave bold calm cool dart dawn deep dusk echo fair fast firm fond free
  glad gold good glow halt haze high huge idle iron jade jolly keen kind
  last lean live long loud lush mint mild moon near neat next nice nova
  open orca pace palm peak pine play plum pure quad rain rare real rich
  # 64-127: Colors & Nature
  ruby safe sage sand silk slim snow soft solo star stem sure tame teal
  tide tiny trek true tune vale vast vine warm wave west wild wind wise
  zero aqua ashe bark beam blue bone clay coal cyan dune fawn fern flax
  foam grey husk iced iris jade kelp lake lava leaf lime lynx malt marl
  # 128-191: Animals & Objects
  mesa mint moss navy neon oaks opal palm pear pine pink plum pond reed
  reef rose rust sage sand silk snow teak twig vine wren yarn zinc acorn
  amber azure bloom brass cedar cherry cloud coral crane crest crown dart
  delta drift ember flame frost gleam grain grove haven helix ivory jewel
  # 192-255: More Nature & Friendly
  knoll lapis lilac lunar maple marsh meadow mirth north ocean olive pearl
  petal prism quail ridge river robin shell shore spark steam stone storm
  swift thorn torch trail tulip vapor vivid waltz wheat whirl aspen birch
  bliss cedar charm clover crystal dahlia forest garden gentle harbor haven
)

get_mac_bytes() {
    # Get primary interface MAC, return last 3 bytes as decimal
    local mac=$(ip link show 2>/dev/null | grep -A1 'state UP' | grep ether | head -1 | awk '{print $2}')
    if [ -z "$mac" ]; then
        mac=$(cat /sys/class/net/eth0/address 2>/dev/null || cat /sys/class/net/end0/address 2>/dev/null || echo "00:00:00:00:00:00")
    fi
    # Take last 3 bytes
    local b1=$(echo "$mac" | cut -d: -f4)
    local b2=$(echo "$mac" | cut -d: -f5)
    local b3=$(echo "$mac" | cut -d: -f6)
    echo "$((16#$b1)) $((16#$b2)) $((16#$b3))"
}

case "${1:-generate}" in
    generate)
        read -r b1 b2 b3 <<< "$(get_mac_bytes)"
        echo "${WORDS[$b1]}-${WORDS[$b2]}-${WORDS[$b3]}"
        ;;
    decode)
        # Reverse: name → MAC bytes
        IFS='-' read -r w1 w2 w3 <<< "$2"
        for i in "${!WORDS[@]}"; do
            [ "${WORDS[$i]}" = "$w1" ] && b1=$i
            [ "${WORDS[$i]}" = "$w2" ] && b2=$i
            [ "${WORDS[$i]}" = "$w3" ] && b3=$i
        done
        printf "xx:xx:xx:%02x:%02x:%02x\n" "$b1" "$b2" "$b3"
        ;;
    mac)
        get_mac_bytes
        ;;
esac
SCRIPT
    chmod +x /usr/local/bin/ods-hostname.sh

    # --- .xprofile (Issue #4 fix: Layer 4 — login persistence) ---
    cat > /home/signage/.xprofile << 'XPROFILE'
# ODS Sleep Prevention (Layer 4 - login persistence)
# Adapted from legacy ods_power_mgr.sh
xset s off
xset s noblank
xset -dpms
XPROFILE
    chown signage:signage /home/signage/.xprofile
    log "  ✅ Layer 4 .xprofile deployed"

    # --- ods-display-config.sh (Upgrade B: dual-monitor + portrait) ---
    cat > /usr/local/bin/ods-display-config.sh << 'SCRIPT'
#!/bin/bash
# ODS Display Configuration — reads layout JSON, applies xrandr
export DISPLAY=:0
CONFIG_DIR="/home/signage/ODS/config/layout"
CURRENT_MODE=$(cat "$CONFIG_DIR/.current_mode" 2>/dev/null || echo "single_hd_landscape")

CONFIG_FILE="$CONFIG_DIR/ods_mode_${CURRENT_MODE}.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[DISPLAY] No config for mode $CURRENT_MODE, defaulting to single screen"
    exit 0
fi

# Read orientation from config
ORIENTATION=$(jq -r '.monitor_config.orientation // "landscape"' "$CONFIG_FILE")
NUM_SCREENS=$(jq -r '.windows | length' "$CONFIG_FILE")

echo "[DISPLAY] Mode: $CURRENT_MODE, Orientation: $ORIENTATION, Screens: $NUM_SCREENS"

# Apply xrandr based on config
case "$ORIENTATION" in
    portrait)
        xrandr --output HDMI-1 --mode 1920x1080 --rotate left 2>/dev/null || true
        if [ "$NUM_SCREENS" -ge 2 ]; then
            xrandr --output HDMI-2 --mode 1920x1080 --rotate left --right-of HDMI-1 2>/dev/null || true
        fi
        ;;
    landscape|*)
        xrandr --output HDMI-1 --mode 1920x1080 --rotate normal 2>/dev/null || true
        if [ "$NUM_SCREENS" -ge 2 ]; then
            xrandr --output HDMI-2 --mode 1920x1080 --rotate normal --right-of HDMI-1 2>/dev/null || true
        fi
        ;;
esac
echo "[DISPLAY] xrandr configuration applied"
SCRIPT
    chmod +x /usr/local/bin/ods-display-config.sh

    # --- Openbox config (maximized, no decorations) ---
    mkdir -p /etc/ods
    cat > /etc/ods/openbox-rc.xml << 'OBXML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>0</strength></resistance>
  <focus><followMouse>no</followMouse></focus>
  <placement><policy>Smart</policy></placement>
  <desktops><number>1</number></desktops>

  <!-- No decorations on any window by default (player mode) -->
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>yes</maximized>
    </application>
    <!-- Boot overlay: fullscreen, always above Chromium -->
    <application title="BOOT_OVERLAY">
      <decor>no</decor>
      <maximized>yes</maximized>
      <layer>above</layer>
      <fullscreen>yes</fullscreen>
    </application>
    <!-- Admin terminal: decorated, always-on-top, centered -->
    <application class="XTerm" title="ODS Admin*">
      <decor>yes</decor>
      <maximized>no</maximized>
      <layer>above</layer>
      <size><width>800</width><height>600</height></size>
      <position force="yes"><x>center</x><y>center</y></position>
    </application>
  </applications>

  <!-- No keybindings (all keyboard handled by Chromium JavaScript) -->
  <keyboard/>
  <mouse/>
</openbox_config>
OBXML
    log "  ✅ Openbox config deployed to /etc/ods/openbox-rc.xml"

    # --- Display layout configs (Upgrade B: initial modes) ---
    mkdir -p /home/signage/ODS/config/layout
    cat > /home/signage/ODS/config/layout/ods_mode_single_hd_landscape.json << 'LJSON'
{
  "mode": "single_hd_landscape",
  "description": "Single HD monitor, landscape, 1 fullscreen Chromium",
  "windows": [
    { "screen": 0, "position": "fullscreen", "url": "http://localhost:8080/network_setup.html" }
  ],
  "monitor_config": {
    "orientation": "landscape",
    "mapping": { "screen_0": "HDMI-1" }
  }
}
LJSON
    cat > /home/signage/ODS/config/layout/ods_mode_single_hd_portrait.json << 'LJSON'
{
  "mode": "single_hd_portrait",
  "description": "Single HD monitor, portrait (rotated left)",
  "windows": [
    { "screen": 0, "position": "fullscreen", "url": "http://localhost:8080/network_setup.html" }
  ],
  "monitor_config": {
    "orientation": "portrait",
    "mapping": { "screen_0": "HDMI-1" }
  }
}
LJSON
    cat > /home/signage/ODS/config/layout/ods_mode_dual_hd_landscape.json << 'LJSON'
{
  "mode": "dual_hd_landscape",
  "description": "Dual HD monitors, landscape, 1 Chromium per screen",
  "windows": [
    { "screen": 0, "position": "fullscreen", "url": "http://localhost:8080/network_setup.html" },
    { "screen": 1, "position": "fullscreen", "url": "http://localhost:8080/network_setup.html" }
  ],
  "monitor_config": {
    "orientation": "landscape",
    "mapping": { "screen_0": "HDMI-1", "screen_1": "HDMI-2" }
  }
}
LJSON
    echo "single_hd_landscape" > /home/signage/ODS/config/layout/.current_mode
    chown -R signage:signage /home/signage/ODS/config
    log "  ✅ Display layout configs deployed (3 modes)"

    log "  ✅ Player scripts deployed (Openbox + 4-layer sleep prevention)"
}

# ─── Step 7: Install Plymouth ODS Theme ────────────────────────────────────

deploy_plymouth() {
    log "🎨 Step 7: Installing Plymouth ODS theme (v8-2-0-FLASH 4K premium splash)..."

    local THEME_DIR="/usr/share/plymouth/themes/ods"
    local REPO_ASSETS="/tmp/atlas_repo/brand/splash/generated"

    # Create theme directory
    mkdir -p "$THEME_DIR"

    # ── Copy ALL pre-generated splash assets from repo ────────────────────
    # Single source of truth: brand/splash/generated/
    # Contains: throbbers, watermark, splash animations, FBI bridge frames,
    #           overlay frames, enrollment frames, Plymouth config
    if [ -d "$REPO_ASSETS" ]; then
        cp "$REPO_ASSETS"/*.png "$THEME_DIR/" 2>/dev/null || true
        cp "$REPO_ASSETS"/*.plymouth "$THEME_DIR/" 2>/dev/null || true
        # Copy pre-built raw files too (saves ~2min of on-device conversion)
        cp "$REPO_ASSETS"/*.raw "$THEME_DIR/" 2>/dev/null || true
        local png_count=$(ls "$THEME_DIR"/*.png 2>/dev/null | wc -l)
        local raw_count=$(ls "$THEME_DIR"/*.raw 2>/dev/null | wc -l)
        log "  ✅ $png_count PNGs + $raw_count pre-built RAWs copied from brand/splash/generated/"
    else
        log "  ⚠️  Splash assets not found at $REPO_ASSETS"
    fi

    # ── Convert framebuffer PNGs to RGB565 raw ────────────────────────────
    # The FBI bridge and enrollment animations write raw RGB565 to /dev/fb0.
    # PNGs are stored in git; raw conversion happens here (fast, ~2min total).
    if command -v convert &>/dev/null && command -v python3 &>/dev/null; then
        log "  → Converting framebuffer PNGs to RGB565 raw..."
        local raw_count=0
        for png in "$THEME_DIR"/fbi_boot_*.png "$THEME_DIR"/enroll_fbi_*.png \
                   "$THEME_DIR"/enroll_progress_*.png "$THEME_DIR"/enroll_success.png \
                   "$THEME_DIR"/enroll_retry_*.png "$THEME_DIR"/enroll_downloading.png \
                   "$THEME_DIR"/enroll_support.png; do
            if [ -f "$png" ]; then
                local raw="${png%.png}.raw"
                convert "$png" -depth 8 rgb:- | python3 -c "
import sys
data=sys.stdin.buffer.read()
out=bytearray()
for i in range(0,len(data),3):
    r,g,b=data[i],data[i+1],data[i+2]
    rgb565=((r>>3)<<11)|((g>>2)<<5)|(b>>3)
    out.extend(rgb565.to_bytes(2,byteorder='little'))
sys.stdout.buffer.write(out)" > "$raw"
                raw_count=$((raw_count + 1))
            fi
        done
        log "  ✅ $raw_count PNGs converted to RGB565 raw"
    else
        log "  ⚠️  ImageMagick or python3 not found — skipping RGB565 conversion"
    fi

    # Create theme config
    cat > /usr/share/plymouth/themes/ods/ods.plymouth << 'EOF'
[Plymouth Theme]
Name=Otter Digital Signage
Description=Otter Digital Signage Landscape Boot Theme
ModuleName=two-step

[two-step]
Font=DejaVu Sans Bold 15
TitleFont=DejaVu Sans Mono Bold 30
ImageDir=/usr/share/plymouth/themes/ods
DialogHorizontalAlignment=.5
DialogVerticalAlignment=.7
TitleHorizontalAlignment=.5
TitleVerticalAlignment=.5
HorizontalAlignment=.5
VerticalAlignment=.90
WatermarkHorizontalAlignment=.5
WatermarkVerticalAlignment=.5
Transition=none
TransitionDuration=0.0
BackgroundStartColor=0x000000
BackgroundEndColor=0x000000
ProgressBarBackgroundColor=0x606060
ProgressBarForegroundColor=0xffffff
DialogClearsFirmwareBackground=false
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false
UseFirmwareBackground=false

[shutdown]
UseEndAnimation=false
UseFirmwareBackground=false

[reboot]
UseEndAnimation=false
UseFirmwareBackground=false

[updates]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Installing Updates...
_Title=Installing Updates...
SubTitle=Do not turn off your computer
_SubTitle=Do not turn off your computer

[system-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading System...
_Title=Upgrading System...
SubTitle=Do not turn off your computer
_SubTitle=Do not turn off your computer

[firmware-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading Firmware...
_Title=Upgrading Firmware...
SubTitle=Do not turn off your computer
_SubTitle=Do not turn off your computer
EOF

    # Set as default theme
    cat > /etc/plymouth/plymouthd.conf << 'EOF'
[Daemon]
Theme=ods
ShowDelay=0
DeviceTimeout=8
EOF

    # Rebuild initramfs with the theme
    update-initramfs -u 2>&1 | tee -a "$LOG_FILE" || true

    log "  ✅ Plymouth ODS theme installed"
}

# ─── Step 8: Configure Kernel Cmdline & Sleep Prevention ──────────────────

configure_boot() {
    log "🔧 Step 8: Configuring boot parameters & sleep prevention..."

    # Disable VT switching — prevents Ctrl+Alt+Fn from opening white TTY pages
    # This also fixes the white flash during splash→player transition
    log "  → Disabling VT switching (prevents white TTY flash)..."
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-no-vtswitch.conf << 'XORGCFG'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "DontZap"      "true"
EndSection
XORGCFG
    log "  ✅ VT switching disabled (Xorg config + -novtswitch flag)"

    # RPi5 uses /boot/firmware/cmdline.txt (not armbianEnv.txt) for kernel params
    # This is the REAL boot config — armbianEnv.txt extraargs are NOT applied on RPi
    if [ -f /boot/firmware/cmdline.txt ]; then
        log "  → Patching /boot/firmware/cmdline.txt (RPi boot config)..."
        local cmdline
        cmdline=$(cat /boot/firmware/cmdline.txt)

        # Add splash quiet if not present
        if ! echo "$cmdline" | grep -q "splash"; then
            cmdline="$cmdline splash quiet"
        fi
        # Add plymouth.ignore-serial-consoles
        if ! echo "$cmdline" | grep -q "plymouth.ignore-serial-consoles"; then
            cmdline="$cmdline plymouth.ignore-serial-consoles"
        fi
        # Add consoleblank=0
        if ! echo "$cmdline" | grep -q "consoleblank=0"; then
            cmdline="$cmdline consoleblank=0"
        fi
        # Add vt.global_cursor_default=0
        if ! echo "$cmdline" | grep -q "vt.global_cursor_default=0"; then
            cmdline="$cmdline vt.global_cursor_default=0"
        fi
        # Suppress systemd [OK] boot messages
        if ! echo "$cmdline" | grep -q "systemd.show_status"; then
            cmdline="$cmdline systemd.show_status=false"
        fi
        # Upgrade loglevel to 0 (completely silent — no kernel output at all)
        cmdline=$(echo "$cmdline" | sed 's/loglevel=[0-9]*/loglevel=0/')

        echo "$cmdline" > /boot/firmware/cmdline.txt
        log "  ✅ /boot/firmware/cmdline.txt updated"
    fi

    # Also update armbianEnv.txt if it exists (belt-and-suspenders)
    if [ -f /boot/armbianEnv.txt ]; then
        if grep -q "^extraargs=" /boot/armbianEnv.txt; then
            sed -i 's/^extraargs=.*/extraargs=cma=256M splash quiet loglevel=3 plymouth.ignore-serial-consoles consoleblank=0 vt.global_cursor_default=0/' /boot/armbianEnv.txt
        else
            echo "extraargs=cma=256M splash quiet loglevel=3 plymouth.ignore-serial-consoles consoleblank=0 vt.global_cursor_default=0" >> /boot/armbianEnv.txt
        fi
        log "  ✅ armbianEnv.txt updated (fallback)"
    fi

    # Mask ALL getty services (tty1-6) — prevents login prompts and white TTY pages
    log "  → Masking getty@tty1-6 (no login sessions on any VT)..."
    for i in 1 2 3 4 5 6; do
        systemctl disable getty@tty${i}.service 2>/dev/null || true
        systemctl mask getty@tty${i}.service 2>/dev/null || true
    done
    log "  ✅ getty@tty1-6 masked"

    # Disable SysRq key — prevents kernel-level VT switching and debug shortcuts
    log "  → Disabling SysRq key..."
    cat > /etc/sysctl.d/99-no-vtswitch.conf << 'SYSCTL'
kernel.sysrq = 0
SYSCTL
    sysctl -p /etc/sysctl.d/99-no-vtswitch.conf 2>/dev/null || true
    log "  ✅ SysRq disabled"

    # Fix shutdown/reboot splash — remove getty@tty1 from After= (we masked it)
    log "  → Fixing plymouth-poweroff/reboot service dependencies..."
    mkdir -p /etc/systemd/system/plymouth-poweroff.service.d
    cat > /etc/systemd/system/plymouth-poweroff.service.d/no-getty.conf << 'OVERRIDE'
[Unit]
After=plymouth-start.service
OVERRIDE
    mkdir -p /etc/systemd/system/plymouth-reboot.service.d
    cat > /etc/systemd/system/plymouth-reboot.service.d/no-getty.conf << 'OVERRIDE'
[Unit]
After=plymouth-start.service
OVERRIDE
    log "  ✅ plymouth-poweroff/reboot dependencies fixed"

    # Disable ALL sleep/suspend/hibernate
    log "  → Disabling sleep/suspend/hibernate..."
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

    # Logind: ignore all sleep/lid triggers
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/no-sleep.conf << 'LOGIND'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
LOGIND
    log "  ✅ Sleep/hibernate fully disabled"
}

# ─── Step 9: Enroll Esper MDM ──────────────────────────────────────────────

enroll_esper() {
    log "📱 Step 9: Enrolling with Esper MDM..."
    log "  Tenant: $ESPER_TENANT"

    cd /tmp
    if curl -sS https://artifacthub.esper.cloud/linux/scripts/prod/setup.sh -o setup.sh 2>&1 | tee -a "$LOG_FILE"; then
        chmod +x setup.sh
        bash ./setup.sh \
            --tenant "$ESPER_TENANT" \
            --token "$ESPER_TOKEN" \
            --blueprint "$ESPER_BLUEPRINT" \
            --group "$ESPER_GROUP" 2>&1 | tee -a "$LOG_FILE" || true
        rm -f setup.sh
        log "  ✅ Esper enrollment complete"
    else
        log "  ⚠️  Esper enrollment failed — can be retried manually"
    fi
}

# ─── Step 10a: Configure RustDesk (Phase 2 — key config only) ──────────────

configure_rustdesk() {
    log "🔧 Step 10a: Configuring RustDesk relay keys..."

    # Configure relay server (binary already installed in Phase 1)
    for dir in /root/.config/rustdesk /home/otter/.config/rustdesk /home/signage/.config/rustdesk /opt/rustdesk; do
        mkdir -p "$dir"
        cat > "$dir/RustDesk2.toml" << EOF
rendezvous_server = '${RUSTDESK_RELAY}:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '${RUSTDESK_RELAY}'
relay-server = '${RUSTDESK_RELAY}'
api-server = 'http://${RUSTDESK_RELAY}:21118'
key = '${RUSTDESK_KEY}'
EOF
        cat > "$dir/RustDesk.toml" << EOF
password = '${RUSTDESK_PASSWORD}'
salt = '3phd4z'
key_confirmed = true

[keys_confirmed]
"${RUSTDESK_RELAY}:21116" = true
EOF
    done

    # Fix ownership
    chown -R root:root /root/.config/rustdesk/ /opt/rustdesk/ 2>/dev/null || true
    chown -R otter:otter /home/otter/.config/rustdesk/ 2>/dev/null || true
    chown -R signage:signage /home/signage/.config/rustdesk/ 2>/dev/null || true

    # Restart RustDesk service to pick up new config
    systemctl restart rustdesk 2>/dev/null || true
    systemctl restart ods-rustdesk-enterprise 2>/dev/null || true

    log "  ✅ RustDesk relay keys configured"
}

# ─── Step 10: Install RustDesk ─────────────────────────────────────────────

install_rustdesk() {
    log "🔧 Step 10: Installing RustDesk remote access..."

    cd /tmp

    # Download ARM64 package
    log "  → Downloading RustDesk ${RUSTDESK_VERSION}..."
    if wget -q -O rustdesk.deb "https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-aarch64.deb" 2>&1; then
        log "  ✅ Download complete"
    else
        log "  ⚠️  RustDesk download failed — skipping"
        return 0
    fi

    # Install
    dpkg -i rustdesk.deb 2>/dev/null || true
    apt-get install -f -y 2>&1 | tee -a "$LOG_FILE" || true
    rm -f rustdesk.deb

    # Configure relay server
    for dir in /root/.config/rustdesk /home/otter/.config/rustdesk /home/signage/.config/rustdesk /opt/rustdesk; do
        mkdir -p "$dir"
        cat > "$dir/RustDesk2.toml" << EOF
rendezvous_server = '${RUSTDESK_RELAY}:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '${RUSTDESK_RELAY}'
relay-server = '${RUSTDESK_RELAY}'
api-server = 'http://${RUSTDESK_RELAY}:21118'
key = '${RUSTDESK_KEY}'
EOF
        cat > "$dir/RustDesk.toml" << EOF
password = '${RUSTDESK_PASSWORD}'
salt = '3phd4z'
key_confirmed = true

[keys_confirmed]
"${RUSTDESK_RELAY}:21116" = true
EOF
    done

    # Fix ownership
    chown -R root:root /root/.config/rustdesk/ /opt/rustdesk/ 2>/dev/null || true
    chown -R otter:otter /home/otter/.config/rustdesk/ 2>/dev/null || true
    chown -R signage:signage /home/signage/.config/rustdesk/ 2>/dev/null || true

    # Create systemd service
    cat > /opt/rustdesk/rustdesk_system_wrapper.sh << 'EOF'
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/0
while ! pgrep -x "Xorg\|X" >/dev/null 2>&1; do
    sleep 2
done
exec /usr/bin/rustdesk --service
EOF
    chmod +x /opt/rustdesk/rustdesk_system_wrapper.sh

    cat > /etc/systemd/system/ods-rustdesk-enterprise.service << 'EOF'
[Unit]
Description=ODS Enterprise Remote Access (RustDesk System Service)
After=network-online.target ods-player-ATLAS.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rustdesk
ExecStart=/opt/rustdesk/rustdesk_system_wrapper.sh
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ods-rustdesk-enterprise.service

    log "  ✅ RustDesk installed and configured"
}

# ─── Step 11: Finalize ─────────────────────────────────────────────────────

finalize_phase1() {
    log "🏁 Phase 1 complete — preparing for clone"

    # Set Phase 2 marker — next boot will run device-specific enrollment
    mkdir -p /var/lib/ods
    echo "2" > /var/lib/ods/phase

    # ODS gate file is already present (created by inject_atlas.sh)
    # Verify it exists for Phase 2
    if [ ! -f /var/lib/ods/atlas_firstboot_pending ]; then
        touch /var/lib/ods/atlas_firstboot_pending
        log "  ⚠️  Gate file was missing — recreated"
    fi
    log "  ✅ ODS gate file verified for Phase 2"

    # Clear machine-id so each cloned device generates a unique one
    echo "" > /etc/machine-id
    rm -f /var/lib/dbus/machine-id 2>/dev/null || true
    log "  ✅ Machine-ID cleared (unique per clone)"

    # Re-enable armbian-resize-filesystem for clones
    # This service expands the rootfs partition to fill the entire SD card.
    # It's one-shot + self-deleting: it ran during this Phase 1 boot and
    # removed its own symlink from basic.target.wants. When we shrink + dd
    # this image into a clone, the clone boots with a stuck 4G partition
    # unless the service is re-enabled. This re-enable ensures every clone
    # auto-expands on first boot without manual intervention.
    mkdir -p /etc/systemd/system/basic.target.wants
    ln -sf /lib/systemd/system/armbian-resize-filesystem.service \
        /etc/systemd/system/basic.target.wants/
    log "  ✅ Filesystem resize re-enabled (clones will auto-expand)"

    # Clean up cloned repo (saves ~100MB on cloned image)
    rm -rf /tmp/atlas_repo

    # Copy log to persistent location
    cp "$LOG_FILE" /home/signage/ODS/logs/atlas_phase1.log 2>/dev/null || true

    log "  ✅ Phase marker set (/var/lib/ods/phase = 2)"
    log "  ✅ Firstboot service remains enabled (Phase 2 will run on next boot)"
    log ""
    log "  ╔══════════════════════════════════════════════════════╗"
    log "  ║   GOLDEN IMAGE READY — Clone this SD card now!      ║"
    log "  ║   System will shut down in 5 seconds.               ║"
    log "  ║                                                     ║"
    log "  ║   Next boot: Esper + RustDesk enrollment (Phase 2)  ║"
    log "  ╚══════════════════════════════════════════════════════╝"
    log ""
    sleep 5
    shutdown -h now
}

finalize_phase2() {
    log "🏁 Phase 2 complete — device enrolled"

    # Disable firstboot service — no more phases needed
    systemctl disable atlas-firstboot.service 2>/dev/null || true

    # Remove phase marker and gate file (prevents any future re-runs)
    rm -f /var/lib/ods/phase
    rm -f /var/lib/ods/atlas_firstboot_pending
    log "  ✅ ODS gate file removed (no re-runs)"

    # Copy log to persistent location
    cp "$LOG_FILE" /home/signage/ODS/logs/atlas_phase2.log 2>/dev/null || true

    log "  ✅ Firstboot service disabled (all phases complete)"
    log "🎉 Atlas Player OS — fully enrolled and ready!"
    log "🔄 Rebooting to production player in 5 seconds..."
    sleep 5
    reboot
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    PHASE_FILE="/var/lib/ods/phase"

    if [ -f "$PHASE_FILE" ] && [ "$(cat $PHASE_FILE)" = "2" ]; then
        # ══════════════════════════════════════════════════════════════════
        # PHASE 2: Device-Specific Enrollment (runs on cloned devices)
        # ══════════════════════════════════════════════════════════════════
        setup_console
        log "🚀 ODS Atlas — Phase 2: Device Enrollment"
        log "📋 This device was cloned from the golden image"
        log "💻 Current host: $(hostname)"

        # FIX: Repair dpkg state — Phase 1 shutdown may leave dpkg interrupted
        log "  → Repairing package manager state..."
        dpkg --configure -a 2>/dev/null || true
        apt-get -f install -y 2>/dev/null || true
        log "  ✅ Package manager repaired"

        set_hostname          # Generate unique three-word hostname
        # NOTE: Esper enrollment and RustDesk are now handled by the Phase 2
        # sealed-in-splash boot pipeline (ods-enrollment-boot.sh), NOT firstboot.
        # configure_rustdesk    # Deferred to Phase 2 boot
        # enroll_esper          # Deferred to Phase 2 boot
        finalize_phase2       # Disable service + reboot to production
    else
        # ══════════════════════════════════════════════════════════════════
        # PHASE 1: Full Provisioning (runs once to create golden image)
        # ══════════════════════════════════════════════════════════════════
        setup_console
        log "🚀 ODS Atlas — Phase 1: Golden Image Provisioning"
        log "🔐 Running as: $(whoami) (UID: $EUID)"
        log "💻 Host: $(hostname)"

        bypass_firstlogin
        wait_for_network
        install_packages
        create_users
        deploy_atlas
        deploy_services
        deploy_player_scripts
        deploy_plymouth
        configure_boot
        install_rustdesk      # Install RustDesk binary + deps in Phase 1 (generic, slow)
        finalize_phase1       # Set phase=2 marker + shutdown for cloning
    fi
}

# ─── Safety Checks ──────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root" | tee -a "$LOG_FILE"
    exit 1
fi

if ! touch /var/lib/dpkg/test_access 2>/dev/null; then
    echo "❌ Cannot access package manager" | tee -a "$LOG_FILE"
    exit 1
else
    rm -f /var/lib/dpkg/test_access
fi

main "$@"

