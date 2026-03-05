#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# generate_splash_all_resolutions.sh — Generate HD, 2K, and 4K splash frames
# ODS Player OS Atlas v9-1
#
# PURPOSE: Generate all boot splash PNGs at 3 resolution tiers from
#          pre-built resolution-specific watermark images.
#          Each tier gets its own folder: generated_HD, generated_2K, generated_4K
#
# REQUIRES: ImageMagick 6/7, DejaVu Sans Mono font
# RUN ON:   jdl-mini-box (Linux build machine)
#
# USAGE:
#   ./generate_splash_all_resolutions.sh         # Generate all 3 tiers
#   ./generate_splash_all_resolutions.sh HD       # Generate HD only
#   ./generate_splash_all_resolutions.sh 2K       # Generate 2K only
#   ./generate_splash_all_resolutions.sh 4K       # Generate 4K only
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SPLASH_DIR="${REPO_DIR}/brand/splash"

# ── RESOLUTION CONFIGS ────────────────────────────────────────────────
# Each tier: WIDTH HEIGHT FONT_SIZE TEXT_Y FOLDER WATERMARK_NAME
# Font size and text position scale proportionally from the 4K baseline:
#   4K: 42pt @ Y=2050 (baseline)
#   2K: 28pt @ Y=1367 (× 0.667)
#   HD: 21pt @ Y=1025 (× 0.500)

declare -A RES_WIDTH=( [HD]=1920  [2K]=2560  [4K]=3840 )
declare -A RES_HEIGHT=( [HD]=1080  [2K]=1440  [4K]=2160 )
declare -A RES_FONT=( [HD]=21   [2K]=28   [4K]=42 )
declare -A RES_TEXT_Y=( [HD]=1025  [2K]=1367  [4K]=2050 )
declare -A RES_WATERMARK=( [HD]="watermark_HD.png" [2K]="watermark_2K.png" [4K]="watermark.png" )

FONT="DejaVu-Sans-Mono"
TEXT_COLOR="white"

# Determine which tiers to generate
TIERS_TO_GEN=("${1:-all}")
if [ "${TIERS_TO_GEN[0]}" = "all" ]; then
    TIERS_TO_GEN=("HD" "2K" "4K")
fi

# ── VALIDATION ────────────────────────────────────────────────────────
if ! command -v convert &>/dev/null; then
    echo "ERROR: ImageMagick not found. Install with: sudo apt install imagemagick"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo " ODS Multi-Resolution Splash Frame Generator"
echo " Tiers: ${TIERS_TO_GEN[*]}"
echo " Source: ${SPLASH_DIR}"
echo "═══════════════════════════════════════════════════════════════"

# ── FUNCTION: Generate dot-animated frames ────────────────────────────
# Draws base text centered, then appends dots to the right
# Text position stays FIXED across all 5 frames
generate_dot_frames() {
    local prefix="$1"
    local base_text="$2"
    local max_dots="${3:-5}"
    local width="$4"
    local font_size="$5"
    local text_y="$6"
    local base_img="$7"
    local output_dir="$8"

    echo ""
    echo "   ── ${prefix}_1..${max_dots}.png"

    # Measure the pixel width of the base text (without dots)
    local text_width
    text_width=$(convert -font "$FONT" -pointsize "$font_size" \
        label:"${base_text}" -format "%w" info: 2>/dev/null)

    # Calculate X position to center the base text horizontally
    local text_x=$(( (width - text_width) / 2 ))

    for i in $(seq 1 "$max_dots"); do
        local dots=""
        for d in $(seq 1 "$i"); do
            dots="${dots}."
        done

        local full_text="${base_text}${dots}"
        local out_file="${output_dir}/${prefix}_${i}.png"

        convert "$base_img" \
            -font "$FONT" -pointsize "$font_size" -fill "$TEXT_COLOR" \
            -gravity NorthWest \
            -annotate "+${text_x}+${text_y}" "${full_text}" \
            "$out_file"

        echo "      ✓ ${prefix}_${i}.png → \"${full_text}\""
    done
}

# ── FUNCTION: Generate static frame ───────────────────────────────────
generate_static_frame() {
    local filename="$1"
    local text="$2"
    local height="$3"
    local font_size="$4"
    local text_y="$5"
    local base_img="$6"
    local output_dir="$7"
    local out_file="${output_dir}/${filename}"

    echo "      ✓ ${filename} → \"${text}\" (static)"

    convert "$base_img" \
        -font "$FONT" -pointsize "$font_size" -fill "$TEXT_COLOR" \
        -gravity South \
        -annotate "+0+$(( height - text_y ))" "${text}" \
        "$out_file"
}

