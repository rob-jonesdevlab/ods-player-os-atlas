/**
 * ODS Atlas Player — Content Cache Manager
 * 
 * 3-tier cache system with atomic swap, checksum verification, and offline fallback.
 * Ported from the legacy ODS local signage cache architecture.
 * 
 * Directory structure:
 *   /home/signage/ODS/cache/
 *   ├── config/
 *   │   └── player_config.json        # Latest config from server
 *   ├── content/
 *   │   ├── good_cache/               # Verified downloaded content
 *   │   │   ├── {content_id}.ext      # Named by content UUID
 *   │   │   └── manifest.json         # Maps content_id → local path + checksum
 *   │   ├── downloading/              # In-progress downloads (atomic swap)
 *   │   └── stale/                    # Previous version (rollback safety)
 *   └── locks/
 *       └── cache_update.lock         # Prevents concurrent downloads
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');
const https = require('https');

// ============================================================
// CONFIGURATION
// ============================================================

const CACHE_ROOT = process.env.ODS_CACHE_DIR || '/home/signage/ODS/cache';
const CONFIG_DIR = path.join(CACHE_ROOT, 'config');
const CONTENT_DIR = path.join(CACHE_ROOT, 'content');
const GOOD_CACHE_DIR = path.join(CONTENT_DIR, 'good_cache');
const DOWNLOADING_DIR = path.join(CONTENT_DIR, 'downloading');
const STALE_DIR = path.join(CONTENT_DIR, 'stale');
const LOCK_DIR = path.join(CACHE_ROOT, 'locks');

const CONFIG_FILE = path.join(CONFIG_DIR, 'player_config.json');
const MANIFEST_FILE = path.join(GOOD_CACHE_DIR, 'manifest.json');
const LOCK_FILE = path.join(LOCK_DIR, 'cache_update.lock');

// Server config — loaded from enrollment
const ENROLLMENT_FILE = '/var/lib/ods/enrollment.flag';

// ============================================================
// INITIALIZATION
// ============================================================

/**
 * Ensure all cache directories exist
 */
function initCacheDirs() {
    [CONFIG_DIR, GOOD_CACHE_DIR, DOWNLOADING_DIR, STALE_DIR, LOCK_DIR].forEach(dir => {
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
            console.log(`[Cache] Created directory: ${dir}`);
        }
    });
}

/**
 * Get server URL and player info from enrollment
 */
function getEnrollmentInfo() {
    if (!fs.existsSync(ENROLLMENT_FILE)) {
        throw new Error('Player not enrolled — run enrollment first');
    }
    return JSON.parse(fs.readFileSync(ENROLLMENT_FILE, 'utf8'));
}

// ============================================================
// FILE LOCKING (prevents concurrent cache updates)
// ============================================================

/**
 * Acquire a file lock — prevents concurrent downloads
 * @returns {boolean} true if lock acquired, false if already locked
 */
function acquireLock() {
    if (fs.existsSync(LOCK_FILE)) {
        // Check if lock is stale (older than 10 minutes)
        const stat = fs.statSync(LOCK_FILE);
        const ageMs = Date.now() - stat.mtimeMs;
        if (ageMs < 10 * 60 * 1000) {
            console.log('[Cache] Lock held by another process, skipping update');
            return false;
        }
        console.log('[Cache] Stale lock detected, overriding');
    }

    fs.writeFileSync(LOCK_FILE, JSON.stringify({
        pid: process.pid,
        timestamp: new Date().toISOString()
    }));
    return true;
}

/**
 * Release the file lock
 */
function releaseLock() {
    if (fs.existsSync(LOCK_FILE)) {
        fs.unlinkSync(LOCK_FILE);
    }
}

// ============================================================
// MANIFEST (tracks what's in good_cache)
// ============================================================

/**
 * Load the manifest — maps content_id → { localPath, checksum, downloadedAt }
 */
function loadManifest() {
    if (!fs.existsSync(MANIFEST_FILE)) return {};
    try {
        return JSON.parse(fs.readFileSync(MANIFEST_FILE, 'utf8'));
    } catch {
        return {};
    }
}

/**
 * Save the manifest
 */
