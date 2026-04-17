const express = require('express');
const cors = require('cors');
require('dotenv').config();

const authRoutes     = require('./routes/auth');
const userRoutes     = require('./routes/user');
const receiptRoutes  = require('./routes/receipts');
const prisma         = require('./lib/prisma');

const app = express();

app.use(cors({ origin: '*' }));
app.use(express.json());

app.use('/api/auth', authRoutes);
app.use('/api/user', userRoutes);
app.use('/api/receipts', receiptRoutes);

app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', service: 'nexus-backend', version: '1.0.0' });
});

// Global error handler
app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: 'Internal server error' });
});

const PORT = process.env.PORT || 3001;

async function start() {
  // Ensure nexus_receipts table exists (safe to run every boot)
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_receipts (
      id             TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::text,
      "userId"       TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      "storeName"    TEXT        NOT NULL,
      category       TEXT        NOT NULL,
      "totalAmount"  FLOAT8      NOT NULL,
      items          JSONB       NOT NULL DEFAULT '[]',
      "pointsEarned" INTEGER     NOT NULL DEFAULT 0,
      "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  console.log('   DB: nexus_receipts table ready');

  app.listen(PORT, () => {
    console.log(`\n🔷 Nexus Backend running on http://localhost:${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/api/health\n`);
  });
}

start().catch((err) => {
  console.error('Startup error:', err);
  process.exit(1);
});
