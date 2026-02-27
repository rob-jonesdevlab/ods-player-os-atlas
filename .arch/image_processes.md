# ODS Atlas — Image Processes

> **Rule:** Insert creates Phase 0. Clone creates Phase 1. Never cross these.

---

## Phase 0: Insert (Base Golden Image)

**Purpose:** Create a fresh golden image from the base Armbian + our ODS instruction set.

**Tool:** `inject_atlas.sh` (loop-mount, inject, unmount)

**Process:**
1. Start with base Armbian image (`Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img`)
2. Run `inject_atlas.sh` on jdl-mini-box — injects `atlas_firstboot.sh`, `atlas-firstboot.service`, `atlas_secrets.conf`
3. Output: `ods-atlas-golden-vN-P-TAG.img`
4. Flash to SD card → firstboot runs → becomes a provisioned device

**When to use:**
- Building from scratch (new Armbian base)
- After updating `atlas_firstboot.sh` with new architecture
- Re-establishing the origin point after a development sprint

**Never use for:**
- Cloning a running dev device
- Creating Phase 1 images

**Commands:**
```bash
# On jdl-mini-box
cd ~/atlas-build
sudo -A bash scripts/inject_atlas.sh \
  /home/jones-dev-lab/atlas-build/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  /home/jones-dev-lab/atlas-build/ods-atlas-golden-vN-P-TAG.img
```

---

## Phase 1: Clone (Dev Device Snapshot)

**Purpose:** Create an exact copy of a running/configured SD card for backup or deployment.

**Tool:** `partclone` + `sfdisk` + `pigz` (partition-level clone with compression)

**Process:**
1. Insert source SD card into jdl-mini-box USB reader
2. Unmount all partitions
3. `sfdisk --dump` → save partition table
4. `partclone.fat32 -c` → clone boot partition (compressed via pigz)
5. `partclone.ext4 -c` → clone root partition (compressed via pigz)
6. Output: directory with `partition-table.dump`, `sdc1-boot.partclone.gz`, `sdc2-root.partclone.gz`

**When to use:**
- Snapshotting a dev device after a milestone (safety net)
- Creating a Phase 1 golden image for deployment (after firstboot completes)
- Preserving a known-good state before risky changes

**Never use for:**
- Creating Phase 0 base images (use inject instead)

### Clone (capture)
```bash
# On jdl-mini-box — source SD card in reader
CLONE_DIR=~/atlas-build/golden-clone-TAG
mkdir -p "$CLONE_DIR"
sudo umount /dev/sdc* 2>/dev/null
sudo sfdisk --dump /dev/sdc > "$CLONE_DIR/partition-table.dump"
sudo partclone.fat32 -c -s /dev/sdc1 | pigz > "$CLONE_DIR/sdc1-boot.partclone.gz"
sudo partclone.ext4 -c -s /dev/sdc2 | pigz > "$CLONE_DIR/sdc2-root.partclone.gz"
cp ~/atlas-build/golden-clone/restore_golden.sh "$CLONE_DIR/"
```

### Restore (deploy)
```bash
# On jdl-mini-box — target SD card in reader
sudo bash ~/atlas-build/golden-clone-TAG/restore_golden.sh /dev/sdc
```

The restore script:
1. Unmounts target partitions
2. Restores partition table via `sfdisk`
3. Restores boot (FAT32) via `partclone.fat32 -r`
4. Restores root (ext4) via `partclone.ext4 -r`
5. Grows root partition to fill all available SD card space

---

## Phase Lifecycle

```
Phase 0 (Insert)     Phase 1 (Clone)      Phase 2 (Boot)       Phase 3 (Boot)
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ Base Armbian  │    │ Provisioned  │    │ Enrollment   │    │ Production   │
│ + firstboot   │───▶│ golden image │───▶│ sealed splash│───▶│ Player OS    │
│ inject_atlas  │    │ partclone    │    │ mgmt server  │    │ full boot    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
    inject_atlas.sh     partclone clone     ods-enrollment-boot   ods-player-boot-wrapper
                        + restore           (no Chromium/Xorg)    (full boot pipeline)
```

## Safety Net Clones (Dev Sprint Pattern)

During rapid development, use the clone process to create safety nets:

```bash
# Before risky changes
golden-clone-v8-0-6-FLASH/     # Dev device snapshot (safety net)

# After successful milestone
golden-clone-v8-1-0-FEATURE/   # New feature verified, snapshot saved
```

**Sprint pattern:** Develop → Verify → Clone → Develop → Verify → Clone

This ensures you can always roll back to the last known-good state without rebuilding from Phase 0.

---

## Phase 2: Shrink + DD (Etcher-Ready Clone Image)

**Purpose:** Create a compact `.img` file suitable for flashing to any SD card with Etcher. The image self-expands on first boot.

**Tool:** `e2fsck` + `resize2fs -M` + `fdisk` + `dd`

**Process:**
1. After Phase 1 firstboot completes, insert SD card into jdl-mini-box
2. Verify Phase 1 checks (Chromium, node, services, machine-id, resize symlink)
3. Unmount all partitions
4. `e2fsck -f` → filesystem check
5. `resize2fs -M` → shrink filesystem to minimum used blocks
6. `fdisk` → shrink partition to match filesystem + 5% buffer
7. `dd` → copy only the used sectors to a compact `.img` file
8. Output: `ods-atlas-clone-vN-P-TAG.img` (~4.5 GB)

**When to use:**
- Creating production deployment images after P:1 verification
- Building flashable images for distribution

**Key detail:** The `armbian-resize-filesystem` service is re-enabled by `finalize_phase1()` during Phase 1 completion. When a clone boots, this service auto-expands the partition to fill the entire SD card. Without this, clones boot with a stuck 4G partition.

