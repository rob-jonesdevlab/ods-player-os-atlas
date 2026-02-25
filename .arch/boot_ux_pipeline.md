# Boot UX Pipeline — ODS Player OS

## Status: ✅ Premium Boot — Multi-Resolution Verified

---

## Architecture Overview

The boot pipeline provides a seamless visual experience from power-on to page-ready, with zero console text, zero grey flash, and animated transitions across every stage. All splash assets use 4K source images that are dynamically resized to the detected display resolution.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Power On → Plymouth throbber → FBI bridge → Starting services          │
│          → Launching ODS overlay → Page visible                        │
│                                                                        │
│ Each stage covers the gap left by the previous one.                    │
│ At no point does the user see console text, a cursor, or bare TTY.    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Boot Pipeline Sequence

```
Stage 1: VT Blackout                       — TTY1-3 blanked, fb0 zeroed, cursors hidden
Stage 2: Plymouth throbber (5s hold)       — kernel/initramfs splash, 75-frame spinner
Stage 3: FBI bridge animation (~3.5s)      — "Booting system" + 1-5 dots (raw RGB565 → /dev/fb0)
Stage 4: Starting services (1.5s)          — 5-frame animation on Xorg root window
Stage 5: Setup (Openbox, display config)   — WM starts, xrandr resolution applied
Stage 6: Launching ODS overlay (~6s)       — 5-frame animation on overlay window, hides Chromium init
Stage 7: Page visible                      — overlay killed, rendered page revealed
```

### Stage Details

| Stage | Technology | Animation | Notes |
|-------|-----------|-----------|-------|
| Plymouth | two-step throbber module | 75-frame spinner at .90 vertical | Held for 5s, then quit-with-retain |
| FBI bridge | Raw RGB565 → `/dev/fb0` | "Booting system" + 1-5 dots | Seamless handoff: starts BEFORE Plymouth quits |
| Starting services | `display -window root` | "Starting services" + 1-5 dots | Painted directly on Xorg root window |
| Launching ODS | `display -window $OVERLAY_WID` | "Launching ODS" + 1-5 dots | Pre-resized via `convert -resize` to screen resolution |

### Splash Frame Spec (5-Frame Standard)

All splash animations use exactly **5 frames** with 1-5 trailing dots. Text is centered on the **base words only** — dots trail to the right and are not part of the centering calculation.

| Set | Text | Repo Location |
|-----|------|--------------|
| `fbi_boot_1-5` (.raw + .png) | Booting system | `brand/splash/generated/` |
| `splash_ods_1-5` (.png) | Starting services | `brand/splash/generated/` |
| `overlay_launch_1-5` (.png) | Launching ODS | `brand/splash/generated/` |
| `enroll_fbi_1-5` (.raw + .png) | Connecting to server | `brand/splash/generated/` |
| `enroll_progress_1-5` (.png) | Enrollment in progress | `brand/splash/generated/` |

**Font:** DejaVu Sans Mono, 54pt, white on dark background
**Canvas:** 3840×2160 (4K source, resized at runtime)
**Generation:** `scripts/generate_splash_frames.sh` (run on jdl-mini-box)

---

## Key Files

### On Device (`/usr/local/bin/`)

| File | Purpose |
|------|---------|
| `ods-player-boot-wrapper.sh` | Boot pipeline orchestrator (universal — no ATLAS tag) |
| `start-player-ATLAS.sh` | Chromium launcher (`--app` mode, OS-specific) |
| `ods-phase-selector.sh` | Routes Phase 2 (enrollment) vs Phase 3 (production) |
| `ods-enrollment-boot.sh` | Phase 2 enrollment boot (no Chromium/Xorg) |
| `ods-display-config.sh` | xrandr resolution configuration |

### On Device (`/usr/share/plymouth/themes/ods/`)

| File | Purpose |
|------|---------|
| `watermark.png` | Base splash image (4K, logo + slogan) |
| `fbi_boot_1-5.raw` | FBI bridge animation (RGB565 for `/dev/fb0`) |
| `splash_ods_1-5.png` | Starting services animation |
| `overlay_launch_1-5.png` | Launching ODS overlay animation |
| `throbber-0000-0074.png` | Plymouth throbber (75 frames) |

