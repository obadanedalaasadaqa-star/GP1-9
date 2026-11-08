// Jest globalSetup: runs once before all test files. setupFiles do not run
// here, so the test env is loaded by hand. Creates any missing tables (same
// ensureSchema() as `npm start`), so a fresh test DB works without starting
// the server first.
module.exports = async () => {
  require('./env');
  const { ensureSchema } = require('../src/lib/schema');
  const prisma = require('../src/lib/prisma');
  await ensureSchema();
  await prisma.$disconnect(); // don't keep Jest open
};