# ── FUNCTION: Copy Plymouth assets ────────────────────────────────────
# Copy resolution-independent Plymouth theme files (throbbers, configs, etc.)
copy_plymouth_assets() {
    local src_dir="$1"
    local dst_dir="$2"

    # Copy throbber frames (resolution-independent — small spinner icons)
    local throbber_count=0
    for f in "$src_dir"/throbber-*.png; do
        if [ -f "$f" ]; then
            cp "$f" "$dst_dir/"
            throbber_count=$((throbber_count + 1))
        fi
    done

    # Copy Plymouth config and other small UI assets
    for f in "$src_dir"/ods.plymouth "$src_dir"/bgrt-fallback.png \
             "$src_dir"/bullet.png "$src_dir"/capslock.png \
             "$src_dir"/entry.png "$src_dir"/keyboard.png \
             "$src_dir"/keymap-render.png "$src_dir"/lock.png; do
        [ -f "$f" ] && cp "$f" "$dst_dir/" || true
    done

    echo "      ✓ ${throbber_count} throbber frames + Plymouth assets copied"
}

# ═══════════════════════════════════════════════════════════════════════
# GENERATE ALL FRAMES FOR EACH TIER
# ═══════════════════════════════════════════════════════════════════════

for TIER in "${TIERS_TO_GEN[@]}"; do
    WIDTH=${RES_WIDTH[$TIER]}
    HEIGHT=${RES_HEIGHT[$TIER]}
    FONT_SIZE=${RES_FONT[$TIER]}
    TEXT_Y=${RES_TEXT_Y[$TIER]}
    WATERMARK_FILE=${RES_WATERMARK[$TIER]}
    OUTPUT_DIR="${SPLASH_DIR}/generated_${TIER}"
    BASE_IMG="${OUTPUT_DIR}/${WATERMARK_FILE}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " Tier: ${TIER} (${WIDTH}×${HEIGHT})"
    echo " Base: ${BASE_IMG}"
    echo " Output: ${OUTPUT_DIR}"
    echo "═══════════════════════════════════════════════════════════════"

    if [ ! -f "$BASE_IMG" ]; then
        echo " ⚠️  Watermark not found: ${BASE_IMG} — SKIPPING tier ${TIER}"
        continue
    fi

    mkdir -p "$OUTPUT_DIR"

    # Also copy the watermark as splash.png and ods-player-boot-splash.png
    # (aliases used by different boot stages)
    cp "$BASE_IMG" "$OUTPUT_DIR/splash.png"
    cp "$BASE_IMG" "$OUTPUT_DIR/ods-player-boot-splash.png"
    echo "   ✓ splash.png + ods-player-boot-splash.png (watermark aliases)"

    # 1. FBI Boot bridge animation (framebuffer, pre-Xorg)
    generate_dot_frames "fbi_boot" "Booting system" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 2. Splash ODS (X11 root window, "Starting services" animation)
    generate_dot_frames "splash_ods" "Starting services" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 3. Overlay launch (X11 overlay window, "Launching ODS" animation)
    generate_dot_frames "overlay_launch" "Launching ODS" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 4. Splash launch (alternative naming — same content as overlay_launch)
    generate_dot_frames "splash_launch" "Launching ODS" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 5. Enrollment FBI animation
    generate_dot_frames "enroll_fbi" "Connecting to server" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 6. Enrollment progress animation
    generate_dot_frames "enroll_progress" "Enrollment in progress" 5 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 7. Enrollment retry animation
    generate_dot_frames "enroll_retry" "Retrying enrollment" 3 \
        "$WIDTH" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 8. Static frames
    echo ""
    echo "   ── Static frames"
    generate_static_frame "splash_starting.png" "Starting..." \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"
    generate_static_frame "splash_boot_complete.png" "Boot complete" \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"
    generate_static_frame "splash_anim1.png" "Starting ODS services" \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"
    generate_static_frame "enroll_success.png" "Enrollment successful" \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"
    generate_static_frame "enroll_downloading.png" "Downloading configuration" \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"
    generate_static_frame "enroll_support.png" "Contact support" \
        "$HEIGHT" "$FONT_SIZE" "$TEXT_Y" "$BASE_IMG" "$OUTPUT_DIR"

    # 9. Copy Plymouth theme assets from 4K (resolution-independent)
    echo ""
    echo "   ── Plymouth assets"
    FOURK_DIR="${SPLASH_DIR}/generated_4K"
    if [ "$TIER" != "4K" ] && [ -d "$FOURK_DIR" ]; then
        copy_plymouth_assets "$FOURK_DIR" "$OUTPUT_DIR"
    elif [ "$TIER" = "4K" ]; then
        echo "      ✓ (4K is the source — assets already in place)"
    fi

    # Count generated files
    local_count=$(ls "$OUTPUT_DIR"/*.png 2>/dev/null | wc -l)
    echo ""
    echo " ✅ ${TIER}: ${local_count} PNG files generated in ${OUTPUT_DIR}"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " ✅ All tiers complete!"
echo ""
echo " Next steps:"
echo "   1. Review generated PNGs visually"
echo "   2. Commit to repo: git add brand/splash/generated_*"
echo "   3. Generate RGB565 raw files for FBI bridge:"
echo "      Run: ./scripts/generate_fbi_raw_all_resolutions.sh"
echo "═══════════════════════════════════════════════════════════════"
