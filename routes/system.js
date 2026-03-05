/**
 * routes/system.js — System management routes for ODS Player Atlas
 *
 * Extracted from monolithic server.js. Handles:
 *  - System info gathering (CPU, RAM, disk, versions, etc.)
 *  - System actions (restart, reboot, shutdown, factory reset, unpair)
 *  - Display resolution changes
 *  - Cache clearing
 *  - Timezone and volume control
 *  - System logs viewer
 */

const express = require('express');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const router = express.Router();

// ─── System Info ────────────────────────────────────────────────────────────
router.get('/info', (req, res) => {
    const info = {};
    const commands = {
        hostname: 'hostname',
        cpu_serial: "cat /proc/cpuinfo | grep Serial | awk '{print $3}'",
        cpu_temp: "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null",
        uptime: 'uptime -p',
        uptime_seconds: "awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0",
        ram: "free -h | awk '/^Mem:/ {print $3 \"/\" $2}'",
        ram_percent: "free | awk '/^Mem:/ {printf \"%.0f\", $3/$2*100}'",
        memory_total_mb: "free -m | awk '/^Mem:/ {print $2}'",
        memory_available_mb: "free -m | awk '/^Mem:/ {print $7}'",
        storage: "df -h / | awk 'NR==2 {print $3 \"/\" $2}'",
        storage_percent: "df / | awk 'NR==2 {print $5}' | tr -d '%'",
        disk_free_mb: "df -m / | awk 'NR==2 {print $4}'",
        os_version: 'cat /home/signage/ODS/VERSION 2>/dev/null || echo unknown',
        player_version: 'cat /home/signage/ODS/PLAYER_VERSION 2>/dev/null || echo unknown',
        os_pretty: "lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo unknown",
        ip_address: "hostname -I | awk '{print $1}'",
        mac_address: "cat /sys/class/net/end0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo --",
        dns: "cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}'",
        interfaces: "ip -o addr show | awk '{print $2, $3, $4}' | grep -v '^lo '",
        display_resolution: "DISPLAY=:0 xrandr 2>/dev/null | grep '[*]' | head -1 | awk '{print $1}'",
        display_scale: "echo $ODS_SCALE",
        disk_total: "lsblk -dn -o SIZE /dev/mmcblk0 2>/dev/null || echo '—'",
        device_name: 'hostname 2>/dev/null || echo unknown',
        rustdesk_id: 'rustdesk --get-id 2>/dev/null || echo unknown',
        device_conf: 'cat /home/signage/ODS/device.conf 2>/dev/null || echo {}'
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
                    cpu_serial: info.cpu_serial && info.cpu_serial !== '—' ? info.cpu_serial : null,
                    device_name: info.device_name || info.hostname,
                    cpu_temp: info.cpu_temp,
                    uptime: info.uptime,
                    uptime_seconds: parseInt(info.uptime_seconds) || 0,
                    ram_usage: info.ram,
                    ram_percent: parseInt(info.ram_percent) || 0,
                    memory_total_mb: parseInt(info.memory_total_mb) || 0,
                    memory_available_mb: parseInt(info.memory_available_mb) || 0,
                    storage_usage: info.storage,
                    storage_percent: parseInt(info.storage_percent) || 0,
                    disk_free_mb: parseInt(info.disk_free_mb) || 0,
                    disk_total: info.disk_total ? info.disk_total.trim() : '—',
                    os_version: (() => {
                        const raw = (info.os_version || '').trim();
                        if (!raw || raw === 'unknown') return '—';
                        const clean = raw.replace(/-[A-Z]+$/, '');
                        return `Atlas ${clean}`;
                    })(),
                    os_version_full: (() => {
                        const raw = (info.os_version || '').trim();
                        if (!raw || raw === 'unknown') return '—';
                        return `Atlas ${raw}`;
                    })(),
                    player_version: (() => {
                        const raw = (info.player_version || '').trim();
                        if (!raw || raw === 'unknown') return '—';
                        return raw;
                    })(),
                    player_version_clean: (() => {
                        const raw = (info.player_version || '').trim();
                        if (!raw || raw === 'unknown') return '—';
                        return raw.replace(/-[A-Z]+$/, '');
                    })(),
                    os_pretty: info.os_pretty && info.os_pretty !== 'unknown' ? info.os_pretty : null,
                    version_clean: (() => {
                        const raw = (info.os_version || '').trim();
                        if (!raw || raw === 'unknown') return '—';
                        return raw.replace(/-[A-Z]+$/, '');
                    })(),
                    ip_address: info.ip_address,
                    mac_address: info.mac_address && info.mac_address !== '--' ? info.mac_address : null,
                    dns: info.dns,
                    interfaces: info.interfaces,
                    display_resolution: info.display_resolution,
                    display_scale: info.display_scale || '1',
                    device_name: info.device_name && info.device_name !== 'unknown' ? info.device_name : null,
                    rustdesk_id: info.rustdesk_id && info.rustdesk_id !== 'unknown' ? info.rustdesk_id : null
                });
            }
        });
    }
});

// ─── System Actions ─────────────────────────────────────────────────────────

