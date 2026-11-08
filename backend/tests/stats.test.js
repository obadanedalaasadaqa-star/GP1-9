jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const getStats = (token, bounds) =>
  request(app).get('/api/user/stats').set(auth(token)).query({ bounds: bounds.join(',') });

// Jordan-style month starts (local midnight, UTC+3) in early 2025, so they can
// never overlap the current month: P1 = Jan, P2 = Feb, P3 = Mar 2025.
const B = [
  '2024-12-31T21:00:00.000Z',
  '2025-01-31T21:00:00.000Z',
  '2025-02-28T21:00:00.000Z',
  '2025-03-31T21:00:00.000Z',
];
// The same instants written with a +03:00 offset.
const B_LOCAL = [
  '2025-01-01T00:00:00+03:00',
  '2025-02-01T00:00:00+03:00',
  '2025-03-01T00:00:00+03:00',
  '2025-04-01T00:00:00+03:00',
];
const ms = (iso, delta = 0) => new Date(new Date(iso).getTime() + delta);

// Current UTC month, for the single-period check.
const now = new Date();
const CUR = [
  new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString(),
  new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString(),
];

const round3 = (n) => Math.round(n * 1000) / 1000;

function addReceipt(userId, storeName, category, totalAmount, createdAt) {
  return prisma.receipt.create({
    data: { userId, storeName, category, totalAmount, items: ['Item'], createdAt },
  });
}

// What the Archive gets for one period: GET /api/user/receipts?from&to, then
// count, sum and group by category on the client side.
async function archive(token, from, to) {
  const res = await request(app).get('/api/user/receipts').set(auth(token)).query({ from, to });
  expect(res.status).toBe(200);
  const byCategory = {};
  for (const r of res.body) {
    byCategory[r.category] ??= { total: 0, count: 0 };
    byCategory[r.category].total += r.totalAmount;
    byCategory[r.category].count += 1;
  }
  return {
    count: res.body.length,
    total: res.body.reduce((s, r) => s + r.totalAmount, 0),
    byCategory,
  };
}

function expectSameAsArchive(period, arc) {
  expect(period.count).toBe(arc.count);
  expect(Math.abs(period.total - round3(arc.total))).toBeLessThan(0.0005);
  expect(period.byCategory).toHaveLength(Object.keys(arc.byCategory).length);
  for (const c of period.byCategory) {
    const a = arc.byCategory[c.category];
    expect(a).toBeDefined();
    expect(c.count).toBe(a.count);
    expect(Math.abs(c.total - round3(a.total))).toBeLessThan(0.0005);
  }
}

let a, b;
beforeAll(async () => {
  a = await registerUser(app);
  b = await registerUser(app);
  const A = a.user.id;
  const cur = new Date(CUR[0]).getTime();
  await Promise.all([
    // P1: two Supermarket receipts at different stores and one Food (fils amounts)
    addReceipt(A, 'Carrefour', 'Supermarket', 0.1, new Date('2025-01-05T10:00:00Z')),
    addReceipt(A, 'Cozmo', 'Supermarket', 1.005, new Date('2025-01-10T10:00:00Z')),
    addReceipt(A, 'KFC', 'Food', 0.1, new Date('2025-01-15T10:00:00Z')),
    // Exactly at the P1/P2 bound: counts in P2
    addReceipt(A, 'Aster', 'Pharmacy', 5, ms(B[1])),
    // 1 ms before the P2/P3 bound: counts in P2
    addReceipt(A, 'KFC', 'Food', 2.675, ms(B[2], -1)),
    // 22:30Z on the last day of Feb = 01:30 on 1 Mar in Jordan: counts in P3
    addReceipt(A, 'Zara', 'Clothing', 20, new Date('2025-02-28T22:30:00Z')),
    // 1 ms before P1: never counted
    addReceipt(A, 'iStore', 'Electronics', 50, ms(B[0], -1)),
    // User B in P2: never in A's stats
    addReceipt(b.user.id, 'Carrefour', 'Supermarket', 100, new Date('2025-02-10T10:00:00Z')),
    // Current month: two receipts in different categories
    addReceipt(A, 'Cozmo', 'Supermarket', 1.005, new Date(cur + 3600_000)),
    addReceipt(A, 'KFC', 'Food', 0.1, new Date(cur + 7200_000)),
  ]);
}, SLOW);
afterAll(cleanup);

