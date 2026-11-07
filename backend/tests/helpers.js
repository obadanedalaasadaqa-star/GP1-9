const crypto = require('crypto');
const request = require('supertest');
const { createApp } = require('../src/app');
const prisma = require('../src/lib/prisma');

const PASSWORD = 'Nexus@2026';
const tracked = new Set();

// App without rate limits, so tests never trip each other's limits.
function makeApp() {
  return createApp({ rateLimit: false });
}

// test_<time><random>@nexus.test — matched by the cleanup SQL in the README.
function uniqueEmail() {
  return `test_${Date.now()}${crypto.randomInt(0, 1_000_000)}@nexus.test`;
}

// A random valid Jordanian number, 079xxxxxxx.
function uniquePhone() {
  return `079${String(crypto.randomInt(0, 10_000_000)).padStart(7, '0')}`;
}

// Remember a user id so cleanup() deletes it.
function track(id) {
  if (id) tracked.add(id);
}

// Register a fresh user through the API. Returns { token, user, password, email }.
async function registerUser(app = makeApp()) {
  const email = uniqueEmail();
  const res = await request(app).post('/api/auth/register').send({
    firstName: 'Test',
    lastName: 'User',
    phone: uniquePhone(),
    email,
    password: PASSWORD,
  });
  if (res.status !== 201) {
    throw new Error(`registerUser failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  track(res.body.user.id);
  return { token: res.body.token, user: res.body.user, password: PASSWORD, email };
}

// Delete only the users this test file created (receipts/codes cascade).
async function cleanup() {
  if (tracked.size > 0) {
    await prisma.user.deleteMany({ where: { id: { in: [...tracked] } } });
    tracked.clear();
  }
  await prisma.$disconnect();
}

module.exports = {
  PASSWORD, makeApp, uniqueEmail, uniquePhone, track, registerUser, cleanup,
};
