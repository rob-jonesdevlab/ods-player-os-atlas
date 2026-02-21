# Boot UX Pipeline — ODS Player OS Atlas v5

**Purpose:** Document the complete visual pipeline from power-on to Chromium kiosk.

---

## The Problem

During the Plymouth → Xorg handoff, the bare Linux VT1 console (white/grey background) flashes briefly on screen. This creates an unprofessional visual artifact during boot.

## The Solution (v5)

Pre-paint VT1 completely black **before** Plymouth releases DRM control. When Plymouth deactivates, the user sees black → black (no flash).

## Pipeline Sequence

### Phase 1: Kernel Boot
```
Kernel parameters (cmdline.txt):
  splash quiet                        — enable Plymouth
  loglevel=3                          — suppress verbose kernel output
  consoleblank=0                      — prevent console blanking
  vt.global_cursor_default=0          — hide cursor globally
  plymouth.ignore-serial-consoles     — prevent serial console interference
```

### Phase 2: Plymouth Splash
```
Plymouth ODS theme (/usr/share/plymouth/themes/ods/):
  ModuleName=two-step
  Font=DejaVu Sans Bold 15
  TitleFont=DejaVu Sans Mono Bold 30
  BackgroundStartColor=0x000000       — solid black
  UseFirmwareBackground=false         — ignore firmware splash
  DialogClearsFirmwareBackground=false
```

### Phase 3: TTY Flash Fix (ods-kiosk-wrapper.sh)
```bash
# 1) Black-on-black text + hide cursor
setterm --foreground black --background black --cursor off > /dev/tty1

# 2) Clear screen to black
printf '\033[2J\033[H' > /dev/tty1

# 3) Suppress all console output
echo 0 > /proc/sys/kernel/printk
stty -echo -F /dev/tty1

# 4) Fill framebuffer with black pixels
dd if=/dev/zero of=/dev/fb0 bs=65536 count=128 conv=notrunc
```

### Phase 4: Plymouth Deactivate
```bash
plymouth deactivate   # Releases DRM — VT1 is already black, no flash
```

### Phase 5: Xorg Start
```bash
Xorg :0 -nolisten tcp -novtswitch -background none vt1 &

# Tight ready loop (replaces fixed sleep)
for i in $(seq 1 40); do
    xdpyinfo -display :0 >/dev/null 2>&1 && break
    sleep 0.05
done

xsetroot -solid "#000000"             # Paint X root black immediately
xset -dpms; xset s off; xset s noblank  # Disable all screen blanking
```

### Phase 6: Chromium Launch
```bash
chromium --kiosk --no-sandbox \
  --default-background-color=000000 \  # Black until page loads
  --force-dark-mode \
  "http://localhost:8080/network_setup.html"
```

### Phase 7: Plymouth Quit
```bash
# Wait for page ready signal (/tmp/ods-loader-ready)
# Then: sleep 2 (paint delay)
plymouth quit    # X is already on VT1, no chvt needed
```

## Supporting Services

| Service | Role |
|---------|------|
| `ods-plymouth-hold.service` | Keeps Plymouth alive during early boot (15s delay) |
| `ods-hide-tty.service` | Pre-suppresses VT1 output before getty |
| `ods-shutdown-splash.service` | Shows Plymouth on reboot/poweroff |

## VT Lockdown

| Mechanism | File | Effect |
|-----------|------|--------|
| Xorg `DontVTSwitch` | `/etc/X11/xorg.conf.d/10-no-vtswitch.conf` | Blocks Ctrl+Alt+Fn |
| Xorg `DontZap` | same file | Blocks Ctrl+Alt+Backspace |
| Xorg `-novtswitch` | `ods-kiosk-wrapper.sh` | Belt-and-suspenders |
| getty@tty1-6 masked | systemd | No login prompts on any VT |
| SysRq disabled | `/etc/sysctl.d/99-no-vtswitch.conf` | kernel.sysrq=0 |
| matchbox `-use_cursor no` | `ods-kiosk-wrapper.sh` | No cursor visible |

## Visual Timeline

```
t=0s    Power on
t=2s    Plymouth splash visible (ODS logo + throbber)
t=8s    ods-kiosk-wrapper.sh starts
t=8.1s  VT1 pre-painted black (TTY flash fix)
t=8.2s  Plymouth deactivated (no flash)
t=8.5s  Xorg running, root window black
t=9s    Chromium launched
t=12s   Page loaded, loader-ready signal
t=14s   Plymouth quit — seamless transition complete
```
