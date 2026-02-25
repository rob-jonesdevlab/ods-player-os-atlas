#!/bin/bash
# ODS Player Boot Wrapper — Premium boot pipeline
# Pipeline: Plymouth (5s) → FBI bridge → "Starting services" (1.5s) → animated overlay "Launching ODS" → Page visible
# DO NOT add set -e — non-zero exits from display/xrandr will kill the wrapper

LOG_DIR="/home/signage/ODS/logs/boot"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/boot_$(date +%Y%m%d_%H%M%S).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [WRAPPER] $1" | tee -a "$LOG_FILE"; }

SPLASH_IMG="/usr/share/plymouth/themes/ods/watermark.png"
ANIM_DIR="/usr/share/plymouth/themes/ods"

# ── STAGE 1: VT BLACKOUT ─────────────────────────────────────────────
log "Starting ODS Player boot wrapper..."

for i in $(seq 1 30); do [ -e /dev/dri/card1 ] && break; sleep 0.1; done
log "DRM device ready"
FB_SIZE=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo "unknown")
FB_BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || echo "unknown")
log "Framebuffer: ${FB_SIZE} @ ${FB_BPP}bpp (simple-framebuffer — Plymouth renders here)"

for tty in /dev/tty1 /dev/tty2 /dev/tty3; do
    printf '\033[2J\033[H\033[?25l' > "$tty" 2>/dev/null || true
    setterm --foreground black --background black --cursor off > "$tty" 2>/dev/null || true
done
dd if=/dev/zero of=/dev/fb0 bs=65536 count=512 conv=notrunc 2>/dev/null || true
log "VT blackout complete"

# ── STAGE 2: PLYMOUTH + FBI BRIDGE ───────────────────────────────────
dmesg -D 2>/dev/null || true
echo 0 > /proc/sys/kernel/printk 2>/dev/null || true
touch /tmp/ods-player-os-starting-ATLAS
sleep 5

# Start fbi bridge animation BEFORE Plymouth quits (seamless transition)
STOP_FBI="/tmp/ods-stop-fbi"
rm -f "$STOP_FBI"
(
    while [ ! -f "$STOP_FBI" ]; do
        dd if="$ANIM_DIR/fbi_boot_1.raw" of=/dev/fb0 bs=65536 2>/dev/null; [ -f "$STOP_FBI" ] && break; sleep 0.20
        dd if="$ANIM_DIR/fbi_boot_2.raw" of=/dev/fb0 bs=65536 2>/dev/null; [ -f "$STOP_FBI" ] && break; sleep 0.25
        dd if="$ANIM_DIR/fbi_boot_3.raw" of=/dev/fb0 bs=65536 2>/dev/null; [ -f "$STOP_FBI" ] && break; sleep 0.25
        dd if="$ANIM_DIR/fbi_boot_4.raw" of=/dev/fb0 bs=65536 2>/dev/null; [ -f "$STOP_FBI" ] && break; sleep 0.30
        dd if="$ANIM_DIR/fbi_boot_5.raw" of=/dev/fb0 bs=65536 2>/dev/null; [ -f "$STOP_FBI" ] && break; sleep 0.35
    done
) &
FBI_ANIM_PID=$!
log "FBI bridge animation started"
FB_SIZE_FBI=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo "unknown")
log "Framebuffer at FBI start: ${FB_SIZE_FBI} (fbi writes raw RGB565 here)"

plymouth quit --retain-splash 2>/dev/null || true
log "Plymouth quit (held 5s) — fbi animation running"

# ── STAGE 3: XORG ────────────────────────────────────────────────────
export HOME=/home/signage
export DISPLAY=:0
Xorg :0 -nolisten tcp -novtswitch vt1 -br &
for i in $(seq 1 120); do
    xdpyinfo -display :0 >/dev/null 2>&1 && break
    sleep 0.05
done
xhost +local: 2>/dev/null || true

# Kill fbi animation — Xorg now owns the display
touch "$STOP_FBI"
kill $FBI_ANIM_PID 2>/dev/null || true
log "Xorg ready — fbi animation stopped"
XORG_RES=$(DISPLAY=:0 xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' || echo "unknown")
log "Xorg display: ${XORG_RES} (DRM modesetting driver)"

# Paint splash on root window immediately
DISPLAY=:0 display -window root "$SPLASH_IMG" 2>/dev/null
log "Root window splash painted"

# ── STAGE 4: "Starting ODS services" ANIMATION (1.5s) ────────────────
for _f in 1 2 3 4 5; do
    DISPLAY=:0 display -window root "$ANIM_DIR/splash_ods_${_f}.png" 2>/dev/null
    sleep 0.3
done
log "Starting ODS services animation complete"

# ── STAGE 5: SETUP (Openbox, config) ─────────────────────────────────
xset -dpms 2>/dev/null || true
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
openbox --config-file /etc/ods/openbox-rc.xml &
unclutter -idle 0.01 -root &
sleep 0.5
/usr/local/bin/ods-display-config.sh 2>/dev/null || true
log "Openbox started"

SCREEN_W=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f1)
[ -z "$SCREEN_W" ] || [ "$SCREEN_W" -eq 0 ] 2>/dev/null && SCREEN_W=1920
if [ "$SCREEN_W" -ge 3000 ]; then
    export ODS_SCALE=2
