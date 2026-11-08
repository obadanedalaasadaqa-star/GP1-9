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

// Tests must never send real email: without these, any code that reaches the
// real mailer only prints a [mail:dev] line.
delete process.env.GMAIL_USER;
delete process.env.GMAIL_APP_PASSWORD;
delete process.env.BREVO_API_KEY;
delete process.env.MAIL_FROM;
