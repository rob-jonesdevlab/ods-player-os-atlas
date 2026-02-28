const express = require('express');
const { exec } = require('child_process');
const fs = require('fs');
const QRCode = require('qrcode');
const app = express();
const PORT = 8080;

app.use(express.json());
app.use(express.static('public'));

// ========================================
// CAPTIVE PORTAL DETECTION
// ========================================
// When phones join the AP, they probe these URLs to detect captive portals.
// iOS CNA does NOT execute JavaScript or follow meta-refresh redirects.
// We serve setup.html directly so the form renders inside the CNA sheet.
const path = require('path');
const SETUP_PAGE = path.join(__dirname, 'public', 'setup.html');

// iOS captive portal detection — serve setup page directly
app.get('/hotspot-detect.html', (req, res) => {
    res.status(200).type('html').sendFile(SETUP_PAGE);
});

// Android captive portal detection (expects non-204 response)
app.get('/generate_204', (req, res) => {
    res.status(200).type('html').sendFile(SETUP_PAGE);
});
app.get('/gen_204', (req, res) => {
    res.status(200).type('html').sendFile(SETUP_PAGE);
});

// Windows captive portal detection
app.get('/connecttest.txt', (req, res) => {
    res.status(200).type('html').sendFile(SETUP_PAGE);
});
app.get('/ncsi.txt', (req, res) => {
    res.status(200).type('html').sendFile(SETUP_PAGE);
});

// Catch-all for any captive portal probe from unknown OS
app.get('/redirect', (req, res) => {
    res.redirect('/setup.html');
});

// ========================================
// NETWORK APIs
// ========================================

// Get network status — per-interface details
app.get('/api/status', (req, res) => {
    exec('iwgetid -r', (error, stdout) => {
        const ssid = (stdout || '').trim();
        const wifi_connected = !!ssid;

        exec('ip route | grep default', (error, stdout) => {
            const routeOutput = (stdout || '');
            // Check for both eth0 (standard) and end0 (Armbian Pi5)
            const ethernet_connected = routeOutput.includes('eth0') || routeOutput.includes('end0');
            const hasInternet = wifi_connected || ethernet_connected;

            // Get per-interface IP details
            const ethIface = routeOutput.includes('end0') ? 'end0' : 'eth0';

            // Gather per-interface details in parallel
            const getIfaceDetails = (iface, callback) => {
                exec(`ip -4 addr show ${iface} 2>/dev/null | grep inet`, (e, ipOut) => {
                    const ipMatch = (ipOut || '').match(/inet\s+([\d.]+)\/([\d]+)/);
                    const ip = ipMatch ? ipMatch[1] : null;
                    const subnet = ipMatch ? ipMatch[2] : null;

                    exec(`ip route | grep "default.*${iface}" | awk '{print $3}'`, (e, gwOut) => {
                        const gateway = (gwOut || '').trim() || null;

                        // Check if DHCP client is running for this interface
                        exec(`ps aux | grep -E "dhclient.*${iface}|dhcpcd.*${iface}|NetworkManager" | grep -v grep`, (e, dhcpOut) => {
                            const isDhcp = !!(dhcpOut || '').trim();

                            callback({ ip, subnet, gateway, dhcp: isDhcp ? 'DHCP' : 'Static' });
                        });
                    });
                });
            };

            // Get DNS (shared system DNS from resolv.conf)
            exec('grep "^nameserver" /etc/resolv.conf | head -2 | awk \'{print $2}\' | paste -sd ", "', (e, dnsOut) => {
                const dns = (dnsOut || '').trim() || null;

                getIfaceDetails(ethIface, (ethDetails) => {
                    getIfaceDetails('wlan0', (wifiDetails) => {
                        res.json({
                            wifi_connected,
                            ethernet_connected,
                            hasInternet,
                            ssid: ssid || null,
                            ethernet: {
                                connected: ethernet_connected,
                                interface: ethIface,
                                ip: ethDetails.ip,
                                subnet: ethDetails.subnet,
                                gateway: ethDetails.gateway,
                                dns: dns,
                                type: ethDetails.dhcp
                            },
                            wifi: {
                                connected: wifi_connected,
                                interface: 'wlan0',
                                ssid: ssid || null,
                                ip: wifiDetails.ip,
                                subnet: wifiDetails.subnet,
                                gateway: wifiDetails.gateway,
                                dns: dns,
                                type: wifiDetails.dhcp
                            },
                            // Legacy fields for backward compat
                            ip_address: ethDetails.ip || wifiDetails.ip || null,
                            dns: dns
                        });
                    });
                });
            });
        });
    });
});

