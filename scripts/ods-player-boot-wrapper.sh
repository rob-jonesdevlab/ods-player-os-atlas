#!/bin/bash
# ODS Player Boot Wrapper — Premium boot pipeline
# Pipeline: Plymouth (5s) → FBI bridge → "Starting services" (1.5s) → animated overlay "Launching ODS" → Page visible
# DO NOT add set -e — non-zero exits from display/xrandr will kill the wrapper

LOG_DIR="/home/signage/ODS/logs/boot"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/boot_$(date +%Y%m%d_%H%M%S).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [WRAPPER] $1" | tee -a "$LOG_FILE"; }

# Visual snapshot helper — captures root window screenshot at each transition
SNAP_DIR="$LOG_DIR/snapshots_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SNAP_DIR"
SNAP_N=0
snap() {
    SNAP_N=$((SNAP_N + 1))
    local label="$1"
    local fname=$(printf "%02d_%s" "$SNAP_N" "$label")
    DISPLAY=:0 import -window root "$SNAP_DIR/${fname}.png" 2>/dev/null &
    local geom=$(DISPLAY=:0 xdpyinfo 2>/dev/null | grep 'dimensions:' | awk '{print $2}' || echo "?")
    log "[SNAP] #${SNAP_N} '${label}' captured (root geom: ${geom})"
}

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

