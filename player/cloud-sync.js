/**
 * ODS Atlas Player — Cloud Sync Client
 * 
 * Persistent socket.io-client connection to ODS Cloud server.
 * Handles registration, heartbeat, deploy push events, and periodic config sync.
 * 
 * Dependencies: socket.io-client, ./cache-manager.js
 * Reads: /var/lib/ods/enrollment.flag (device_uuid, server URL)
 */

const { io: SocketIO } = require('socket.io-client');
const fs = require('fs');
const path = require('path');
const cache = require('./cache-manager');

// ============================================================
// CONFIGURATION
// ============================================================

const ENROLLMENT_FILE = '/var/lib/ods/enrollment.flag';
const CONFIG_FILE = path.join(cache.CONFIG_DIR, 'player_config.json');
const SYNC_STATE_FILE = '/var/lib/ods/sync_state.json';

const HEARTBEAT_INTERVAL = 60 * 1000;         // 60 seconds
const CONFIG_POLL_INTERVAL = 5 * 60 * 1000;   // 5 minutes
const RECONNECT_DELAY_INITIAL = 1000;          // 1 second
const RECONNECT_DELAY_MAX = 30000;             // 30 seconds

// ============================================================
// STATE
// ============================================================

let socket = null;
let playerId = null;
let syncInProgress = false;
let lastSyncTime = null;
let isOnline = false;
let heartbeatTimer = null;
let configPollTimer = null;
let onContentReady = null;  // Callback for renderer notification

// ============================================================
// ENROLLMENT DATA
// ============================================================

/**
 * Read enrollment info from disk
 * @returns {{ device_uuid: string, pairing_code: string, timestamp: string }|null}
 */
function getEnrollmentInfo() {
    if (!fs.existsSync(ENROLLMENT_FILE)) {
        console.log('[CloudSync] No enrollment file — player not enrolled');
        return null;
    }
    try {
        return JSON.parse(fs.readFileSync(ENROLLMENT_FILE, 'utf8'));
    } catch {
        console.error('[CloudSync] Failed to read enrollment file');
        return null;
    }
}

/**
 * Get CPU serial from /proc/cpuinfo
 */
function getCpuSerial() {
    try {
        const cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8');
        const match = cpuinfo.match(/Serial\s+:\s+(\w+)/);
        return match ? match[1] : 'UNKNOWN';
    } catch {
        return 'UNKNOWN';
    }
}

// ============================================================
// SYNC STATE PERSISTENCE
// ============================================================

function saveSyncState() {
    const state = {
        lastSyncTime,
        isOnline,
        playerId,
        updatedAt: new Date().toISOString()
    };
    try {
        const dir = path.dirname(SYNC_STATE_FILE);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(SYNC_STATE_FILE, JSON.stringify(state, null, 2));
    } catch (err) {
        console.error('[CloudSync] Failed to save sync state:', err.message);
    }
}

function loadSyncState() {
    try {
        if (fs.existsSync(SYNC_STATE_FILE)) {
            const state = JSON.parse(fs.readFileSync(SYNC_STATE_FILE, 'utf8'));
            lastSyncTime = state.lastSyncTime || null;
            playerId = state.playerId || null;
        }
    } catch { /* ignore */ }
}

// ============================================================
// CONTENT SYNC
// ============================================================

/**
 * Perform a content sync cycle
 * Uses cache-manager.syncContent() for the heavy lifting
 */
async function doSync() {
    if (syncInProgress) {
        console.log('[CloudSync] Sync already in progress, skipping');
        return;
    }

    const enrollment = getEnrollmentInfo();
    if (!enrollment) return;

    const serverUrl = process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';

    // Use system token for device API calls (no user JWT on device)
    const token = process.env.ODS_DEVICE_TOKEN || 'system';

    syncInProgress = true;
    console.log('[CloudSync] Starting content sync...');

    try {
        const result = await cache.syncContent(serverUrl, playerId, token);
        lastSyncTime = new Date().toISOString();
        saveSyncState();

        console.log(`[CloudSync] Sync complete:`, result);

        // Report status to server
        if (socket && socket.connected) {
            socket.emit('sync_status', {
                status: result.success ? 'complete' : 'partial',
                downloaded: result.downloaded,
                failed: result.failed,
                removed: result.removed,
                timestamp: lastSyncTime
            });
        }

        // Notify renderer if content changed
        if (result.downloaded > 0 || result.removed > 0) {
            if (onContentReady) onContentReady();
        }

    } catch (error) {
        console.error('[CloudSync] Sync failed:', error.message);
        if (socket && socket.connected) {
            socket.emit('sync_status', {
                status: 'error',
                error: error.message,
                timestamp: new Date().toISOString()
            });
        }
    } finally {
        syncInProgress = false;
    }
}

