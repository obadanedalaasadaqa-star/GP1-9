require('dotenv').config();

const http = require('http');
const { createApp } = require('./app');
const { initRealtime } = require('./lib/realtime');
const { ensureSchema } = require('./lib/schema');
const { mailProvider } = require('./lib/mailer');
const { isSmsConfigured } = require('./lib/twilioVerify');
const { AI_MODEL, useFallbacks } = require('./lib/ai');
const { startWeeklyJob } = require('./lib/weeklyJob');

const PORT = process.env.PORT || 3001;

async function start() {
  await ensureSchema();
  const provider = mailProvider();
  console.log(`   Mail: ${
    provider === 'brevo' ? `Brevo API from ${process.env.MAIL_FROM}`
    : provider === 'gmail' ? `Gmail SMTP from ${process.env.GMAIL_USER}`
    : 'not configured — verification codes are printed here (dev mode)'}`);
  const serviceSid = process.env.TWILIO_VERIFY_SERVICE_SID ?? '';
  console.log(`   SMS: ${
    isSmsConfigured() ? `Twilio Verify (service VA…${serviceSid.slice(-4)})`
    : process.env.NODE_ENV === 'production'
      ? 'NOT CONFIGURED — phone verification answers 502 until TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN and TWILIO_VERIFY_SERVICE_SID are set'
      : 'not configured — phone codes are printed here (dev mode)'}`);
  console.log(`   AI: ${process.env.ANTHROPIC_API_KEY
    ? `${AI_MODEL()} (fallbacks ${useFallbacks() ? 'on' : 'off'})`
    : 'not configured — insight/chat answer 503, reports have no AI text'}`);

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
