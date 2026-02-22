#!/bin/bash
# ODS Phase Selector — Gates between Phase 2 (enrollment) and Phase 3 (production)
# Called by ods-kiosk.service as the primary boot entrypoint

ENROLLED_FLAG="/etc/ods/esper_enrolled.flag"
LOG="/home/signage/ODS/logs/boot/phase_selector.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [PHASE] $1" | tee -a "$LOG"; }

if [ -f "$ENROLLED_FLAG" ]; then
    log "Phase 3: Enrolled flag found — launching production boot (v8-0-6-FLASH)"
    exec /usr/local/bin/ods-kiosk-wrapper.sh
else
    log "Phase 2: No enrolled flag — launching enrollment boot"
    exec /usr/local/bin/ods-enrollment-boot.sh
fi