elif [ "$SCREEN_W" -ge 2000 ]; then
    export ODS_SCALE=1.5
else
    export ODS_SCALE=1
fi
SCREEN_FULL=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' || echo "unknown")
log "Screen: ${SCREEN_W}px (${SCREEN_FULL}), Scale: ${ODS_SCALE}"

export GTK_THEME="Adwaita:dark"
export GTK2_RC_FILES="/usr/share/themes/Adwaita-dark/gtk-2.0/gtkrc"
mkdir -p /home/signage/.config/gtk-3.0
cat > /home/signage/.config/gtk-3.0/settings.ini << 'GTK'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
GTK
log "Config complete"

# ── STAGE 6: ANIMATED OVERLAY + CHROMIUM ─────────────────────────────
rm -f /tmp/ods-loader-ready

# Pre-resize first frame to actual screen resolution, then display
# (4K PNGs must be resized when display runs at 1080p or 2K)
log "Overlay: creating ${SCREEN_FULL:-3840x2160} overlay from 4K frame"
convert "$ANIM_DIR/overlay_launch_1.png" -resize "${SCREEN_FULL:-3840x2160}!" /tmp/overlay_resized.png 2>/dev/null
DISPLAY=:0 display -immutable -title BOOT_OVERLAY \
  -geometry ${SCREEN_FULL:-3840x2160}+0+0 \
  /tmp/overlay_resized.png 2>/dev/null &
OVERLAY_PID=$!
sleep 0.3
OVERLAY_WID=$(DISPLAY=:0 xdotool search --name BOOT_OVERLAY 2>/dev/null | head -1)
[ -n "$OVERLAY_WID" ] && DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
log "Overlay created (PID: $OVERLAY_PID, WID: $OVERLAY_WID, Res: ${SCREEN_FULL})"

# Launch Chromium behind overlay
/usr/local/bin/start-player-ATLAS.sh &
PLAYER_PID=$!
log "Chromium launched behind overlay (PID: $PLAYER_PID)"

# Re-raise overlay
sleep 0.5
[ -n "$OVERLAY_WID" ] && DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
log "Overlay re-raised"

# Animate "Launching OS" on the overlay window
# Pre-resize each frame then display into the existing overlay window
(
    while [ ! -f /tmp/ods-loader-ready ]; do
        for _d in 1 2 3 4 5; do
            [ -f /tmp/ods-loader-ready ] && break 2
            if [ -n "$OVERLAY_WID" ]; then
                DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
                convert "$ANIM_DIR/overlay_launch_${_d}.png" -resize "${SCREEN_FULL:-3840x2160}!" png:- 2>/dev/null | \
                    DISPLAY=:0 display -window "$OVERLAY_WID" - 2>/dev/null
            fi
            sleep 0.4
        done
    done
) &
ANIM_PID=$!
log "Launching OS animation started (on overlay)"

# ── STAGE 7: WAIT FOR PAGE READY ─────────────────────────────────────
TIMEOUT=60
ELAPSED=0
log "Waiting for page ready signal..."

while [ ! -f /tmp/ods-loader-ready ]; do
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ $ELAPSED -ge $((TIMEOUT * 2)) ]; then
        log "WARN: Page ready not received after ${TIMEOUT}s"
        break
    fi
done

[ -f /tmp/ods-loader-ready ] && log "Page ready signal received"

# Wait 1s for page paint to complete
sleep 1
log "Buffer complete — killing overlay"

# Kill overlay — reveal fully-rendered page
kill $OVERLAY_PID 2>/dev/null || true
kill $ANIM_PID 2>/dev/null || true
log "Overlay killed — page visible"

# ── STAGE 8: CLEANUP ─────────────────────────────────────────────────
plymouth quit 2>/dev/null || true
rm -f /tmp/ods-player-os-starting-ATLAS /tmp/ods-loader-ready "$STOP_FBI"
find "$LOG_DIR" -name "boot_*.log" -type f -mtime +7 -delete 2>/dev/null || true
log "Boot pipeline complete."

wait $PLAYER_PID 2>/dev/null
log "Player process exited"

# ── CHROMIUM RESPAWN LOOP ─────────────────────────────────────────
# If Chromium exits (e.g. Ctrl+W or crash), restart it automatically
while true; do
    log "WARN: Chromium exited — respawning in 2s..."
    sleep 2
    /usr/local/bin/start-player-ATLAS.sh &
    PLAYER_PID=$!
    log "Chromium respawned (PID: $PLAYER_PID)"
    wait $PLAYER_PID 2>/dev/null
    log "Chromium exited again"
done