// Keep "[user/stats]" error logs quiet if a test triggers one on purpose.
beforeEach(() => jest.spyOn(console, 'error').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

describe('GET /api/user/stats', () => {
  test('done-when: every period matches the Archive request for the same range', async () => {
    const res = await getStats(a.token, B);
    expect(res.status).toBe(200);
    expect(res.body.periods).toHaveLength(3);
    expect(res.body.periods.map((p) => p.count)).toEqual([3, 2, 1]);

    for (let i = 0; i < 3; i++) {
      const p = res.body.periods[i];
      expect(p.from).toBe(B[i]);
      expect(p.to).toBe(B[i + 1]);
      expectSameAsArchive(p, await archive(a.token, B[i], B[i + 1]));
    }

    // Single period (2 bounds), the shape the Archive uses most.
    const single = await getStats(a.token, CUR);
    expect(single.status).toBe(200);
    const cur = single.body.periods[0];
    expect(cur.count).toBe(2);
    expect(cur.byCategory).toHaveLength(2);
    expectSameAsArchive(cur, await archive(a.token, CUR[0], CUR[1]));
  }, SLOW);

  test('values for P1: total, average, byCategory order and topStore', async () => {
    const res = await getStats(a.token, B);
    const p1 = res.body.periods[0];
    expect(p1.total).toBe(1.205);
    expect(p1.count).toBe(3);
    expect(p1.average).toBe(0.402); // 1.205 / 3 = 0.40166...
    expect(p1.byCategory).toEqual([
      { category: 'Supermarket', total: 1.105, count: 2 },
      { category: 'Food', total: 0.1, count: 1 },
    ]);
    expect(p1.topStore).toEqual({ storeName: 'Cozmo', total: 1.005, count: 1 });

    const p2 = res.body.periods[1];
    expect(p2.total).toBe(7.675);
    expect(p2.topStore.storeName).toBe('Aster');
    expect(res.body.periods[2].byCategory).toEqual([{ category: 'Clothing', total: 20, count: 1 }]);
  }, SLOW);

  test('an empty period gives zeros and topStore null', async () => {
    const res = await getStats(a.token, [...B, '2025-04-30T21:00:00.000Z']);
    expect(res.status).toBe(200);
    expect(res.body.periods).toHaveLength(4);
    expect(res.body.periods[3]).toEqual({
      from: '2025-03-31T21:00:00.000Z', to: '2025-04-30T21:00:00.000Z',
      total: 0, count: 0, average: 0, byCategory: [], topStore: null,
    });
  }, SLOW);

  test('a new user with no receipts gets zeros with 200', async () => {
    const fresh = await registerUser(app);
    const res = await getStats(fresh.token, B);
    expect(res.status).toBe(200);
    expect(res.body.periods.map((p) => [p.total, p.count, p.topStore])).toEqual([
      [0, 0, null], [0, 0, null], [0, 0, null],
    ]);
  }, SLOW);

  test('+03:00 bounds (URL-encoded) give the same result as the matching Z bounds', async () => {
    const z = await getStats(a.token, B);
    const local = await getStats(a.token, B_LOCAL);
    expect(local.status).toBe(200);
    expect(local.body).toEqual(z.body);
  }, SLOW);

  test.each([
    ['missing', null, 'bounds is required.'],
    ['empty', '', 'bounds is required.'],
    ['one value', B[0], 'bounds must have 2 to 13 dates.'],
    ['14 values', Array.from({ length: 14 }, (_, k) => new Date(Date.UTC(2025, k, 1)).toISOString()).join(','),
      'bounds must have 2 to 13 dates.'],
    ['no zone', '2026-11-01T00:00:00,2026-12-01T00:00:00',
      'bounds must be ISO dates with a time zone (e.g. 2026-11-01T00:00:00.000Z).'],
    ['30 Feb', '2026-02-01T00:00:00Z,2026-02-30T00:00:00Z',
      'bounds must be ISO dates with a time zone (e.g. 2026-11-01T00:00:00.000Z).'],
    ['reversed', `${B[1]},${B[0]}`, 'bounds must be in increasing order.'],
  ])('400 when bounds is %s', async (_, bounds, message) => {
    const req = request(app).get('/api/user/stats').set(auth(a.token));
    const res = await (bounds === null ? req : req.query({ bounds }));
    expect(res.status).toBe(400);
    expect(res.body.error).toBe(message);
  }, SLOW);

  test('400 when bounds is given twice (array)', async () => {
    const res = await request(app)
      .get(`/api/user/stats?bounds=${B[0]}&bounds=${B[1]}`).set(auth(a.token));
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('bounds is required.');
  }, SLOW);

  test('401 without a token and with a bad token', async () => {
    const none = await request(app).get('/api/user/stats').query({ bounds: B.join(',') });
    const bad = await request(app).get('/api/user/stats').set(auth('not-a-token'))
      .query({ bounds: B.join(',') });
    expect(none.status).toBe(401);
    expect(bad.status).toBe(401);
  }, SLOW);
});
