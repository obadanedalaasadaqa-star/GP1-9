const path = require('path');
const express = require('express');
const cors = require('cors');

const authRoutes     = require('./routes/auth');
const userRoutes     = require('./routes/user');
const receiptRoutes  = require('./routes/receipts');
const storeRoutes    = require('./routes/store');
const { makeLimiters } = require('./lib/rateLimit');

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
 */
function createApp({ rateLimit } = {}) {
  const app = express();
  const limiters = makeLimiters(rateLimit);

  app.set('trust proxy', trustProxySetting());
  app.use(cors({ origin: '*' }));
  app.use(express.json());

  app.use('/api/auth', authRoutes(limiters));
  app.use('/api/user', userRoutes(limiters));
  app.use('/api/receipts', receiptRoutes);
  app.use('/api/store', storeRoutes(limiters));

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
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  });

  return app;
}

module.exports = { createApp };