### In Repo (`scripts/`)

| File | Purpose |
|------|---------|
| `ods-player-boot-wrapper.sh` | Boot wrapper source (deployed as-is) |
| `start-player-os-ATLAS.sh` | Chromium launcher source |
| `generate_splash_frames.sh` | Regenerates all splash PNGs on jdl-mini-box |

### Single Source of Truth

All splash assets live in `brand/splash/generated/`. This is the only location — there is no duplicate `assets/plymouth/` directory. Deployment copies from `brand/splash/generated/` to the device's Plymouth theme directory.

---

## Naming Convention

| Category | ATLAS Tag? | Rationale |
|----------|-----------|-----------|
| Boot wrapper | **No** | Boot sequence is universal across all OS versions |
| Chromium launcher | **Yes** | OS-specific configuration |
| Systemd service | **Yes** | `ods-player-ATLAS.service` — OS-specific |
| Signal file | **Yes** | `/tmp/ods-player-os-starting-ATLAS` |
| Chromium policy | **Yes** | `ods-player-ATLAS.json` |

---

## Grey Flash Root Causes & Fixes

| Root Cause | Fix | Version |
|-----------|-----|---------|
| Chromium GPU compositor paints `gray(60)` | `--disable-gpu-compositing` flag | v12 |
| `--kiosk` bypasses WM stacking | Switch to `--app` + `--start-maximized` | v8-0-0 |
| Overlay can't sit above kiosk window | Openbox `<layer>above</layer>` rule for `BOOT_OVERLAY` | v8-0-0 |
| Framebuffer animation garbled | RGB565 format (16-bit fb0, not 32-bit BGRA) | v8-0-5 |
| `preload.html` redirect stalls in `--app` mode | Direct URL to `network_setup.html` | v8-0-0 |
| Overlay shows tiny mirror at 1080p | `convert -resize` before `display` (4K→detected res) | v8-3-2 |

---

## Multi-Resolution Support

The overlay and splash images are 4K source (3840×2160). At runtime, the boot wrapper detects the actual resolution via `xrandr` and uses `convert -resize "${SCREEN_FULL}!"` to scale them. This works at any resolution the display reports.

| Resolution | Scale Factor | Behavior |
|-----------|-------------|----------|
| 3840×2160 | 2x | Native 4K, no resize needed |
| 2560×1440 | 1.5x | Resized from 4K |
| 1920×1080 | 1x | Resized from 4K (most common) |

---

## Esper Enrollment Boot (Phase 2)

When no enrollment flag exists, the phase selector routes to `ods-enrollment-boot.sh` instead of the production boot wrapper. This boot sequence uses its own splash frames:

1. **`enroll_fbi_1-5`** — "Connecting to server" (8 second minimum display)
2. **`enroll_progress_1-5`** — "Enrollment in progress" (until Esper reports success)

After enrollment completes, the device sets the enrolled flag and reboots into Phase 3 (production boot).

---

## Lessons Learned

1. **One change at a time.** Combining overlay + sandbox changes caused cascading failures
2. **`--kiosk` bypasses WM stacking.** Use `--app` mode for overlay compatibility
3. **Framebuffer is 16-bit RGB565**, not 32-bit BGRA — always check `bits_per_pixel`
4. **Complete file rewrites via `scp`** are more reliable than `sed` edits
5. **`preload.html` JS redirects stall in `--app` mode** — use direct URLs
6. **Version, tag, and document before testing** — rollback saves hours
7. **`display -geometry` doesn't resize images** — it only sets window size. Use `convert -resize` before piping to `display` for cross-resolution support
8. **`ods-display-config.sh` runs BEFORE the overlay** — if it changes resolution, the overlay must use the new resolution, not the raw 4K
9. **Center text on words, not on text+dots** — anchor X on base text width, dots trail right. Use monospace font for pixel-perfect consistency
10. **Always check project docs for credentials** — don't guess SSH passwords when `atlas_secrets.conf` is right there in the repo
