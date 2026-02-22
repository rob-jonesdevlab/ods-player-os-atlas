# ODS Player OS Atlas — Architecture

**Last Updated:** February 21, 2026  
**Golden Image:** v7-11-OPENBOX  
**Status:** Active iteration — boot UX polish sprint

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

## Current State (v7-11)

### Completed
- ✅ 11-step automated firstboot (`atlas_firstboot.sh`, ~1270 lines)
- ✅ TTY flash fix — VT1 pre-painted black (tty1-3 + framebuffer + kernel printk)
- ✅ Grey flash fix — removed `-background none` (grey stipple), continuous xsetroot repaint loop
- ✅ Plymouth hold — `ods-plymouth-hold.service` blocks `plymouth-quit.service` until kiosk ready
- ✅ Admin auth — `su`/PAM-based (yescrypt-safe, confirmed working on device)
- ✅ Chromium managed policy — password popup and autofill disabled
- ✅ Dark GTK theme — Adwaita-dark via env vars + settings.ini (prevents Chromium white flash)
- ✅ VT lockdown — getty tty1-6 masked, SysRq disabled, Xorg `DontVTSwitch`
- ✅ System config shortcut — `Ctrl+Alt+Shift+O` opens diagnostics panel
- ✅ Shutdown splash — Plymouth on reboot/poweroff with correct service deps
- ✅ Plymouth ODS theme — bold font, black background, throbber animation
- ✅ Sleep prevention — `consoleblank=0`, DPMS off, suspend/hibernate masked, 5-min timer
- ✅ RustDesk remote access — self-hosted relay, systemd service
- ✅ Esper MDM enrollment — Linux agent
- ✅ Health monitor service
- ✅ Boot diagnostics — systemd journal capture per boot

### Version History (v7-x sprint)

| Version | Commit | Key Change |
|---------|--------|------------|
| v7-5 | `9470538` | Admin auth fix (spwd removed), kiosk wrapper v9, Chromium policy |
| v7-6 | `4e61f5b` | su/PAM auth (yescrypt-safe), dark GTK theme |
| v7-7 | `e8d9ec5` | Removed `--force-dark-mode` (grey #3C3C3C), delayed plymouth quit |
| v7-8 | `cbf14b1` | Removed `-background none` (grey stipple), xsetroot in ready loop |
| v7-9 | `f384229` | Unmasked plymouth-quit (boot text leak fix), reverted VT7→VT1 |
| v7-10 | `ecd2562` | ROOT CAUSE: kiosk started 26s after plymouth-quit, service dep fix |
| v7-11 | `a0ae81b` | Continuous xsetroot repaint loop (covers modeset color map resets) |

### Pending / Next Version
- [ ] Static splash image during Xorg startup gap
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
