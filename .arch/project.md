# ODS Player OS Atlas — Architecture

**Last Updated:** February 23, 2026  
**Golden Image:** v8-2-4-FLASH  
**Status:** Active iteration — enrollment working, no-sandbox fix deployed

---

## System Overview

ODS Player OS Atlas converts a Raspberry Pi 4b running Armbian into a locked-down digital signage kiosk. The system operates as a three-layer stack:

```
┌─────────────────────────────────────────────────┐
│ ODS Cloud Dashboard (ods-signage)               │
│ → Playlist management, content upload, pairing  │
│ → https://www.ods-cloud.com                     │
├─────────────────────────────────────────────────┤
│ ODS Player OS Atlas (this repo)                 │
│ → Express server (port 8080)                    │
│ → Chromium kiosk (X11 fullscreen)               │
│ → systemd services (9 production services)      │
│ → Boot UX pipeline (Plymouth → VT1 → Xorg)     │
├─────────────────────────────────────────────────┤
│ Armbian 26.2.1 Trixie (RPi4b)                  │
│ → Linux 6.18.9, ext4, systemd                  │
│ → DRM/KMS display, Plymouth boot splash         │
│ → Debian Trixie (Python 3.13, yescrypt hashes)  │
└─────────────────────────────────────────────────┘
```

## Build Pipeline

Golden images are built **offline** on the `jdl-mini-box` build server:

```
Base Armbian .img
    │
    ├── inject_atlas.sh (loop-mount, inject, patch cmdline.txt)
    │       ↓
    ├── Golden Image (.img, ~1.8 GB)
    │       ↓
    ├── Flash to SD card (Raspberry Pi Imager / dd)
    │       ↓
    └── First boot → atlas_firstboot.sh runs (systemd oneshot)
            ↓
        Production kiosk in ~15 minutes
```

## Current State (v8-2-4-FLASH)

### Completed — Core
- ✅ 11-step automated firstboot (`atlas_firstboot.sh`, ~1280 lines)
- ✅ TTY flash fix — VT1 pre-painted black (tty1-3 + framebuffer + kernel printk)
- ✅ Grey flash fix — removed `-background none`, continuous xsetroot repaint loop
- ✅ Plymouth hold — `ods-plymouth-hold.service` blocks `plymouth-quit.service` until kiosk ready
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

### Completed — v8 Boot UX Sprint
- ✅ 4K Plymouth theme — 3840x2160 watermark, transparent bgrt-fallback
- ✅ Throbber alignment — `.90` vertical position across all boot stages
- ✅ Watermark alignment — `.5` vertical (centered on 4K display)
- ✅ 54pt DejaVu Sans Mono splash text — monospace padded for stable animation
- ✅ 5-frame FBI boot bridge — "Booting system" with animated dots (RGB565 raw)
- ✅ 5-frame "Starting services" splash — `splash_ods_1-5.png`
- ✅ 5-frame "Launching ODS" overlay — `overlay_launch_1-5.png`
- ✅ Enrollment splash — "Connecting to server" + "Enrollment in progress" (stage-tied)
- ✅ Status pill alignment — `.90` vertical on player_link.html and network_setup.html
- ✅ Status pill font increase — 1.05rem text, 0.9rem details
- ✅ Unused pairing.html deleted
- ✅ Secrets path symlink — `/etc/ods/atlas_secrets.conf` → `/usr/local/etc/`
- ✅ `brand/splash/generated/` asset path — pre-built 4K PNGs + RGB565 raws
- ✅ `assets/plymouth/ods/` upgraded to 4K — replaced all HD (1920x1080) assets
- ✅ Enrollment race condition fix — lock file + `Restart=no` override during enrollment
- ✅ Chromium sandbox — runs as `signage` user (no `--no-sandbox`)

### Version History

| Version | Commit | Key Change |
|---------|--------|------------|
| v7-5 | `9470538` | Admin auth fix, kiosk wrapper v9, Chromium policy |
| v7-6 | `4e61f5b` | su/PAM auth (yescrypt-safe), dark GTK theme |
| v7-7 | `e8d9ec5` | Removed `--force-dark-mode` (grey #3C3C3C), delayed plymouth quit |
| v7-8 | `cbf14b1` | Removed `-background none` (grey stipple), xsetroot in ready loop |
| v7-9 | `f384229` | Unmasked plymouth-quit, reverted VT7→VT1 |
| v7-10 | `ecd2562` | ROOT CAUSE: kiosk started 26s after plymouth-quit, service dep fix |
| v7-11 | `a0ae81b` | Continuous xsetroot repaint loop (covers modeset resets) |
| v8-1-0 | `6e5f0b9` | Premium boot UX: 104 PNGs, 4K watermark, 5-frame FBI, throbber .90 |
| v8-2-0 | `e6cafbf` | Secrets symlink, Plymouth .90/.5 config, generated assets path |
| v8-2-1 | `312881f` | 4K watermark fix in assets/, enrollment 5-frame splash, HD purge |
| v8-2-2 | `4a92dee` | Sync all 133 4K PNGs to assets/, throbber 106x106, Esper state cleanup |
| v8-2-3 | `93f9239` | CRITICAL: Fix enrollment killed after 6s by kiosk service restart |
| v8-2-4 | `2286a84` | Security: Remove --no-sandbox, Chromium runs as signage user |

### Pending / Next Version
- [x] Validate Esper enrollment end-to-end on fresh flash
- [ ] Wayland/Cage migration for zero-flash boot
- [ ] OTA updates from ODS Cloud dashboard
- [ ] Remote background/content push

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

## Environment

| Machine | IP | Purpose |
|---------|-----|---------|
| ArPi4b (player) | `10.111.123.102` | Production test device |
| jdl-mini-box | `10.111.123.134` | Golden image build server |
| Mac (dev) | local | Development, SCP transfer |
