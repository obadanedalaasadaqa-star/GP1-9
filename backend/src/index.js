require('dotenv').config();

const http = require('http');
const { createApp } = require('./app');
const { initRealtime } = require('./lib/realtime');
const { ensureSchema } = require('./lib/schema');
const { mailProvider } = require('./lib/mailer');

const PORT = process.env.PORT || 3001;

async function start() {
  await ensureSchema();
  const provider = mailProvider();
  console.log(`   Mail: ${
    provider === 'brevo' ? `Brevo API from ${process.env.MAIL_FROM}`
    : provider === 'gmail' ? `Gmail SMTP from ${process.env.GMAIL_USER}`
    : 'not configured — verification codes are printed here (dev mode)'}`);

  // One HTTP server for the API and the Socket.IO live connection.
  const server = http.createServer(createApp());
  initRealtime(server);
  server.listen(PORT, () => {
    console.log(`\n🔷 Nexus Backend running on http://localhost:${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/api/health\n`);
  });
}

start().catch((err) => {
  console.error('Startup error:', err);
  process.exit(1);
});
