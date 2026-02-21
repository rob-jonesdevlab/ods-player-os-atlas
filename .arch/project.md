# ODS Player OS Atlas — Architecture

**Last Updated:** February 19, 2026  
**Golden Image:** v5  
**Status:** Production — v5 image built and ready to flash

---

## System Overview

ODS Player OS Atlas converts a Raspberry Pi 5 running Armbian into a locked-down digital signage kiosk. The system operates as a three-layer stack:

```
┌─────────────────────────────────────────────────┐
│ ODS Cloud Dashboard (ods-signage)               │
│ → Playlist management, content upload, pairing  │
│ → https://www.ods-cloud.com                     │
├─────────────────────────────────────────────────┤
│ ODS Player OS Atlas (this repo)                 │
│ → Express server (port 8080)                    │
│ → Chromium kiosk (X11 fullscreen)               │
│ → systemd services (7 production services)      │
│ → Boot UX pipeline (Plymouth → VT1 → Xorg)     │
├─────────────────────────────────────────────────┤
│ Armbian 26.2.1 Trixie (RPi4b/RPi5)             │
│ → Linux 6.18.9, ext4, systemd                  │
│ → DRM/KMS display, Plymouth boot splash         │
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

## Current State (v5)

### Completed
- ✅ 11-step automated firstboot (`atlas_firstboot.sh`, 873 lines)
- ✅ TTY flash fix — VT1 pre-painted black before Plymouth deactivation
- ✅ Tight Xorg ready loop — `xdpyinfo` poll (50ms) replaces fixed `sleep`
- ✅ VT lockdown — getty tty1-6 masked, SysRq disabled, Xorg `DontVTSwitch`
- ✅ System config shortcut — `Ctrl+Alt+Shift+O` opens diagnostics panel
- ✅ Shutdown splash — Plymouth on reboot/poweroff with correct service deps
- ✅ Plymouth ODS theme — bold font, black background, throbber animation
- ✅ Sleep prevention — `consoleblank=0`, DPMS off, suspend/hibernate masked
- ✅ RustDesk remote access — self-hosted relay, systemd service
- ✅ Esper MDM enrollment — Linux agent
- ✅ Health monitor service

### Pending / Next Version (Beacon v2.x)
- [ ] OTA updates from ODS Cloud dashboard
- [ ] Remote background/content push
- [ ] Multi-zone display support
- [ ] Player analytics reporting to dashboard

## Key Patterns

### SUDO_ASKPASS for SSH Builds
`sudo -S` hangs over SSH due to pam_tty. Use `SUDO_ASKPASS` with `sudo -A`:
```bash
cat > /tmp/askpass.sh << "EOF"
#!/bin/bash
echo "password"
EOF
chmod +x /tmp/askpass.sh
export SUDO_ASKPASS=/tmp/askpass.sh
sudo -A bash scripts/inject_atlas.sh <source> <output>
```

### Explicit Paths with Sudo
`sudo` sets `$HOME=/root`, breaking default paths. Always pass explicit paths as arguments.

## Environment

| Machine | IP | Purpose |
|---------|-----|---------|
| ArPi5 (player) | `10.111.123.102` | Production test device |
| jdl-mini-box | `10.111.123.134` | Golden image build server |
| Mac (dev) | local | Development, SCP transfer |
