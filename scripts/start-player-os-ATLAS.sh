#!/bin/bash
# ODS Player OS ATLAS — Start Player
# Uses --app mode (not --kiosk) so overlay can stay above
# Openbox handles maximization and decoration removal
#
# SECURITY NOTE: --no-sandbox required (root). See .arch/boot_ux_pipeline.md

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
