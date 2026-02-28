# ODS Player OS — Atlas

**Version:** v9-3-2-ORIGIN · **Code Name:** Atlas  
**Purpose:** Dedicated player OS runtime for ODS digital signage  
**Last Updated:** February 28, 2026

---

## Overview

Atlas is the foundation release of ODS Player OS. It transforms a bare Armbian 26.2.1 (Trixie) image into a production-ready, auto-recovering kiosk that pairs with the [ODS Cloud dashboard](https://www.ods-cloud.com), displays content playlists, and provides remote management via Esper MDM and RustDesk.

The golden image is built offline on the `jdl-mini-box` build server, then flashed to SD cards. On first boot, `atlas_firstboot.sh` (systemd oneshot) converts the base Armbian into a fully provisioned player in ~15 minutes.

---

## Key Features

| Feature | Details |
|---------|---------|
| **Device Pairing** | QR code pairing with ODS Cloud dashboard |
| **Network Config** | WiFi + Ethernet setup UI (`network_setup.html`) |
| **Captive Portal** | Auto-launching setup for phone-based WiFi config (`captive_portal.html`) |
| **System Options** | On-device diagnostics panel (`system_options.html`, `Ctrl+Alt+Shift+O`) |
| **Player Ready** | Status page with glass card + wallpaper support (`player_ready.html`, `Ctrl+Alt+Shift+I`) |
| **Status Pill** | 8-stage color pill showing connection/config state on Player Ready |
| **Glass Card** | Smokey dark glass card with backdrop-filter blur when wallpaper assigned |
| **Kiosk Mode** | Auto-recovering Chromium kiosk (systemd restart loop) |
| **Boot UX** | Seamless black boot → Plymouth splash → Chromium (zero flash) |
| **Keyboard Shortcuts** | `Ctrl+Alt+Shift+I` (Info), `K` (Kill), `O` (Options), `B` (Debug) |
| **Offline Border** | Configurable animated border (6 templates, 0.450px default) |
| **VT Lockdown** | getty tty1-6 masked, SysRq disabled, VT switching blocked |
| **Sleep Prevention** | `consoleblank=0`, DPMS off, screen blanking off, suspend masked |
| **Remote Access** | RustDesk with self-hosted relay server |
| **MDM** | Esper MDM enrollment (Linux agent) |
| **Health Monitor** | Automated health checks via `ods_health_monitor.sh` |

---

## Boot UX Pipeline (v5)

The boot sequence has been carefully engineered for a seamless, flash-free visual experience:

```
Power On
  │
  ├─ Kernel loads with: splash quiet loglevel=3 consoleblank=0 vt.global_cursor_default=0
  │
  ├─ Plymouth ODS theme → black background, ODS logo watermark, throbber animation
  │     (UseFirmwareBackground=false, DialogClearsFirmwareBackground=false)
  │
  ├─ ods-kiosk-wrapper.sh starts:
  │     1. Wait for DRM (/dev/dri/card*)
  │     2. ── TTY FLASH FIX ──
  │     │   • setterm: black-on-black text, cursor off on VT1
  │     │   • printf: clear VT1 screen
  │     │   • printk 0 + stty -echo: suppress console output
  │     │   • dd /dev/zero → /dev/fb0: fill framebuffer black
  │     3. plymouth deactivate (VT1 is already black → no flash)
  │     4. Xorg :0 vt1 -novtswitch -background none
  │     5. xdpyinfo poll loop (50ms intervals, max 2s)
  │     6. xsetroot -solid "#000000"
  │     7. matchbox-window-manager + unclutter
  │     8. start-kiosk.sh (Chromium --kiosk --default-background-color=000000)
  │     9. Wait for /tmp/ods-loader-ready signal
  │    10. plymouth quit → seamless transition to Chromium
  │
  └─ Result: Black → ODS splash → Black → Chromium (no white/grey flash)
```

---

## Architecture

```
ods-player-atlas/
├── public/                       # Web server public directory
│   ├── network_setup.html        # Network configuration UI (default kiosk page)
│   ├── player_ready.html         # Player Ready status page (glass card + status pill)
│   ├── player_link.html          # QR code pairing flow
│   ├── captive_portal.html       # WiFi AP captive portal setup
│   ├── system_options.html       # System diagnostics panel (Ctrl+Alt+Shift+O)
│   ├── enrolling.html            # Enrollment status
│   ├── loader.html               # Boot loader screen
│   └── resources/
│       └── designs/
│           └── ODS_Background.png  # Default wallpaper for glass card
├── server.js                     # Express server (port 8080, 43 API endpoints)
├── package.json                  # Node.js dependencies
├── VERSION                       # Current version code name ("atlas")
├── bin/
│   └── ods_health_monitor.sh     # Health monitoring script
├── brand/
│   └── splash/                   # Plymouth theme assets (landscape/portrait)
├── scripts/
│   ├── inject_atlas.sh           # Golden image builder (loop-mount + inject)
│   ├── atlas_firstboot.sh        # 11-step automated first boot (~1400 lines)
│   ├── atlas-firstboot.service   # systemd oneshot service
│   ├── start-player-os-ATLAS.sh  # Chromium --app mode launcher
│   ├── ods-setup-ap.sh           # WiFi AP management
│   └── atlas_secrets.conf        # Credentials (NOT in git)
├── .arch/
│   ├── project.md                # Full architecture documentation
│   └── api_doc.md                # API documentation (43 endpoints)
└── README.md
```

---

## Golden Image Build Process

### Prerequisites

- **Build server:** `jdl-mini-box` (Ubuntu, IP `10.111.123.134`)
- **Base image:** `Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img`
- **Credentials:** `atlas_secrets.conf` with GitHub token, Esper keys, RustDesk config

### Build Command

```bash
# SSH to build server
ssh jones-dev-lab@10.111.123.134

# Setup sudo access (SUDO_ASKPASS required over SSH)
cat > /tmp/askpass.sh << "EOF"
#!/bin/bash
echo "your-password"
EOF
chmod +x /tmp/askpass.sh
export SUDO_ASKPASS=/tmp/askpass.sh

# Update scripts from GitHub
cd ~/atlas-build
sudo -A rm -f ods-atlas-rpi5-golden-v5.img
git -C scripts-repo pull  # or re-clone

# Build with explicit paths (sudo changes $HOME)
sudo -A bash scripts/inject_atlas.sh \
  /home/jones-dev-lab/atlas-build/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  /home/jones-dev-lab/atlas-build/ods-atlas-rpi5-golden-v5.img

# Copy to Mac
scp jones-dev-lab@10.111.123.134:~/atlas-build/ods-atlas-rpi5-golden-v5.img ~/Desktop/
```

### What `inject_atlas.sh` Does

1. Copies base Armbian image → output image
2. Loop-mounts the image (`losetup --partscan`)
3. Checks filesystem (`e2fsck`)
4. Mounts rootfs (partition 2)
5. Injects: `atlas_firstboot.sh`, `atlas-firstboot.service`, `atlas_secrets.conf`
6. Enables firstboot service at `multi-user.target`
7. Patches boot partition `cmdline.txt` (consoleblank, splash, cursor, loglevel)
8. Unmounts and produces output image (~1.8 GB)

### What `atlas_firstboot.sh` Does (11 Steps)

| Step | Action | Key Details |
|------|--------|-------------|
| 1 | Bypass Armbian first-login | Set root password, disable firstlogin service |
| 2 | Install packages | chromium, xorg, matchbox, plymouth, nodejs, npm, git |
| 3 | Create users | `signage` (kiosk, no password), `otter` (admin, sudo) |
| 4 | Clone & deploy Atlas | Git clone → `/home/signage/ODS/`, npm install |
| 5 | Deploy systemd services | 6 services: kiosk, webserver, health monitor, plymouth-hold, hide-tty, shutdown-splash |
| 6 | Deploy kiosk scripts | `start-kiosk.sh`, `ods-kiosk-wrapper.sh` (with TTY flash fix), `hide-tty.sh` |
| 7 | Install Plymouth theme | ODS branded splash, `two-step` module, bold fonts, black background |
| 8 | Configure boot params | VT lockdown (Xorg `DontVTSwitch`, getty mask, SysRq disable), sleep prevention, kernel cmdline patches |
| 9 | Enroll Esper MDM | Download + run Esper Linux agent setup |
| 10 | Install RustDesk | ARM64 .deb, self-hosted relay config, systemd service |
| 11 | Finalize | Disable firstboot service, copy logs, reboot to production |

---

## Systemd Services (Production)

| Service | Purpose | Type |
|---------|---------|------|
| `ods-kiosk.service` | X11 + Chromium kiosk wrapper | simple, restart=always |
| `ods-webserver.service` | Node.js Express server (port 8080) | simple, User=signage |
| `ods-health-monitor.service` | Automated health checks | simple, restart=always |
| `ods-plymouth-hold.service` | Hold Plymouth splash until kiosk starts | oneshot |
| `ods-hide-tty.service` | Suppress TTY1 text output | oneshot |
| `ods-shutdown-splash.service` | Show Plymouth on reboot/shutdown | oneshot |
| `ods-rustdesk-enterprise.service` | RustDesk remote access | simple, restart=always |

---

## Server API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/status` | Network + device status (hostname, WiFi, Ethernet) |
| POST | `/api/wifi/configure` | Configure WiFi (SSID + password) |
| GET | `/api/qr` | Generate setup QR code |
| POST | `/api/enroll` | Trigger device enrollment |
| GET | `/api/loader-ready` | Signal boot loader is ready |
| GET | `/api/system/info` | System diagnostics |
| POST | `/api/system/restart-signage` | Kill/restart Chromium (Ctrl+Alt+Shift+K) |
| POST | `/api/system/reboot` | Reboot device |
| POST | `/api/system/shutdown` | Shutdown device |
| POST | `/api/system/cache-clear` | Clear Chromium cache |
| POST | `/api/system/factory-reset` | Factory reset (wipe + reboot) |
| GET | `/api/system/logs` | View system logs |

> See `.arch/api_doc.md` for all 43 endpoints.

---

## File Locations (on device)

| Component | Path |
|-----------|------|
| Player Runtime | `/home/signage/ODS/` |
| Public Files | `/home/signage/ODS/public/` |
| Server | `/home/signage/ODS/server.js` |
| Health Monitor | `/home/signage/ODS/bin/ods_health_monitor.sh` |
| Boot Logs | `/home/signage/ODS/logs/boot/` |
| Kiosk Script | `/usr/local/bin/start-kiosk.sh` |
| Kiosk Wrapper | `/usr/local/bin/ods-kiosk-wrapper.sh` |
| Hide TTY Script | `/usr/local/bin/hide-tty.sh` |
| Plymouth Theme | `/usr/share/plymouth/themes/ods/` |
| Xorg No-VT Config | `/etc/X11/xorg.conf.d/10-no-vtswitch.conf` |
| Secrets | `/usr/local/etc/atlas_secrets.conf` (chmod 600) |

---

## Version History

| Image | Date | Key Changes |
|-------|------|-------------|
| v1 (golden) | Feb 17, 2026 | Initial build — basic kiosk, Plymouth, services |
| v4 | Feb 18, 2026 | VT lockdown (getty mask, SysRq off), shutdown splash fix |
| **v5** | **Feb 19, 2026** | **TTY flash fix (VT1 pre-paint), tight Xorg ready loop, Ctrl+Alt+Shift+O shortcut** |

---

## Known Issues & Gotchas

| Issue | Details | Status |
|-------|---------|--------|
| `sudo -S` over SSH hangs | Use `SUDO_ASKPASS` with `-A` flag instead | ✅ Workaround |
| `inject_atlas.sh` path with sudo | Pass explicit paths as args (sudo sets `$HOME=/root`) | ✅ Fixed |
| `package.json` name | Still says `ods-wifi-setup` — legacy artifact | ⚠️ Cosmetic |
| Armbian auto-updates | `jdl-mini-box` may install updates and reboot during builds | ⚠️ Monitor |

---

## Next Version

**v9-3-2** (current) — Player Ready Overhaul & Glass Card

- Smokey glass card with wallpaper support
- 8-stage status pill
- Keyboard shortcuts: `Ctrl+Alt+Shift+I/K/O/B`
- Config `appearance` section (wallpaper, card style)
- Restart-signage API endpoint
- File renames for clarity

---

## Development

### Local Testing

```bash
npm install
npm start
# Access: http://localhost:8080/network_setup.html
# Access: http://localhost:8080/system_options.html
# Access: http://localhost:8080/player_ready.html
```

### Deploy Changes to Device

```bash
scp public/*.html root@10.111.123.102:/home/signage/ODS/public/
scp server.js root@10.111.123.102:/home/signage/ODS/
ssh root@10.111.123.102 'systemctl restart ods-webserver'
```

### Troubleshooting

| Problem | Check |
|---------|-------|
| No display | `systemctl status ods-kiosk`, `journalctl -u ods-kiosk` |
| Server not running | `systemctl status ods-webserver` |
| Boot logs | `ls -la /home/signage/ODS/logs/boot/` |
| White flash on boot | Verify `ods-kiosk-wrapper.sh` has TTY FLASH FIX section |
| VT switching works | Verify `10-no-vtswitch.conf` exists and getty@tty* are masked |

---

## License

Copyright © 2026 ODS Cloud. All rights reserved.