// Scan for available WiFi networks
app.get('/api/wifi/scan', (req, res) => {
    // Guard: if AP mode is active (hostapd running), skip scan to avoid disrupting it
    exec('pgrep -x hostapd', { timeout: 2000 }, (err) => {
        if (!err) {
            // hostapd is running — don't scan, it would kill the AP
            return res.json({ networks: [], ap_active: true });
        }
        // Bring wlan0 up first (Pi 5 boots with it DOWN), then scan with iw
        exec('sudo ip link set wlan0 up 2>/dev/null; sleep 2; sudo iw dev wlan0 scan 2>/dev/null | grep -E "SSID:|signal:" | paste - - 2>/dev/null', { timeout: 25000 }, (error, stdout) => {
            const networks = [];
            if (stdout && stdout.trim()) {
                const lines = stdout.trim().split('\n');
                lines.forEach(line => {
                    const ssidMatch = line.match(/SSID:\s*(.+?)(?:\s|$)/);
                    const signalMatch = line.match(/signal:\s*(-?[\d.]+)/);
                    if (ssidMatch && ssidMatch[1] && ssidMatch[1] !== '\\x00') {
                        networks.push({
                            ssid: ssidMatch[1].trim(),
                            signal: signalMatch ? parseFloat(signalMatch[1]) : -100
                        });
                    }
                });
            }
            // Deduplicate by SSID, keep strongest signal
            const unique = [...new Map(networks.map(n => [n.ssid, n])).values()];
            unique.sort((a, b) => b.signal - a.signal);
            res.json({ networks: unique });
        });
    });
});

// Get available display resolutions from xrandr
app.get('/api/display/modes', (req, res) => {
    exec("DISPLAY=:0 xrandr 2>/dev/null | grep -E '^\\s+[0-9]+x[0-9]+' | awk '{print $1}' | sort -t x -k1 -rn | uniq", { timeout: 5000 }, (error, stdout) => {
        const modes = stdout ? stdout.trim().split('\n').filter(m => m.match(/^\d+x\d+$/)) : [];
        res.json({ modes });
    });
});

// Configure WiFi
app.post('/api/wifi/configure', (req, res) => {
    const { ssid, password } = req.body;
    if (!ssid) return res.status(400).json({ error: 'SSID required' });

    // Build FULL wpa_supplicant.conf (header + network block)
    // Must include ctrl_interface/update_config/country or wpa_supplicant won't connect
    const wpaHeader = `ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=US\n`;
    const wpaNetwork = password
        ? `\nnetwork={\n    ssid="${ssid}"\n    psk="${password}"\n}\n`
        : `\nnetwork={\n    ssid="${ssid}"\n    key_mgmt=NONE\n}\n`;
    const wpaFull = wpaHeader + wpaNetwork;

    // Step 1: Write WiFi credentials (overwrite, not append — ensure clean config)
    exec(`echo '${wpaFull}' | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null`, (error) => {
        if (error) {
            return res.status(500).json({ error: 'Failed to configure WiFi' });
        }

        // Step 2: RESPOND IMMEDIATELY — phone will lose AP connection when we stop hostapd
        // The phone MUST get this response before we tear down the AP
        res.json({ success: true, message: `Credentials saved. Connecting to ${ssid}...` });

        // Step 3: Async — stop AP and switch wlan0 to client mode (phone disconnects here)
        console.log(`[WiFi] Credentials saved for "${ssid}" — stopping AP in 2s...`);
        setTimeout(() => {
            // Step 3a: Stop the AP service (kills hostapd/dnsmasq, frees wlan0)
            exec('sudo systemctl stop ods-setup-ap', { timeout: 10000 }, () => {
                console.log('[WiFi] AP stopped — switching wlan0 to client mode');

                // Step 3b: Start wpa_supplicant on wlan0 with saved credentials
                // The systemd service uses D-Bus mode (-u -s) without -i wlan0, so we run it directly
                const wpaCmd = 'sudo ip link set wlan0 up 2>/dev/null; sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null';
                exec(wpaCmd, { timeout: 10000 }, () => {
                    console.log('[WiFi] wpa_supplicant started — waiting for association...');

                    // Step 3c: Wait 8s for WPA association, then reconfigure + DHCP
                    setTimeout(() => {
                        exec('sudo wpa_cli -i wlan0 reconfigure 2>/dev/null', { timeout: 5000 }, () => {
                            // Step 3d: Get IP via busybox udhcpc (dhclient is not installed)
                            setTimeout(() => {
                                exec('busybox udhcpc -i wlan0 -n -q 2>/dev/null', { timeout: 15000 }, () => {
                                    console.log('[WiFi] DHCP request sent');

                                    // Step 4: Verify connection
                                    setTimeout(() => {
                                        exec('wpa_cli -i wlan0 status | grep wpa_state', (err, stdout) => {
                                            const state = (stdout || '').trim();
                                            const connected = state.includes('COMPLETED');
                                            if (connected) {
                                                exec('iwgetid -r', (e, ssidOut) => {
                                                    console.log(`[WiFi] Connected! State: ${state}, SSID: ${(ssidOut || '').trim()}`);
                                                });
                                            } else {
                                                console.log(`[WiFi] Connection failed (state: ${state}) — restarting AP`);
                                                exec('killall wpa_supplicant 2>/dev/null; sudo systemctl start ods-setup-ap', (e) => {
                                                    if (e) console.error('[WiFi] Failed to restart AP:', e.message);
                                                    else console.log('[WiFi] AP restarted — user can try again');
                                                });
                                            }
                                        });
                                    }, 5000);
                                });
                            }, 3000);
                        });
                    }, 8000);
                });
            });
        }, 2000);  // 2s delay gives phone time to receive response
    });
});

