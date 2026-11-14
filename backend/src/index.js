require('dotenv').config();

const http = require('http');
const { createApp } = require('./app');
const { initRealtime } = require('./lib/realtime');
const { ensureSchema } = require('./lib/schema');
const { mailProvider } = require('./lib/mailer');
const { isLoginTwoFactorAllowed } = require('./lib/loginTwoFactor');
const { AI_MODEL, useFallbacks } = require('./lib/ai');
const { startWeeklyJob } = require('./lib/weeklyJob');

const PORT = process.env.PORT || 3001;

async function start() {
  // Warning only: the server still starts.
  if (process.env.NODE_ENV === 'production' && (process.env.JWT_SECRET || '').length < 32) {
    console.log('   WARNING: JWT_SECRET is short; use 32+ random characters');
  }
  await ensureSchema();
  const provider = mailProvider();
  console.log(`   Mail: ${
    provider === 'brevo' ? `Brevo API from ${process.env.MAIL_FROM}`
    : provider === 'gmail' ? `Gmail SMTP from ${process.env.GMAIL_USER}`
    : 'not configured — verification codes are printed here (dev mode)'}`);
  console.log(`   AI: ${process.env.ANTHROPIC_API_KEY
    ? `${AI_MODEL()} (fallbacks ${useFallbacks() ? 'on' : 'off'})`
    : 'not configured — insight/chat answer 503, reports have no AI text'}`);
  console.log(`   Login 2FA: ${
    !isLoginTwoFactorAllowed() ? 'OFF for everyone (LOGIN_2FA=off)'
    : !provider && process.env.NODE_ENV === 'production'
      ? 'available, but MAIL NOT CONFIGURED — sign-in codes are only in this log'
      : 'available (opt-in per user, email codes)'}`);

  // One HTTP server for the API and the Socket.IO live connection.
  const server = http.createServer(createApp());
  initRealtime(server);
  server.listen(PORT, () => {
    console.log(`\n🔷 Nexus Backend running on http://localhost:${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/api/health\n`);
  });

  // Weekly summary emails (never started by tests, which only use createApp).
  console.log(startWeeklyJob()
    ? '   Weekly summary: on (Sunday 09:00 local, checked every 15 min)'
    : '   Weekly summary: off');
}

start().catch((err) => {
  console.error('Startup error:', err);
  process.exit(1);
});
