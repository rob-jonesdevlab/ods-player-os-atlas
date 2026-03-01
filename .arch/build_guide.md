# Golden Image Build Guide — ODS Player OS Atlas

**Build Server:** `jdl-mini-box` (Ubuntu, `10.111.123.134`)  
**User:** `jones-dev-lab` (password: `mnbvcxz!!!`)  
**Build Dir:** `/home/jones-dev-lab/atlas-build/`
**Dev Device:** ArPi4b at `10.111.123.102` (root password: `0D5@dm!n`)

---

## Prerequisites

### On jdl-mini-box
```
~/atlas-build/
├── Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img   # Base image
├── ods-player-os-atlas/                                        # Git clone (pulled before build)
│   └── scripts/
│       ├── inject_atlas.sh
│       ├── atlas_firstboot.sh
│       ├── atlas-firstboot.service
│       ├── atlas_secrets.conf                                  # Sensitive — see below
│       ├── ods-player-boot-wrapper.sh
│       ├── start-player-os-ATLAS.sh
│       ├── ods-phase-selector.sh
│       ├── ods-enrollment-boot.sh
│       └── generate_splash_frames.sh
└── ods-atlas-golden-v9-1-7-ORIGIN.img                          # Output (built)
```

### `atlas_secrets.conf` (in repo)
This file contains production credentials and IS checked into the private repo.
On the device it lives at `/usr/local/etc/atlas_secrets.conf` (chmod 600).

---

## Build Steps

### 1. SSH to Build Server
```bash
export SSHPASS='mnbvcxz!!!'
sshpass -e ssh -o StrictHostKeyChecking=no jones-dev-lab@10.111.123.134
```

### 2. Setup SUDO_ASKPASS
`sudo -S` hangs over SSH. Use `SUDO_ASKPASS` instead:
```bash
cat > /tmp/askpass.sh << "EOF"
#!/bin/bash
echo "mnbvcxz!!!"
EOF
chmod +x /tmp/askpass.sh
export SUDO_ASKPASS=/tmp/askpass.sh
```

### 3. Update Scripts from GitHub
```bash
cd ~/atlas-build
git -C ods-player-os-atlas pull origin main
```

### 4. Run Build
```bash
# Remove old output
sudo -A rm -f ~/atlas-build/ods-atlas-golden-*.img

# Build (MUST pass explicit paths — sudo changes $HOME to /root)
cd ~/atlas-build/ods-player-os-atlas
sudo -A bash scripts/inject_atlas.sh \
  /home/jones-dev-lab/atlas-build/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  /home/jones-dev-lab/atlas-build/ods-atlas-golden-v9-1-7-ORIGIN.img
```

### 5. Copy Image to Mac Desktop (ALWAYS)
Every golden image must be copied to Mac Desktop immediately after build:
```bash
# From Mac:
SSHPASS='mnbvcxz!!!' sshpass -e scp -o StrictHostKeyChecking=no \
  jones-dev-lab@10.111.123.134:~/atlas-build/ods-atlas-golden-vX-Y-Z-TAG.img ~/Desktop/
```

### 6. Flash to SD Card
Use Etcher (recommended) or:
```bash
# macOS (find disk with diskutil list)
sudo dd if=~/Desktop/ods-atlas-golden-v9-1-7-ORIGIN.img of=/dev/rdiskN bs=4m status=progress
```

### 7. First Boot
Insert SD card, power on. `atlas_firstboot.sh` runs automatically:
- Phase 1: Package install + user creation + app deploy + services → shutdown
- Power cycle → Phase 2: Esper enrollment → reboot
- Phase 3: Production player boot

---

## Deploying Updates to the Dev Device

For iterative testing (without rebuilding P:0), deploy scripts directly:

```bash
# SSH credentials for the dev device
export SSHPASS='0D5@dm!n'

# Deploy boot wrapper
sshpass -e scp -o StrictHostKeyChecking=no \
  scripts/ods-player-boot-wrapper.sh root@10.111.123.102:/usr/local/bin/

# Deploy Chromium launcher
sshpass -e scp -o StrictHostKeyChecking=no \
  scripts/start-player-os-ATLAS.sh root@10.111.123.102:/usr/local/bin/start-player-ATLAS.sh

# Deploy splash assets
sshpass -e scp -o StrictHostKeyChecking=no \
  brand/splash/generated/*.png brand/splash/generated/*.raw \
  root@10.111.123.102:/usr/share/plymouth/themes/ods/

# Reboot to test
sshpass -e ssh -o StrictHostKeyChecking=no root@10.111.123.102 'reboot'
```

> **Important:** Dev device deployment is for testing only. Everything must ultimately be captured in `atlas_firstboot.sh` so that a fresh P:0 inject produces the same result.

---

## Gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| `sudo -S` hangs over SSH | pam_tty blocks stdin password | Use `SUDO_ASKPASS` + `sudo -A` |
| `Source image not found: /root/atlas-build/...` | sudo sets `$HOME=/root` | Pass explicit paths as arguments |
| Build server doing apt updates | Unattended-upgrades running after boot | Wait or `sudo kill` the process |
| SSH auth failure with `-tt` flag | `sshpass` + `-tt` conflict with `!!!` in password | Use `SSHPASS=... sshpass -e` (env var) |
| Loop device stale after failed build | `losetup -l` shows lingering loops | `sudo losetup -d /dev/loopN` |
| SSH permission denied on dev device | Using build server password | Check `atlas_secrets.conf` for device root password |
| Overlay shows tiny image at 1080p | 4K PNG displayed without resize | Already fixed in wrapper — uses `convert -resize` |
| Splash frames not updating on device | Old files in Plymouth theme dir | Clean old files before deploying new ones |
| `apt-get install` fails with 404 on Chromium | Clock skew — Pi clock at image date, signatures rejected | NTP sync in `wait_for_network()` before apt |
| `set -e` aborts firstboot silently | Any non-zero return kills the script | Replaced with `set -o pipefail` + ERR trap |
| Cloned card doesn't expand partition | `armbian-resize-filesystem` self-deletes after P:1 boot | `finalize_phase1()` re-enables the service |
| Esper enrollment fails with 'No space left' | Partition stuck at 4G — resize didn't run | See above — resize service re-enable fix |

## Version Naming

```
ods-atlas-golden-vMAJOR-PATCH-TAG.img
```

| Component | Example | Description |
|-----------|---------|-------------|
| `vMAJOR` | `v8` | Major version (sequential) |
| `PATCH` | `3-3` | Minor-patch within major |
| `TAG` | `PLAYER` | Human-readable milestone (ALLCAPS) |

### Immutable Versioning Rules

1. **Never overwrite** — every build gets a unique version
2. **Desktop = staging** — delete old version before placing new build
3. **NVME_VAULT = archive** — all builds preserved at `/Volumes/NVME_VAULT/golden-atlas-img/`
4. **jdl-mini-box** — may retain only latest build

---

## Lima Portable Build Environment (Offsite)

When working away from jdl-mini-box, use Lima VM on Mac:

```bash
# Setup (one-time)
brew install lima
limactl create --name=atlas-build tools/atlas-build.yaml
limactl start atlas-build

# Shell in and build (same commands as jdl-mini-box)
limactl shell atlas-build
cd /Users/robert.leejones/Documents/GitHub/ods-player-os-atlas
sudo bash scripts/inject_atlas.sh \
  /path/to/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  ~/Desktop/ods-atlas-golden-vN-P-TAG.img
```

Output appears directly on Mac Desktop via shared virtiofs mount.

See `.arch/image_processes.md` for the full Phase 0-3 lifecycle including Lima clone/restore commands.