// Generate QR code
app.get('/api/qr', async (req, res) => {
    try {
        // Get SSID from hostapd config
        const ssid = require('child_process').execSync(
            '/usr/local/bin/ods-setup-ap.sh ssid 2>/dev/null || echo ODS-Player'
        ).toString().trim();

        // WIFI: QR format (open hidden network) — H:true tells phone the SSID is hidden
        const wifiQR = `WIFI:T:nopass;S:${ssid};H:true;;`;
        const qrCode = await QRCode.toDataURL(wifiQR, { width: 400 });
        res.json({ qrCode, ssid, setupUrl: 'http://192.168.4.1:8080/setup.html' });
    } catch (e) {
        console.error('[QR] Error:', e.message);
        res.status(500).json({ error: 'Failed to generate QR' });
    }
});

// Trigger enrollment — register device with ODS Cloud
app.post('/api/enroll', async (req, res) => {
    try {
        // Get CPU serial from /proc/cpuinfo
        const { promisify } = require('util');
        const execAsync = promisify(exec);

        const { stdout: cpuInfo } = await execAsync("cat /proc/cpuinfo | grep Serial | awk '{print $3}'");
        const cpuSerial = cpuInfo.trim() || 'UNKNOWN';

        // Generate or retrieve device UUID
        const uuidFile = '/home/signage/ODS/config/device_uuid';
        let deviceUuid;
        try {
            deviceUuid = fs.readFileSync(uuidFile, 'utf8').trim();
        } catch {
            const crypto = require('crypto');
            deviceUuid = crypto.randomUUID();
            const dir = require('path').dirname(uuidFile);
            if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
            fs.writeFileSync(uuidFile, deviceUuid);
        }

        // Call ODS Cloud pairing API
        const ODS_SERVER_URL = process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
        const pairingRes = await fetch(`${ODS_SERVER_URL}/api/pairing/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ cpu_serial: cpuSerial, device_uuid: deviceUuid })
        });

        const pairingData = await pairingRes.json();

        if (pairingRes.ok) {
            // Write enrollment flag for retry script
            fs.writeFileSync('/var/lib/ods/enrollment.flag', JSON.stringify({
                enrolled: true,
                timestamp: new Date().toISOString(),
                device_uuid: deviceUuid,
                pairing_code: pairingData.pairing_code
            }));

            res.json({
                success: true,
                device_uuid: deviceUuid,
                pairing_code: pairingData.pairing_code,
                expires_at: pairingData.expires_at,
                qr_data: pairingData.qr_data
            });
        } else if (pairingRes.status === 409) {
            // Already paired — not an error
            res.json({ success: true, already_paired: true, account_id: pairingData.account_id });
        } else {
            console.error('[ENROLL] Cloud API error:', pairingData);
            res.status(500).json({ error: pairingData.error || 'Cloud registration failed' });
        }
    } catch (error) {
        console.error('[ENROLL] Error:', error.message);
        res.status(500).json({ error: 'Enrollment failed: ' + error.message });
    }
});

// ========================================
// LOADER API
// ========================================

// Signal that loader is ready (Plymouth can quit)
app.get('/api/loader-ready', (req, res) => {
    const signalFile = '/tmp/ods-loader-ready';
    fs.writeFileSync(signalFile, Date.now().toString());
    console.log('[LOADER] Ready signal received — Plymouth can quit');
    res.json({ success: true });
});

// ========================================
// SYSTEM APIs
// ========================================

// System info
app.get('/api/system/info', (req, res) => {
    const info = {};
    const commands = {
        hostname: 'hostname',
        cpu_temp: "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null",
        uptime: 'uptime -p',
        ram: "free -h | awk '/^Mem:/ {print $3 \"/\" $2}'",
        ram_percent: "free | awk '/^Mem:/ {printf \"%.0f\", $3/$2*100}'",
        storage: "df -h / | awk 'NR==2 {print $3 \"/\" $2}'",
        storage_percent: "df / | awk 'NR==2 {print $5}' | tr -d '%'",
        os_version: 'cat /home/signage/ODS/VERSION 2>/dev/null || echo unknown',
        ip_address: "hostname -I | awk '{print $1}'",
        dns: "cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}'",
        interfaces: "ip -o addr show | awk '{print $2, $3, $4}' | grep -v '^lo '",
        display_resolution: "DISPLAY=:0 xrandr 2>/dev/null | grep '[*]' | head -1 | awk '{print $1}'",
        display_scale: "echo $ODS_SCALE",
        disk_total: "lsblk -dn -o SIZE /dev/mmcblk0 2>/dev/null || echo '—'",
        device_name: 'hostname 2>/dev/null || echo unknown'
    };

    let completed = 0;
    const total = Object.keys(commands).length;

    for (const [key, cmd] of Object.entries(commands)) {
        exec(cmd, { timeout: 3000 }, (error, stdout) => {
            let value = stdout ? stdout.trim() : '—';

            // Convert CPU temp from millidegrees
            if (key === 'cpu_temp' && value !== '—' && !isNaN(value)) {
                value = (parseInt(value) / 1000).toFixed(1) + '°C';
            }

            info[key] = value;
            completed++;

            if (completed === total) {
                res.json({
                    hostname: info.hostname,
                    device_name: info.device_name || info.hostname,
                    cpu_temp: info.cpu_temp,
                    uptime: info.uptime,
                    ram_usage: info.ram,
                    ram_percent: parseInt(info.ram_percent) || 0,
                    storage_usage: info.storage,
                    storage_percent: parseInt(info.storage_percent) || 0,
                    disk_total: info.disk_total ? info.disk_total.trim() : '—',
                    os_version: info.os_version ? `v${info.os_version.trim().replace(/\./g, '-')}-FLASH` : '—',
                    version_clean: info.os_version ? `v${info.os_version.trim().replace(/\./g, '-')}` : '—',
                    ip_address: info.ip_address,
                    dns: info.dns,
                    interfaces: info.interfaces,
                    display_resolution: info.display_resolution,
                    display_scale: info.display_scale || '1'
                });
            }
        });
    }
});

// System actions
app.post('/api/system/reboot', (req, res) => {
    res.json({ success: true, message: 'Rebooting...' });
    setTimeout(() => exec('sudo /usr/sbin/reboot'), 2000);
});

app.post('/api/system/shutdown', (req, res) => {
    res.json({ success: true, message: 'Shutting down...' });
    setTimeout(() => exec('sudo /usr/sbin/shutdown -h now'), 2000);
});

// Unpair device — removes from ODS Cloud active, keeps in Supabase, reboots to player_link
app.post('/api/system/unpair', async (req, res) => {
    console.log('[UNPAIR] Device unpair initiated');
    res.json({ success: true, message: 'Unpairing device...' });

    setTimeout(async () => {
        try {
            // Read enrollment data
            let playerId = null;
            let cloudUrl = null;
            try {
                const flagData = JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'));
                playerId = flagData.player_id;
                cloudUrl = flagData.cloud_url || process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
            } catch (e) { /* no enrollment data */ }

            // Call ODS Cloud to unpair (keep in Supabase)
            if (playerId && cloudUrl) {
                try {
                    await fetch(`${cloudUrl}/api/players/${playerId}/unpair`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' }
                    });
                    console.log('[UNPAIR] Player unpaired from ODS Cloud');
                } catch (e) {
                    console.error('[UNPAIR] Cloud unpair failed (non-blocking):', e.message);
                }
            }

            // Clear local enrollment
            exec('rm -f /var/lib/ods/enrollment.flag');
            console.log('[UNPAIR] Local state cleared — rebooting');

            // Reboot to player_link workflow
            exec('sudo /usr/sbin/reboot');
        } catch (e) {
            console.error('[UNPAIR] Error:', e.message);
            exec('sudo /usr/sbin/reboot');
        }
    }, 2000);
});

app.post('/api/system/resolution', (req, res) => {
    const { resolution } = req.body;
    if (!resolution || !resolution.match(/^\d+x\d+$/)) {
        return res.status(400).json({ error: 'Invalid resolution format' });
    }
    // Change resolution via xrandr
    const cmd = `DISPLAY=:0 xrandr --output $(DISPLAY=:0 xrandr | grep ' connected' | head -1 | awk '{print $1}') --mode ${resolution} 2>&1`;
    exec(cmd, { timeout: 10000 }, (error, stdout) => {
        if (error) {
            return res.status(500).json({ error: 'Failed to set resolution: ' + (stdout || error.message) });
        }
        res.json({ success: true, message: `Resolution set to ${resolution}.` });
    });
});

app.post('/api/system/cache-clear', (req, res) => {
    exec('sudo rm -rf /home/signage/.config/chromium/Default/Cache/* /home/signage/.config/chromium/Default/Code\\ Cache/*', (error) => {
        if (error) return res.status(500).json({ error: 'Failed to clear cache' });
        res.json({ success: true, message: 'Browser cache cleared. Restart to take effect.' });
    });
});

app.post('/api/system/factory-reset', async (req, res) => {
    console.log('[FACTORY RESET] Initiated — restoring P:2.5 state');
    res.json({ success: true, message: 'Factory reset initiated. Device will reboot to enrollment...' });

    setTimeout(async () => {
        try {
            // 1. Read enrollment data before clearing
            let playerId = null;
            let cloudUrl = null;
            try {
                const flagData = JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'));
                playerId = flagData.player_id;
                cloudUrl = flagData.cloud_url || process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
            } catch (e) { /* no enrollment data */ }

            // 2. Call ODS Cloud to remove player from active (keep in Supabase)
            if (playerId && cloudUrl) {
                try {
                    await fetch(`${cloudUrl}/api/players/${playerId}/unpair`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' }
                    });
                    console.log('[FACTORY RESET] Player unpaired from ODS Cloud');
                } catch (e) {
                    console.error('[FACTORY RESET] Cloud unpair failed (non-blocking):', e.message);
                }
            }

            // 3. Clear all local enrollment/pairing state
            exec('rm -f /var/lib/ods/enrollment.flag');
            exec('rm -rf /home/signage/.config/chromium');
            exec('rm -rf /home/signage/ODS/cache/*');

            console.log('[FACTORY RESET] Local state cleared — rebooting to P:2.5');

            // 4. Reboot — device will go through player_link enrollment again
            exec('sudo /usr/sbin/reboot');
        } catch (e) {
            console.error('[FACTORY RESET] Error:', e.message);
            exec('sudo /usr/sbin/reboot'); // reboot anyway
        }
    }, 2000);
});

// Timezone — persist system timezone
app.post('/api/system/timezone', (req, res) => {
    const { timezone } = req.body;
    if (!timezone) return res.status(400).json({ error: 'Timezone required' });
    exec(`sudo timedatectl set-timezone '${timezone.replace(/[^a-zA-Z0-9_/]/g, '')}'`, { timeout: 5000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to set timezone' });
        res.json({ success: true, message: `Timezone set to ${timezone}` });
    });
});

// Audio — get current volume
app.get('/api/system/volume', (req, res) => {
    exec("amixer sget Master 2>/dev/null | grep -oP '\\[\\d+%\\]' | head -1 | tr -d '[]%'", { timeout: 3000 }, (error, stdout) => {
        const volume = parseInt(stdout?.trim()) || 75;
        res.json({ volume });
    });
});

// Audio — set volume
app.post('/api/system/volume', (req, res) => {
    const { volume } = req.body;
    const vol = Math.max(0, Math.min(100, parseInt(volume) || 75));
    exec(`amixer sset Master ${vol}% 2>/dev/null`, { timeout: 3000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to set volume' });
        res.json({ success: true, volume: vol });
    });
});

// System logs — typed log viewer
app.get('/api/system/logs', (req, res) => {
    const type = req.query.type || 'boot';
    const commands = {
        boot: 'ls -t /var/log/ods/boot_*.log 2>/dev/null | head -1 | xargs cat 2>/dev/null || echo "No boot logs found"',
        health: 'journalctl -u ods-health-monitor --no-pager -n 100 2>/dev/null || echo "No health monitor logs"',
        services: 'sudo systemctl status ods-kiosk ods-webserver ods-dpms-enforce.timer ods-display-config ods-health-monitor ods-enrollment-boot --no-pager 2>&1',
        system: 'dmesg | tail -100 2>/dev/null || echo "No dmesg access"',
        esper: 'echo "=== ODS Enrollment ==="; cat /var/log/ods-enrollment.log 2>/dev/null; echo ""; echo "=== Esper CMSE ==="; tail -100 /var/log/esper-cmse.log 2>/dev/null; echo ""; echo "=== Esper Telemetry ==="; tail -50 /var/log/esper-telemetry.log 2>/dev/null'
    };
    const cmd = commands[type] || commands.boot;
    exec(cmd, { timeout: 10000 }, (error, stdout) => {
        res.json({ logs: stdout || 'No logs available', type });
    });
});

// WiFi toggle (on/off)
app.post('/api/wifi/toggle', (req, res) => {
    const { enabled } = req.body;
    const cmd = enabled ? 'sudo ip link set wlan0 up 2>&1' : 'sudo ip link set wlan0 down 2>&1';
    exec(cmd, { timeout: 5000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to toggle WiFi' });
        res.json({ success: true, enabled, message: `WiFi ${enabled ? 'enabled' : 'disabled'}` });
    });
});

// Get WiFi state (client mode, not AP mode)
app.get('/api/wifi/state', (req, res) => {
    // If hostapd is running, wlan0 is in AP mode — WiFi client is off
    exec("pgrep -x hostapd", { timeout: 2000 }, (apErr) => {
        if (!apErr) {
            return res.json({ enabled: false, ap_mode: true });
        }
        exec("ip link show wlan0 2>/dev/null | head -1", { timeout: 3000 }, (error, stdout) => {
            const up = stdout && stdout.includes('UP');
            res.json({ enabled: up, ap_mode: false });
        });
    });
});

// Configure static IP or switch to DHCP
app.post('/api/network/configure', (req, res) => {
    const { interface: iface, mode, ip, subnet, gateway, dns } = req.body;

    // Determine the actual Linux interface name
    let linuxIface;
    if (iface === 'ethernet') {
        // Check if end0 or eth0 exists
        try {
            require('child_process').execSync('ip link show end0 2>/dev/null');
            linuxIface = 'end0';
        } catch {
            linuxIface = 'eth0';
        }
    } else if (iface === 'wifi') {
        linuxIface = 'wlan0';
    } else {
        return res.status(400).json({ error: 'Invalid interface' });
    }

    // If switching to DHCP
    if (mode === 'dhcp') {
        exec(`sudo ip addr flush dev ${linuxIface} && sudo dhclient ${linuxIface} 2>/dev/null`, { timeout: 15000 }, (error) => {
            if (error) return res.status(500).json({ error: 'Failed to switch to DHCP' });
            res.json({ success: true, message: `${iface} switched to DHCP` });
        });
        return;
    }

    // Static IP configuration
    if (!ip || !subnet || !gateway) {
        return res.status(400).json({ error: 'IP, Subnet, and Gateway are required for static config' });
    }

    // Convert subnet mask (255.255.255.0) to CIDR (/24)
    function subnetToCidr(mask) {
        if (/^\d+$/.test(mask)) return mask; // Already CIDR
        return mask.split('.').reduce((c, o) => c + (parseInt(o) >>> 0).toString(2).split('1').length - 1, 0);
    }
    const cidr = subnetToCidr(subnet);

    // Build command sequence
    const cmds = [
        `sudo ip addr flush dev ${linuxIface}`,
        `sudo ip addr add ${ip}/${cidr} dev ${linuxIface}`,
        `sudo ip link set ${linuxIface} up`,
        `sudo ip route add default via ${gateway} dev ${linuxIface} 2>/dev/null || sudo ip route replace default via ${gateway} dev ${linuxIface}`
    ];

    // Update DNS if provided
    if (dns) {
        cmds.push(`echo 'nameserver ${dns}' | sudo tee /etc/resolv.conf > /dev/null`);
    }

    const fullCmd = cmds.join(' && ');
    console.log(`[NET] Applying static config to ${linuxIface}: ${ip}/${cidr} gw ${gateway} dns ${dns || 'unchanged'}`);

    exec(fullCmd, { timeout: 10000 }, (error, stdout, stderr) => {
        if (error) {
            console.error(`[NET] Static config failed:`, stderr);
            return res.status(500).json({ error: 'Failed to apply static config: ' + (stderr || error.message) });
        }
        console.log(`[NET] Static config applied to ${linuxIface}`);
        res.json({ success: true, message: `Static IP ${ip}/${cidr} applied to ${iface}` });
    });
});

// ========================================
// PAGE READY SIGNAL (for Plymouth transition)
// ========================================

app.post('/api/signal-ready', (req, res) => {
    const signalFile = '/tmp/ods-loader-ready';
    fs.writeFileSync(signalFile, Date.now().toString());
    console.log('[SIGNAL] Page ready — Plymouth can quit');
    res.json({ success: true });
});

// ========================================
// ADMIN AUTH APIs (Upgrade C — otter user auth)
// ========================================

// Simple session tracking (in-memory, resets on restart — fine for device-local)
const adminSessions = new Map();

// Validate otter credentials via PAM-standard crypt (replaces broken su pipe)
app.post('/api/admin/login', (req, res) => {
    const { username, password } = req.body;

    if (!username || !password) {
        return res.status(400).json({ error: 'Username and password required' });
    }

    // Only allow 'otter' user login
    if (username !== 'otter') {
        return res.status(401).json({ error: 'Invalid credentials' });
    }

    // Validate via Python crypt+spwd (reads /etc/shadow via sudo)
    const escapedUser = username.replace(/[^a-zA-Z0-9_]/g, '');
    const escapedPass = password.replace(/'/g, "'\\'");
    exec(`sudo /usr/local/bin/ods-auth-check.sh '${escapedUser}' '${escapedPass}'`, { timeout: 5000 }, (error, stdout) => {
        if (stdout && stdout.trim() === 'OK') {
            // Generate simple session token
            const token = require('crypto').randomBytes(32).toString('hex');
            adminSessions.set(token, {
                username,
                created: Date.now(),
                expires: Date.now() + (30 * 60 * 1000) // 30 min session
            });
            console.log(`[ADMIN] ${username} authenticated successfully`);
            res.json({ success: true, token });
        } else {
            console.log(`[ADMIN] Failed login attempt for ${username}`);
            res.status(401).json({ error: 'Invalid credentials' });
        }
    });
});

// Middleware to validate admin session
function requireAdmin(req, res, next) {
    const token = req.headers['x-admin-token'] || req.body.token;
    if (!token) {
        return res.status(401).json({ error: 'Admin authentication required' });
    }

    const session = adminSessions.get(token);
    if (!session || session.expires < Date.now()) {
        adminSessions.delete(token);
        return res.status(401).json({ error: 'Session expired' });
    }

    req.adminUser = session.username;
    next();
}

// Launch admin terminal (opens xterm via Openbox — appears as overlay)
app.post('/api/admin/terminal', requireAdmin, (req, res) => {
    exec('DISPLAY=:0 xterm -title "Admin Terminal" -fa "Monospace" -fs 14 -bg "#1a1a2e" -fg "#00ff88" &');
    console.log(`[ADMIN] Terminal launched by ${req.adminUser}`);
    res.json({ success: true, message: 'Admin terminal launched' });
});

// Restart all ODS services
app.post('/api/admin/restart-services', requireAdmin, (req, res) => {
    console.log(`[ADMIN] Services restart requested by ${req.adminUser}`);
    res.json({ success: true, message: 'Restarting all ODS services...' });
    setTimeout(() => exec('sudo systemctl restart ods-kiosk ods-webserver ods-health-monitor ods-dpms-enforce.timer 2>/dev/null'), 1000);
});

// Update admin password
app.post('/api/admin/password', requireAdmin, (req, res) => {
    const { newPassword } = req.body;
    if (!newPassword || newPassword.length < 8) {
        return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }
    // Change otter user password via chpasswd
    exec(`echo 'otter:${newPassword.replace(/'/g, "'\\'")}' | sudo chpasswd`, { timeout: 5000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to update password' });
        console.log(`[ADMIN] Password updated by ${req.adminUser}`);
        res.json({ success: true, message: 'Admin password updated' });
    });
});

