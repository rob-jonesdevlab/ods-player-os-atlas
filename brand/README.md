# ODS Player OS Atlas - Brand Assets

This directory contains branding and visual assets for ODS Player OS Atlas.

## Directory Structure

```
brand/
├── splash/                      # Boot splash screen themes
│   ├── landscape/               # Landscape orientation (1920x1080)
│   │   ├── ods.plymouth         # Plymouth theme config
│   │   └── watermark.png        # ODS logo watermark
│   └── portrait/                # Portrait orientation (1080x1920)
│       ├── ods.plymouth         # Plymouth theme config
│       └── watermark.png        # ODS logo watermark
├── ods-wallpaper.png            # Desktop wallpaper
└── xfce4-panel-config.xml       # Panel configuration
```

## Plymouth Splash Screen

The splash screens use Plymouth's `two-step` theme module with centered branding.

**Key Configuration:**
- **TitleVerticalAlignment:** `.5` (centered, not `.382`)
- **WatermarkVerticalAlignment:** `.89` (bottom of screen)
- **Background:** Solid black (#000000)
- **Font:** DejaVu Sans Mono Bold 30

**Deployment:**

```bash
# Copy theme to device
scp brand/splash/portrait/ods.plymouth \
    brand/splash/portrait/watermark.png \
    root@device:/usr/share/plymouth/themes/ods/

# For landscape orientation  
scp brand/splash/landscape/ods.plymouth \
    brand/splash/landscape/watermark.png \
    root@device:/usr/share/plymouth/themes/ods/

# Reboot to see changes
ssh root@device 'reboot'
```

## Customization

**Changing Watermark:**
Replace `watermark.png` (recommend 500x200px transparent PNG)

**Changing Alignment:**
Edit `ods.plymouth`:
- `TitleVerticalAlignment=.5` → centered
- `TitleVerticalAlignment=.382` → upper third
- `WatermarkVerticalAlignment=.89` → bottom

**Orientation Switch:**
Copy the appropriate theme file:
- Landscape for 16:9 displays
- Portrait for 9:16 vertical displays

## Notes

- **DietPi/Pi5:** Does NOT use initramfs, theme loads directly from `/usr/share/plymouth/themes/`
- **Reboot required:** Plymouth only loads theme at boot time
- **System role only:** Custom splash screens are system admin controlled, not available to account users per product requirements
