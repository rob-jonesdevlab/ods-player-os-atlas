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
    echo "[ODS] Device enrolled — loading player_status"
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
  --force-device-scale-factor=${ODS_SCALE:-1}
  --password-store=basic
  --credentials-enable-service=false
  --disable-save-password-bubble
  --disable-autofill-keyboard-accessory-view
  --default-background-color=000000
  --force-dark-mode
  --disable-gpu-compositing
)

# Launch primary Chromium (screen 0)
chromium --app="$START_URL" \
  --start-maximized \
  --remote-debugging-port=9222 \
  "${CHROME_FLAGS[@]}" &

PRIMARY_PID=$!
echo "[ODS] Primary Chromium launched (PID: $PRIMARY_PID)"

# If dual display detected, launch second Chromium on screen 1 with offset
if [ "$DISPLAY_COUNT" -ge 2 ] && [ -f "$ENROLLMENT_FLAG" ]; then
    # Get resolution of primary display to offset second window
    PRIMARY_RES=$(xrandr 2>/dev/null | grep "${DISPLAYS[0]}" | grep -oP '\d+x\d+\+\d+\+\d+' | head -1)
    PRIMARY_WIDTH=$(echo "$PRIMARY_RES" | cut -d'x' -f1)
    [ -z "$PRIMARY_WIDTH" ] && PRIMARY_WIDTH=1920

    echo "[ODS] Dual display mode — launching second Chromium at offset ${PRIMARY_WIDTH}x0"

    # Second Chromium uses a separate user-data-dir to avoid conflicts
    chromium --app="http://localhost:8080/player_content_manager.html?screen=1" \
      --user-data-dir=/home/signage/.config/chromium-screen2 \
      --window-position=${PRIMARY_WIDTH},0 \
      --start-maximized \
      --remote-debugging-port=9223 \
      "${CHROME_FLAGS[@]}" &

    SECONDARY_PID=$!
    echo "[ODS] Secondary Chromium launched (PID: $SECONDARY_PID)"
fi

# Wait for primary Chromium to exit
wait $PRIMARY_PID
