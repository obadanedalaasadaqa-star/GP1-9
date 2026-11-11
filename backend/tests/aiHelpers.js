// Shared bits for the AI integration tests.
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { registerUser } = require('./helpers');

const TZ = 180; // Jordan
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'];

const auth = (token) => ({ Authorization: `Bearer ${token}` });

// The local (Jordan) year and month of [now].
function jordanMonth(now = new Date()) {
  const local = new Date(now.getTime() + TZ * 60000);
  return { y: local.getUTCFullYear(), m: local.getUTCMonth() };
}

/**
 * What the app sends as `bounds`: [months] + 1 Jordan month starts, oldest
 * first, ending with the end of the current month. shift moves the window.
 */
function jordanBounds({ months = 6, shift = 0, now = new Date() } = {}) {
  const { y, m } = jordanMonth(now);
  const out = [];
  for (let k = months - 1; k >= -1; k--) {
    out.push(new Date(Date.UTC(y, m - k + shift, 1) - TZ * 60000).toISOString());
  }
  return out;
}

// "November 2026" labels for the 6 months of jordanBounds().
function monthLabels(months = 6, now = new Date()) {
  const { y, m } = jordanMonth(now);
  const out = [];
  for (let k = months - 1; k >= 0; k--) {
    const d = new Date(Date.UTC(y, m - k, 1));
    out.push(`${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`);
  }
  return out;
}

// A new user with the 7 demo receipts (287.99 JD this month).
async function seededUser(app) {
  const u = await registerUser(app);
  const res = await request(app).post('/api/receipts/seed').set(auth(u.token));
  if (res.status !== 200 || !res.body.seeded) throw new Error(`seed failed: ${res.status}`);
  return u;
}

function addReceipt(app, token, storeName, category, totalAmount) {
  return request(app).post('/api/receipts').set(auth(token))
    .send({ storeName, category, totalAmount, items: ['Item'] });
}

// Today's usage row of a user for a kind, or null.
async function usageRow(userId, kind) {
  const rows = await prisma.$queryRaw`
    SELECT count, "inputTokens", "outputTokens" FROM nexus_ai_usage
     WHERE "userId" = ${userId} AND kind = ${kind} AND day = (NOW() AT TIME ZONE 'UTC')::date`;
  return rows[0] ?? null;
}

module.exports = { TZ, auth, jordanBounds, monthLabels, seededUser, addReceipt, usageRow };
