/**
 * tests/network.test.js — Network routes unit tests
 *
 * Tests network status (WiFi + Ethernet), WiFi scanning,
 * WiFi configure/toggle/state, display modes/monitors,
 * connection status polling, and static IP / DHCP configuration.
 */

const express = require('express');
const request = require('supertest');
const { exec } = require('child_process');
const os = require('os');

// Mock child_process.exec (but not the whole module — supertest needs execSync)
jest.mock('child_process', () => {
    const actual = jest.requireActual('child_process');
    return {
        ...actual,
        exec: jest.fn(),
        execSync: jest.fn()
    };
});

// Spy on os.hostname without replacing the entire os module
jest.spyOn(os, 'hostname').mockReturnValue('test-player');

let app;
function createApp() {
    delete require.cache[require.resolve('../routes/network')];
    const networkRoutes = require('../routes/network');
    app = express();
    app.use(express.json());
    app.use('/api', networkRoutes);
    return app;
}

describe('Network Routes', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        os.hostname.mockReturnValue('test-player');
        app = createApp();
    });

    // ─── Network Status ─────────────────────────────────────────────────────
    describe('GET /api/status', () => {
        it('returns network status with WiFi connected', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];

                if (cmd === 'iwgetid -r') {
                    return cb(null, 'MyNetwork\n');
                }
                if (cmd.includes('ip route | grep default')) {
                    return cb(null, 'default via 192.168.1.1 dev end0\n');
                }
                if (cmd.includes('nameserver')) {
                    return cb(null, '8.8.8.8, 8.8.4.4\n');
                }
                if (cmd.includes('ip -4 addr show')) {
                    return cb(null, '    inet 192.168.1.50/24 brd 192.168.1.255 scope global\n');
                }
                if (cmd.includes('ip route') && cmd.includes('awk')) {
                    return cb(null, '192.168.1.1\n');
                }
                if (cmd.includes('dhclient') || cmd.includes('dhcpcd') || cmd.includes('NetworkManager')) {
                    return cb(null, 'dhclient running\n');
                }
                cb(null, '\n');
            });

            const res = await request(app).get('/api/status');
            expect(res.status).toBe(200);
            expect(res.body.hostname).toBe('test-player');
            expect(res.body.wifi_connected).toBe(true);
            expect(res.body.ssid).toBe('MyNetwork');
            expect(res.body.ethernet_connected).toBe(true);
            expect(res.body.hasInternet).toBe(true);
        });

        it('returns status when WiFi is disconnected', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd === 'iwgetid -r') return cb(null, '\n');
                if (cmd.includes('wpa_cli')) return cb(null, 'wpa_state=DISCONNECTED\n');
                if (cmd.includes('ip route | grep default')) return cb(null, 'default via 192.168.1.1 dev eth0\n');
                if (cmd.includes('nameserver')) return cb(null, '8.8.8.8\n');
                if (cmd.includes('ip -4 addr')) return cb(null, '    inet 192.168.1.50/24\n');
                if (cmd.includes("awk '{print $3}'")) return cb(null, '192.168.1.1\n');
                if (cmd.includes('grep -v grep')) return cb(null, '\n');
                cb(null, '\n');
            });

            const res = await request(app).get('/api/status');
            expect(res.status).toBe(200);
            expect(res.body.wifi_connected).toBe(false);
            expect(res.body.ethernet_connected).toBe(true);
        });
    });

    // ─── WiFi Scan ──────────────────────────────────────────────────────────
    describe('GET /api/wifi/scan', () => {
        it('returns empty list when AP is active', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd === 'pgrep -x hostapd') {
                    return cb(null, '1234\n');  // hostapd is running
                }
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/scan');
            expect(res.status).toBe(200);
            expect(res.body.networks).toEqual([]);
            expect(res.body.ap_active).toBe(true);
        });

        it('returns scanned networks sorted by signal', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd === 'pgrep -x hostapd') {
                    return cb(new Error('not running'), '');
                }
                if (cmd.includes('iw dev wlan0 scan')) {
                    return cb(null, [
                        '\tsignal: -45.00 dBm\tSSID: StrongNetwork',
                        '\tsignal: -80.00 dBm\tSSID: WeakNetwork',
                        '\tsignal: -60.00 dBm\tSSID: MediumNetwork'
                    ].join('\n'));
                }
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/scan');
            expect(res.status).toBe(200);
            expect(res.body.networks.length).toBe(3);
            // Sorted by signal strength (strongest first)
            expect(res.body.networks[0].ssid).toBe('StrongNetwork');
            expect(res.body.networks[0].signal).toBe(-45);
        });

        it('deduplicates networks', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd === 'pgrep -x hostapd') return cb(new Error(), '');
                if (cmd.includes('iw dev wlan0 scan')) {
                    return cb(null, [
                        '\tsignal: -40.00 dBm\tSSID: DuplicateNet',
                        '\tsignal: -70.00 dBm\tSSID: DuplicateNet',
                        '\tsignal: -50.00 dBm\tSSID: UniqueNet'
                    ].join('\n'));
                }
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/scan');
            expect(res.status).toBe(200);
            const ssids = res.body.networks.map(n => n.ssid);
            expect(new Set(ssids).size).toBe(ssids.length);
        });
    });

    // ─── WiFi Configure ─────────────────────────────────────────────────────
    describe('POST /api/wifi/configure', () => {
        it('rejects missing SSID', async () => {
            const res = await request(app)
                .post('/api/wifi/configure')
                .send({});
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/ssid/i);
        });

        it('configures WiFi with password', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/wifi/configure')
                .send({ ssid: 'TestNetwork', password: 'secret123' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toContain('TestNetwork');
        });

        it('configures open WiFi (no password)', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/wifi/configure')
                .send({ ssid: 'OpenNetwork' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
        });

        it('returns 500 on config write failure', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                cb(new Error('permission denied'));
            });

            const res = await request(app)
                .post('/api/wifi/configure')
                .send({ ssid: 'TestNetwork', password: 'pass' });
            expect(res.status).toBe(500);
        });
    });

    // ─── WiFi Toggle ────────────────────────────────────────────────────────
    describe('POST /api/wifi/toggle', () => {
        it('enables WiFi', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/wifi/toggle')
                .send({ enabled: true });
            expect(res.status).toBe(200);
            expect(res.body.enabled).toBe(true);
            expect(res.body.message).toMatch(/enabled/i);
        });

        it('disables WiFi', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/wifi/toggle')
                .send({ enabled: false });
            expect(res.status).toBe(200);
            expect(res.body.enabled).toBe(false);
            expect(res.body.message).toMatch(/disabled/i);
        });

        it('returns 500 on failure', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(new Error('device busy'));
            });

            const res = await request(app)
                .post('/api/wifi/toggle')
                .send({ enabled: true });
            expect(res.status).toBe(500);
        });
    });

    // ─── WiFi State ─────────────────────────────────────────────────────────
    describe('GET /api/wifi/state', () => {
        it('detects AP mode when hostapd running', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd.includes('pgrep')) return cb(null, '1234\n');
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/state');
            expect(res.status).toBe(200);
            expect(res.body.ap_mode).toBe(true);
            expect(res.body.enabled).toBe(false);
        });

        it('reports WiFi interface UP', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd.includes('pgrep')) return cb(new Error(), '');
                if (cmd.includes('ip link show wlan0')) return cb(null, '2: wlan0: <BROADCAST,MULTICAST,UP> mtu 1500\n');
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/state');
            expect(res.status).toBe(200);
            expect(res.body.enabled).toBe(true);
            expect(res.body.ap_mode).toBe(false);
        });

        it('reports WiFi interface DOWN', async () => {
            exec.mockImplementation((cmd, ...args) => {
                const cb = args[args.length - 1];
                if (cmd.includes('pgrep')) return cb(new Error(), '');
                if (cmd.includes('ip link show wlan0')) return cb(null, '2: wlan0: <BROADCAST,MULTICAST> mtu 1500\n');
                cb(null, '\n');
            });

            const res = await request(app).get('/api/wifi/state');
            expect(res.status).toBe(200);
            expect(res.body.enabled).toBe(false);
        });
    });

    // ─── WiFi Connection Status ─────────────────────────────────────────────
    describe('GET /api/wifi/connection-status', () => {
        it('returns a valid connection state object', async () => {
            // wifiConnectionState is module-level mutable state — may be modified by prior tests
            // in the same Jest run. Test the contract (valid shape), not the exact initial value.
            const res = await request(app).get('/api/wifi/connection-status');
            expect(res.status).toBe(200);
            expect(res.body).toHaveProperty('stage');
            expect(res.body).toHaveProperty('message');
            expect(res.body).toHaveProperty('ssid');
            expect(res.body).toHaveProperty('ip');
            expect(['idle', 'configuring', 'connecting', 'obtaining_ip', 'connected', 'failed', 'restarting']).toContain(res.body.stage);
        });
    });

    // ─── Display Modes ──────────────────────────────────────────────────────
    describe('GET /api/display/modes', () => {
        it('returns available display modes', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '1920x1080\n1280x720\n3840x2160\n');
            });

            const res = await request(app).get('/api/display/modes');
            expect(res.status).toBe(200);
            expect(res.body.modes).toContain('1920x1080');
            expect(res.body.modes).toContain('1280x720');
        });

        it('returns empty modes when xrandr fails', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app).get('/api/display/modes');
            expect(res.status).toBe(200);
            expect(res.body.modes).toEqual([]);
        });
    });

    // ─── Display Monitors ───────────────────────────────────────────────────
    describe('GET /api/display/monitors', () => {
        it('parses connected monitors from xrandr output', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, [
                    'HDMI-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 530mm x 300mm',
                    '   1920x1080     60.00*+',
                    '   1280x720      60.00',
                    'HDMI-2 disconnected (normal left inverted right x axis y axis)',
                ].join('\n'));
            });

            const res = await request(app).get('/api/display/monitors');
            expect(res.status).toBe(200);
            expect(res.body.count).toBe(1);  // Only connected monitors
            expect(res.body.monitors[0].name).toBe('HDMI-1');
            expect(res.body.monitors[0].primary).toBe(true);
            expect(res.body.monitors[0].resolution).toBe('1920x1080');
            expect(res.body.monitors[0].modes.length).toBe(2);
            expect(res.body.monitors[0].currentMode.resolution).toBe('1920x1080');
        });

        it('returns empty when xrandr fails', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(new Error('no display'), '');
            });

            const res = await request(app).get('/api/display/monitors');
            expect(res.status).toBe(200);
            expect(res.body.monitors).toEqual([]);
            expect(res.body.count).toBe(0);
        });
    });

    // ─── Network Configure (Static/DHCP) ────────────────────────────────────
    describe('POST /api/network/configure', () => {
        it('rejects invalid interface', async () => {
            const res = await request(app)
                .post('/api/network/configure')
                .send({ interface: 'invalid', mode: 'dhcp' });
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/invalid interface/i);
        });

        it('switches ethernet to DHCP', async () => {
            const { execSync } = require('child_process');
            execSync.mockImplementation(() => 'end0');

            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/network/configure')
                .send({ interface: 'ethernet', mode: 'dhcp' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/dhcp/i);
        });

        it('rejects static config with missing fields', async () => {
            const { execSync } = require('child_process');
            execSync.mockImplementation(() => 'end0');

            const res = await request(app)
                .post('/api/network/configure')
                .send({ interface: 'ethernet', mode: 'static', ip: '192.168.1.100' });
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/required/i);
        });

        it('applies static IP configuration', async () => {
            const { execSync } = require('child_process');
            execSync.mockImplementation(() => 'end0');

            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/network/configure')
                .send({
                    interface: 'ethernet',
                    mode: 'static',
                    ip: '192.168.1.100',
                    subnet: '255.255.255.0',
                    gateway: '192.168.1.1',
                    dns: '8.8.8.8'
                });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
        });

        it('handles wifi interface correctly', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/network/configure')
                .send({ interface: 'wifi', mode: 'dhcp' });
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
        });
    });
});