// ============================================================
// WEBSOCKET CONNECTION
// ============================================================

/**
 * Start the cloud sync client
 * @param {{ onContentReady?: Function }} options
 */
function start(options = {}) {
    onContentReady = options.onContentReady || null;

    loadSyncState();
    cache.initCacheDirs();

    const enrollment = getEnrollmentInfo();
    if (!enrollment) {
        console.log('[CloudSync] Skipping — player not enrolled. Will retry on next boot.');
        return;
    }

    const serverUrl = process.env.ODS_SERVER_URL || 'https://api.ods-cloud.com';
    const cpuSerial = getCpuSerial();

    console.log(`[CloudSync] Connecting to ${serverUrl}...`);

    socket = SocketIO(serverUrl, {
        reconnection: true,
        reconnectionDelay: RECONNECT_DELAY_INITIAL,
        reconnectionDelayMax: RECONNECT_DELAY_MAX,
        reconnectionAttempts: Infinity,
        transports: ['websocket', 'polling']
    });

    // --- Connection Events ---

    socket.on('connect', () => {
        console.log('[CloudSync] ✅ Connected to ODS Cloud');
        isOnline = true;

        // Register this player
        socket.emit('register', {
            cpu_serial: cpuSerial,
            device_uuid: enrollment.device_uuid,
            name: `Atlas-${cpuSerial.slice(-6)}`
        });
    });

    socket.on('registered', (player) => {
        playerId = player.id;
        console.log(`[CloudSync] Registered as player: ${player.name} (${player.id})`);
        saveSyncState();

        // Initial sync after registration
        doSync();
    });

    socket.on('disconnect', (reason) => {
        console.log(`[CloudSync] Disconnected: ${reason}`);
        isOnline = false;
        saveSyncState();
    });

    socket.on('connect_error', (error) => {
        console.log(`[CloudSync] Connection error: ${error.message}`);
        isOnline = false;
    });

    // --- Deploy Push ---

    socket.on('deploy_playlist', (data) => {
        console.log(`[CloudSync] 📡 Deploy push received:`, data);
        // Trigger immediate sync
        doSync();
    });

    // --- Heartbeat ---

    heartbeatTimer = setInterval(() => {
        if (socket && socket.connected) {
            socket.emit('heartbeat', {
                timestamp: new Date().toISOString()
            });
        }
    }, HEARTBEAT_INTERVAL);

    // --- Config Polling (fallback) ---

    configPollTimer = setInterval(() => {
        if (isOnline && playerId) {
            doSync();
        }
    }, CONFIG_POLL_INTERVAL);

    // Initial sync attempt (covers case where already enrolled but never synced)
    if (playerId) {
        setTimeout(() => doSync(), 5000);
    }
}

/**
 * Stop the cloud sync client
 */
function stop() {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    if (configPollTimer) clearInterval(configPollTimer);
    if (socket) {
        socket.disconnect();
        socket = null;
    }
    console.log('[CloudSync] Stopped');
}

// ============================================================
// STATUS API (for server.js endpoints)
// ============================================================

/**
 * Get current sync status
 */
function getStatus() {
    const offline = cache.checkOfflineCapability();
    return {
        isOnline,
        isConnected: socket ? socket.connected : false,
        playerId,
        lastSyncTime,
        syncInProgress,
        cachedAssets: offline.assetCount,
        canPlayOffline: offline.canOperate
    };
}

/**
 * Get current playlist content for the renderer
 * Returns cached config's playlist with local file paths
 */
function getContentForRenderer() {
    const config = cache.getCachedConfig();
    if (!config || !config.playlist || !config.playlist.assets) {
        return null;
    }

    // Map each asset to its local cached path
    const assets = config.playlist.assets.map(asset => {
        const localPath = cache.getCachedAssetPath(asset.id);
        return {
            id: asset.id,
            type: asset.type,
            filename: asset.filename,
            localPath: localPath,
            duration: asset.duration || 10,
            order: asset.order,
            available: localPath !== null
        };
    });

    return {
        playlist_id: config.playlist.id,
        playlist_name: config.playlist.name,
        total_duration: config.playlist.total_duration,
        assets: assets.filter(a => a.available),
        config_hash: config.config_hash
    };
}

// ============================================================
// EXPORTS
// ============================================================

module.exports = {
    start,
    stop,
    doSync,
    getStatus,
    getContentForRenderer
};
