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

  // First/last name on users (safe to run every boot)
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "firstName" TEXT,
      ADD COLUMN IF NOT EXISTS "lastName"  TEXT;
  `);
  // Backfill older accounts: split the existing full name at the first space
  await prisma.$executeRawUnsafe(`
    UPDATE nexus_users
       SET "firstName" = split_part(trim(name), ' ', 1),
           "lastName"  = trim(substr(trim(name), length(split_part(trim(name), ' ', 1)) + 1))
     WHERE "firstName" IS NULL;
  `);
  console.log('   DB: nexus_users name columns ready');

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

  // Stores that send receipts (Store Simulator). apiKeyHash = SHA-256 of the
  // store key; the plain key is shown once by scripts/create-store.js.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_stores (
      id           TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::text,
      name         TEXT        NOT NULL,
      category     TEXT        NOT NULL,
      "apiKeyHash" TEXT        NOT NULL UNIQUE,
      "createdAt"  TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  // Which store sent a receipt (NULL for older/self-created receipts).
  // The FK is added by name only if missing, so it never stacks up on reboots.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_receipts ADD COLUMN IF NOT EXISTS "storeId" TEXT;
  `);
  await prisma.$executeRawUnsafe(`
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'nexus_receipts_storeId_fkey'
           AND conrelid = 'nexus_receipts'::regclass
      ) THEN
        ALTER TABLE nexus_receipts
          ADD CONSTRAINT "nexus_receipts_storeId_fkey"
          FOREIGN KEY ("storeId") REFERENCES nexus_stores(id) ON DELETE SET NULL;
      END IF;
    END $$;
  `);
  console.log('   DB: nexus_stores table ready');

  // Every stats/archive query filters receipts by user and date range.
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS nexus_receipts_user_created_idx
      ON nexus_receipts ("userId", "createdAt" DESC);
  `);
  console.log('   DB: nexus_receipts (userId, createdAt) index ready');

  // Full receipt lines from stores: [{ name, qty, unitPrice }]. NULL for older
  // receipts, which only have the "Milk x2" strings in items.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_receipts ADD COLUMN IF NOT EXISTS "lineItems" JSONB;
  `);
  console.log('   DB: nexus_receipts lineItems column ready');

  // AI insight cache: one row per user, overwritten. Used only while inputHash
  // equals the hash of today's numbers and the row is under 24 h old.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_ai_insights (
      "userId"       TEXT        PRIMARY KEY REFERENCES nexus_users(id) ON DELETE CASCADE,
      "inputHash"    TEXT        NOT NULL,
      summary        TEXT        NOT NULL,
      tip            TEXT        NOT NULL,
      model          TEXT        NOT NULL,
      "inputTokens"  INTEGER     NOT NULL DEFAULT 0,
      "outputTokens" INTEGER     NOT NULL DEFAULT 0,
      "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  console.log('   DB: nexus_ai_insights table ready');

  // Daily AI use per user and kind ('chat' | 'report' | 'report_email' | 'insight') on the
  // UTC day: the daily caps and the tokens paid.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_ai_usage (
      "userId"       TEXT    NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      day            DATE    NOT NULL,
      kind           TEXT    NOT NULL,
      count          INTEGER NOT NULL DEFAULT 0,
      "inputTokens"  INTEGER NOT NULL DEFAULT 0,
      "outputTokens" INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY ("userId", day, kind)
    );
  `);
  console.log('   DB: nexus_ai_usage table ready');

  // AI text of spending reports (numbers are never stored). rangeKey is
  // '<fromUtcIso>/<toUtcIso>'.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_ai_reports (
      "userId"       TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      "rangeKey"     TEXT        NOT NULL,
      "inputHash"    TEXT        NOT NULL,
      headline       TEXT        NOT NULL,
      narrative      TEXT        NOT NULL,
      tips           JSONB       NOT NULL DEFAULT '[]'::jsonb,
      model          TEXT        NOT NULL,
      "inputTokens"  INTEGER     NOT NULL DEFAULT 0,
      "outputTokens" INTEGER     NOT NULL DEFAULT 0,
      "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY ("userId", "rangeKey")
    );
  `);
  console.log('   DB: nexus_ai_reports table ready');

  // Budget alert and weekly summary settings. tzOffsetMinutes is the phone's
  // offset (minutes east of UTC), saved with a budget or a setting.
  // weeklySummarySentWeek is internal: the 'YYYY-MM-DD' Sunday of the last week
  // emailed (or skipped). Neither of the last two is ever returned by the API.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "budgetAlertEmails"     BOOLEAN NOT NULL DEFAULT true,
      ADD COLUMN IF NOT EXISTS "weeklySummaryEmails"   BOOLEAN NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS "tzOffsetMinutes"       INTEGER NOT NULL DEFAULT 180,
      ADD COLUMN IF NOT EXISTS "weeklySummarySentWeek" TEXT;
  `);
  console.log('   DB: nexus_users budget/alert columns ready');

  // One monthly budget per user per category (the same amount every month).
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_budgets (
      "userId"       TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      category       TEXT        NOT NULL,
      "monthlyLimit" FLOAT8      NOT NULL CHECK ("monthlyLimit" > 0),
      "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      "updatedAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY ("userId", category)
    );
  `);
  console.log('   DB: nexus_budgets table ready');

  // Budget alerts already sent. The primary key is the "fire once" rule: each
  // level fires at most once per category per month ('YYYY-MM', user's zone).
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_budget_alerts (
      "userId"       TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      category       TEXT        NOT NULL,
      month          TEXT        NOT NULL,
      level          SMALLINT    NOT NULL CHECK (level IN (80, 100)),
      spent          FLOAT8      NOT NULL,
      "monthlyLimit" FLOAT8      NOT NULL,
      "receiptId"    TEXT,
      emailed        BOOLEAN     NOT NULL DEFAULT false,
      "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY ("userId", category, month, level)
    );
  `);
  console.log('   DB: nexus_budget_alerts table ready');

  // Two-step sign-in (opt-in, off for everyone by default). Only turned on with
  // a verified email; an email change turns it off again.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "loginTwoFactor" BOOLEAN NOT NULL DEFAULT false;
  `);
  console.log('   DB: nexus_users loginTwoFactor column ready');

  // Session version: every session token carries it ("tv"), and a password
  // change, 2FA on, an email change or "sign out everywhere" adds 1, so every
  // older token stops working. Existing users start at 0, like tokens without it.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "tokenVersion" INTEGER NOT NULL DEFAULT 0;
  `);
  console.log('   DB: nexus_users tokenVersion column ready');

  // Accounts created by "Continue with Google" have no password the user knows
  // (the column holds the hash of random bytes): passwordSet is false until
  // they set one with Forgot password. Every existing row has a real password.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_users
      ADD COLUMN IF NOT EXISTS "passwordSet" BOOLEAN NOT NULL DEFAULT true;
  `);
  console.log('   DB: nexus_users passwordSet column ready');

  // Outside sign-in identities (Google now, Apple later): one row per user and
  // provider. subject is the provider's stable user id ("sub"); it and email
  // are personal data and are never returned or logged.
  await prisma.$executeRawUnsafe(`
    CREATE TABLE IF NOT EXISTS nexus_auth_identities (
      id           TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::text,
      "userId"     TEXT        NOT NULL REFERENCES nexus_users(id) ON DELETE CASCADE,
      provider     TEXT        NOT NULL CHECK (provider IN ('google', 'apple')),
      subject      TEXT        NOT NULL,
      email        TEXT,
      "createdAt"  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      "lastUsedAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT nexus_auth_identities_provider_subject_key UNIQUE (provider, subject),
      CONSTRAINT nexus_auth_identities_user_provider_key    UNIQUE ("userId", provider)
    );
  `);
  console.log('   DB: nexus_auth_identities table ready');

  // The address an email code was sent to, so it only verifies that address.
  // NULL for sign-in codes and for codes from before this column.
  await prisma.$executeRawUnsafe(`
    ALTER TABLE nexus_verification_codes ADD COLUMN IF NOT EXISTS email TEXT;
  `);
  console.log('   DB: nexus_verification_codes email column ready');

  // Case-insensitive email lookups (login, "already registered"). Not unique on
  // purpose: older rows may differ only in case.
  await prisma.$executeRawUnsafe(`
    CREATE INDEX IF NOT EXISTS nexus_users_email_lower_idx ON nexus_users (lower(email));
  `);
  console.log('   DB: nexus_users lower(email) index ready');
}

module.exports = { ensureSchema };