### Shrink + DD commands
```bash
# On jdl-mini-box — SD card in reader after P:1 completes
# 1. Unmount
sudo umount /media/jones-dev-lab/armbi_root1
sudo umount /media/jones-dev-lab/RPICFG1

# 2. Check + shrink filesystem
sudo e2fsck -f -y /dev/sdc2
sudo resize2fs -M /dev/sdc2

# 3. Calculate new partition size
BLOCK_COUNT=$(sudo dumpe2fs -h /dev/sdc2 2>/dev/null | grep "Block count" | awk '{print $3}')
BLOCK_SIZE=$(sudo dumpe2fs -h /dev/sdc2 2>/dev/null | grep "Block size" | awk '{print $3}')
FS_SECTORS=$((BLOCK_COUNT * BLOCK_SIZE / 512))
BUFFER=$((FS_SECTORS * 5 / 100))
NEW_SECTORS=$(( (FS_SECTORS + BUFFER + 7) / 8 * 8 ))
P2_START=1056768
P2_END=$((P2_START + NEW_SECTORS - 1))
TOTAL=$((P2_END + 1))

# 4. Shrink partition
echo -e "d\n2\nn\np\n2\n${P2_START}\n${P2_END}\nw" | sudo fdisk /dev/sdc

# 5. Verify
sudo e2fsck -f -y /dev/sdc2

# 6. DD clone
sudo dd if=/dev/sdc of=~/atlas-build/ods-atlas-clone-vN-P-TAG.img \
    bs=512 count=${TOTAL} status=progress

# 7. Transfer to Mac
scp ~/atlas-build/ods-atlas-clone-vN-P-TAG.img ~/Desktop/
```

### Verification checklist (run BEFORE shrink)
```
Phase: 2              ✅ Phase 1 ran
Gate file: present    ✅ Phase 2 enrollment will run
Chromium:             ✅ Installed
node/npm/git:         ✅ Installed
RustDesk:             ✅ Installed
server.js:            ✅ Deployed
node_modules:         ✅ 100+ packages
ODS services:         ✅ 12 services
Plymouth theme:       ✅ 138 files
Machine-ID:           ✅ Cleared
Firstboot enabled:    ✅ For Phase 2
Resize service:       ✅ Re-enabled for clones
```

---

## Storage Locations

| Location | Purpose |
|----------|---------|
| `~/atlas-build/` on jdl-mini-box | Active builds and clones |
| `~/Desktop/` on Mac | Staging (one image at a time) |
| `/Volumes/NVME_VAULT/golden-atlas-img/` | Permanent archive |

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `inject_atlas.sh` | `scripts/` in repo | Phase 0 image builder |
| `atlas_firstboot.sh` | `scripts/` in repo | Firstboot provisioning |
| `restore_golden.sh` | `golden-clone*/` on jdl-mini-box | Phase 1 clone restore |
| `atlas_secrets.conf` | `~/atlas-build/scripts/` on jdl-mini-box | Credentials (NOT in git) |

---

## Lima Portable Build Environment (Offsite)

> **The Lima VM replaces jdl-mini-box for both Insert and Clone when working offsite.**

### Setup (one-time)
```bash
brew install lima
limactl create --name=atlas-build tools/atlas-build.yaml
limactl start atlas-build
```

### VM Quick Reference
```bash
limactl shell atlas-build     # Shell into VM
limactl stop atlas-build       # Suspend (instant resume later)
limactl start atlas-build      # Resume
```

### Phase 0: Insert via Lima
```bash
# 1. Shell into Lima
limactl shell atlas-build

# 2. Navigate to repo (same path as Mac — shared virtiofs mount)
cd /Users/robert.leejones/Documents/GitHub/ods-player-os-atlas

# 3. Run insert (identical to jdl-mini-box)
sudo bash scripts/inject_atlas.sh \
  /path/to/Armbian_26.2.1_Rpi4b_trixie_current_6.18.9_minimal.img \
  ~/Desktop/ods-atlas-golden-vN-P-TAG.img

# 4. Output .img appears on Mac Desktop immediately (shared filesystem)
# 5. Flash to SD card from Mac using Raspberry Pi Imager or dd
```

### Phase 1: Clone / Restore via Lima
```bash
# Clone an SD card (from Mac terminal — ods-sd handles the bridge)
tools/ods-sd clone /dev/diskN my-backup-name

# Restore an SD card
tools/ods-sd restore /dev/diskN my-backup-name

# List available clones
tools/ods-sd list
```

**How `ods-sd` works under the hood:**
1. Mac `dd` reads raw SD card → shared work dir (`/tmp/lima-sd-work/`)
2. Lima `losetup` mounts the raw image as a loopback device
3. Lima `partclone` clones each partition (filesystem-aware, compressed)
4. Output is identical format to jdl-mini-box `golden-clone/`

### Where to Put the Base Armbian Image

| Location | When to Use |
|----------|-------------|
| `~/Desktop/` | Quick access (shared into Lima) |
| Repo `images/` | Versioned base images (gitignored) |
| `/tmp/lima-sd-work/` | Temporary working copies |

### Prerequisites Checklist
- [ ] `brew install lima` 
- [ ] `limactl create --name=atlas-build tools/atlas-build.yaml`
- [ ] `atlas_secrets.conf` copied into Lima (see below)
- [ ] Base Armbian `.img` available on shared path

### Secrets for Lima (first time only)
```bash
# Copy secrets into the VM's working directory
limactl shell atlas-build -- bash -c 'mkdir -p ~/atlas-build/scripts'
# Then manually create ~/atlas-build/scripts/atlas_secrets.conf inside Lima
# (contains passwords — never commit to git)
```

