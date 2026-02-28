# ODS Player Atlas — Architecture

**Last Updated:** February 28, 2026  
**Current Version:** v9-3-2-ORIGIN  
**Status:** Production-ready P:0 → P:1 → P:2 pipeline — WiFi AP connection flow verified, glass card wallpaper, status pill, keyboard shortcuts, configurable offline border

---

## System Overview

ODS Player OS Atlas converts a Raspberry Pi 4b running Armbian into a locked-down digital signage player. The system operates as a three-layer stack:

```
┌─────────────────────────────────────────────────┐
│ ODS Cloud Dashboard (ods-cloud-amigo)            │
│ → Playlist management, content upload, pairing  │
│ → https://www.ods-cloud.com                     │
├─────────────────────────────────────────────────┤
│ ODS Player Atlas (this repo)                    │
│ → Express server (port 8080)                    │
│ → Chromium --app mode (X11 fullscreen)          │
│ → systemd services (12 production services)     │
│ → Boot UX pipeline (Plymouth → FBI → Xorg)     │
├─────────────────────────────────────────────────┤
│ Armbian 26.2.1 Trixie (RPi4b)                  │
│ → Linux 6.18.9, ext4, systemd                  │
│ → DRM/KMS display, Plymouth boot splash         │
│ → Debian Trixie (Python 3.13, yescrypt hashes)  │
└─────────────────────────────────────────────────┘
```

## Build Pipeline (P:0 → P:3)

Golden images are built via **inject + firstboot**, not by cloning the dev device:

