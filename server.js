const express = require('express');
const { exec } = require('child_process');
const fs = require('fs');
const QRCode = require('qrcode');
const app = express();

app.use(express.json());
app.use(express.static('public'));

// ========================================
// NETWORK APIs
// ========================================

// Get network status
app.get('/api/status', (req, res) => {
    exec('iwgetid -r', (error, stdout) => {
        const ssid = stdout.trim();
        const wifi_connected = !!ssid;

        exec('ip route | grep default', (error, stdout) => {
            // Check for both eth0 (standard) and end0 (Armbian Pi5)
            const ethernet_connected = stdout.includes('eth0') || stdout.includes('end0');
            const hasInternet = wifi_connected || ethernet_connected;

            res.json({
                wifi_connected,
                ethernet_connected,
                hasInternet,
                ssid: ssid || null
            });
        });
    });
});

// Configure WiFi
app.post('/api/wifi/configure', (req, res) => {
    const { ssid, password } = req.body;

    const wpaConfig = `
network={
    ssid="${ssid}"
    psk="${password}"
}
`;

    exec(`echo '${wpaConfig}' >> /etc/wpa_supplicant/wpa_supplicant.conf`, (error) => {
        if (error) {
            return res.status(500).json({ error: 'Failed to configure WiFi' });
        }

        exec('wpa_cli -i wlan0 reconfigure', (error) => {
            if (error) {
                return res.status(500).json({ error: 'Failed to restart WiFi' });
            }

            res.json({ success: true });
        });
    });
});

// Generate QR code
app.get('/api/qr', async (req, res) => {
    const setupUrl = `http://${req.hostname}:8080/setup.html`;
    const qrCode = await QRCode.toDataURL(setupUrl, { width: 400 });
    res.json({ qrCode });
});

// Trigger enrollment
app.post('/api/enroll', (req, res) => {
    exec('python3 /usr/local/bin/device_uuid_generator.py 209.38.118.127 9999', (error, stdout) => {
        if (error) {
            return res.status(500).json({ error: 'Enrollment failed' });
        }
        res.json({ success: true, output: stdout });
    });
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
        os_version: 'cat /etc/armbian-release 2>/dev/null | grep VERSION= | cut -d= -f2 || lsb_release -d -s',
        ip_address: "hostname -I | awk '{print $1}'",
        dns: "cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}'",
        interfaces: "ip -br addr show",
        display_resolution: "DISPLAY=:0 xrandr 2>/dev/null | grep '[*]' | head -1 | awk '{print $1}'",
        display_scale: "echo $ODS_SCALE"
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
                    cpu_temp: info.cpu_temp,
                    uptime: info.uptime,
                    ram_usage: info.ram,
                    ram_percent: parseInt(info.ram_percent) || 0,
                    storage_usage: info.storage,
                    storage_percent: parseInt(info.storage_percent) || 0,
                    os_version: info.os_version,
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
    res.json({ success: true, message: 'Rebooting in 3 seconds...' });
    setTimeout(() => exec('reboot'), 3000);
});

app.post('/api/system/shutdown', (req, res) => {
    res.json({ success: true, message: 'Shutting down in 3 seconds...' });
    setTimeout(() => exec('shutdown -h now'), 3000);
});

app.post('/api/system/cache-clear', (req, res) => {
    exec('rm -rf /home/signage/.config/chromium/Default/Cache/* /home/signage/.config/chromium/Default/Code\\ Cache/*', (error) => {
        if (error) return res.status(500).json({ error: 'Failed to clear cache' });
        res.json({ success: true, message: 'Browser cache cleared. Restart to take effect.' });
    });
});

app.post('/api/system/factory-reset', (req, res) => {
    res.json({ success: true, message: 'Factory reset initiated...' });
    setTimeout(() => {
        exec('rm -rf /home/signage/.config/chromium && reboot');
    }, 2000);
});

// System logs
app.get('/api/system/logs', (req, res) => {
    exec('journalctl -n 100 --no-pager -u ods-kiosk -u ods-webserver 2>/dev/null || tail -100 /var/log/ods-kiosk.log', (error, stdout) => {
        res.json({ logs: stdout || 'No logs available' });
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

// Validate otter credentials via system `su` command
app.post('/api/admin/login', (req, res) => {
    const { username, password } = req.body;

    if (!username || !password) {
        return res.status(400).json({ error: 'Username and password required' });
    }

    // Only allow 'otter' user login
    if (username !== 'otter') {
        return res.status(401).json({ error: 'Invalid credentials' });
    }

    // Validate password via su (checks PAM/shadow)
    const escapedPassword = password.replace(/'/g, "'\\''");
    exec(`echo '${escapedPassword}' | su -c 'echo OK' ${username} 2>&1`, { timeout: 5000 }, (error, stdout) => {
        if (stdout.trim() === 'OK') {
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
    exec('DISPLAY=:0 xterm -title "ODS Admin Terminal" -fa "Monospace" -fs 14 -bg "#1a1a2e" -fg "#00ff88" &');
    console.log(`[ADMIN] Terminal launched by ${req.adminUser}`);
    res.json({ success: true, message: 'Admin terminal launched' });
});

// Restart kiosk service
app.post('/api/admin/restart-kiosk', requireAdmin, (req, res) => {
    console.log(`[ADMIN] Kiosk restart requested by ${req.adminUser}`);
    res.json({ success: true, message: 'Restarting kiosk...' });
    setTimeout(() => exec('systemctl restart ods-kiosk'), 1000);
});

// View service status
app.get('/api/admin/services', requireAdmin, (req, res) => {
    exec('systemctl status ods-kiosk ods-webserver ods-dpms-enforce.timer ods-display-config ods-health-monitor --no-pager 2>&1', { timeout: 5000 }, (error, stdout) => {
        res.json({ status: stdout || 'Unable to query services' });
    });
});

// ========================================
// START SERVER
// ========================================
app.listen(8080, () => {
    console.log('[SETUP] ODS Player OS v6 server running on port 8080');
});