// Restart signage — detached process restart (Ctrl+Alt+Shift+K equivalent)
router.post('/restart-signage', (req, res) => {
    console.log('[SYSTEM] Restart signage requested');
    res.json({ success: true, message: 'Restarting signage...' });
    setTimeout(() => {
        const child = spawn('sudo', ['systemctl', 'restart', 'ods-webserver'], {
            detached: true,
            stdio: 'ignore'
        });
        child.unref();
    }, 500);
});

router.post('/reboot', (req, res) => {
    res.json({ success: true, message: 'Rebooting...' });
    setTimeout(() => exec('sudo /usr/sbin/reboot'), 2000);
});

router.post('/shutdown', (req, res) => {
    res.json({ success: true, message: 'Shutting down...' });
    setTimeout(() => exec('sudo /usr/sbin/shutdown -h now'), 2000);
});

// ─── Unpair ─────────────────────────────────────────────────────────────────
router.post('/unpair', async (req, res) => {
    console.log('[UNPAIR] Device unpair initiated');
    res.json({ success: true, message: 'Unpairing device...' });

    setTimeout(async () => {
        try {
            let playerId = null;
            let cloudUrl = null;
            try {
                const flagData = JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'));
                playerId = flagData.player_id;
                cloudUrl = flagData.cloud_url || process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
            } catch (e) { /* no enrollment data */ }

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

            exec('rm -f /var/lib/ods/enrollment.flag');
            console.log('[UNPAIR] Local state cleared — rebooting');
            exec('sudo /usr/sbin/reboot');
        } catch (e) {
            console.error('[UNPAIR] Error:', e.message);
            exec('sudo /usr/sbin/reboot');
        }
    }, 2000);
});

// ─── Resolution ─────────────────────────────────────────────────────────────
router.post('/resolution', (req, res) => {
    const { resolution } = req.body;
    if (!resolution || !resolution.match(/^\d+x\d+$/)) {
        return res.status(400).json({ error: 'Invalid resolution format' });
    }
    const cmd = `DISPLAY=:0 xrandr --output $(DISPLAY=:0 xrandr | grep ' connected' | head -1 | awk '{print $1}') --mode ${resolution} 2>&1`;
    exec(cmd, { timeout: 10000 }, (error, stdout) => {
        if (error) {
            return res.status(500).json({ error: 'Failed to set resolution: ' + (stdout || error.message) });
        }
        res.json({ success: true, message: `Resolution set to ${resolution}.` });
    });
});

// ─── Cache Clear ────────────────────────────────────────────────────────────
router.post('/cache-clear', (req, res) => {
    exec('sudo rm -rf /home/signage/.config/chromium/Default/Cache/* /home/signage/.config/chromium/Default/Code\\ Cache/*', (error) => {
        if (error) return res.status(500).json({ error: 'Failed to clear cache' });
        res.json({ success: true, message: 'Browser cache cleared. Restart to take effect.' });
    });
});

// ─── Factory Reset ──────────────────────────────────────────────────────────
router.post('/factory-reset', async (req, res) => {
    console.log('[FACTORY RESET] Initiated — restoring P:2.5 state');
    res.json({ success: true, message: 'Factory reset initiated. Device will reboot to enrollment...' });

    setTimeout(async () => {
        try {
            let playerId = null;
            let cloudUrl = null;
            try {
                const flagData = JSON.parse(fs.readFileSync('/var/lib/ods/enrollment.flag', 'utf8'));
                playerId = flagData.player_id;
                cloudUrl = flagData.cloud_url || process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
            } catch (e) { /* no enrollment data */ }

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

            exec('rm -f /var/lib/ods/enrollment.flag');
            exec('rm -rf /home/signage/.config/chromium');
            exec('rm -rf /home/signage/ODS/cache/*');

            console.log('[FACTORY RESET] Local state cleared — rebooting to P:2.5');
            exec('sudo /usr/sbin/reboot');
        } catch (e) {
            console.error('[FACTORY RESET] Error:', e.message);
            exec('sudo /usr/sbin/reboot');
        }
    }, 2000);
});

// ─── Timezone ───────────────────────────────────────────────────────────────
router.post('/timezone', (req, res) => {
    const { timezone } = req.body;
    if (!timezone) return res.status(400).json({ error: 'Timezone required' });
    exec(`sudo timedatectl set-timezone '${timezone.replace(/[^a-zA-Z0-9_/]/g, '')}'`, { timeout: 5000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to set timezone' });
        res.json({ success: true, message: `Timezone set to ${timezone}` });
    });
});

// ─── Volume ─────────────────────────────────────────────────────────────────
router.get('/volume', (req, res) => {
    exec("amixer sget Master 2>/dev/null | grep -oP '\\[\\d+%\\]' | head -1 | tr -d '[]%'", { timeout: 3000 }, (error, stdout) => {
        const volume = parseInt(stdout?.trim()) || 75;
        res.json({ volume });
    });
});

router.post('/volume', (req, res) => {
    const { volume } = req.body;
    const vol = Math.max(0, Math.min(100, parseInt(volume) || 75));
    exec(`amixer sset Master ${vol}% 2>/dev/null`, { timeout: 3000 }, (error) => {
        if (error) return res.status(500).json({ error: 'Failed to set volume' });
        res.json({ success: true, volume: vol });
    });
});

// ─── Logs ───────────────────────────────────────────────────────────────────
router.get('/logs', (req, res) => {
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

module.exports = router;