# Paint full-screen splash on root IMMEDIATELY — no delay between FBI kill and splash!
# NOTE: Do NOT use watermark.png here — it's 549x72 and ImageMagick tiles small
# images across the root window, causing a visible flash. Use splash_ods_1.png (1920x1080).
DISPLAY=:0 xsetroot -solid black 2>/dev/null || true
snap "after_fbi_kill_xsetroot"
DISPLAY=:0 display -window root "$ANIM_DIR/splash_ods_1.png" 2>/dev/null
snap "after_splash_paint"
XORG_RES=$(DISPLAY=:0 xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' || echo "unknown")
log "Root window splash painted (${XORG_RES} root, splash=$ANIM_DIR/splash_ods_1.png)"

# ── DIAGNOSTIC: Xorg initial state (non-blocking, after splash is visible) ──
log "[DIAG] xrandr after Xorg start:"
DISPLAY=:0 xrandr 2>/dev/null | grep -E 'connected|\*' | while read -r _line; do log "[DIAG]   $_line"; done
log "[DIAG] Splash asset: $(wc -c < "$SPLASH_IMG" 2>/dev/null || echo 0) bytes, FBI raw: $(wc -c < "$ANIM_DIR/fbi_boot_1.raw" 2>/dev/null || echo 0) bytes"

# ── STAGE 4: "Starting ODS services" ANIMATION (1.5s) ────────────────
for _f in 1 2 3 4 5; do
    DISPLAY=:0 display -window root "$ANIM_DIR/splash_ods_${_f}.png" 2>/dev/null
    sleep 0.3
done
log "Starting ODS services animation complete"
snap "after_services_anim"

# ── STAGE 5: SETUP (Openbox, display config, metrics) ────────────────
DISPLAY=:0 xsetroot -solid black 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
openbox --config-file /etc/ods/openbox-rc.xml &
unclutter -idle 0.01 -root &
sleep 0.5
snap "after_openbox_start"
# Re-blacken after Openbox (it may alter root)
DISPLAY=:0 xsetroot -solid black 2>/dev/null || true
# Apply display config AFTER Openbox (proven e417033 pattern).
/usr/local/bin/ods-display-config.sh 2>/dev/null || true
log "Openbox + display config applied"
snap "after_display_config"
# ── DIAGNOSTIC: xrandr after display config ──
log "[DIAG] xrandr after display-config:"
DISPLAY=:0 xrandr 2>/dev/null | grep -E 'connected|\*' | while read -r _line; do log "[DIAG]   $_line"; done

# Compute screen metrics AFTER display config
HDMI1_W=$(DISPLAY=:0 xrandr 2>/dev/null | grep '^HDMI-1' | grep -oP '\d+x\d+\+' | head -1 | cut -dx -f1)
[ -z "$HDMI1_W" ] && HDMI1_W=1920
HDMI2_RES=""
if DISPLAY=:0 xrandr 2>/dev/null | grep -q 'HDMI-2 connected'; then
    HDMI2_RES=$(DISPLAY=:0 xrandr 2>/dev/null | grep '^HDMI-2' | grep -oP '\d+x\d+\+' | head -1 | sed 's/+$//' )
    [ -z "$HDMI2_RES" ] && HDMI2_RES="1920x1080"
    # If HDMI-2 is mirrored (at +0+0), extend it to the right of HDMI-1
    HDMI2_POS=$(DISPLAY=:0 xrandr 2>/dev/null | grep '^HDMI-2' | grep -oP '\d+x\d+\+\d+\+\d+' | head -1)
    if echo "$HDMI2_POS" | grep -q '+0+0'; then
        log "HDMI-2 mirrored — extending to right of HDMI-1 at ${HDMI1_W}x0"
        DISPLAY=:0 xrandr --output HDMI-2 --mode "$HDMI2_RES" --pos ${HDMI1_W}x0 2>/dev/null || true
        # Re-blacken root after xrandr extension (mode change invalidates xsetroot)
        DISPLAY=:0 xsetroot -solid black 2>/dev/null || true
        snap "after_hdmi2_extend"
    fi
fi
SCREEN_W=$(DISPLAY=:0 xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f1)
[ -z "$SCREEN_W" ] || [ "$SCREEN_W" -eq 0 ] 2>/dev/null && SCREEN_W=1920
if [ "$SCREEN_W" -ge 3000 ]; then
    export ODS_SCALE=2
elif [ "$SCREEN_W" -ge 2000 ]; then
    export ODS_SCALE=1.5
else
    export ODS_SCALE=1
fi
SCREEN_FULL=$(DISPLAY=:0 xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' || echo "1920x1080")
log "Screen: ${SCREEN_W}px (${SCREEN_FULL}), HDMI-2: ${HDMI2_RES:-none}, Scale: ${ODS_SCALE}"

export GTK_THEME="Adwaita:dark"
export GTK2_RC_FILES="/usr/share/themes/Adwaita-dark/gtk-2.0/gtkrc"
mkdir -p /home/signage/.config/gtk-3.0
cat > /home/signage/.config/gtk-3.0/settings.ini << 'GTK'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
GTK
log "Config complete"
snap "before_overlay_creation"

# ── STAGE 6: ANIMATED OVERLAY + CHROMIUM ─────────────────────────────
rm -f /tmp/ods-loader-ready /tmp/ods-boot-complete

# Screen 0 overlay — use HD overlay directly (no resize needed at 1080p)
log "Overlay: creating ${SCREEN_FULL} overlay"
DISPLAY=:0 display -immutable -title BOOT_OVERLAY \
  -geometry ${SCREEN_FULL}+0+0 \
  "$ANIM_DIR/overlay_launch_1.png" 2>/dev/null &
OVERLAY_PID=$!
sleep 0.3
OVERLAY_WID=$(DISPLAY=:0 xdotool search --name BOOT_OVERLAY 2>/dev/null | head -1)
[ -n "$OVERLAY_WID" ] && DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
log "Screen 0 overlay created (PID: $OVERLAY_PID, WID: $OVERLAY_WID, Res: ${SCREEN_FULL})"

# Screen 1 overlay (HDMI-2, secondary)
OVERLAY2_PID=""
OVERLAY2_WID=""
if [ -n "$HDMI2_RES" ]; then
    HDMI2_W=$(echo "$HDMI2_RES" | cut -dx -f1)
    HDMI2_H=$(echo "$HDMI2_RES" | cut -dx -f2)
    DISPLAY=:0 display -immutable -title BOOT_OVERLAY2 \
      -geometry ${HDMI2_RES}+${HDMI1_W}+0 \
      "$ANIM_DIR/overlay_launch_1.png" 2>/dev/null &
    OVERLAY2_PID=$!
    sleep 0.5
    for _try in 1 2 3; do
        OVERLAY2_WID=$(DISPLAY=:0 xdotool search --name BOOT_OVERLAY2 2>/dev/null | head -1)
        [ -n "$OVERLAY2_WID" ] && break
        sleep 0.3
    done
    if [ -n "$OVERLAY2_WID" ]; then
        DISPLAY=:0 xdotool windowmove "$OVERLAY2_WID" "$HDMI1_W" 0 2>/dev/null
        DISPLAY=:0 xdotool windowsize "$OVERLAY2_WID" "$HDMI2_W" "$HDMI2_H" 2>/dev/null
        DISPLAY=:0 xdotool windowraise "$OVERLAY2_WID" 2>/dev/null
    fi
    log "Screen 1 overlay created (PID: $OVERLAY2_PID, WID: ${OVERLAY2_WID:-NONE}, Res: ${HDMI2_RES}, X: ${HDMI1_W})"
fi

# Launch Chromium behind overlay
/usr/local/bin/start-player-ATLAS.sh &
PLAYER_PID=$!
log "Chromium launched behind overlay (PID: $PLAYER_PID)"

# Re-raise both overlays
sleep 0.5
[ -n "$OVERLAY_WID" ] && DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
[ -n "$OVERLAY2_WID" ] && DISPLAY=:0 xdotool windowraise "$OVERLAY2_WID" 2>/dev/null
log "Overlays re-raised"

# Animate "Launching OS" on BOTH overlay windows in sync
# With HD assets, overlay PNGs are 1920x1080 — display directly, no convert
(
    while [ ! -f /tmp/ods-loader-ready ]; do
        for _d in 1 2 3 4 5; do
            [ -f /tmp/ods-loader-ready ] && break 2
            # Screen 0
            if [ -n "$OVERLAY_WID" ]; then
                DISPLAY=:0 xdotool windowraise "$OVERLAY_WID" 2>/dev/null
                DISPLAY=:0 display -window "$OVERLAY_WID" "$ANIM_DIR/overlay_launch_${_d}.png" 2>/dev/null
            fi
            # Screen 1
            if [ -n "$OVERLAY2_WID" ]; then
                DISPLAY=:0 xdotool windowraise "$OVERLAY2_WID" 2>/dev/null
                DISPLAY=:0 display -window "$OVERLAY2_WID" "$ANIM_DIR/overlay_launch_${_d}.png" 2>/dev/null
            fi
            sleep 0.4
        done
    done
) &
ANIM_PID=$!
log "Launching OS animation started (synced on both screens)"

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
log "Buffer complete — killing overlays"

# Kill BOTH overlays simultaneously — synced reveal on both screens
kill $OVERLAY_PID 2>/dev/null || true
kill $ANIM_PID 2>/dev/null || true
[ -n "$OVERLAY2_PID" ] && kill $OVERLAY2_PID 2>/dev/null || true

# Signal boot complete — Screen 1 watermark polls this to sync its reveal
touch /tmp/ods-boot-complete
log "Both overlays killed + boot-complete signaled — pages visible"

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