function saveManifest(manifest) {
    fs.writeFileSync(MANIFEST_FILE, JSON.stringify(manifest, null, 2));
}

// ============================================================
// CHECKSUM VERIFICATION
// ============================================================

/**
 * Calculate SHA256 checksum of a file
 * @param {string} filePath - Path to file
 * @returns {string} sha256:hexdigest
 */
function calculateChecksum(filePath) {
    const hash = crypto.createHash('sha256');
    const data = fs.readFileSync(filePath);
    hash.update(data);
    return `sha256:${hash.digest('hex')}`;
}

/**
 * Verify a file's checksum matches expected value
 * @param {string} filePath - Path to file
 * @param {string} expected - Expected checksum (sha256:hexdigest)
 * @returns {boolean} true if checksum matches
 */
function verifyChecksum(filePath, expected) {
    if (!expected) return true; // No checksum = skip verification
    const actual = calculateChecksum(filePath);
    const match = actual === expected;
    if (!match) {
        console.error(`[Cache] Checksum mismatch for ${filePath}: expected ${expected}, got ${actual}`);
    }
    return match;
}

// ============================================================
// HTTP HELPERS
// ============================================================

/**
 * Make an HTTP/HTTPS GET request and return JSON
 */
function fetchJSON(url, token) {
    return new Promise((resolve, reject) => {
        const client = url.startsWith('https') ? https : http;
        const req = client.get(url, {
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json'
            }
        }, (res) => {
            if (res.statusCode !== 200) {
                return reject(new Error(`HTTP ${res.statusCode} from ${url}`));
            }
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch (e) { reject(new Error(`Invalid JSON from ${url}`)); }
            });
        });
        req.on('error', reject);
        req.setTimeout(30000, () => { req.destroy(); reject(new Error('Request timeout')); });
    });
}

/**
 * Download a file from URL and save to disk
 * @param {string} url - File URL
 * @param {string} destPath - Local save path
 * @param {string} token - Auth token
 * @returns {Promise<string>} Path to downloaded file
 */
function downloadFile(url, destPath, token) {
    return new Promise((resolve, reject) => {
        const client = url.startsWith('https') ? https : http;
        const req = client.get(url, {
            headers: { 'Authorization': `Bearer ${token}` }
        }, (res) => {
            if (res.statusCode !== 200) {
                return reject(new Error(`HTTP ${res.statusCode} downloading ${url}`));
            }
            const file = fs.createWriteStream(destPath);
            res.pipe(file);
            file.on('finish', () => { file.close(); resolve(destPath); });
            file.on('error', (err) => { fs.unlinkSync(destPath); reject(err); });
        });
        req.on('error', reject);
        req.setTimeout(300000, () => { req.destroy(); reject(new Error('Download timeout')); });
    });
}

// ============================================================
// CORE SYNC LOGIC
// ============================================================

/**
 * Check if config has changed (lightweight hash check)
 * @param {string} serverUrl - ODS Cloud API URL
 * @param {string} playerId - Player UUID
 * @param {string} token - Auth token
 * @returns {{ changed: boolean, serverHash: string }}
 */
async function checkConfigHash(serverUrl, playerId, token) {
    // Load cached config hash
    let cachedHash = null;
    if (fs.existsSync(CONFIG_FILE)) {
        try {
            const cached = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
            cachedHash = cached.config_hash;
        } catch { /* corrupt config, will re-fetch */ }
    }

    // Fetch server hash
    const { config_hash: serverHash } = await fetchJSON(
        `${serverUrl}/api/players/${playerId}/config/hash`, token
    );

    return {
        changed: cachedHash !== serverHash,
        serverHash
    };
}

/**
 * Fetch full config from server
 * @param {string} serverUrl - ODS Cloud API URL
 * @param {string} playerId - Player UUID
 * @param {string} token - Auth token
 * @returns {object} Player config JSON
 */
async function fetchConfig(serverUrl, playerId, token) {
    const config = await fetchJSON(
        `${serverUrl}/api/players/${playerId}/config`, token
    );

    // Save to disk
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
    console.log(`[Cache] Config saved: ${config.config_hash}`);

    return config;
}

