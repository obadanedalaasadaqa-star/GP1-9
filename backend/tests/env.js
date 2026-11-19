// Jest setupFiles: runs before every test file.
// Loads backend/.env.test if it exists (another DB that already has the Nexus
// tables), otherwise backend/.env.
const fs = require('fs');
const path = require('path');

const testEnv = path.join(__dirname, '..', '.env.test');
const devEnv  = path.join(__dirname, '..', '.env');
require('dotenv').config({ path: fs.existsSync(testEnv) ? testEnv : devEnv });

if (!process.env.JWT_SECRET || !process.env.DATABASE_URL) {
  throw new Error('tests need JWT_SECRET and DATABASE_URL in backend/.env');
}

// These are set to '' instead of deleted: loading the Prisma client reads
// backend/.env again and fills in every variable that is missing (it never
// overwrites one that exists, even empty). A deleted GMAIL_USER or
// ANTHROPIC_API_KEY would come back as soon as a test file loads Prisma.

// Tests must never send real email: without these, any code that reaches the
// real mailer only prints a [mail:dev] line.
process.env.GMAIL_USER = '';
process.env.GMAIL_APP_PASSWORD = '';
process.env.BREVO_API_KEY = '';
process.env.MAIL_FROM = '';

// Two-step sign-in: tests start with the per-user setting in charge, not a
// developer's kill switch in .env ('' counts as not "off").
process.env.LOGIN_2FA = '';

// Tests must never reach the real Claude API, and must not depend on a
// developer's model choice in .env ('' means not set).
process.env.ANTHROPIC_API_KEY = '';
process.env.AI_MODEL = '';
process.env.AI_FALLBACKS = '';

// Google sign-in: a fake client ID (never a real one, and too short to look
// like one), so tests never depend on a developer's .env.
process.env.GOOGLE_CLIENT_IDS = 'test-client.apps.googleusercontent.com';
