#!/bin/bash

# =============================================================================
# ODS Player OS Atlas — Automated First Boot
# =============================================================================
# Adapted from Legacy: utils/automated_firstboot.sh
# Transforms bare Armbian 26.2.1 trixie into production Player OS Atlas kiosk
# Runs once on first boot via atlas-firstboot.service (systemd oneshot)
# =============================================================================

set -e

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
    log "🔧 Step 1: Bypassing Armbian first-login..."

    # Remove first-login marker
    rm -f /root/.not_logged_in_yet

    # Set root password
    echo "root:$ROOT_PASSWORD" | chpasswd
    log "  ✅ Root password set"

    # Disable Armbian first-login service if present
    systemctl disable armbian-firstlogin 2>/dev/null || true
    systemctl disable armbian-first-run 2>/dev/null || true

    log "  ✅ First-login bypassed"
}

# ─── Step 2: Install Packages ──────────────────────────────────────────────

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

    log "  → apt update..."
    apt-get update -y 2>&1 | tee -a "$LOG_FILE"

    log "  → Installing core packages..."
    apt-get install -y \
        chromium \
        xserver-xorg \
        x11-xserver-utils \
        matchbox-window-manager \
        unclutter \
        plymouth \
        plymouth-themes \
        nodejs \
        npm \
        git \
        curl \
        wget \
        bc \
        dnsutils \
        2>&1 | tee -a "$LOG_FILE"

    log "  ✅ Packages installed"
}

# ─── Step 3: Create Users ──────────────────────────────────────────────────

create_users() {
    log "👥 Step 3: Creating users..."

    # Create signage kiosk user (no password, minimal shell)
    if ! id signage >/dev/null 2>&1; then
        useradd -m -s /bin/bash signage
        passwd -d signage
        log "  ✅ signage user created"
    else
        log "  ℹ️  signage user already exists"
    fi

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

    # --- ods-kiosk.service ---
    cat > /etc/systemd/system/ods-kiosk.service << 'EOF'
[Unit]
Description=ODS Chromium Kiosk (X11 + Chromium)
After=ods-webserver.service ods-plymouth-hold.service
Wants=ods-webserver.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ods-kiosk-wrapper.sh
Restart=always
RestartSec=10
StartLimitIntervalSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
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
After=ods-kiosk.service

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
    cat > /etc/systemd/system/ods-plymouth-hold.service << 'EOF'
[Unit]
Description=ODS Plymouth Hold - Keep splash until kiosk starts
DefaultDependencies=no
After=plymouth-start.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/bin/sleep 15
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=sysinit.target
EOF

    # --- ods-hide-tty.service ---
    cat > /etc/systemd/system/ods-hide-tty.service << 'EOF'
[Unit]
Description=Hide TTY1 text (kiosk mode)
DefaultDependencies=no
After=local-fs.target
Before=getty@tty1.service ods-kiosk.service

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

    # Enable all services
    systemctl daemon-reload
    systemctl enable ods-kiosk.service
    systemctl enable ods-webserver.service
    systemctl enable ods-health-monitor.service
    systemctl enable ods-plymouth-hold.service
    systemctl enable ods-hide-tty.service
    systemctl enable ods-shutdown-splash.service

    log "  ✅ All 6 services deployed and enabled"
}

# ─── Step 6: Deploy Kiosk Scripts ──────────────────────────────────────────