/**
 * Diff asset list — determine what needs downloading
 * @param {Array} serverAssets - Assets from server config
 * @param {object} manifest - Current cache manifest
 * @returns {{ toDownload: Array, toRemove: Array }}
 */
function diffAssets(serverAssets, manifest) {
    const serverIds = new Set(serverAssets.map(a => a.id));
    const cachedIds = new Set(Object.keys(manifest));

    // New or changed assets
    const toDownload = serverAssets.filter(asset => {
        const cached = manifest[asset.id];
        if (!cached) return true; // New asset
        if (asset.checksum && cached.checksum !== asset.checksum) return true; // Changed
        return false;
    });

    // Assets no longer in playlist
    const toRemove = [...cachedIds].filter(id => !serverIds.has(id));

    return { toDownload, toRemove };
}

/**
 * Download a single asset with atomic swap
 * Download to downloading/ → verify checksum → move to good_cache/
 * @param {object} asset - Asset metadata from config
 * @param {string} serverUrl - ODS Cloud API URL
 * @param {string} token - Auth token
 * @returns {{ success: boolean, error?: string }}
 */
async function downloadAsset(asset, serverUrl, token) {
    const ext = path.extname(asset.filename) || '';
    const tempPath = path.join(DOWNLOADING_DIR, `${asset.id}${ext}`);
    const finalPath = path.join(GOOD_CACHE_DIR, `${asset.id}${ext}`);

    try {
        // Download to temp location
        const downloadUrl = asset.url.startsWith('http')
            ? asset.url
            : `${serverUrl}${asset.url}`;

        console.log(`[Cache] Downloading: ${asset.filename} (${asset.id})`);
        await downloadFile(downloadUrl, tempPath, token);

        // Verify checksum
        if (asset.checksum && !verifyChecksum(tempPath, asset.checksum)) {
            fs.unlinkSync(tempPath);
            return { success: false, error: `Checksum mismatch for ${asset.filename}` };
        }

        // Atomic swap: move stale version, move new to good_cache
        if (fs.existsSync(finalPath)) {
            const stalePath = path.join(STALE_DIR, `${asset.id}${ext}`);
            fs.renameSync(finalPath, stalePath);
        }
        fs.renameSync(tempPath, finalPath);

        console.log(`[Cache] ✅ Cached: ${asset.filename} → ${finalPath}`);
        return { success: true };

    } catch (error) {
        // Cleanup temp file on failure
        if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
        console.error(`[Cache] ❌ Failed: ${asset.filename}: ${error.message}`);
        return { success: false, error: error.message };
    }
}

/**
 * Full content sync — the main cache update cycle
 * 
 * Flow:
 * 1. Check config hash (lightweight)
 * 2. If changed → fetch full config
 * 3. Diff assets vs manifest
 * 4. Download new/changed assets to downloading/
 * 5. Verify checksums
 * 6. Atomic swap to good_cache/
 * 7. Update manifest
 * 
 * @param {string} serverUrl - ODS Cloud API URL
 * @param {string} playerId - Player UUID
 * @param {string} token - Auth token
 * @returns {{ success: boolean, downloaded: number, failed: number, removed: number }}
 */
