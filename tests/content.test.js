/**
 * tests/content.test.js — Content & cache routes unit tests
 *
 * Tests cache sync, cache content serving, player content decision tree,
 * sync status, sync-now trigger, and device info gathering.
 */

const express = require('express');
const request = require('supertest');
const { exec } = require('child_process');

// Mock child_process.exec
jest.mock('child_process', () => {
    const actual = jest.requireActual('child_process');
    return {
        ...actual,
        exec: jest.fn()
    };
});

// Mock the player modules — cloud-sync and cache-manager
const mockCloudSync = {
    getContentForRenderer: jest.fn(),
    isCacheReady: jest.fn(),
    hasPlaylistChanged: jest.fn(),
    fetchLiveContent: jest.fn(),
    doSync: jest.fn(),
    getStatus: jest.fn(),
    start: jest.fn(),
    triggerSync: jest.fn()
};

const mockCacheManager = {
    getCachedConfig: jest.fn(),
    getCachedAssetPath: jest.fn(),
    getAssetUrl: jest.fn(),
    getCacheStatus: jest.fn(),
    checkOfflineCapability: jest.fn(),
    loadManifest: jest.fn(),
    syncContent: jest.fn(),
    cleanStaleCache: jest.fn(),
    GOOD_CACHE_DIR: '/tmp/test-cache',
    CACHE_DIR: '/tmp/test-cache'
};

// Mock the player modules
jest.mock('../player/cloud-sync', () => mockCloudSync);
jest.mock('../player/cache-manager', () => mockCacheManager);

// Mock fs for enrollment flag reads
jest.mock('fs', () => {
    const actual = jest.requireActual('fs');
    return {
        ...actual,
        readFileSync: jest.fn(),
        existsSync: jest.fn(),
        writeFileSync: jest.fn()
    };
});

let app;
function createApp() {
    delete require.cache[require.resolve('../routes/content')];
    const contentRoutes = require('../routes/content');
    app = express();
    app.use(express.json());
    app.use('/api', contentRoutes);
    return app;
}

