/**
 * tests/system.test.js — System routes unit tests
 *
 * Tests system info gathering, reboot/shutdown/restart-signage,
 * unpair, factory reset, resolution, cache clear, timezone, volume, and logs.
 */

const express = require('express');
const request = require('supertest');
const { exec, spawn } = require('child_process');

// Mock child_process
jest.mock('child_process', () => ({
    exec: jest.fn(),
    spawn: jest.fn(() => ({ unref: jest.fn() }))
}));

// Mock fs for unpair/factory-reset (reads enrollment.flag)
jest.mock('fs', () => ({
    readFileSync: jest.fn(),
    writeFileSync: jest.fn(),
    existsSync: jest.fn()
}));

let app;
function createApp() {
    delete require.cache[require.resolve('../routes/system')];
    const systemRoutes = require('../routes/system');
    app = express();
    app.use(express.json());
    app.use('/api/system', systemRoutes);
    return app;
}

describe('System Routes', () => {
    beforeEach(() => {
        jest.useFakeTimers();
        jest.clearAllMocks();
        app = createApp();
    });

    afterEach(() => {
        jest.useRealTimers();
    });

    // ─── System Info ────────────────────────────────────────────────────────
    describe('GET /api/system/info', () => {
        it('returns system info from multiple exec calls', async () => {
            // Mock exec to return different values based on command
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; opts = {}; }
                const responses = {
                    'hostname': 'test-player',
                    'cat /sys/class/thermal/thermal_zone0/temp': '45000',
                    'uptime -p': 'up 2 days, 3 hours',
                    "awk '{print int($1)}' /proc/uptime": '180000',
                    'free -h': 'Mem:          3.8Gi       1.2Gi       2.0Gi',
                    'free |': '25',
                    'free -m': '3800\n3200',
                    'df -h': '5.0G/29G',
                    'df /': '18',
                    'df -m': '24000',
                    'cat /home/signage/ODS/VERSION': '10.0.0-BETA',
                    'cat /home/signage/ODS/PLAYER_VERSION': '9.3.0-RC',
                    'lsb_release': 'Armbian 24.11',
                    "hostname -I": '192.168.1.50',
                    'cat /sys/class/net': 'aa:bb:cc:dd:ee:ff',
                    'cat /etc/resolv.conf': '8.8.8.8',
                    'ip -o addr': 'end0 inet4 192.168.1.50/24',
                    'DISPLAY=:0 xrandr': '1920x1080',
                    'echo $ODS_SCALE': '1',
                    'lsblk': '29.7G',
                    'rustdesk': 'ABC123',
                    'cat /home/signage/ODS/device.conf': '{}'
                };

                // Find matching response (check if cmd starts with key)
                let value = '—';
                for (const [key, val] of Object.entries(responses)) {
                    if (cmd.includes(key)) {
                        value = val;
                        break;
                    }
                }
                cb(null, value + '\n');
            });

            const res = await request(app).get('/api/system/info');

            expect(res.status).toBe(200);
            expect(res.body.hostname).toBe('test-player');
            expect(res.body.cpu_temp).toBe('45.0°C');
            expect(res.body.os_version).toBe('Atlas 10.0.0');  // strips -BETA suffix
            expect(res.body.os_version_full).toBe('Atlas 10.0.0-BETA');  // keeps full version
            expect(res.body.ip_address).toBeDefined();
        });

        it('handles cpu_temp gracefully when unavailable', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '—\n');
            });

            const res = await request(app).get('/api/system/info');
            expect(res.status).toBe(200);
            expect(res.body.cpu_temp).toBe('—');
        });
    });

    // ─── System Actions ─────────────────────────────────────────────────────
    describe('POST /api/system/restart-signage', () => {
        it('returns success and spawns detached restart', async () => {
            const res = await request(app)
                .post('/api/system/restart-signage')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/restart/i);
        });
    });

    describe('POST /api/system/reboot', () => {
        it('returns success', async () => {
            const res = await request(app)
                .post('/api/system/reboot')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/reboot/i);
        });
    });

    describe('POST /api/system/shutdown', () => {
        it('returns success', async () => {
            const res = await request(app)
                .post('/api/system/shutdown')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/shutting down/i);
        });
    });

    // ─── Unpair ─────────────────────────────────────────────────────────────
    describe('POST /api/system/unpair', () => {
        it('returns success immediately (deferred reboot)', async () => {
            const res = await request(app)
                .post('/api/system/unpair')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/unpair/i);
        });
    });

    // ─── Resolution ─────────────────────────────────────────────────────────
    describe('POST /api/system/resolution', () => {
        it('rejects invalid resolution format', async () => {
            const res = await request(app)
                .post('/api/system/resolution')
                .send({ resolution: 'not-valid' });
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/invalid/i);
        });

        it('rejects missing resolution', async () => {
            const res = await request(app)
                .post('/api/system/resolution')
                .send({});
            expect(res.status).toBe(400);
        });

        it('sets valid resolution via xrandr', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/system/resolution')
                .send({ resolution: '1920x1080' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toContain('1920x1080');
        });

        it('handles xrandr failure', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(new Error('xrandr fail'), 'Mode not found');
            });

            const res = await request(app)
                .post('/api/system/resolution')
                .send({ resolution: '9999x9999' });
            expect(res.status).toBe(500);
        });
    });

    // ─── Cache Clear ────────────────────────────────────────────────────────
    describe('POST /api/system/cache-clear', () => {
        it('clears browser cache successfully', async () => {
            exec.mockImplementation((cmd, cb) => {
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/system/cache-clear')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/cache/i);
        });

        it('returns 500 on cache clear failure', async () => {
            exec.mockImplementation((cmd, cb) => {
                cb(new Error('rm failed'));
            });

            const res = await request(app)
                .post('/api/system/cache-clear')
                .send({});
            expect(res.status).toBe(500);
        });
    });

    // ─── Factory Reset ──────────────────────────────────────────────────────
    describe('POST /api/system/factory-reset', () => {
        it('returns success immediately (deferred cleanup + reboot)', async () => {
            const res = await request(app)
                .post('/api/system/factory-reset')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/factory reset/i);
        });
    });

    // ─── Timezone ───────────────────────────────────────────────────────────
    describe('POST /api/system/timezone', () => {
        it('rejects missing timezone', async () => {
            const res = await request(app)
                .post('/api/system/timezone')
                .send({});
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/required/i);
        });

        it('sets timezone via timedatectl', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/system/timezone')
                .send({ timezone: 'America/New_York' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toContain('America/New_York');
        });

        it('handles timedatectl failure', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(new Error('invalid timezone'));
            });

            const res = await request(app)
                .post('/api/system/timezone')
                .send({ timezone: 'Invalid/Zone' });
            expect(res.status).toBe(500);
        });
    });

    // ─── Volume ─────────────────────────────────────────────────────────────
    describe('GET /api/system/volume', () => {
        it('returns current volume', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '65');
            });

            const res = await request(app).get('/api/system/volume');
            expect(res.status).toBe(200);
            expect(res.body.volume).toBe(65);
        });

        it('defaults to 75 when amixer fails', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app).get('/api/system/volume');
            expect(res.status).toBe(200);
            expect(res.body.volume).toBe(75);
        });
    });

    describe('POST /api/system/volume', () => {
        it('sets volume level', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/system/volume')
                .send({ volume: 50 });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.volume).toBe(50);
        });

        it('clamps volume to 0–100 range', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/system/volume')
                .send({ volume: 150 });
            expect(res.status).toBe(200);
            expect(res.body.volume).toBe(100);
        });
    });

    // ─── Logs ───────────────────────────────────────────────────────────────
    describe('GET /api/system/logs', () => {
        it('returns boot logs by default', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '[2026-03-04] ODS booted successfully\n');
            });

            const res = await request(app).get('/api/system/logs');
            expect(res.status).toBe(200);
            expect(res.body.logs).toContain('ODS booted');
            expect(res.body.type).toBe('boot');
        });

        it('returns health logs when type=health', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, 'Health monitor active\n');
            });

            const res = await request(app)
                .get('/api/system/logs')
                .query({ type: 'health' });
            expect(res.status).toBe(200);
            expect(res.body.type).toBe('health');
        });

        it('returns service logs for type=services', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '● ods-kiosk.service - Active');
            });

            const res = await request(app)
                .get('/api/system/logs')
                .query({ type: 'services' });
            expect(res.status).toBe(200);
            expect(res.body.type).toBe('services');
        });
    });
});