async function syncContent(serverUrl, playerId, token) {
    // Step 0: Acquire lock
    if (!acquireLock()) {
        return { success: false, downloaded: 0, failed: 0, removed: 0, reason: 'locked' };
    }

    try {
        initCacheDirs();

        // Step 1: Check if config changed
        const { changed } = await checkConfigHash(serverUrl, playerId, token);
        if (!changed) {
            console.log('[Cache] Config unchanged, skipping sync');
            return { success: true, downloaded: 0, failed: 0, removed: 0, reason: 'unchanged' };
        }

        // Step 2: Fetch full config
        const config = await fetchConfig(serverUrl, playerId, token);

        if (!config.playlist || !config.playlist.assets || config.playlist.assets.length === 0) {
            console.log('[Cache] No playlist assets, nothing to sync');
            return { success: true, downloaded: 0, failed: 0, removed: 0, reason: 'no_assets' };
        }

        // Step 3: Diff assets
        const manifest = loadManifest();
        const { toDownload, toRemove } = diffAssets(config.playlist.assets, manifest);

        console.log(`[Cache] Sync plan: ${toDownload.length} to download, ${toRemove.length} to remove`);

        // Step 4 + 5 + 6: Download with atomic swap
        let downloaded = 0;
        let failed = 0;

        for (const asset of toDownload) {
            const result = await downloadAsset(asset, serverUrl, token);
            if (result.success) {
                const ext = path.extname(asset.filename) || '';
                manifest[asset.id] = {
                    localPath: path.join(GOOD_CACHE_DIR, `${asset.id}${ext}`),
                    checksum: asset.checksum || calculateChecksum(path.join(GOOD_CACHE_DIR, `${asset.id}${ext}`)),
                    filename: asset.filename,
                    type: asset.type,
                    downloadedAt: new Date().toISOString()
                };
                downloaded++;
            } else {
                failed++;
            }
        }

        // Step 7: Remove stale assets
        let removed = 0;
        for (const id of toRemove) {
            const entry = manifest[id];
            if (entry && fs.existsSync(entry.localPath)) {
                const stalePath = path.join(STALE_DIR, path.basename(entry.localPath));
                fs.renameSync(entry.localPath, stalePath);
                removed++;
            }
            delete manifest[id];
        }

        // Update manifest
        saveManifest(manifest);

        console.log(`[Cache] Sync complete: ${downloaded} downloaded, ${failed} failed, ${removed} removed`);
        return { success: failed === 0, downloaded, failed, removed };

    } finally {
        releaseLock();
    }
}

// ============================================================
// OFFLINE FALLBACK
// ============================================================

/**
 * Get cached config (for offline operation)
 * @returns {object|null} Cached config or null
 */
function getCachedConfig() {
    if (!fs.existsSync(CONFIG_FILE)) return null;
    try {
        return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    } catch {
        return null;
    }
}

/**
 * Get local path for a cached asset
 * @param {string} contentId - Content UUID
 * @returns {string|null} Local file path or null if not cached
 */
function getCachedAssetPath(contentId) {
    const manifest = loadManifest();
    const entry = manifest[contentId];
    if (!entry) return null;
    if (!fs.existsSync(entry.localPath)) return null;
    return entry.localPath;
}

/**
 * Check if we can operate offline (have cached config and content)
 * @returns {{ canOperate: boolean, config: object|null, assetCount: number }}
 */
function checkOfflineCapability() {
    const config = getCachedConfig();
    const manifest = loadManifest();
    const assetCount = Object.keys(manifest).length;

    return {
        canOperate: config !== null && assetCount > 0,
        config,
        assetCount
    };
}

// ============================================================
// CLEANUP
// ============================================================

/**
 * Clean up stale cache (remove old versions to free disk space)
 * @param {number} maxAgeDays - Maximum age of stale files in days
 */
function cleanStaleCache(maxAgeDays = 7) {
    if (!fs.existsSync(STALE_DIR)) return;

    const maxAgeMs = maxAgeDays * 24 * 60 * 60 * 1000;
    const files = fs.readdirSync(STALE_DIR);
    let cleaned = 0;

    for (const file of files) {
        const filePath = path.join(STALE_DIR, file);
        const stat = fs.statSync(filePath);
        if (Date.now() - stat.mtimeMs > maxAgeMs) {
            fs.unlinkSync(filePath);
            cleaned++;
        }
    }

    if (cleaned > 0) {
        console.log(`[Cache] Cleaned ${cleaned} stale files`);
    }
}

// ============================================================
// EXPORTS
// ============================================================

module.exports = {
    // Core sync
    syncContent,
    checkConfigHash,
    fetchConfig,
    downloadAsset,

    // Offline
    getCachedConfig,
    getCachedAssetPath,
    checkOfflineCapability,

    // Utilities
    initCacheDirs,
    loadManifest,
    saveManifest,
    calculateChecksum,
    verifyChecksum,
    cleanStaleCache,
    acquireLock,
    releaseLock,

    // Paths (for testing)
    CACHE_ROOT,
    CONFIG_DIR,
    GOOD_CACHE_DIR,
    DOWNLOADING_DIR,
    STALE_DIR
};
