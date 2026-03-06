#!/bin/bash
# ODS Player OS ATLAS — Start Player
# Uses --app mode so overlay can stay above
# Openbox handles maximization and decoration removal
# Supports dual-screen: detects second display via xrandr and launches
# a second Chromium instance on screen 1 if a dual layout is configured.
export DISPLAY=:0
export HOME=/home/signage

xhost +local: 2>/dev/null || true
chown -R signage:signage /home/signage/.config/chromium 2>/dev/null
rm -f /home/signage/.config/chromium/SingletonLock 2>/dev/null

# Determine startup page based on enrollment and connectivity
ENROLLMENT_FLAG="/var/lib/ods/enrollment.flag"

if [ -f "$ENROLLMENT_FLAG" ]; then
    echo "[ODS] Device enrolled — loading player status (fast boot)"
    START_URL="http://localhost:8080/player_status.html"
elif curl -sf --max-time 3 http://connectivitycheck.gstatic.com/generate_204 >/dev/null 2>&1; then
    echo "[ODS] Internet detected — loading player_link for enrollment"
    START_URL="http://localhost:8080/player_link.html"
else
    echo "[ODS] No internet — starting AP for network setup"
    sudo /usr/local/bin/ods-setup-ap.sh start 2>/dev/null || true
    START_URL="http://localhost:8080/network_setup.html"
fi

# Detect connected displays
DISPLAY_COUNT=$(xrandr 2>/dev/null | grep -c ' connected')
echo "[ODS] Detected ${DISPLAY_COUNT} display(s)"

# Get display output names
DISPLAYS=($(xrandr 2>/dev/null | grep ' connected' | awk '{print $1}'))
echo "[ODS] Display outputs: ${DISPLAYS[*]}"

# Common Chromium flags
CHROME_FLAGS=(
  --no-sandbox
  --noerrdialogs
  --disable-infobars
  --disable-translate
  --no-first-run
  --disable-features=TranslateUI
  --disable-session-crashed-bubble
  --disable-component-update
  --check-for-update-interval=31536000
  --autoplay-policy=no-user-gesture-required
  --password-store=basic
  --credentials-enable-service=false
  --disable-save-password-bubble
  --disable-autofill-keyboard-accessory-view
  --default-background-color=000000
  --force-dark-mode
  --disable-gpu-compositing
)

# Launch primary Chromium (screen 0)
# ODS_SCALE is set by the boot wrapper based on primary display width
chromium --app="$START_URL" \
  --start-maximized \
  --remote-debugging-port=9222 \
  --force-device-scale-factor=${ODS_SCALE:-1} \
  "${CHROME_FLAGS[@]}" &

PRIMARY_PID=$!
echo "[ODS] Primary Chromium launched (PID: $PRIMARY_PID)"

# ── Screen 1 setup (dual display) ─────────────────────────────────────
DUAL_MODE=false
if [ "$DISPLAY_COUNT" -ge 2 ] && [ -f "$ENROLLMENT_FLAG" ]; then
    DUAL_MODE=true

    # Get the x-offset where the second display starts
    SECONDARY_OFFSET=$(xrandr 2>/dev/null | grep "${DISPLAYS[1]}" | grep -oP '\d+x\d+\+\K\d+' | head -1)
    if [ -z "$SECONDARY_OFFSET" ] || [ "$SECONDARY_OFFSET" = "0" ]; then
        PRIMARY_RES=$(xrandr 2>/dev/null | grep "${DISPLAYS[0]}" | grep -oP '\d+x\d+\+\d+\+\d+' | head -1)
        SECONDARY_OFFSET=$(echo "$PRIMARY_RES" | cut -d'x' -f1)
    fi
    [ -z "$SECONDARY_OFFSET" ] && SECONDARY_OFFSET=1920
    PRIMARY_WIDTH=$SECONDARY_OFFSET

    # Get secondary display resolution
    SECONDARY_RES=$(xrandr 2>/dev/null | grep "${DISPLAYS[1]}" | grep -oP '\d+x\d+\+' | head -1 | sed 's/+$//')
    SECONDARY_W=$(echo "$SECONDARY_RES" | cut -dx -f1)
    SECONDARY_H=$(echo "$SECONDARY_RES" | cut -dx -f2)
    [ -z "$SECONDARY_W" ] && SECONDARY_W=1920
    [ -z "$SECONDARY_H" ] && SECONDARY_H=1080

    SCREEN1_URL="http://localhost:8080/player_watermark.html?screen=1"

    # Calculate scale factor for secondary display (independent of primary)
    if [ "$SECONDARY_W" -ge 3000 ] 2>/dev/null; then
        SCREEN1_SCALE=2
    elif [ "$SECONDARY_W" -ge 2000 ] 2>/dev/null; then
        SCREEN1_SCALE=1.5
    else
        SCREEN1_SCALE=1
    fi

    echo "[ODS] Dual display mode — launching second Chromium at offset ${PRIMARY_WIDTH}x0 (${SECONDARY_W}x${SECONDARY_H}, scale=${SCREEN1_SCALE})"

    # Launch Screen 1 Chromium
    # NOTE: --start-maximized is NOT used — Openbox's <maximized>yes</maximized>
    # overrides --window-position, snapping the window to 0,0 on the primary display.
    launch_screen1() {
        rm -f /home/signage/.config/chromium-screen2/SingletonLock 2>/dev/null
        chromium --app="$SCREEN1_URL" \
          --user-data-dir=/home/signage/.config/chromium-screen2 \
          --window-position=${PRIMARY_WIDTH},0 \
          --window-size=${SECONDARY_W},${SECONDARY_H} \
          --remote-debugging-port=9223 \
          --force-device-scale-factor=${SCREEN1_SCALE} \
          "${CHROME_FLAGS[@]}" &
        SECONDARY_PID=$!
        echo "[ODS] Screen 1 Chromium launched (PID: $SECONDARY_PID)"

        # Force reposition — Openbox maximization can override --window-position
        sleep 1.5
        SEC_WID=$(xdotool search --name "Screen 1" 2>/dev/null | head -1)
        if [ -n "$SEC_WID" ]; then
            xdotool windowmove "$SEC_WID" "$PRIMARY_WIDTH" 0
            xdotool windowsize "$SEC_WID" "$SECONDARY_W" "$SECONDARY_H"
            echo "[ODS] Screen 1 repositioned to ${PRIMARY_WIDTH}x0 (WID: $SEC_WID)"
        fi
    }

    # Screen 1 launch + respawn loop (background)
    # IMPORTANT: launch_screen1 MUST be called inside this subshell so that
    # 'wait' can track the Chromium PID (wait can only see child processes
    # of the current shell). Calling it in the parent then waiting in a
    # subshell causes an immediate return → crash loop.
    (
        launch_screen1
        while true; do
            wait $SECONDARY_PID 2>/dev/null
            echo "[ODS] WARN: Screen 1 Chromium exited — respawning in 2s..."
            sleep 2
            launch_screen1
        done
    ) &
    RESPAWN1_PID=$!
fi

# Wait for primary Chromium to exit (boot wrapper has its own respawn loop for this)
wait $PRIMARY_PID