// Toggle SSH
app.post('/api/admin/ssh', requireAdmin, (req, res) => {
    const { enabled } = req.body;
    const action = enabled ? 'enable --now' : 'disable --now';
    exec(`systemctl ${action} ssh 2>/dev/null || systemctl ${action} sshd 2>/dev/null`, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to toggle SSH' });
        console.log(`[ADMIN] SSH ${enabled ? 'enabled' : 'disabled'} by ${req.adminUser}`);
        res.json({ success: true, message: `SSH ${enabled ? 'enabled' : 'disabled'}` });
    });
});

// View service status
app.get('/api/admin/services', requireAdmin, (req, res) => {
    exec('systemctl status ods-kiosk ods-webserver ods-dpms-enforce.timer ods-display-config ods-health-monitor --no-pager 2>&1', { timeout: 5000 }, (error, stdout) => {
        res.json({ status: stdout || 'Unable to query services' });
    });
});

// ========================================
// DEVICE INFO API (hostname, MAC, network, pairing)
// ========================================

app.get('/api/device/info', (req, res) => {
    const commands = {
        three_word_name: 'hostname 2>/dev/null || echo unknown',
        mac_address: "cat /sys/class/net/end0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo --",
        connection_method: "ip route get 8.8.8.8 2>/dev/null | head -1 | sed -n 's/.*dev \\([^ ]*\\).*/\\1/p' || echo --",
        ssid: "iwgetid -r 2>/dev/null || echo ''",
        ip_address: "hostname -I 2>/dev/null | awk '{print $1}' || echo --"
    };

    let completed = 0;
    const total = Object.keys(commands).length;
    const info = {};

    for (const [key, cmd] of Object.entries(commands)) {
        exec(cmd, { timeout: 3000 }, (error, stdout) => {
            info[key] = stdout ? stdout.trim() : '--';
            completed++;

            if (completed === total) {
                // Determine connection type from interface name
                const iface = info.connection_method;
                let connType = 'Unknown';
                if (iface.startsWith('eth') || iface.startsWith('end')) connType = 'Ethernet';
                else if (iface.startsWith('wl')) connType = 'WiFi';

                // Read pairing data if available
                let account_name = '';
                let device_name = '';
                try {
                    const flagData = JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'));
                    account_name = flagData.account_name || '';
                    device_name = flagData.device_name || '';
                } catch (e) { /* not paired yet */ }

                res.json({
                    three_word_name: info.three_word_name,
                    mac_address: info.mac_address,
                    connection_type: connType,
                    ssid: connType === 'WiFi' ? info.ssid : '',
                    ip_address: info.ip_address,
                    account_name,
                    device_name
                });
            }
        });
    }
});

