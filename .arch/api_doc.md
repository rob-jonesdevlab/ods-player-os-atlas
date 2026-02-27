# ODS Player OS Atlas — API Documentation

> **Server:** Express.js on port 8080 (+ port 80 for captive portal)  
> **Base URL:** `http://<device-ip>:8080`  
> **Auth:** Most endpoints are unauthenticated (local device). Admin endpoints require `x-admin-token` header.

---

## Captive Portal (iOS/Android WiFi Setup)

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/hotspot-detect.html` | iOS captive portal detection — returns setup.html redirect |
| GET | `/generate_204` | Android captive portal detection |
| GET | `/gen_204` | Android (alt) captive portal detection |
| GET | `/connecttest.txt` | Windows captive portal detection |
| GET | `/ncsi.txt` | Windows NCSI probe |
| GET | `/redirect` | Generic redirect → setup.html |

---

## Network Status & Configuration

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/status` | Full network status | `{ wifi_connected, ethernet_connected, ssid, hasInternet, ethernet: { ip, subnet, gateway, dns, type }, wifi: { ip, subnet, gateway, dns, type } }` |
| GET | `/api/wifi/scan` | Scan available WiFi networks | `[{ ssid, signal, security }]` |
| GET | `/api/wifi/state` | WiFi client state (AP-aware) | `{ enabled, ap_mode }` |
| POST | `/api/wifi/toggle` | Enable/disable WiFi | Body: `{ enabled }` |
| POST | `/api/wifi/configure` | Connect to WiFi network | Body: `{ ssid, password }` |
| POST | `/api/network/configure` | Apply static IP or switch to DHCP | Body: `{ interface: "ethernet"|"wifi", mode?, ip, subnet, gateway, dns }` |
| GET | `/api/display/modes` | Available display resolutions | `[{ mode, current }]` |

---

## QR Code & Enrollment

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/qr` | Generate WiFi QR code for AP join | `{ qrCode (dataURL), ssid, setupUrl }` |
| POST | `/api/enroll` | Register device with ODS Cloud | Body: none. Response: `{ success, device_uuid, pairing_code, expires_at, qr_data }` |

**QR Format:** `WIFI:T:nopass;S:<SSID>;H:true;;` (hidden open network)

---

## Device Info

| Method | Endpoint | Purpose | Response |
|--------|----------|---------|----------|
| GET | `/api/device/info` | Device identity & pairing status | `{ three_word_name, mac_address, connection_type, ssid, ip_address, account_name, device_name }` |

---

## System Management

| Method | Endpoint | Purpose | Body |
|--------|----------|---------|------|
| GET | `/api/system/info` | System hardware/software info | Response: `{ hostname, device_name, cpu_temp, uptime, ram_usage, ram_percent, storage_usage, storage_percent, disk_total, os_version, ip_address, dns, interfaces, display_resolution, display_scale }` |
| POST | `/api/system/reboot` | Reboot device | — |
| POST | `/api/system/shutdown` | Shutdown device | — |
| POST | `/api/system/unpair` | Unpair from ODS Cloud + reboot | — |
| POST | `/api/system/factory-reset` | Factory reset → enrollment flow | — |
| POST | `/api/system/resolution` | Set display resolution | `{ resolution: "1920x1080" }` |
| POST | `/api/system/cache-clear` | Clear Chromium cache | — |
| POST | `/api/system/timezone` | Set system timezone | `{ timezone: "America/Los_Angeles" }` |
| GET | `/api/system/volume` | Get audio volume | `{ volume: 75 }` |
| POST | `/api/system/volume` | Set audio volume | `{ volume: 0-100 }` |
| GET | `/api/system/logs` | View system logs by type | Query: `?type=boot|health|services|system|esper` |

---

## Loader / Plymouth

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/loader-ready` | Signal that loader page is ready (Plymouth can quit) |
| POST | `/api/signal-ready` | Page ready signal (alternative) |

---

## Admin (Requires `x-admin-token` header)

| Method | Endpoint | Purpose | Body |
|--------|----------|---------|------|
| POST | `/api/admin/login` | Authenticate as otter user | `{ username: "otter", password }` → `{ success, token }` |
| POST | `/api/admin/terminal` | Launch xterm overlay on display | — |
| POST | `/api/admin/restart-services` | Restart all ODS systemd services | — |
| POST | `/api/admin/password` | Update otter password | `{ newPassword }` (min 8 chars) |
| POST | `/api/admin/ssh` | Toggle SSH on/off | `{ enabled }` |
| GET | `/api/admin/services` | View systemd service statuses | — |

---

## Content Cache

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/cache/sync` | Manual content sync trigger |
| GET | `/api/cache/status` | Cache health & manifest | `{ canOperate, assetCount, configCached, configHash, assets[] }` |
| GET | `/api/cache/content/:contentId` | Serve cached content file |
| POST | `/api/cache/clean` | Clean stale cache entries | `{ maxAgeDays: 7 }` |

---

## Player Content Delivery

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/player/content` | Current playlist for renderer | `{ hasContent, playlist }` |
| GET | `/api/player/sync-status` | Cloud sync health status |
| POST | `/api/player/sync-now` | Manual cloud sync trigger |

**Static:** `/cache/*` — Serves cached content files directly

---

## Static Files

| Path | Purpose |
|------|---------|
| `/setup.html` | WiFi/network configuration page (AP captive portal target) |
| `/network_setup.html` | Network setup wizard |
| `/player_link.html` | Pairing code card + enrollment |
| `/system_config.html` | System Options admin panel |
| `/player.html` | Content renderer |
| `/loader.html` | Boot loader animation |

---

## Data Flow Summary

```
Phone QR Scan → WIFI:T:nopass;S:SSID;H:true;;
  → Phone joins AP (wlan0, 192.168.4.0/24)
  → iOS checks captive.apple.com:80 → redirected to setup.html
  → User configures WiFi on setup.html → POST /api/wifi/configure
  → Device drops AP, connects WiFi → POST /api/enroll → ODS Cloud
  → GET /api/device/info → player_link.html shows pairing code
  → User enters code at ods-cloud.com/pair → POST /api/pairing/verify (Cloud)
  → Player polls /api/player/content → renders playlist
```
