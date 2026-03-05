#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# generate_fbi_raw_all_resolutions.sh — Convert FBI PNGs to RGB565 raw
# ODS Player OS Atlas v9-1
#
# PURPOSE: Convert framebuffer animation PNGs to RGB565 raw format
#          for direct /dev/fb0 writes during pre-Xorg FBI bridge phase.
#          Processes HD, 2K, and 4K resolution tiers.
#
# REQUIRES: ImageMagick (convert), Python 3
# RUN ON:   jdl-mini-box (Linux build machine)
#
# USAGE:
#   ./generate_fbi_raw_all_resolutions.sh         # Convert all 3 tiers
#   ./generate_fbi_raw_all_resolutions.sh HD       # Convert HD only
#   ./generate_fbi_raw_all_resolutions.sh 2K       # Convert 2K only
#   ./generate_fbi_raw_all_resolutions.sh 4K       # Convert 4K only
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SPLASH_DIR="${REPO_DIR}/brand/splash"

# ── TIERS ─────────────────────────────────────────────────────────────
TIERS_TO_GEN=("${1:-all}")
if [ "${TIERS_TO_GEN[0]}" = "all" ]; then
    TIERS_TO_GEN=("HD" "2K" "4K")
fi

# ── VALIDATION ────────────────────────────────────────────────────────
if ! command -v convert &>/dev/null; then
    echo "ERROR: ImageMagick not found. Install with: sudo apt install imagemagick"
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found."
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo " ODS Multi-Resolution FBI Raw (RGB565) Converter"
echo " Tiers: ${TIERS_TO_GEN[*]}"
echo " Source: ${SPLASH_DIR}"
echo "═══════════════════════════════════════════════════════════════"

# ── RGB565 CONVERSION FUNCTION ────────────────────────────────────────
# Converts a PNG to little-endian RGB565 raw for direct framebuffer write.
# Uses ImageMagick to decode PNG to raw RGB, then Python to pack RGB565.
convert_to_rgb565() {
    local png="$1"
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
}

# ── PROCESS EACH TIER ─────────────────────────────────────────────────
TOTAL_COUNT=0

for TIER in "${TIERS_TO_GEN[@]}"; do
    DIR="${SPLASH_DIR}/generated_${TIER}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " Tier: ${TIER}"
    echo " Directory: ${DIR}"
    echo "═══════════════════════════════════════════════════════════════"

    if [ ! -d "$DIR" ]; then
        echo " ⚠️  Directory not found — SKIPPING tier ${TIER}"
        continue
    fi

    TIER_COUNT=0

    # FBI boot animation frames
    for png in "$DIR"/fbi_boot_*.png; do
        if [ -f "$png" ]; then
            convert_to_rgb565 "$png"
            TIER_COUNT=$((TIER_COUNT + 1))
            echo "   ✓ $(basename "${png%.png}.raw")"
        fi
    done

    # Enrollment FBI animation frames
    for png in "$DIR"/enroll_fbi_*.png; do
        if [ -f "$png" ]; then
            convert_to_rgb565 "$png"
            TIER_COUNT=$((TIER_COUNT + 1))
            echo "   ✓ $(basename "${png%.png}.raw")"
        fi
    done

    # Enrollment progress animation frames
    for png in "$DIR"/enroll_progress_*.png; do
        if [ -f "$png" ]; then
            convert_to_rgb565 "$png"
            TIER_COUNT=$((TIER_COUNT + 1))
            echo "   ✓ $(basename "${png%.png}.raw")"
        fi
    done

    # Enrollment retry animation frames
    for png in "$DIR"/enroll_retry_*.png; do
        if [ -f "$png" ]; then
            convert_to_rgb565 "$png"
            TIER_COUNT=$((TIER_COUNT + 1))
            echo "   ✓ $(basename "${png%.png}.raw")"
        fi
    done

    # Static enrollment frames
    for png in "$DIR"/enroll_success.png "$DIR"/enroll_downloading.png "$DIR"/enroll_support.png; do
        if [ -f "$png" ]; then
            convert_to_rgb565 "$png"
            TIER_COUNT=$((TIER_COUNT + 1))
            echo "   ✓ $(basename "${png%.png}.raw")"
        fi
    done

    # Verify file sizes
    echo ""
    if [ $TIER_COUNT -gt 0 ]; then
        SAMPLE_RAW=$(ls "$DIR"/fbi_boot_1.raw 2>/dev/null || true)
        if [ -n "$SAMPLE_RAW" ] && [ -f "$SAMPLE_RAW" ]; then
            SAMPLE_SIZE=$(du -h "$SAMPLE_RAW" | cut -f1)
            echo " ✅ ${TIER}: ${TIER_COUNT} RAW files generated (sample: fbi_boot_1.raw = ${SAMPLE_SIZE})"
        else
            echo " ✅ ${TIER}: ${TIER_COUNT} RAW files generated"
        fi
    else
        echo " ⚠️  ${TIER}: No PNGs found to convert"
    fi

    TOTAL_COUNT=$((TOTAL_COUNT + TIER_COUNT))
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " ✅ All tiers complete! ${TOTAL_COUNT} total RAW files generated."
echo ""
echo " Expected sizes per frame:"
echo "   HD (1920×1080): ~4.0 MB"
echo "   2K (2560×1440): ~7.0 MB"
echo "   4K (3840×2160): ~15.8 MB"
echo "═══════════════════════════════════════════════════════════════"