// ========================================
// CONTENT CACHE API
// ========================================

const cacheManager = require('./player/cache-manager');

// Manual sync trigger
app.post('/api/cache/sync', async (req, res) => {
    try {
        const enrollment = cacheManager.getCachedConfig()
            ? JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'))
            : null;

        if (!enrollment) {
            return res.status(400).json({ error: 'Player not enrolled' });
        }

        const result = await cacheManager.syncContent(
            enrollment.cloud_url,
            enrollment.player_id,
            enrollment.api_token
        );

        res.json(result);
    } catch (error) {
        console.error('[Cache] Sync error:', error.message);
        res.status(500).json({ error: error.message });
    }
});

// Cache status
app.get('/api/cache/status', (req, res) => {
    const offline = cacheManager.checkOfflineCapability();
    const manifest = cacheManager.loadManifest();

    res.json({
        canOperate: offline.canOperate,
        assetCount: offline.assetCount,
        configCached: offline.config !== null,
        configHash: offline.config?.config_hash || null,
        assets: Object.entries(manifest).map(([id, entry]) => ({
            id,
            filename: entry.filename,
            type: entry.type,
            checksum: entry.checksum,
            downloadedAt: entry.downloadedAt
        }))
    });
});

// Serve cached content files
app.get('/api/cache/content/:contentId', (req, res) => {
    const localPath = cacheManager.getCachedAssetPath(req.params.contentId);
    if (!localPath) {
        return res.status(404).json({ error: 'Content not cached' });
    }
    res.sendFile(localPath);
});

