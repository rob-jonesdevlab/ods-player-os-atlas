# Boot UX Pipeline — ODS Player OS Atlas v7-11

**Purpose:** Document the complete visual pipeline from power-on to Chromium kiosk.  
**Kiosk Wrapper:** v11  
**Last Updated:** February 21, 2026

---

## The Problem

During the Plymouth → Xorg handoff, multiple visual artifacts can appear:

| Issue | Root Cause | Status |
|-------|-----------|--------|
| White TTY flash | Bare VT1 console visible during handoff | ✅ Fixed (v5) |
| White Chromium flash | Chromium renders white before CSS loads | ✅ Fixed (v7-6: dark GTK theme) |
| Grey Chromium flash | `--force-dark-mode` renders #3C3C3C | ✅ Fixed (v7-7: removed flag) |
| Grey Xorg root | `-background none` = grey stipple default | ✅ Fixed (v7-8: removed flag) |
| 26s bare TTY gap | `plymouth-quit` fires before kiosk starts | ✅ Fixed (v7-10: service deps) |
| Grey modeset resets | KMS color map re-initialized 6+ times | 🔄 Fix in test (v7-11: repaint loop) |

## The Solution (v7-11)

Multi-layer approach: Paint VT1 black before Plymouth releases DRM. Block `plymouth-quit` until kiosk has display control. Continuous xsetroot repaint loop covers modeset driver color map resets.

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

### Phase 3: Plymouth Hold (systemd)
```
ods-plymouth-hold.service:
  After=plymouth-start.service
  Before=plymouth-quit.service plymouth-quit-wait.service
  Polls for /tmp/ods-kiosk-starting (kiosk wrapper signal)
  Blocks plymouth-quit from firing until kiosk has display control
```

### Phase 4: VT1 Blackout (ods-kiosk-wrapper.sh)
```bash
# Kernel printk suppression
echo 0 > /proc/sys/kernel/printk

# Black-on-black text + hide cursor (tty1, tty2, tty3)
for tty in /dev/tty1 /dev/tty2 /dev/tty3; do
    setterm --foreground black --background black --cursor off > "$tty"
    printf '\033[2J\033[H\033[?25l' > "$tty"
    stty -echo -F "$tty"
done

# Fill framebuffer with black pixels
dd if=/dev/zero of=/dev/fb0 bs=65536 count=512 conv=notrunc
```

### Phase 5: Plymouth Deactivate + Kiosk Signal
```bash
touch /tmp/ods-kiosk-starting      # Unblocks ods-plymouth-hold
plymouth deactivate                # Releases DRM for Xorg (splash stays as watermark)
# → ods-plymouth-hold sees signal → finishes → plymouth-quit fires → Plymouth dies
# By this point, kiosk wrapper already controls the display
```

### Phase 6: Xorg Start (grey flash fixed)
```bash
# NO -background none (caused grey stipple root window)
Xorg :0 -nolisten tcp -novtswitch vt1 &

# Wait for Xorg to accept connections
for i in $(seq 1 120); do
    xdpyinfo -display :0 && break
    sleep 0.05
done

# CONTINUOUS black repaint — covers modeset color map resets
# modeset driver re-initializes kms color map 6+ times during startup
(
    for j in $(seq 1 200); do
        xsetroot -solid "#000000"
        sleep 0.05
    done
) &
```

### Phase 7: GTK Theme + Chromium Launch
```bash
export GTK_THEME="Adwaita:dark"     # Dark canvas for Chromium initial render
# NO --force-dark-mode (renders grey #3C3C3C, not black)
chromium --kiosk --no-sandbox \
  --default-background-color=000000 \
  "http://localhost:8080/network_setup.html"
```

### Phase 8: Page Ready + Plymouth Quit
```bash
# network_setup.html calls /api/signal-ready → touches /tmp/ods-loader-ready
# FOUC guard: page starts at opacity:0, fades to opacity:1 on body.ready
# Stage 6 (delayed): plymouth quit fires after page is fully rendered
```

## Supporting Services

| Service | Role |
|---------|------|
| `ods-plymouth-hold.service` | Blocks `plymouth-quit` until kiosk signals readiness |
| `ods-hide-tty.service` | Pre-suppresses VT1 output before getty |
| `ods-shutdown-splash.service` | Shows Plymouth on reboot/poweroff |
| `ods-dpms-enforce.timer` | Resets DPMS every 5 minutes (belt-and-suspenders) |

## VT Lockdown

| Mechanism | File | Effect |
|-----------|------|--------|
| Xorg `DontVTSwitch` | `/etc/X11/xorg.conf.d/10-no-vtswitch.conf` | Blocks Ctrl+Alt+Fn |
| Xorg `DontZap` | same file | Blocks Ctrl+Alt+Backspace |
| Xorg `-novtswitch` | `ods-kiosk-wrapper.sh` | Belt-and-suspenders |
| getty@tty1-6 masked | systemd | No login prompts on any VT |
| SysRq disabled | `/etc/sysctl.d/99-no-vtswitch.conf` | kernel.sysrq=0 |
| unclutter | `ods-kiosk-wrapper.sh` | No cursor visible |

## Visual Timeline (v7-11 target)

```
t=0s    Power on
t=2s    Plymouth splash visible (ODS logo + throbber)
t=5.7s  ods-plymouth-hold.service starts (blocks plymouth-quit)
t=6.9s  ods-kiosk starts → VT1 blackout → /tmp/ods-kiosk-starting
t=7.0s  Plymouth deactivated (DRM released for Xorg)
t=7.0s  plymouth-hold unblocked → plymouth-quit fires (display under kiosk control)
t=12.5s Xorg ready (continuous black repaint loop active)
t=14.7s Openbox + Chromium launched
t=21.2s Page ready signal → Plymouth quit (delayed) → Boot complete
```

## Lessons Learned

| Lesson | Details |
|--------|---------|
| `-background none` ≠ black | Leaves root window undefined → grey stipple pattern |
| `--force-dark-mode` ≠ black | Renders Chromium canvas as grey #3C3C3C |
| `plymouth-quit` timing is critical | If it fires before kiosk starts, 26s of bare TTY |
| `openssl passwd` doesn't support yescrypt | Debian Trixie uses `$y$` hashes; use `su`/PAM |
| Python 3.13 removed `crypt` AND `spwd` | No Python-based auth possible on Trixie |
| Masking `plymouth-quit.service` breaks boot | Systemd boot messages leak to console |
| VT7 for Xorg causes AIGLX VT-switch events | Stay on VT1 |
| modeset driver does 6+ kms color map resets | Single xsetroot insufficient; needs continuous loop |
