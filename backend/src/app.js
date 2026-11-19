const path = require('path');
const express = require('express');
const cors = require('cors');

const authRoutes     = require('./routes/auth');
const userRoutes     = require('./routes/user');
const receiptRoutes  = require('./routes/receipts');
const storeRoutes    = require('./routes/store');
const aiRoutes       = require('./routes/ai');
const budgetRoutes   = require('./routes/budgets');
const { makeLimiters } = require('./lib/rateLimit');
const { proxyCheckMiddleware } = require('./lib/proxyCheck');
const { getAiClient: realGetAiClient } = require('./lib/ai');

// "trust proxy" from TRUST_PROXY (default 1 = one proxy hop, e.g. Render).
// A number string becomes a number; anything else (e.g. "loopback") is passed as is.
// Read on every createApp() call so a value loaded by dotenv is never missed.
function trustProxySetting() {
  const raw = process.env.TRUST_PROXY;
  if (raw == null || raw.trim() === '') return 1;
  return /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : raw.trim();
}

/**
 * Build the Express app. Does not load .env, listen, or touch the DB schema,
 * so tests can create it with Supertest.
 * rateLimit: false = no limits, or per-limiter overrides (see lib/rateLimit.js).
 * aiClient: undefined = the real Claude client (null without ANTHROPIC_API_KEY);
 * tests pass a fake, or null for "not configured".
 * aiCaps: overrides of the daily AI caps (see routes/ai.js DEFAULT_AI_CAPS).
 * resetFloorMs: minimum time of a forgot/reset-password answer (default
 * 700 ms, lib/passwordReset.js); tests pass 0.
 * proxyCheck: true logs one "[proxy-check]" line for the first request
 * (index.js passes it; tests leave it off).
 * testRoutes: true mounts POST /api/receipts and /api/receipts/seed (tests
 * only; index.js never passes it, so production has neither route).
 */
function createApp({ rateLimit, aiClient, aiCaps, resetFloorMs, proxyCheck = false, testRoutes = false } = {}) {
  const app = express();
  const limiters = makeLimiters(rateLimit);
  const getAiClient = aiClient === undefined ? realGetAiClient : () => aiClient;

  const trust = trustProxySetting();
  app.set('trust proxy', trust);
  // One "[proxy-check]" line per process: the shape of the proxy chain (no
  // IP addresses), so TRUST_PROXY can be set from the Render logs.
  if (proxyCheck) app.use(proxyCheckMiddleware(trust));
  app.use(cors({ origin: '*' }));
  app.use(express.json());

  app.use('/api/auth', authRoutes(limiters, { resetFloorMs }));
  app.use('/api/user', userRoutes(limiters));
  if (testRoutes === true) app.use('/api/receipts', receiptRoutes());
  app.use('/api/store', storeRoutes(limiters));
  app.use('/api/ai', aiRoutes(limiters, { getAiClient, caps: aiCaps }));
  app.use('/api/budgets', budgetRoutes(limiters));

  app.get('/api/health', (_req, res) => {
    res.json({ status: 'ok', service: 'nexus-backend', version: '1.0.0' });
  });

  // Store Simulator (web page for cashiers) + the QR decoder it uses,
  // served from node_modules so the demo needs no CDN.
  app.get('/store/vendor/jsQR.js', (_req, res) => {
    res.sendFile(require.resolve('jsqr/dist/jsQR.js'));
  });
  app.use('/store', express.static(path.join(__dirname, '..', 'public', 'store')));

  // Global error handler
  app.use((err, _req, res, _next) => {
    // Broken JSON body (express.json): the client's fault, not a server error
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'Invalid JSON body.' });
    }
    // Other client errors Express raises itself, e.g. a URL path with broken
    // percent-encoding (/api/budgets/%E0).
    if (err.status === 400 || err instanceof URIError) {
      return res.status(400).json({ error: 'Invalid request.' });
    }
    // Other client errors from the body parser keep their own 4xx status:
    // 413 body too large, 415 unsupported charset or encoding.
    if (err.type && err.expose && err.status >= 400 && err.status < 500) {
      const error = err.status === 413 ? 'Request body is too large.'
        : err.status === 415 ? 'Unsupported request body.' : 'Invalid request.';
      return res.status(err.status).json({ error });
    }
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  });

  return app;
}

module.exports = { createApp };