describe('Content Routes', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        app = createApp();
    });

    // ─── Player Content Decision Tree ───────────────────────────────────────
    describe('GET /api/player/content', () => {
        it('serves from cache when cache is ready and unchanged', async () => {
            const mockPlaylist = {
                items: [{ id: '1', filename: 'test.mp4', duration: 10 }],
                layout: { type: 'fullscreen' }
            };

            mockCloudSync.getContentForRenderer.mockReturnValue(mockPlaylist);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: true, cached: 5, total: 5 });
            mockCloudSync.hasPlaylistChanged.mockResolvedValue({ changed: false, offline: false });

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('cache');
            expect(res.body.playlist).toEqual(mockPlaylist);
        });

        it('fetches live when playlist has changed', async () => {
            const mockPlaylist = { items: [{ id: '1' }] };
            const livePlaylist = { items: [{ id: '1' }, { id: '2' }] };

            mockCloudSync.getContentForRenderer.mockReturnValue(mockPlaylist);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: true, cached: 5, total: 5 });
            mockCloudSync.hasPlaylistChanged.mockResolvedValue({ changed: true, offline: false });
            mockCloudSync.fetchLiveContent.mockResolvedValue(livePlaylist);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('live-changed');
            expect(mockCloudSync.doSync).toHaveBeenCalled();
        });

        it('serves stale cache when live fetch fails', async () => {
            const mockPlaylist = { items: [{ id: '1' }] };

            mockCloudSync.getContentForRenderer.mockReturnValue(mockPlaylist);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: true, cached: 3, total: 3 });
            mockCloudSync.hasPlaylistChanged.mockResolvedValue({ changed: true, offline: false });
            mockCloudSync.fetchLiveContent.mockResolvedValue(null);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('stale-cache');
        });

        it('serves offline-cache when offline with ready cache', async () => {
            const mockPlaylist = { items: [{ id: '1' }] };

            mockCloudSync.getContentForRenderer.mockReturnValue(mockPlaylist);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: true, cached: 3, total: 3 });
            mockCloudSync.hasPlaylistChanged.mockResolvedValue({ changed: true, offline: true });

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('offline-cache');
        });

        it('serves partial cache and kicks off background sync', async () => {
            const mockPlaylist = { items: [{ id: '1' }] };

            mockCloudSync.getContentForRenderer.mockReturnValue(mockPlaylist);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: false, cached: 2, total: 5 });

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('partial-cache');
            expect(mockCloudSync.doSync).toHaveBeenCalled();
        });

        it('returns live-cold when no cache but live content available', async () => {
            const livePlaylist = { items: [{ id: '1' }] };

            mockCloudSync.getContentForRenderer.mockReturnValue(null);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: false, cached: 0, total: 0 });
            mockCloudSync.fetchLiveContent.mockResolvedValue(livePlaylist);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('live-cold');
        });

        it('returns empty when no cache and no network', async () => {
            mockCloudSync.getContentForRenderer.mockReturnValue(null);
            mockCloudSync.isCacheReady.mockReturnValue({ ready: false, cached: 0, total: 0 });
            mockCloudSync.fetchLiveContent.mockResolvedValue(null);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(false);
            expect(res.body.bootMode).toBe('empty');
        });

        it('falls back to error-fallback on exception with cache', async () => {
            const mockPlaylist = { items: [{ id: '1' }] };

            mockCloudSync.getContentForRenderer
                .mockImplementationOnce(() => { throw new Error('boom'); })
                .mockReturnValue(mockPlaylist);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(true);
            expect(res.body.bootMode).toBe('error-fallback');
        });

        it('returns error mode when exception and no cache', async () => {
            // First call (try block) throws, second call (catch block) returns null
            mockCloudSync.getContentForRenderer
                .mockImplementationOnce(() => { throw new Error('boom'); })
                .mockReturnValueOnce(null);

            const res = await request(app).get('/api/player/content');
            expect(res.status).toBe(200);
            expect(res.body.hasContent).toBe(false);
            expect(res.body.bootMode).toBe('error');
        });
    });

    // ─── Sync Status ────────────────────────────────────────────────────────
    describe('GET /api/player/sync-status', () => {
        it('returns sync status from cloudSync', async () => {
            mockCloudSync.getStatus.mockReturnValue({
                syncing: false,
                lastSync: '2026-03-04T08:00:00.000Z',
                cached: 5,
                total: 5,
                healthy: true
            });

            const res = await request(app).get('/api/player/sync-status');
            expect(res.status).toBe(200);
            expect(res.body.healthy).toBe(true);
            expect(res.body.cached).toBe(5);
        });
    });

    // ─── Cache Status ───────────────────────────────────────────────────────
    describe('GET /api/cache/status', () => {
        it('returns offline capability and asset manifest', async () => {
            mockCacheManager.checkOfflineCapability.mockReturnValue({
                canOperate: true,
                assetCount: 5,
                config: { config_hash: 'abc123' }
            });
            mockCacheManager.loadManifest.mockReturnValue({
                'id-1': { filename: 'video.mp4', type: 'video', checksum: 'sha1', downloadedAt: '2026-03-04' },
                'id-2': { filename: 'image.jpg', type: 'image', checksum: 'sha2', downloadedAt: '2026-03-04' }
            });

            const res = await request(app).get('/api/cache/status');
            expect(res.status).toBe(200);
            expect(res.body.canOperate).toBe(true);
            expect(res.body.assetCount).toBe(5);
            expect(res.body.configHash).toBe('abc123');
            expect(res.body.assets.length).toBe(2);
            expect(res.body.assets[0].id).toBe('id-1');
        });
    });

    // ─── Cache Content Serving ──────────────────────────────────────────────
    describe('GET /api/cache/content/:contentId', () => {
        it('returns 404 when content is not cached', async () => {
            mockCacheManager.getCachedAssetPath.mockReturnValue(null);

            const res = await request(app).get('/api/cache/content/some-id');
            expect(res.status).toBe(404);
            expect(res.body.error).toMatch(/not cached/i);
        });
    });

    // ─── Cache Clean ────────────────────────────────────────────────────────
    describe('POST /api/cache/clean', () => {
        it('cleans stale cache with default age', async () => {
            const res = await request(app)
                .post('/api/cache/clean')
                .send({});
            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(mockCacheManager.cleanStaleCache).toHaveBeenCalledWith(7);
        });

        it('accepts custom max age', async () => {
            const res = await request(app)
                .post('/api/cache/clean')
                .send({ maxAgeDays: 14 });
            expect(res.status).toBe(200);
            expect(mockCacheManager.cleanStaleCache).toHaveBeenCalledWith(14);
        });
    });

    // ─── Player Cache Ready ─────────────────────────────────────────────────
    describe('GET /api/player/cache-ready', () => {
        it('returns cache readiness status', async () => {
            mockCloudSync.isCacheReady.mockReturnValue({ ready: true, cached: 10, total: 10 });

            const res = await request(app).get('/api/player/cache-ready');
            expect(res.status).toBe(200);
            expect(res.body.ready).toBe(true);
            expect(res.body.cached).toBe(10);
        });
    });

    // ─── Device Info ────────────────────────────────────────────────────────
    describe('GET /api/device/info', () => {
        it('returns device info from exec commands', async () => {
            const fs = require('fs');
            fs.readFileSync.mockImplementation((filePath) => {
                if (typeof filePath === 'string' && filePath.includes('enrollment.flag')) {
                    return JSON.stringify({
                        enrolled: true,
                        device_uuid: 'test-uuid',
                        account_name: 'Test Org',
                        device_name: 'Lobby Display'
                    });
                }
                throw new Error('not found');
            });

            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                if (cmd.includes('hostname') && !cmd.includes('-I')) return cb(null, 'test-player\n');
                if (cmd.includes('cat /sys/class/net')) return cb(null, 'aa:bb:cc:dd:ee:ff\n');
                // The full piped command includes sed, so exec returns the extracted interface name
                if (cmd.includes('ip route get')) return cb(null, 'end0\n');
                if (cmd.includes('iwgetid')) return cb(null, '\n');
                if (cmd.includes('hostname -I')) return cb(null, '192.168.1.50\n');
                cb(null, '--\n');
            });

            const res = await request(app).get('/api/device/info');
            expect(res.status).toBe(200);
            expect(res.body.three_word_name).toBe('test-player');
            expect(res.body.mac_address).toBe('aa:bb:cc:dd:ee:ff');
            expect(res.body.connection_type).toBe('Ethernet');
            expect(res.body.ip_address).toBe('192.168.1.50');
            expect(res.body.account_name).toBe('Test Org');
            expect(res.body.device_name).toBe('Lobby Display');
        });

        it('handles unenrolled device gracefully', async () => {
            const fs = require('fs');
            fs.readFileSync.mockImplementation(() => {
                throw new Error('ENOENT');
            });

            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                if (cmd.includes('hostname') && !cmd.includes('-I')) return cb(null, 'fresh-player\n');
                if (cmd.includes('cat /sys/class/net')) return cb(null, '--\n');
                if (cmd.includes('ip route get')) return cb(null, '--\n');
                if (cmd.includes('iwgetid')) return cb(null, '\n');
                if (cmd.includes('hostname -I')) return cb(null, '--\n');
                cb(null, '--\n');
            });

            const res = await request(app).get('/api/device/info');
            expect(res.status).toBe(200);
            expect(res.body.account_name).toBe('');
            expect(res.body.device_name).toBe('');
        });
    });
});
