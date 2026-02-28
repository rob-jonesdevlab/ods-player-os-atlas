# ODS Player Atlas — API Documentation

> **Server:** Express.js on Raspberry Pi 4b (Armbian)  
> **Base URL:** `http://localhost:8080` (device-local)  
> **Port 80:** Captive portal listener (iOS/Android detection)  
> **Auth:** Admin endpoints require `x-admin-token` header (30-min session)  
> **Runtime:** Node.js v20.19.2

---

## Captive Portal Detection

Auto-redirects phone browsers to `captive_portal.html` when connected to the device's WiFi AP.

| Method | Endpoint | Platform | Behavior |
|--------|----------|----------|----------|
| GET | `/hotspot-detect.html` | iOS | Serves `captive_portal.html` directly (200) |
| GET | `/generate_204` | Android | Serves `captive_portal.html` (200 instead of 204) |
| GET | `/gen_204` | Android alt | Same as above |
| GET | `/connecttest.txt` | Windows | Serves `captive_portal.html` |
| GET | `/ncsi.txt` | Windows alt | Same as above |
| GET | `/redirect` | Fallback | 302 redirect to `/captive_portal.html` |

---

## Network

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/status` | Network status (WiFi + Ethernet) | `{ wifi_connected, ethernet_connected, hasInternet, ssid, hostname, ethernet: {...}, wifi: {...}, ip_address, dns }` |
| POST | `/api/network/configure` | Set static IP or switch to DHCP | Body: `{ interface: "ethernet"|"wifi", mode: "static"|"dhcp", ip, subnet, gateway, dns }` |

---

## WiFi

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/wifi/scan` | Scan available WiFi networks | `{ networks: [{ ssid, signal }] }` — Returns `{ ap_active: true }` if hostapd running |
| POST | `/api/wifi/configure` | Save WiFi credentials + connect | Body: `{ ssid, password }` → `{ success, message }`. Async: stops AP, starts wpa_supplicant, runs udhcpc |
| POST | `/api/wifi/toggle` | Enable/disable WiFi interface | Body: `{ enabled }` → `{ success, enabled }` |
| GET | `/api/wifi/state` | WiFi client state | `{ enabled, ap_mode }` — Returns `enabled: false` when hostapd running |

---

## Display

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/display/modes` | Available display resolutions | `{ modes: ["3840x2160", "1920x1080", ...] }` |

---

## QR / Enrollment

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/qr` | Generate WiFi QR code for AP | `{ qrCode (dataURL), ssid, setupUrl }` |
| POST | `/api/enroll` | Register device with ODS Cloud | Body: `{ }` (reads CPU serial internally) → `{ success, device_uuid, pairing_code, expires_at, qr_data }` |

---

## System

| Method | Endpoint | Purpose | Notes |
|--------|----------|---------|-------|
| GET | `/api/system/info` | Full system diagnostics | `{ hostname, cpu_temp, uptime, ram_usage, ram_percent, storage_usage, storage_percent, os_version, ip_address, dns, display_resolution, ... }` |
| POST | `/api/system/restart-signage` | Restart signage (kill Chromium, systemd relaunches) | `{ success, message }` — 500ms delay before `pkill -9 chromium` |
| POST | `/api/system/reboot` | Reboot device | 2s delay before reboot |
| POST | `/api/system/shutdown` | Shutdown device | 2s delay before shutdown |
| POST | `/api/system/unpair` | Unpair from ODS Cloud + reboot | Calls cloud API to unpair, clears enrollment flag |
| POST | `/api/system/resolution` | Change display resolution | Body: `{ resolution: "1920x1080" }` — via xrandr |
| POST | `/api/system/cache-clear` | Clear Chromium browser cache | Deletes Cache + Code Cache dirs |
| POST | `/api/system/factory-reset` | Factory reset + reboot | Unpairs from cloud, clears all local state |
| POST | `/api/system/timezone` | Set system timezone | Body: `{ timezone: "America/New_York" }` |
| GET | `/api/system/volume` | Get current audio volume | `{ volume: 75 }` |
| POST | `/api/system/volume` | Set audio volume | Body: `{ volume: 0-100 }` |
| GET | `/api/system/logs` | View system logs by type | Query: `?type=boot|health|services|system|esper` |

---

## Admin (Session-authenticated)

Login creates a 30-minute session token. All admin endpoints require `x-admin-token` header.

| Method | Endpoint | Auth | Purpose |
|--------|----------|------|---------|
| POST | `/api/admin/login` | None | Authenticate `otter` user → `{ success, token }` |
| POST | `/api/admin/terminal` | Token | Launch xterm overlay on device display |
| POST | `/api/admin/restart-services` | Token | Restart all ODS systemd services |
| POST | `/api/admin/password` | Token | Change `otter` user password |
| POST | `/api/admin/ssh` | Token | Enable/disable SSH service |
| GET | `/api/admin/services` | Token | View ODS service statuses |

---

## Device Info

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/device/info` | Device identity + pairing data | `{ three_word_name, mac_address, connection_type, ssid, ip_address, account_name, device_name }` |

---

## Content Cache

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| POST | `/api/cache/sync` | Trigger content sync from ODS Cloud | `{ synced, assetCount, ... }` |
| GET | `/api/cache/status` | Cache health + manifest | `{ canOperate, assetCount, configCached, assets: [...] }` |
| GET | `/api/cache/content/:contentId` | Serve cached content file | Binary file stream |
| POST | `/api/cache/clean` | Remove stale cached files | Body: `{ maxAgeDays: 7 }` |

---

## Content Delivery (Player Renderer)

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/player/content` | Current playlist for renderer | `{ hasContent, playlist }` |
| GET | `/api/player/sync-status` | Sync health for system config | `{ syncing, lastSync, errors, ... }` |
| POST | `/api/player/sync-now` | Manual sync trigger | `{ success, status }` |

---

## Loader / Signal

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/loader-ready` | Signal boot loader ready (Plymouth can quit) |
| POST | `/api/signal-ready` | Page ready signal (Plymouth transition) |

---

## Static Assets

| Path | Purpose |
|------|---------|
| `/cache/*` | Serves cached content files from `player/cache/good/` |
| `/*` | Static files from `public/` directory |

---

## WiFi Connection Flow (Internal)

```
Phone → connects to ODS AP (hidden SSID) → captive portal → setup.html
  → POST /api/wifi/configure { ssid, password }
  → Server saves wpa_supplicant.conf
  → Server responds { success: true } (phone gets response before AP drops)
  → 2s delay
  → killall hostapd/dnsmasq/wpa_supplicant
  → ip addr flush wlan0 + ip link set wlan0 up
  → wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
  → 10s wait for WPA association
  → wpa_cli reconfigure
  → 5s wait
  → busybox udhcpc -i wlan0 (DHCP — dhclient not installed)
  → 5s verify via wpa_cli status
   → Connected → network_setup.html polls /api/status → redirect to player_link.html
   → Failed → killall wpa_supplicant + systemctl start ods-setup-ap (restart AP)
```

---

## Keyboard Shortcuts (All Pages)

| Shortcut | Action | Source |
|----------|--------|--------|
| `Ctrl+Alt+Shift+O` | System Options page | All pages |
| `Ctrl+Alt+Shift+I` | Player Info (Player Ready) | All pages |
| `Ctrl+Alt+Shift+K` | Kill/Restart signage | All pages → `POST /api/system/restart-signage` |
| `Ctrl+Alt+Shift+B` | Debug: cycle offline border templates | `player_ready.html` only |

**Total endpoints: 43**
