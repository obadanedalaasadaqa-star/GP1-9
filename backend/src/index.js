const express = require('express');
const cors = require('cors');
require('dotenv').config();

const authRoutes     = require('./routes/auth');
const userRoutes     = require('./routes/user');
const receiptRoutes  = require('./routes/receipts');
const prisma         = require('./lib/prisma');
const { isMailConfigured } = require('./lib/mailer');

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

  // First/last name + phone on users (safe to run every boot)
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "firstName" TEXT,
      ADD COLUMN IF NOT EXISTS "lastName"  TEXT,
      ADD COLUMN IF NOT EXISTS phone       TEXT;
  `);
  await prisma.$executeRawUnsafe(`
    CREATE UNIQUE INDEX IF NOT EXISTS nexus_users_phone_key ON nexus_users(phone);
  `);
  // Backfill older accounts: split the existing full name at the first space
  await prisma.$executeRawUnsafe(`
    UPDATE nexus_users
       SET "firstName" = split_part(trim(name), ' ', 1),
           "lastName"  = trim(substr(trim(name), length(split_part(trim(name), ' ', 1)) + 1))
     WHERE "firstName" IS NULL;
  `);
  console.log('   DB: nexus_users name/phone columns ready');

  // Email verification (safe to run every boot)
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "emailVerified" BOOLEAN NOT NULL DEFAULT false;
  `);
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_verification_codes (
      id           TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::text,
      "userId"     TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      type         TEXT        NOT NULL,
      "codeHash"   TEXT        NOT NULL,
      "expiresAt"  TIMESTAMPTZ NOT NULL,
      attempts     INTEGER     NOT NULL DEFAULT 0,
      "lastSentAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE ("userId", type)
    );
  `);
  console.log('   DB: email verification ready');
  console.log(`   Mail: ${isMailConfigured()
    ? `sending from ${process.env.GMAIL_USER}`
    : 'not configured — verification codes are printed here (dev mode)'}`);

  app.listen(PORT, () => {
    console.log(`\n🔷 Nexus Backend running on http://localhost:${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/api/health\n`);
  });
}

start().catch((err) => {
  console.error('Startup error:', err);
  process.exit(1);
});