deploy_kiosk_scripts() {
    log "🖥️  Step 6: Deploying kiosk scripts..."

    # --- start-kiosk.sh ---
    cat > /usr/local/bin/start-kiosk.sh << 'SCRIPT'
#!/bin/bash
# ODS Player OS - Start Kiosk (no loader - direct page loading)
export DISPLAY=:0

chromium \
  --no-sandbox \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-translate \
  --no-first-run \
  --disable-features=TranslateUI \
  --disable-session-crashed-bubble \
  --disable-component-update \
  --check-for-update-interval=31536000 \
  --autoplay-policy=no-user-gesture-required \
  --start-fullscreen \
  --force-device-scale-factor=${ODS_SCALE:-1} \
  --remote-debugging-port=9222 \
  --default-background-color=000000 \
  --force-dark-mode \
  "http://localhost:8080/network_setup.html"
SCRIPT
    chmod +x /usr/local/bin/start-kiosk.sh

    # --- ods-kiosk-wrapper.sh ---
    cat > /usr/local/bin/ods-kiosk-wrapper.sh << 'SCRIPT'
#!/bin/bash
# ODS Kiosk Wrapper — direct page loading (no loader iframe)
# Handles: DRM wait → Plymouth deactivate → X start → Chromium → Plymouth quit
LOG_DIR="/home/signage/ODS/logs/boot"
mkdir -p "$LOG_DIR"
BOOT_LOG="$LOG_DIR/boot_$(date +%Y%m%d_%H%M%S).log"

log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23)
    local msg="$ts [WRAPPER] $1"
    echo "$msg" >> "$BOOT_LOG"
    echo "$msg"
}

log "Starting ODS kiosk wrapper..."

# Wait for DRM display
TIMEOUT=30
ELAPSED=0
while [ ! -e /dev/dri/card* ] 2>/dev/null; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "ERROR: DRM device not found after ${TIMEOUT}s"
        break
    fi
done
log "DRM device ready (${ELAPSED}s)"

# ── TTY FLASH FIX ──────────────────────────────────────────────────────
# Paint VT1 completely black BEFORE Plymouth releases DRM.
# Without this, the bare VT1 console (white/grey) flashes briefly
# during the Plymouth→Xorg handoff.
log "Preparing black VT1 for seamless transition..."

# 1) Set VT1 text colors to black-on-black and hide cursor
export TERM=linux
setterm --foreground black --background black --cursor off > /dev/tty1 2>/dev/null || true

# 2) Clear the screen to the new background color (black)
printf '\033[2J\033[H' > /dev/tty1 2>/dev/null || true

# 3) Suppress all console output to VT1
echo 0 > /proc/sys/kernel/printk 2>/dev/null || true
stty -echo -F /dev/tty1 2>/dev/null || true

# 4) Fill framebuffer with black pixels (belt-and-suspenders)
dd if=/dev/zero of=/dev/fb0 bs=65536 count=128 conv=notrunc 2>/dev/null || true

log "VT1 pre-painted black"

# Deactivate Plymouth (releases DRM — VT1 is already black, no flash)
plymouth deactivate 2>/dev/null || true
log "Plymouth deactivated (VT1 is black)"

# Start X on VT1 (same VT — no VT switch needed)
export HOME=/home/signage
Xorg :0 -nolisten tcp -novtswitch -background none vt1 &

# Wait for Xorg to be ready (tight loop instead of fixed sleep)
for i in $(seq 1 40); do
    if xdpyinfo -display :0 >/dev/null 2>&1; then
        break
    fi
    sleep 0.05
done
export DISPLAY=:0

# Paint X root window black immediately
xsetroot -solid "#000000"
log "X server started on VT1, root window black"

# Disable screen blanking/DPMS immediately after X starts
xset -dpms 2>/dev/null || true
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
log "Screen blanking/DPMS disabled"

# Window manager and cursor hide (WHITE FLASH FIX: -use_cursor no)
matchbox-window-manager -use_titlebar no -use_cursor no &
unclutter -idle 0.01 -root &

# Detect screen resolution and set scale
SCREEN_W=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f1)
if [ -z "$SCREEN_W" ] || [ "$SCREEN_W" -eq 0 ] 2>/dev/null; then
    SCREEN_W=1920
fi

if [ "$SCREEN_W" -ge 3000 ]; then
    export ODS_SCALE=2
elif [ "$SCREEN_W" -ge 2000 ]; then
    export ODS_SCALE=1.5
else
    export ODS_SCALE=1
fi
log "Screen width: ${SCREEN_W}, Scale factor: ${ODS_SCALE}"

# Start the kiosk
/usr/local/bin/start-kiosk.sh &
KIOSK_PID=$!
log "Chromium launched (PID: $KIOSK_PID)"

