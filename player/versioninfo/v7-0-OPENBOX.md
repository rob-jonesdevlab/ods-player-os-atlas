# v7-OPENBOX — Architectural Overhaul

**Released:** 2026-02-21  
**Image:** `ods-atlas-golden-v7-OPENBOX.img` (1.8G)  
**Repo:** `ods-player-os-atlas`  
**Commits:** `5a3b910`, `c93604f`, `03d6357`

---

## Summary

Major architectural upgrade incorporating 4 structural improvements and fixes for all 5 field-test issues identified in v5/v6. Informed by forensic analysis of the legacy ODS system (`ods_power_mgr.sh`, `ods_esper_mgr.sh`, `ods_splash_mgr.sh`).

## Commits

| Commit | Message |
|--------|---------|
| `5a3b910` | `feat(v6): Openbox WM, dual-monitor, portrait, admin-gated Options, 4-layer sleep prevention` |
| `c93604f` | `fix(#5): replace legacy enrollment with ODS Cloud pairing API + retry` |
| `03d6357` | `docs: store jdl-mini-box password in build guide` |

## Architectural Upgrades

### Upgrade A: Matchbox → Openbox WM
- **Removed:** `matchbox-window-manager` (single-window only)
- **Added:** `openbox` (multi-window, configurable window rules)
- **Config:** `/etc/ods/openbox-rc.xml`
  - All windows: no decorations, auto-maximize (kiosk mode)
  - Admin terminal (`XTerm`, title `ODS Admin*`): decorated, always-on-top, 800×600, centered
  - No keybindings (all keyboard handled by Chromium JavaScript)
- **Why:** Enables dual-monitor (separate Chromium per screen) and admin overlay windows

### Upgrade B: Dual-Monitor + Portrait Orientation
- **New service:** `ods-display-config.service` (runs after kiosk starts)
- **New script:** `/usr/local/bin/ods-display-config.sh` (reads JSON config, applies `xrandr`)
- **Layout configs** at `/home/signage/ODS/config/layout/`:
  - `ods_mode_single_hd_landscape.json` — default, single HDMI, landscape
  - `ods_mode_single_hd_portrait.json` — single HDMI, rotated left
  - `ods_mode_dual_hd_landscape.json` — two HDMI outputs, landscape
- **Mode selection:** `/home/signage/ODS/config/layout/.current_mode` (defaults to `single_hd_landscape`)
- **New packages:** `xdotool`, `jq`

### Upgrade C: Admin-Gated Options Menu
- **Server:** `POST /api/admin/login` — validates `otter` credentials via system `su` (PAM/shadow)
- **Server:** `requireAdmin` middleware — 30-min session tokens (in-memory)
- **Server:** `POST /api/admin/terminal` — launches xterm overlay via Openbox
- **Server:** `POST /api/admin/restart-kiosk` — restarts `ods-kiosk.service`
- **Server:** `GET /api/admin/services` — queries all ODS service statuses
- **UI:** `system_config.html` → Admin panel section (separated in sidebar with divider + lock icon)
  - Login form (username readonly `otter`, password input)
  - On auth: lock icon → unlock, tools panel revealed
  - Tools: Launch Terminal, Restart Kiosk, Service Status, Reboot Device
  - Session persisted in `sessionStorage`, auto-restores on page revisit

### Upgrade D: 4-Layer Sleep Prevention
Adapted from legacy `ods_power_mgr.sh`:

| Layer | Mechanism | Location |
|-------|-----------|----------|
| 1 | Kernel `consoleblank=0` | `cmdline.txt` (inject_atlas.sh) |
| 2 | `systemd-logind` `IdleAction=ignore`, handles disabled | `/etc/systemd/logind.conf` |
| 3 | `xset -dpms; xset s off; xset s noblank` | `ods-kiosk-wrapper.sh` (at X startup) |
| 4 | `.xprofile` persistence (re-applied on every login) | `/home/signage/.xprofile` |
| 5a | `ods-dpms-enforce.timer` — runs every 5 min, kills DPMS + simulates keypress | `systemd timer` |

## Field Test Fixes

