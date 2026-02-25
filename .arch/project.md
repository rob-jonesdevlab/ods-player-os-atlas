# ODS Player OS Atlas — Architecture

**Last Updated:** February 24, 2026  
**Current Version:** v9-0-0-ORIGIN  
**Status:** P:0 built — kiosk terminology removed, player naming established, ready for ODS Cloud pivot

---

## System Overview

ODS Player OS Atlas converts a Raspberry Pi 4b running Armbian into a locked-down digital signage player. The system operates as a three-layer stack:

```
┌─────────────────────────────────────────────────┐
│ ODS Cloud Dashboard (ods-signage)               │
│ → Playlist management, content upload, pairing  │
│ → https://www.ods-cloud.com                     │
├─────────────────────────────────────────────────┤
│ ODS Player OS Atlas (this repo)                 │
│ → Express server (port 8080)                    │
│ → Chromium --app mode (X11 fullscreen)          │
│ → systemd services (9 production services)      │
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

## Current State (v8-3-3)

### Completed — Core
- ✅ 11-step automated firstboot (`atlas_firstboot.sh`, ~1280 lines)
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
- ✅ Esper MDM enrollment — Phase 2 sealed-in-splash enrollment boot
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

### Completed — v8-3 Terminology & Infrastructure
- ✅ **Removed all "kiosk" terminology** — replaced with "player" naming
- ✅ Overlay 4K→1080p resize fix — `convert -resize` before `display` for multi-res support
- ✅ Deleted legacy v12 wrapper and start scripts (dead code)
- ✅ Naming convention: boot files omit ATLAS tag (universal), OS-specific files include ATLAS
- ✅ Directory consolidation — removed redundant `assets/plymouth/ods/`
- ✅ 5-frame standard enforced across all splash animations

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
| v7-1 through v7-4 | OPENBOX | 2/21/26 | Grey flash iterations — dark theme, xsetroot, VT fixes |
| v7-5 | OPENBOX | 2/21/26 | Admin auth + Chromium managed policy (611 MB — minimal build) |
| v7-6 | OPENBOX | 2/21/26 | su/PAM auth (yescrypt-safe), dark GTK |
| v7-7 | OPENBOX | 2/21/26 | Removed `--force-dark-mode` (was painting grey), delayed plymouth quit |
| v7-8 | OPENBOX | 2/21/26 | Removed `-background none` (grey stipple), xsetroot repaint |
| v7-9 | OPENBOX | 2/21/26 | Unmasked plymouth-quit, reverted VT7→VT1 |
| v7-10 | OPENBOX | 2/21/26 | ROOT CAUSE: boot started 26s after plymouth-quit, service dep fix |
| v7-11 | OPENBOX | 2/21/26 | Continuous xsetroot repaint loop (covers modeset resets) |
| v7-12 | OPENBOX | 2/21/26 | fbi bridge animation, FBI→Xorg handoff |
| v7-13 | OPENBOX | 2/21/26 | Splash overlay approach — Openbox BOOT_OVERLAY rule |
| v7-14-0 | OPENBOX | 2/21/26 | Full animated pipeline (Plymouth → FBI → splash → overlay) |
| v7-14-1 | OPENBOX | 2/22/26 | Hotfix: throbber alignment, animation timing |
| v8-1-0 | FLASH | 2/22/26 | Premium boot UX: 104 PNGs, 4K watermark, 5-frame FBI, throbber .90 |
| v8-2-0 | FLASH | 2/22/26 | Secrets symlink, Plymouth .90/.5 config, generated assets path |
| v8-2-1 | FLASH | 2/22/26 | 4K watermark fix, enrollment 5-frame splash, HD purge |
| v8-2-2 | FLASH | 2/22/26 | Sync all 133 4K PNGs, throbber 106x106, Esper state cleanup |
| v8-2-3 | FLASH | 2/22/26 | CRITICAL: Fix enrollment killed after 6s by service restart |
| v8-2-4 | FLASH | 2/23/26 | Security: Remove --no-sandbox, Chromium runs as signage user |
| **v9-0-0** | **ORIGIN** | **2/24/26** | **Major: Removed kiosk terminology, player naming, 5-frame standard, multi-res overlay, consolidated assets, comprehensive docs refresh** |

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

### Pending / Next Version
- [x] P:0 golden image rebuild → **v9-0-0-ORIGIN**
- [ ] Validate Esper enrollment end-to-end on fresh P:0 flash
- [ ] ODS Cloud — Account, Content, Device, User management
- [ ] OTA updates from ODS Cloud dashboard
- [ ] Remote background/content push
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
| `atlas_firstboot.sh` | Target device | 11-step provisioning on first boot |
| `ods-phase-selector.sh` | Target device | Routes Phase 2 (enrollment) vs Phase 3 (production) |
| `ods-player-boot-wrapper.sh` | Target device | Full premium boot pipeline orchestrator |
| `start-player-os-ATLAS.sh` | Target device | Chromium `--app` mode launcher |
| `ods-enrollment-boot.sh` | Target device | Phase 2 enrollment (sealed splash, no Xorg) |
| `generate_splash_frames.sh` | jdl-mini-box | Regenerates all splash PNGs from base watermark |
| `ods-display-config.sh` | Target device | xrandr resolution configuration |

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

## Environment

| Machine | IP | User | Purpose |
|---------|-----|------|---------|
| ArPi4b (player) | `10.111.123.102` | root / signage | Production test device |
| jdl-mini-box | `10.111.123.134` | jones-dev-lab | Golden image build server (Ubuntu) |
| Mac (dev) | local | robert.leejones | Development, SCP transfer, Lima builds |