// Clean stale cache
app.post('/api/cache/clean', (req, res) => {
    const maxDays = req.body.maxAgeDays || 7;
    cacheManager.cleanStaleCache(maxDays);
    res.json({ success: true, message: `Cleaned stale files older than ${maxDays} days` });
});

// ========================================
// CONTENT DELIVERY APIs (for player.html renderer)
// ========================================

const cloudSync = require('./player/cloud-sync');

// GET /api/player/content — Returns current playlist for the renderer
app.get('/api/player/content', (req, res) => {
    const content = cloudSync.getContentForRenderer();
    if (!content) {
        return res.json({ hasContent: false, playlist: null });
    }
    res.json({ hasContent: true, playlist: content });
});

// GET /api/player/sync-status — Returns sync health for system config panel
app.get('/api/player/sync-status', (req, res) => {
    res.json(cloudSync.getStatus());
});

// POST /api/player/sync-now — Manual sync trigger (from system config)
app.post('/api/player/sync-now', async (req, res) => {
    try {
        await cloudSync.doSync();
        res.json({ success: true, status: cloudSync.getStatus() });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Serve cached content files directly (for renderer <img>/<video> tags)
app.use('/cache', express.static(cacheManager.GOOD_CACHE_DIR));


// ========================================
// START SERVER
// ========================================
app.listen(PORT, () => {
    console.log(`[SETUP] ODS Player OS server running on port ${PORT}`);

    // Start cloud sync (WebSocket + config polling)
    cloudSync.start({
        onContentReady: () => {
            console.log('[CloudSync] 🎬 Content ready — renderer will pick up on next poll');
        }
    });

    // Also listen on port 80 — iOS captive portal detection checks port 80
    // Without this, the phone connects to AP but immediately disassociates
    const http = require('http');
    http.createServer(app).listen(80, () => {
        console.log('[SETUP] Captive portal listener on port 80 (for iOS/Android)');
    }).on('error', (err) => {
        if (err.code === 'EACCES') {
            console.log('[SETUP] Port 80 requires root — use: sudo setcap cap_net_bind_service=+ep $(which node)');
        } else {
            console.log('[SETUP] Port 80 listener error:', err.message);
        }
    });

    // Clean stale cache daily
    setInterval(() => cacheManager.cleanStaleCache(7), 24 * 60 * 60 * 1000);
});
