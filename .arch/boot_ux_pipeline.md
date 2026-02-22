# Boot UX Pipeline — v8-0-6-FLASH (Stable)

## Status: ✅ GREY FLASH ELIMINATED

**Tag:** `boot-ux-v8-0-6-flash` (pending)
**Rollback:** `git checkout boot-ux-v12-stable`

---

## Problem

Chromium 144's GPU compositor creates a `gray(60)` = `#3C3C3C` surface for ~400ms when the kiosk window first maps. This happens BEFORE the renderer draws any content. Previous attempts to fix with `--disable-gpu-compositing` and `--default-background-color=000000` reduced but didn't eliminate it.

## Solution: Overlay Approach

A fullscreen overlay window sits ON TOP of Chromium during initialization, hiding the grey compositor surface. The overlay is killed after the page signals ready + 1s buffer.

**Critical discovery:** `--kiosk` mode bypasses Openbox window stacking — the overlay can't sit above it. Fix: `--app` mode + `--start-maximized` respects WM layer rules and is visually identical to kiosk mode.

---

## Boot Pipeline Sequence

```
Phase 1: Plymouth throbber (5s)           — kernel/initramfs splash
Phase 2: FBI bridge animation (~3.5s)     — "System ready... Booting OS..." on framebuffer (RGB565)
Phase 3: Starting ODS services (1.5s)     — animated on Xorg root window
Phase 4: Launching OS overlay (~6s)       — animated on overlay window, hides Chromium grey flash
Phase 5: Page visible                     — overlay killed, rendered page revealed
```

### Phase Details

| Phase | Technology | Font | Size | Animation |
|-------|-----------|------|------|-----------|
| Plymouth | two-step module, throbber PNGs | Built-in | 53px (25% enlarged) | 75-frame spinner |
| FBI bridge | Raw RGB565 → `/dev/fb0` | DejaVu Sans | 28pt | 8 frames, 150-300ms progressive |
| Starting ODS | ImageMagick `display -window root` | DejaVu Sans Bold | 42pt | 5 frames × 300ms |
| Launching OS | ImageMagick `display -window $WID` | DejaVu Sans Bold | 42pt | 5 frames × 400ms |

### Two-Tier Font System

- **Pre-boot (system feel):** DejaVu Sans (regular) 28pt — FBI bridge
- **Post-boot (signage feel):** DejaVu Sans Bold 42pt — Starting ODS + Overlay

42pt is industry standard for 4K digital signage viewed at 10-15 feet.

---

## Key Files (on device)

| File | Purpose |
|------|---------|
| `/usr/local/bin/ods-kiosk-wrapper.sh` | Boot pipeline orchestrator |
| `/usr/local/bin/start-kiosk.sh` | Chromium launcher (`--app` mode) |
| `/etc/ods/openbox-rc.xml` | Window manager config (BOOT_OVERLAY layer rule) |
| `/usr/share/plymouth/themes/ods/watermark.png` | Base splash image |
| `/usr/share/plymouth/themes/ods/fbi_boot_*.raw` | FBI bridge animation (8 frames, RGB565) |
| `/usr/share/plymouth/themes/ods/splash_ods_*.png` | Starting ODS animation (5 frames) |
| `/usr/share/plymouth/themes/ods/overlay_launch_*.png` | Launching OS overlay (5 frames) |
| `/usr/share/plymouth/themes/ods/throbber-*.png` | Plymouth throbber (75 frames, 53px) |

## Key Files (in repo)

| File | Purpose |
|------|---------|
| `scripts/ods-kiosk-wrapper-v8-0-6.sh` | Stable wrapper backup |
| `scripts/start-kiosk-v8-0-6.sh` | Stable kiosk launcher backup |

---

## Grey Flash Root Causes & Fixes

| Root Cause | Fix | Version |
|-----------|-----|---------|
| Chromium GPU compositor paints `gray(60)` | `--disable-gpu-compositing` flag | v12 |
| `--kiosk` bypasses WM stacking | Switch to `--app` + `--start-maximized` | v8-0-0 |
| Overlay can't sit above kiosk window | Openbox `<layer>above</layer>` rule for `BOOT_OVERLAY` | v8-0-0 |
| Framebuffer animation garbled | RGB565 format (16-bit fb0, not 32-bit BGRA) | v8-0-5 |
| `preload.html` redirect stalls in `--app` mode | Direct URL to `network_setup.html` | v8-0-0 |

---

## Security Assessment

### `--no-sandbox` (HIGH RISK)

Chromium runs as root without sandbox. Mitigated by:
- Policy file suppresses warning banner
- No user input (kiosk mode)
- No external URLs loaded

**Future fix (v8-1-0-FLASH):** Split systemd service into root phase (VT/Plymouth/Xorg) and `User=signage` phase (Openbox/Chromium with full sandbox).

---

## Openbox Config (BOOT_OVERLAY Rule)

```xml
<application title="BOOT_OVERLAY">
  <decor>no</decor>
  <maximized>yes</maximized>
  <layer>above</layer>
  <fullscreen>yes</fullscreen>
</application>
```

---

## Versioning Scheme

Format: `vX-Y-Z-CODENAME` (major.minor.patch)

| Version | Scope |
|---------|-------|
| v8-0-0-FLASH | Initial overlay approach |
| v8-0-1-FLASH | Simplified two-phase splash |
| v8-0-2-FLASH | fbi bridge + splash image overlay |
| v8-0-3-FLASH | Animated overlay with Launching OS frames |
| v8-0-4-FLASH | Full animated pipeline |
| v8-0-5-FLASH | RGB565 fix + two-tier fonts |
| **v8-0-6-FLASH** | **Updated splash, faster fbi, 25% throbber (STABLE)** |
| v8-1-0-FLASH | Systemd service split for sandbox (planned) |

---

## Deployment Pipeline Phases

| Phase | Description | Boot Sequence |
|-------|-------------|---------------|
| Phase 0 | Base golden image | N/A |
| Phase 1 | Golden + RustDesk, ready to clone | Minimal boot |
| Phase 2 | Restored clone → Esper enrollment | Enrollment splash (TBD) |
| Phase 3 | Post-Esper reboot → production | Current v8-0-6-FLASH pipeline |

---

## Multi-Resolution Support (Planned)

| Resolution | Name | Splash Size | Font Scale |
|-----------|------|------------|------------|
| 1920×1080 | HD | Native | 1x (21pt/28pt) |
| 2560×1440 | 2K | Native | 1.33x (28pt/37pt) |
| 3840×2160 | 4K | Native | 2x (28pt/42pt) |

---

## Lessons Learned

1. **One change at a time.** Combining overlay + sandbox changes caused cascading failures
2. **`--kiosk` bypasses WM stacking.** Use `--app` mode for overlay compatibility
3. **Framebuffer is 16-bit RGB565**, not 32-bit BGRA — always check `bits_per_pixel`
4. **Complete file rewrites via `scp`** are more reliable than `sed` edits
5. **`preload.html` JS redirects stall in `--app` mode** — use direct URLs
6. **Version, tag, and document before testing** — rollback saves hours
