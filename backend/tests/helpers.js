const crypto = require('crypto');
const request = require('supertest');
const { createApp } = require('../src/app');
const prisma = require('../src/lib/prisma');
const { generateStoreKey, hashStoreKey } = require('../src/lib/storeKeys');

const PASSWORD = 'Nexus@2026';
const tracked = new Set();
const trackedStores = new Set();

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

// Mark a user's email as verified without going through the code flow.
function verifyUser(id) {
  return prisma.user.update({ where: { id }, data: { emailVerified: true } });
}

// Create a store directly in the DB. Name starts with test_store_ (matched by
// the cleanup SQL in the README). Returns { store, key }; cleanup() deletes it.
async function createTestStore(category = 'Supermarket') {
  const key = generateStoreKey();
  const store = await prisma.store.create({
    data: {
      name: `test_store_${Date.now()}${crypto.randomInt(0, 1_000_000)}`,
      category,
      apiKeyHash: hashStoreKey(key),
    },
  });
  trackedStores.add(store.id);
  return { store, key };
}

// Delete only the users and stores this test file created (receipts/codes
// cascade with the user; a store's receipts just lose their storeId).
async function cleanup() {
  if (tracked.size > 0) {
    await prisma.user.deleteMany({ where: { id: { in: [...tracked] } } });
    tracked.clear();
  }
  if (trackedStores.size > 0) {
    await prisma.store.deleteMany({ where: { id: { in: [...trackedStores] } } });
    trackedStores.clear();
  }
  await prisma.$disconnect();
}

module.exports = {
  PASSWORD, makeApp, uniqueEmail, uniquePhone, track, registerUser, verifyUser,
  createTestStore, cleanup,
};