# Wait for page ready signal
SIGNAL_FILE="/tmp/ods-loader-ready"
rm -f "$SIGNAL_FILE"
TIMEOUT=20
ELAPSED=0
log "Waiting for page ready signal..."

while [ ! -f "$SIGNAL_FILE" ]; do
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ $ELAPSED -ge $((TIMEOUT * 2)) ]; then
        log "WARN: Page ready signal not received after ${TIMEOUT}s — forcing transition"
        break
    fi
done

if [ -f "$SIGNAL_FILE" ]; then
    log "Page ready signal received"
fi

# Give Chromium extra time to finish rendering
sleep 2
log "Paint delay complete, starting transition"

# Quit Plymouth — X is already on VT1, no chvt needed
log "TRANSITION: quitting plymouth (X already on VT1)..."
plymouth quit 2>/dev/null || true
log "TRANSITION: plymouth quit. Kiosk active."

# Clean up old boot logs (keep 7 days)
find "$LOG_DIR" -name "boot_*.log" -type f -mtime +7 -delete 2>/dev/null || true

# Wait for kiosk process
wait $KIOSK_PID
log "Kiosk process exited"
SCRIPT
    chmod +x /usr/local/bin/ods-kiosk-wrapper.sh

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

    log "  ✅ Kiosk scripts deployed"
}

# ─── Step 7: Install Plymouth ODS Theme ────────────────────────────────────

deploy_plymouth() {
    log "🎨 Step 7: Installing Plymouth ODS theme..."

    # Create theme directory
    mkdir -p /usr/share/plymouth/themes/ods

    # Copy theme assets from the cloned repo brand/splash/landscape/
    if [ -d "/tmp/atlas_repo/brand/splash/landscape" ]; then
        cp /tmp/atlas_repo/brand/splash/landscape/*.png /usr/share/plymouth/themes/ods/ 2>/dev/null || true
        # Copy throbber animation frames
        if [ -d "/tmp/atlas_repo/brand/splash/landscape/throbber" ]; then
            cp /tmp/atlas_repo/brand/splash/landscape/throbber/*.png /usr/share/plymouth/themes/ods/ 2>/dev/null || true
            log "  ✅ Throbber frames copied"
        fi
        log "  ✅ Plymouth landscape assets copied"
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
TitleVerticalAlignment=.382
HorizontalAlignment=.5
VerticalAlignment=.89
WatermarkHorizontalAlignment=.5
WatermarkVerticalAlignment=.7
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
    # This also fixes the white flash during splash→kiosk transition
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
        # Upgrade loglevel to 3 (suppress verbose kernel output)
        cmdline=$(echo "$cmdline" | sed 's/loglevel=[0-9]*/loglevel=3/')

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
After=network-online.target graphical.target
Wants=network-online.target graphical.target

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
WantedBy=graphical.target multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ods-rustdesk-enterprise.service

    log "  ✅ RustDesk installed and configured"
}

# ─── Step 11: Finalize ─────────────────────────────────────────────────────

finalize() {
    log "🏁 Step 11: Finalizing..."

    # Disable this firstboot service so it doesn't run again
    systemctl disable atlas-firstboot.service 2>/dev/null || true

    # Clean up cloned repo
    rm -rf /tmp/atlas_repo

    # Copy log to persistent location
    cp "$LOG_FILE" /home/signage/ODS/logs/atlas_firstboot.log 2>/dev/null || true

    log "  ✅ Firstboot service disabled"
    log "🎉 Atlas Player OS setup complete!"
    log "🔄 Rebooting to production kiosk in 5 seconds..."
    sleep 5
    reboot
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    setup_console
    log "🚀 ODS Player OS Atlas — Automated First Boot"
    log "🔐 Running as: $(whoami) (UID: $EUID)"
    log "💻 Host: $(hostname)"

    bypass_firstlogin
    install_packages
    create_users
    deploy_atlas
    deploy_services
    deploy_kiosk_scripts
    deploy_plymouth
    configure_boot
    enroll_esper
    install_rustdesk
    finalize
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
