/**
 * tests/admin.test.js — Admin routes unit tests
 *
 * Tests admin login (PAM auth), session management, SSH toggle,
 * password change, terminal launch, service restart, and service status.
 */

const express = require('express');
const request = require('supertest');
const { exec } = require('child_process');
const crypto = require('crypto');

// Mock child_process.exec
jest.mock('child_process', () => ({
    exec: jest.fn()
}));

// Mock crypto.randomBytes for deterministic token generation
jest.spyOn(crypto, 'randomBytes');

// Fresh router on each test to reset session state
function createApp() {
    jest.isolateModules(() => { });
    // Clear module cache so adminSessions resets
    delete require.cache[require.resolve('../routes/admin')];
    const adminRoutes = require('../routes/admin');
    const app = express();
    app.use(express.json());
    app.use('/api/admin', adminRoutes);
    return app;
}

describe('Admin Routes', () => {
    let app;

    beforeEach(() => {
        jest.clearAllMocks();
        app = createApp();
    });

    // ─── Login ──────────────────────────────────────────────────────────────
    describe('POST /api/admin/login', () => {
        it('rejects missing credentials', async () => {
            const res = await request(app)
                .post('/api/admin/login')
                .send({});
            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/required/i);
        });

        it('rejects non-otter username', async () => {
            const res = await request(app)
                .post('/api/admin/login')
                .send({ username: 'root', password: 'password123' });
            expect(res.status).toBe(401);
            expect(res.body.error).toMatch(/invalid/i);
        });

        it('authenticates otter user via PAM check', async () => {
            const fakeToken = 'a'.repeat(64);
            crypto.randomBytes.mockReturnValue(Buffer.from(fakeToken, 'hex'));

            exec.mockImplementation((cmd, opts, cb) => {
                cb(null, 'OK\n');
            });

            const res = await request(app)
                .post('/api/admin/login')
                .send({ username: 'otter', password: 'correct-password' });

            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.token).toBeDefined();
        });

        it('rejects invalid PAM credentials', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                cb(null, 'FAIL\n');
            });

            const res = await request(app)
                .post('/api/admin/login')
                .send({ username: 'otter', password: 'wrong' });

            expect(res.status).toBe(401);
            expect(res.body.error).toMatch(/invalid/i);
        });
    });

    // ─── Session Middleware ──────────────────────────────────────────────────
    describe('Session middleware (requireAdmin)', () => {
        it('rejects requests without admin token', async () => {
            const res = await request(app)
                .post('/api/admin/terminal')
                .send({});
            expect(res.status).toBe(401);
        });

        it('rejects expired session token', async () => {
            const res = await request(app)
                .post('/api/admin/terminal')
                .set('x-admin-token', 'nonexistent-token')
                .send({});
            expect(res.status).toBe(401);
        });
    });

    // ─── Protected Routes (with valid session) ──────────────────────────────
    describe('Protected routes', () => {
        let token;

        beforeEach(async () => {
            // Login to get a valid session token
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') {
                    cb = opts;
                }
                cb(null, 'OK\n');
            });

            const loginRes = await request(app)
                .post('/api/admin/login')
                .send({ username: 'otter', password: 'test' });
            token = loginRes.body.token;
        });

        it('POST /terminal — launches terminal', async () => {
            exec.mockImplementation((cmd) => {
                // Fire-and-forget exec for terminal
            });

            const res = await request(app)
                .post('/api/admin/terminal')
                .set('x-admin-token', token)
                .send({});

            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/terminal/i);
        });

        it('POST /restart-services — restarts ODS services', async () => {
            const res = await request(app)
                .post('/api/admin/restart-services')
                .set('x-admin-token', token)
                .send({});

            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/restart/i);
        });

        it('POST /password — rejects short password', async () => {
            const res = await request(app)
                .post('/api/admin/password')
                .set('x-admin-token', token)
                .send({ newPassword: 'short' });

            expect(res.status).toBe(400);
            expect(res.body.error).toMatch(/8 characters/i);
        });

        it('POST /password — updates password', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/admin/password')
                .set('x-admin-token', token)
                .send({ newPassword: 'a-valid-long-password' });

            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
        });

        it('POST /ssh — enables SSH', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/admin/ssh')
                .set('x-admin-token', token)
                .send({ enabled: true });

            expect(res.status).toBe(200);
            expect(res.body.success).toBe(true);
            expect(res.body.message).toMatch(/enabled/i);
        });

        it('POST /ssh — disables SSH', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '');
            });

            const res = await request(app)
                .post('/api/admin/ssh')
                .set('x-admin-token', token)
                .send({ enabled: false });

            expect(res.status).toBe(200);
            expect(res.body.message).toMatch(/disabled/i);
        });

        it('GET /services — returns service status', async () => {
            exec.mockImplementation((cmd, opts, cb) => {
                if (typeof opts === 'function') { cb = opts; }
                cb(null, '● ods-kiosk.service - Active\n● ods-webserver.service - Active');
            });

            const res = await request(app)
                .get('/api/admin/services')
                .set('x-admin-token', token);

            expect(res.status).toBe(200);
            expect(res.body.status).toContain('ods-kiosk');
        });
    });
});
