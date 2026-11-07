const prisma = require('./prisma');

// Creates/updates the tables and columns the app needs. Safe to run on every
// boot (IF NOT EXISTS everywhere). Never use `prisma db push` for this database.
async function ensureSchema() {
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
}

module.exports = { ensureSchema };