### Issue #1: Plymouth Timing (fixed)
- **Before:** Fixed `sleep 15` in plymouth-hold service
- **After:** Poll-based: waits for `/tmp/ods-kiosk-starting` signal (max 30s, 0.5s intervals)
- Kiosk wrapper creates signal file at startup → plymouth-hold detects and releases

### Issue #2: White-to-Grey Boot Flash (fixed)
- **Before:** Gap between Plymouth quit and Chromium visible
- **After:** `xterm -fullscreen -bg black` overlay launched before Chromium
- Overlay killed after page-ready signal received and Chromium confirms rendered
- Plymouth quit delayed until after overlay dismissal

### Issue #3: Missing `/player.html` (fixed)
- **New file:** `public/player.html`
- Dark ODS-branded design with device info (hostname, IP, CPU temp)
- 60-second keep-alive polling (`/api/system/info` + `/api/status`)
- Sends Plymouth signal via `POST /api/signal-ready`
- Keyboard security: only `Ctrl+Alt+Shift+O` allowed

### Issue #4: Display Blanking (fixed)
- Root cause: single `xset` call at boot is insufficient — DPMS re-enables on X state changes
- Fix: 4-layer sleep prevention (see Upgrade D) + periodic timer enforcement

### Issue #5: Cloud Registration (fixed)
- **Root cause:** `device_uuid_generator.py` posted to port `9999` (legacy piSignage), but ODS Cloud pairing API runs on port `3001`
- **Fix:** `/api/enroll` now:
  1. Reads CPU serial from `/proc/cpuinfo`
  2. Generates/persists UUID at `/home/signage/ODS/config/device_uuid`
  3. Calls ODS Cloud `POST /api/pairing/generate` on port 3001
  4. Returns pairing code to `player_registration.html`
- **Retry:** `ods-enrollment-retry.timer` — calls `/api/enroll` every 30 min until `enrollment.flag` exists
- **UI:** `player_registration.html` rewritten with 5-attempt escalating retry (3s→30s), pairing code display, pairing status polling

## Services (9 total)

| Service | Type | Purpose |
|---------|------|---------|
| `ods-kiosk.service` | simple | X + Openbox + Chromium |
| `ods-webserver.service` | simple | Node.js Express on :8080 |
| `ods-health-monitor.service` | simple | System health checks |
| `ods-plymouth-hold.service` | oneshot | Poll-based splash hold |
| `ods-hide-tty.service` | oneshot | Black VT1 text |
| `ods-shutdown-splash.service` | oneshot | Plymouth on shutdown |
| `ods-dpms-enforce.timer` | timer | 5-min DPMS kill |
| `ods-display-config.service` | oneshot | xrandr layout |
| `ods-enrollment-retry.timer` | timer | 30-min cloud enrollment retry |

## New Packages

| Package | Purpose |
|---------|---------|
| `openbox` | Multi-window WM (replaces matchbox) |
| `xdotool` | Simulated keypress for DPMS wake |
| `xterm` | Black overlay + admin terminal |
| `jq` | JSON config parsing for display layouts |

## Removed Packages

| Package | Reason |
|---------|--------|
| `matchbox-window-manager` | Single-window limitation, replaced by openbox |

## Files Modified

| File | Changes |
|------|---------|
| `scripts/atlas_firstboot.sh` | Openbox, 9 services, 4-layer sleep, display configs, enrollment retry |
| `server.js` | Admin auth, signal-ready, enrollment via pairing API, hasInternet |
| `public/system_config.html` | Admin panel (login + gated tools) |
| `public/player_registration.html` | Rewritten with retry + pairing code display |
| `.arch/build_guide.md` | jdl-mini-box password stored permanently |
| `.arch/project.md` | Password placeholder updated |

## Files Added

| File | Purpose |
|------|---------|
| `public/player.html` | Player display page with keep-alive |
| `/etc/ods/openbox-rc.xml` | Openbox kiosk window rules (deployed by firstboot) |
| `/usr/local/bin/ods-display-config.sh` | xrandr configuration script (deployed by firstboot) |
| `config/layout/*.json` | 3 display layout presets (deployed by firstboot) |
| `/home/signage/.xprofile` | Sleep prevention Layer 4 (deployed by firstboot) |