```
P:0 (Insert)         P:1 (Clone)          P:2 (Enrollment)     P:3 (Production)
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ Base Armbian  │    │ Provisioned  │    │ Enrollment   │    │ Production   │
│ + firstboot   │───▶│ golden image │───▶│ sealed splash│───▶│ Player OS    │
│ inject_atlas  │    │ partclone    │    │ mgmt server  │    │ full boot    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

**P:0:** `inject_atlas.sh` loop-mounts base Armbian, injects firstboot + service + secrets  
**P:1:** `partclone` snapshot of provisioned device (safety net)  
**P:2:** Enrollment boot — connects to Esper MDM (no Chromium/Xorg)  
**P:3:** Production boot — full premium boot pipeline with Chromium  

> **Goal:** Make P:0 as close to P:3 as possible. Every feature must be captured in `atlas_firstboot.sh` so a fresh inject produces a device that reaches P:3 on its own.

See `.arch/image_processes.md` for detailed build commands and `.arch/build_guide.md` for step-by-step instructions.

## Current State (v9-1-7)

### Completed — Core
- ✅ 11-step automated firstboot (`atlas_firstboot.sh`, ~1400 lines)
- ✅ NTP clock sync before apt — prevents signature verification failures from clock skew
- ✅ Resilient batched package install — 3 batches with `--fix-missing` and retry logic
- ✅ Chromium install retry — separate batch with fresh `apt-get update` on failure
- ✅ Filesystem resize re-enable — `finalize_phase1()` re-enables self-deleting Armbian resize service for clones
- ✅ TTY flash fix — VT1 pre-painted black (tty1-3 + framebuffer + kernel printk)
- ✅ Grey flash fix — overlay window hides Chromium compositor surface
- ✅ Plymouth hold — `ods-plymouth-hold.service` blocks `plymouth-quit` until player ready
- ✅ Admin auth — `su`/PAM-based (yescrypt-safe, confirmed working on device)
- ✅ Chromium managed policy — password popup and autofill disabled
- ✅ Dark GTK theme — Adwaita-dark via env vars + settings.ini
- ✅ VT lockdown — getty tty1-6 masked, SysRq disabled, Xorg `DontVTSwitch`
- ✅ System config shortcut — `Ctrl+Alt+Shift+O` opens diagnostics panel
- ✅ Sleep prevention — `consoleblank=0`, DPMS off, suspend/hibernate masked
- ✅ RustDesk remote access — self-hosted relay, systemd service
- ✅ Esper MDM enrollment — Phase 2 sealed-in-splash enrollment boot (verified end-to-end)
- ✅ Health monitor service
- ✅ Boot diagnostics — systemd journal capture per boot
- ✅ Chromium `--app` mode (not `--kiosk`) for overlay compatibility

### Completed — v8 Boot UX Sprint
- ✅ 4K Plymouth theme — 3840×2160 watermark, transparent bgrt-fallback
- ✅ Throbber alignment — `.90` vertical position across all boot stages
- ✅ Watermark alignment — `.5` vertical (centered on 4K display)
- ✅ 54pt DejaVu Sans Mono splash text — monospace padded for stable animation
- ✅ 5-frame FBI boot bridge — "Booting system" + 1-5 dots (RGB565 raw)
- ✅ 5-frame "Starting services" splash — `splash_ods_1-5.png`
- ✅ 5-frame "Launching ODS" overlay — `overlay_launch_1-5.png`
- ✅ Enrollment splash — "Connecting to server" + "Enrollment in progress" (stage-tied)
- ✅ Status pill alignment — `.90` vertical on player_link.html and network_setup.html
- ✅ `brand/splash/generated/` — single source of truth for all splash assets
- ✅ Enrollment race condition fix — lock file + `Restart=no` override during enrollment

### Completed — v9.2 QR Setup & Signage UI Sprint
- ✅ **WiFi AP mode** — hostapd/dnsmasq for phone-based network configuration
- ✅ **QR code → WiFi join** — `WIFI:T:nopass;S:ODS-DEVICE-NAME;;` format
- ✅ **Captive portal detection** — iOS/Android/Windows auto-redirect to setup.html
- ✅ **AP stability** — kills `wpa_supplicant`, guards WiFi scan from disrupting AP mode
- ✅ **AP config** — `country_code=US`, `ieee80211n=1`, channel 6, hidden SSID
- ✅ **QR code → ODS Cloud deep link** — player_link.html pairing flow
- ✅ **Rate limiting** — 5 pairing attempts per 10-minute window
- ✅ **Signage-friendly UI** — high-contrast text (#1a1a2e), font-bold/semibold, all pages
- ✅ **Dynamic card width** — `whitespace-nowrap` + `w-auto`, no text wrapping
- ✅ **3-state network indicators** — Green (Primary), Blue (Standby), Amber (Disconnected)
- ✅ **Default network toggle** — Radio buttons for primary/failover with localStorage persistence
- ✅ **Ethernet auto-redirect** — null-safe poll skips network_setup when ethernet connected
- ✅ **ALL CAPS device names** — reduces l/I confusion on signage
- ✅ **QR code 380px** — large enough for phone scanning at distance
- ✅ **Status pill** — `.90` vertical with glass-pill styling on all pages
- ✅ Device name: `ods-setup-ap.sh` script (start/stop/status/ssid)

### Completed — v9.3 Captive Portal & Network Config Sprint
- ✅ **Captive portal auto-launch** — serves setup.html directly (`sendFile`) instead of meta-refresh/JS redirect (iOS CNA ignores both)
- ✅ **ODS-branded setup.html** — dark glassmorphism theme, WiFi scan dropdown with signal strength bars, password toggle, 3-step progress, device name display
- ✅ **Configurable DHCP/Static** — per-interface dropdown on Network Status cards (Ethernet + WiFi), editable IP/Subnet/Gateway/DNS in Static mode
- ✅ **Subnet mask handling** — CIDR notation (`/24`) for DHCP, full mask (`255.255.255.0`) input for Static
- ✅ **`/api/network/configure`** — server endpoint applies static IP via `ip` commands, converts subnet mask to CIDR, updates `/etc/resolv.conf`
- ✅ **WiFi state AP-awareness** — `/api/wifi/state` returns `enabled: false` when hostapd running (prevents toggle flip during AP)
- ✅ **Port 80 listener** — iOS captive portal detection requires port 80 reachable; `setcap` on node binary
- ✅ **QR `H:true`** — hidden SSID parameter for iOS compatibility
- ✅ **API documentation** — `.arch/api_doc.md` cataloging all 42 endpoints
- ✅ **Repo rename** — `ods-player-os-atlas` → `ods-player-atlas`

### Completed — v9.3.1 WiFi Connection Fix & Layout Refinements
- ✅ **WiFi connection flow** — end-to-end captive portal → WiFi client mode verified working
- ✅ **Root cause: `dhclient` missing** — device has no `dhclient`; fixed to use `busybox udhcpc`
- ✅ **Root cause: `wpa_supplicant` sudoers** — `signage` user lacked sudo for `wpa_supplicant`, `killall`, `busybox`; added to `/etc/sudoers.d/signage`
- ✅ **Root cause: `ip addr flush` sudoers** — `signage` user lacked sudo for `ip addr`; added to sudoers
- ✅ **Root cause: systemd Conflicts** — `ods-setup-ap.service` has `Conflicts=wpa_supplicant.service`; bypassed `systemctl stop` entirely, using direct `killall` for AP teardown
- ✅ **Root cause: wpa_supplicant D-Bus mode** — `wpa_supplicant.service` runs `-u -s` (D-Bus, no `-i wlan0`); fixed to run `wpa_supplicant -B -i wlan0 -c conf` directly
- ✅ **Compact card layout** — `width: fit-content` + `flex: 0 0 auto` on both columns, card shrinks to content
- ✅ **Card divider removed** — `border-right` between text and QR columns removed
- ✅ **Padding balanced** — 5rem left padding on text column, 5rem right padding on QR column
- ✅ **Step numbers centered** — `align-items: center` for vertical centering between title/description
- ✅ **Removed step 1 description** — "On your computer or mobile device" removed for brevity
- ✅ **HOSTNAME label** — network_setup changed "Device Name" → "HOSTNAME", strips "ODS-" prefix from displayed value
- ✅ **API documentation** — `.arch/api_doc.md` updated with all 42 endpoints including WiFi connection flow diagram

### Completed — v9.3.2 Player Ready Overhaul & Glass Card Sprint
- ✅ **File renames** — `player.html` → `player_ready.html`, `setup.html` → `captive_portal.html`, `system_config.html` → `system_options.html` with all cross-references updated
- ✅ **Status pill** — Dark-themed glass-pill on player_ready with 8-stage color progression (amber → teal → blue → purple → green → red → orange → reset)
- ✅ **Hostname ALL CAPS** — `text-transform: uppercase` on hostname display (matching brand standard)
- ✅ **Smokey glass card** — `backdrop-filter: blur(24px)` + `rgba(10,10,10,0.65)` on player_ready when wallpaper set via config `appearance.wallpaper`
- ✅ **Smart connection status** — `hasConnected` flag: shows "Connecting..." on first attempt, "Reconnecting..." only after prior success
- ✅ **"Status" label** — replaced "ODS Cloud" with binary "Online"/"Offline" in info table (pill handles transitional states)
- ✅ **Config `appearance` section** — `{ wallpaper, ready_card_style }` added to device config response
- ✅ **Offline border refinement** — Progressive reduction: 6px → 3px → 1.75px → 1.125px → 0.675px → **0.450px** (heartbeat max 0.90px)
- ✅ **Keyboard shortcuts**:
  - `Ctrl+Alt+Shift+I` — Player Info (shows Player Ready status page from any page)
  - `Ctrl+Alt+Shift+K` — Kill/Restart signage (calls `/api/system/restart-signage`)
  - `Ctrl+Alt+Shift+O` — System options
  - `Ctrl+Alt+Shift+B` — Debug (cycle offline border templates)
- ✅ **`/api/system/restart-signage`** — New endpoint: kills Chromium so systemd relaunches it (support tool)
- ✅ **Signage-friendly text** — 3.5rem heading, 1.7rem sub, 1.3-1.4rem info on player_ready
- ✅ **`os.hostname()`** — Added to `/api/status` response for hostname display

### 7 Root Cause Fixes (v9-1-0 → v9-1-7)

| # | Root Cause | Fix | Commit |
|---|-----------|-----|--------|
| 1 | Armbian `armbian-firstlogin` deletes gate file — blocks firstboot | ODS-owned gate file + mask Armbian first-login | `7b82395` |
| 2 | `After=network-online.target` blocks forever without ethernet | `After=basic.target` + script-level `wait_for_network()` | `ef98b61` |
| 3 | `set -e` silently kills 1400-line script on any non-zero return | `set -o pipefail` + ERR trap with line numbers | `6ab2af1` |
| 4 | Single `apt-get install` batch — one 404 cascades to skip all packages | 3 resilient batches with `--fix-missing` | `ddc498e` |
| 5 | Clock skew (Pi clock at image date) → apt signature check fails → stale index → Chromium 404 | NTP sync before apt + Chromium retry with fresh `apt-get update` | `c568e7b` |
| 6 | `armbian-resize-filesystem` self-deletes symlink after P:1 → clones stuck at 4G | `finalize_phase1()` re-enables resize service before shutdown | `054a3d0` |

### Golden Image History

Complete lineage of every P:0 golden image ever built:

| Image | Codename | Date | Milestone |
|-------|----------|------|-----------|
| v1-0-0 | INITIAL | 2/16/26 | First golden image — bare Armbian + firstboot injection |
| v2-0 | SECURE | 2/16/26 | Root password, user creation, basic lockdown |
| v3-0 | PRODUCTION | 2/16/26 | Express server, Chromium, systemd services |
| v4-0 | LEGACY | 2/16/26 | Legacy script migration from ods-signage |
| v5-0 | NATIVE | 2/16/26 | Native Armbian integration (dropped legacy wrappers) |
| v6-0 | SPLASH | 2/18/26 | Plymouth boot splash, TTY hide, sleep prevention |
| v7-0 | OPENBOX | 2/21/26 | Window manager, Chromium `--app` mode, grey flash hunt begins |
| v7-1 — v7-4 | OPENBOX | 2/21/26 | Grey flash iterations — dark theme, xsetroot, VT fixes |
| v7-5 | OPENBOX | 2/21/26 | Admin auth + Chromium managed policy (611 MB — minimal build) |
| v7-6 | OPENBOX | 2/21/26 | su/PAM auth (yescrypt-safe), dark GTK |
| v7-7 — v7-9 | OPENBOX | 2/21/26 | Dark mode / VT / plymouth-quit iterations |
| v7-10 | OPENBOX | 2/21/26 | ROOT CAUSE: boot started 26s after plymouth-quit, service dep fix |
| v7-11 — v7-13 | OPENBOX | 2/21/26 | xsetroot repaint loop, FBI bridge, overlay approach |
| v7-14-0/1 | OPENBOX | 2/21-22/26 | Full animated pipeline (Plymouth → FBI → splash → overlay) |
| v8-1-0 | FLASH | 2/22/26 | Premium boot UX: 104 PNGs, 4K watermark, 5-frame FBI, throbber .90 |
| v8-2-0 — v8-2-4 | FLASH | 2/22-23/26 | Secrets, enrollment fixes, security hardening |
| v8-3-2/3 | FLASH | 2/23/26 | Multi-res overlay, 5-frame standard, kiosk→player rename |
| v9-0-0 | ORIGIN | 2/24/26 | Major: player naming, consolidated assets, docs refresh |
| v9-1-0 | ORIGIN | 2/26/26 | Fix: ODS gate file + disable Armbian first-login |
| v9-1-1 | ORIGIN | 2/26/26 | Fix: `After=basic.target` + script-level network wait |
| v9-1-2 | ORIGIN | 2/26/26 | Fix: Replace `set -e` with ERR trap |
| v9-1-3 | ORIGIN | 2/26/26 | Fix: Batched apt install (3 resilient batches) |
| v9-1-4 | ORIGIN | 2/26/26 | Fix: `--fix-missing` + retry on batch failures |
| v9-1-5 | ORIGIN | 2/26/26 | Fix: NTP clock sync + Chromium retry with fresh apt update |
| v9-1-6 | ORIGIN | 2/26/26 | Fix: Re-enable resize in inject (interim — replaced in v9-1-7) |
| **v9-1-7** | **ORIGIN** | **2/26/26** | **Fix: `finalize_phase1()` re-enables resize service — proper fix. Clean P:0** |
| v9-2-0 | ORIGIN | 2/27/26 | WiFi AP setup, QR network config, captive portal, signage-friendly UI |
| v9-2-1 | ORIGIN | 2/27/26 | AP stability, dynamic card width, 3-state network indicators, ethernet auto-redirect |
| v9-3-0 | ORIGIN | 2/27/26 | Captive portal auto-launch, ODS-branded setup.html, configurable DHCP/Static, API docs, repo rename |
| **v9-3-1** | **ORIGIN** | **2/28/26** | **WiFi connection fix (wpa_supplicant/udhcpc), compact card layout, HOSTNAME label, step centered** |
| **v9-3-2** | **ORIGIN** | **2/28/26** | **File renames, glass card + wallpaper, status pill, keyboard shortcuts (I/K/O/B), config appearance, restart-signage API, offline border 0.450px** |

### Commit History (v8-v9)

| Version | Commit | Key Change |
|---------|--------|------------|
| v8-1-0 | `6e5f0b9` | Premium boot UX: 104 PNGs, 4K watermark, 5-frame FBI, throbber .90 |
| v8-2-0 | `e6cafbf` | Secrets symlink, Plymouth .90/.5 config, generated assets path |
| v8-2-1 | `312881f` | 4K watermark fix, enrollment 5-frame splash, HD purge |
| v8-2-2 | `4a92dee` | Sync all 133 4K PNGs, throbber 106x106, Esper state cleanup |
| v8-2-3 | `93f9239` | CRITICAL: Fix enrollment killed after 6s by service restart |
| v8-2-4 | `2286a84` | Security: Remove --no-sandbox, Chromium runs as signage user |
| v8-3-2 | `5b576a5` | Splash 5-frame standard + consolidated Plymouth assets |
| v8-3-2 | `b3cb640` | Fix overlay tiny mirror — resize 4K PNGs to detected screen res |
| v8-3-3 | `e417033` | Remove kiosk terminology — rename to player/ATLAS convention |
| v9-0-0 | `7ab906c` | Docs refresh + P:0 golden image build as ORIGIN |
| v9-1-0 | `7b82395` | ODS gate file + disable Armbian first-login |
| v9-1-1 | `ef98b61` | `After=basic.target` + script-level `wait_for_network()` |
| v9-1-2 | `6ab2af1` | Replace `set -e` with `set -o pipefail` + ERR trap |
| v9-1-3 | `ddc498e` | 3 resilient apt batches with `--fix-missing` |
| v9-1-5 | `c568e7b` | NTP clock sync + Chromium retry with fresh `apt-get update` |
| v9-1-6 | `bd7c668` | Re-enable resize in inject (interim bandaid) |
| **v9-1-7** | **`054a3d0`** | **`finalize_phase1()` re-enables resize service — proper fix** |
| v9-2-0 | `d11e8ad` | Network status 3-state indicators + default network toggle + signage fonts |
| v9-2-1 | `b0eceb7` | AP stability, WiFi scan guard, dynamic card width, whitespace-nowrap |
| v9-2-1+ | `c1e4bce` | Hidden SSID fix (country_code/ieee80211n root cause) |
| v9-2-1+ | `8f49c7d` | AP stability — kill wpa, guard WiFi scan, US reg |
| v9-2-1+ | `f9bbc03` | Port 80 + H:true in QR (iOS captive portal + hidden SSID) |
| v9-2-1+ | `9eb4525` | WiFi state returns disabled during AP mode (hostapd check) |
| v9-2-1+ | `975d7c3` | Configurable DHCP/Static per network card + /api/network/configure |
| v9-2-1+ | `dcf1b72` | API docs — .arch/api_doc.md (42 endpoints) |
| v9-3-0 | `4fdd2d2` | Captive portal sendFile fix + ODS dark theme setup.html with WiFi scan |
| v9-3-1 | `47b73a6` | WiFi connection: bypass systemd, use direct killall + busybox udhcpc |
| v9-3-1 | `e61937c` | Card layout: fit-content width, divider removed, padding balanced |
| v9-3-1 | `c345f89` | Remove step 1 desc, center step numbers, HOSTNAME label |
| v9-3-2 | `4b89ff4` | Restore waiting screen + 1.75px offline border |
| v9-3-2 | `518f390` | Hostname CAPS, status pill, file renames (player→player_ready, setup→captive_portal, system_config→system_options) |
| v9-3-2 | `5644f4f` | Smart ODS Cloud status, balanced layout, border 0.450px |
| v9-3-2 | `0b96ede` | Smokey glass card, wallpaper support, Status label, Ctrl+Alt+Shift+S shortcut |
| v9-3-2 | `4146b7e` | Ctrl+Alt+Shift+I (Player Info), Ctrl+Alt+Shift+K (Kill/Restart), restart-signage API |

### Pending / Next Version
- [x] P:0 golden image rebuild → **v9-3-0-ORIGIN**
- [x] WiFi connection flow verified end-to-end
- [x] Compact card layout (fit-content + centered steps)
- [x] HOSTNAME label (replaced Device Name)
- [x] API documentation (.arch/api_doc.md — 42 endpoints)
- [x] File renames (player→player_ready, setup→captive_portal, system_config→system_options)
- [x] Glass card + wallpaper support (player_ready.html)
- [x] Status pill (8-stage color progression)
- [x] Keyboard shortcuts (Ctrl+Alt+Shift+I/K/O/B)
- [x] Offline border 0.450px
- [x] `/api/system/restart-signage` endpoint
- [ ] ODS Cloud — Player Settings UI for wallpaper, border template, appearance config
- [ ] ODS Cloud — Content delivery pipeline (cloud-sync, cache-manager)
- [ ] OTA updates from ODS Cloud dashboard
- [ ] Remote background/content push
- [ ] Offline mode via local cache management
- [ ] ODS Cloud > Players > Player Settings (remote network config)
- [ ] Wayland/Cage migration for zero-flash boot

## Script Architecture

### Naming Convention

| Category | Example | ATLAS Tag? | Rationale |
|----------|---------|-----------|-----------|
| Boot wrapper | `ods-player-boot-wrapper.sh` | No | Universal across OS versions |
| Chromium launcher | `start-player-os-ATLAS.sh` | Yes | OS-specific |
| Systemd service | `ods-player-ATLAS.service` | Yes | OS-specific |
| Signal file | `/tmp/ods-player-os-starting-ATLAS` | Yes | OS-specific |
| Build tools | `inject_atlas.sh` | N/A | Build-time only |

### File Map

| Script | Runs On | Purpose |
|--------|---------|---------|
| `inject_atlas.sh` | jdl-mini-box / Lima | P:0 image builder (loop-mount inject) |
| `atlas_firstboot.sh` | Target device | 11-step provisioning on first boot (~1400 lines) |
| `ods-phase-selector.sh` | Target device | Routes Phase 2 (enrollment) vs Phase 3 (production) |
| `ods-player-boot-wrapper.sh` | Target device | Full premium boot pipeline orchestrator |
| `start-player-os-ATLAS.sh` | Target device | Chromium `--app` mode launcher |
| `ods-enrollment-boot.sh` | Target device | Phase 2 enrollment (sealed splash, no Xorg) |
| `generate_splash_frames.sh` | jdl-mini-box | Regenerates all splash PNGs from base watermark |
| `ods-display-config.sh` | Target device | xrandr resolution configuration |
| `ods-setup-ap.sh` | Target device | WiFi AP management (start/stop/status/ssid) |

## Key Patterns

### Debian Trixie Auth (yescrypt)
Python 3.13 removed `crypt` AND `spwd` modules. `openssl passwd` doesn't support yescrypt (`$y$`). Use `su` via PAM:
```bash
echo "$PASS" | su -c "echo OK" "$USER" 2>/dev/null | grep -q "^OK$"
```

### SUDO_ASKPASS for SSH Builds
`sudo -S` hangs over SSH due to pam_tty. Use `SUDO_ASKPASS` with `sudo -A`.

### Explicit Paths with Sudo
`sudo` sets `$HOME=/root`, breaking default paths. Always pass explicit paths.

### Multi-Resolution Overlay
Splash assets are 4K source. The boot wrapper detects resolution via `xrandr` and uses `convert -resize "${SCREEN_FULL}!"` to scale them at runtime. Never assume 4K output.

### Credentials
Device credentials are in `scripts/atlas_secrets.conf` (root: `0D5@dm!n`). Build server (jdl-mini-box) password: `mnbvcxz!!!`. Always check project docs before SSH attempts.

### WiFi AP Setup (Phone Config)
hostapd runs in AP mode on wlan0 with `country_code=US`, `ieee80211n=1`, channel 6, hidden SSID. AP start kills `wpa_supplicant` first (it fights hostapd for wlan0). WiFi scan endpoint guarded with `pgrep -x hostapd` to prevent disrupting AP mode. dnsmasq uses `except-interface=end0` (Pi5 Armbian ethernet name).

### WiFi Client Connection (After Captive Portal)
After user submits WiFi creds via captive portal, server.js tears down AP and connects to WiFi:
- **Cannot use `systemctl stop ods-setup-ap`** — its stop handler starts `wpa_supplicant` in D-Bus mode (`-u -s`, no `-i wlan0`) and the `Conflicts=wpa_supplicant.service` kills any manually-started instance
- **Cannot use `dhclient`** — not installed on Armbian Trixie. Use `busybox udhcpc -i wlan0 -n -q`
- **Sudoers required:** `wpa_supplicant`, `killall`, `busybox`, `ip addr *` for the `signage` user
- **Sequence:** `killall hostapd/dnsmasq/wpa_supplicant` → `ip addr flush wlan0` → `ip link set wlan0 up` → `wpa_supplicant -B -i wlan0 -c conf` → 10s wait → `wpa_cli reconfigure` → `busybox udhcpc` → verify via `wpa_cli status`

## Environment

| Machine | IP | User | Purpose |
|---------|-----|------|---------|
| ArPi4b (player) | `10.111.123.102` | root / signage | Production test device |
| jdl-mini-box | `10.111.123.134` | jones-dev-lab | Golden image build server (Ubuntu) |
| Mac (dev) | local | robert.leejones | Development, SCP transfer, Lima builds |
