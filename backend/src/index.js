require('dotenv').config();

const { createApp } = require('./app');
const { ensureSchema } = require('./lib/schema');
const { isMailConfigured } = require('./lib/mailer');

const PORT = process.env.PORT || 3001;

async function start() {
  await ensureSchema();
  console.log(`   Mail: ${isMailConfigured()
    ? `sending from ${process.env.GMAIL_USER}`
    : 'not configured — verification codes are printed here (dev mode)'}`);

  createApp().listen(PORT, () => {
    console.log(`\n🔷 Nexus Backend running on http://localhost:${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/api/health\n`);
  });
}

start().catch((err) => {
  console.error('Startup error:', err);
  process.exit(1);
});
