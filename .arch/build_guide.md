# Golden Image Build Guide — ODS Player OS Atlas

**Build Server:** `jdl-mini-box` (Ubuntu, `10.111.123.134`)  
**User:** `jones-dev-lab`  
**Build Dir:** `/home/jones-dev-lab/atlas-build/`

---

## Prerequisites

### On jdl-mini-box
```
~/atlas-build/
├── Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img   # Base image
├── scripts/                                                    # Symlink or clone
│   ├── inject_atlas.sh
│   ├── atlas_firstboot.sh
│   ├── atlas-firstboot.service
│   └── atlas_secrets.conf                                      # NOT in git
└── ods-atlas-rpi5-golden-v5.img                               # Output (built)
```

### `atlas_secrets.conf` (template)
```bash
ROOT_PASSWORD="your-root-password"
OTTER_PASSWORD="your-otter-password"
GITHUB_USERNAME="your-github-user"
GITHUB_TOKEN="your-github-pat"
ESPER_TENANT="your-esper-tenant"
ESPER_TOKEN="your-esper-token"
ESPER_BLUEPRINT="your-blueprint-id"
ESPER_GROUP="your-group-id"
RUSTDESK_VERSION="1.3.7"
RUSTDESK_RELAY="your-relay-ip"
RUSTDESK_KEY="your-relay-key"
RUSTDESK_PASSWORD="your-rustdesk-password"
```

---

## Build Steps

### 1. SSH to Build Server
```bash
ssh jones-dev-lab@10.111.123.134
```

### 2. Setup SUDO_ASKPASS
`sudo -S` hangs over SSH. Use `SUDO_ASKPASS` instead:
```bash
cat > /tmp/askpass.sh << "EOF"
#!/bin/bash
echo "your-password"
EOF
chmod +x /tmp/askpass.sh
export SUDO_ASKPASS=/tmp/askpass.sh
```

### 3. Update Scripts from GitHub
```bash
cd ~/atlas-build
# Pull latest or re-clone
git -C ods-player-os-atlas pull origin main
# Or fresh clone:
# git clone https://github.com/rob-jonesdevlab/ods-player-os-atlas.git
```

### 4. Run Build
```bash
# Remove old output
sudo -A rm -f ~/atlas-build/ods-atlas-rpi5-golden-v5.img

# Build (MUST pass explicit paths — sudo changes $HOME to /root)
cd ~/atlas-build
sudo -A bash ods-player-os-atlas/scripts/inject_atlas.sh \
  /home/jones-dev-lab/atlas-build/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  /home/jones-dev-lab/atlas-build/ods-atlas-rpi5-golden-v5.img
```

### 5. Transfer to Mac
```bash
# From Mac:
scp jones-dev-lab@10.111.123.134:~/atlas-build/ods-atlas-rpi5-golden-v5.img ~/Desktop/

# Or with sshpass for scripted transfer:
SSHPASS='password' sshpass -e scp -o StrictHostKeyChecking=no \
  jones-dev-lab@10.111.123.134:~/atlas-build/ods-atlas-rpi5-golden-v5.img ~/Desktop/
```

### 6. Flash to SD Card
Use Raspberry Pi Imager or:
```bash
# macOS (find disk with diskutil list)
sudo dd if=~/Desktop/ods-atlas-rpi5-golden-v5.img of=/dev/rdiskN bs=4m status=progress
```

---

## Gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| `sudo -S` hangs over SSH | pam_tty blocks stdin password | Use `SUDO_ASKPASS` + `sudo -A` |
| `Source image not found: /root/atlas-build/...` | sudo sets `$HOME=/root` | Pass explicit paths as arguments |
| Build server doing apt updates | Unattended-upgrades running after boot | Wait or `sudo kill` the process |
| SSH auth failure with `-tt` flag | `sshpass` + `-tt` conflict with `!!!` in password | Use `SSHPASS=... sshpass -e` (env var) |
| Loop device stale after failed build | `losetup -l` shows lingering loops | `sudo losetup -d /dev/loopN` |

## Version Naming

| Name | Meaning |
|------|---------|
| `ods-atlas-rpi5-golden.img` | Default output (no version suffix) |
| `ods-atlas-rpi5-golden-v5.img` | Versioned output (current) |

Always build with an explicit version suffix to avoid overwriting the default.
