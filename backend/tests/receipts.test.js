jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { createApp } = require('../src/app');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });

afterAll(cleanup);

describe('POST /api/receipts + GET /api/user/receipts', () => {
  let a;
  beforeAll(async () => { a = await registerUser(app); });

  test('201 creates a receipt, earns floor(total) points and adds them to the user', async () => {
    const res = await request(app).post('/api/receipts').set(auth(a.token)).send({
      storeName: ' Carrefour ', category: 'Supermarket', totalAmount: 12.75, items: ['Milk'],
    });
    expect(res.status).toBe(201);
    expect(res.body.storeName).toBe('Carrefour');
    expect(res.body.pointsEarned).toBe(12);
    expect(res.body.userId).toBe(a.user.id);

    const me = await request(app).get('/api/user/me').set(auth(a.token));
    expect(me.body.loyaltyPoints).toBe(a.user.loyaltyPoints + 12);
  });

  test('400 when fields are missing', async () => {
    const res = await request(app).post('/api/receipts').set(auth(a.token))
      .send({ storeName: 'Zara', totalAmount: 10 });
    expect(res.status).toBe(400);
  });

  test('401 without a token', async () => {
    const post = await request(app).post('/api/receipts').send({});
    const list = await request(app).get('/api/user/receipts');
    expect(post.status).toBe(401);
    expect(list.status).toBe(401);
  });

  test('lists the latest receipt first', async () => {
    const res = await request(app).post('/api/receipts').set(auth(a.token)).send({
      storeName: 'Zara', category: 'Clothing', totalAmount: 30, items: [],
    });
    expect(res.status).toBe(201);

    const list = await request(app).get('/api/user/receipts').set(auth(a.token));
    expect(list.status).toBe(200);
    expect(list.body.map((r) => r.storeName)).toEqual(['Zara', 'Carrefour']);
  });

  test('from/to filter by date', async () => {
    const hourAgo = new Date(Date.now() - 3600_000).toISOString();
    const inHour  = new Date(Date.now() + 3600_000).toISOString();

    const inRange = await request(app).get('/api/user/receipts').set(auth(a.token))
      .query({ from: hourAgo, to: inHour });
    expect(inRange.status).toBe(200);
    expect(inRange.body).toHaveLength(2);

    const future = await request(app).get('/api/user/receipts').set(auth(a.token))
      .query({ from: inHour });
    expect(future.body).toHaveLength(0);

    const past = await request(app).get('/api/user/receipts').set(auth(a.token))
      .query({ to: hourAgo });
    expect(past.body).toHaveLength(0);
  });

  test('400 for an invalid date', async () => {
    const res = await request(app).get('/api/user/receipts').set(auth(a.token))
      .query({ from: 'not-a-date' });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('from and to must be valid dates.');
  });
});

describe('POST /api/receipts/seed', () => {
  let b;
  beforeAll(async () => { b = await registerUser(app); });

  test('seeds 7 demo receipts once for a fresh user', async () => {
    const seed = await request(app).post('/api/receipts/seed').set(auth(b.token));
    expect(seed.status).toBe(200);
    expect(seed.body).toEqual({ seeded: true, count: 7 });

    const list = await request(app).get('/api/user/receipts').set(auth(b.token));
    expect(list.body).toHaveLength(7);

    const again = await request(app).post('/api/receipts/seed').set(auth(b.token));
    expect(again.body.seeded).toBe(false);
  }, SLOW);
});

describe('POST /api/receipts input checks', () => {
  let c;
  beforeAll(async () => { c = await registerUser(app); });

  const valid = { storeName: 'Carrefour', category: 'Supermarket', totalAmount: 10, items: ['Milk'] };
  const TOTAL = 'Total must be a number above 0 and at most 10000.';
  const ITEMS = 'Items must be a list of up to 100 texts of at most 200 characters.';

  test.each([
    ['a negative total', { totalAmount: -5 }, TOTAL],
    ['a zero total', { totalAmount: 0 }, TOTAL],
    ['a string total', { totalAmount: '12' }, TOTAL],
    ['a total above 10000', { totalAmount: 10000.01 }, TOTAL],
    ['a non-string item', { items: ['Milk', 5] }, ITEMS],
    ['101 items', { items: Array.from({ length: 101 }, () => 'x') }, ITEMS],
    ['a 61-character store name', { storeName: 'S'.repeat(61) }, 'Store name must be 1 to 60 characters.'],
    ['a numeric storeName (400, not a hang)', { storeName: 5 }, 'Store name must be 1 to 60 characters.'],
    ['a 41-character category', { category: 'C'.repeat(41) }, 'Category must be 1 to 40 characters.'],
  ])('400 for %s', async (_label, over, error) => {
    const res = await request(app).post('/api/receipts').set(auth(c.token)).send({ ...valid, ...over });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe(error);
  });

  test('nothing was saved and the points are unchanged', async () => {
    const list = await request(app).get('/api/user/receipts').set(auth(c.token));
    expect(list.body).toHaveLength(0);
    const me = await request(app).get('/api/user/me').set(auth(c.token));
    expect(me.body.loyaltyPoints).toBe(c.user.loyaltyPoints);
  });
});

// Audit L9-L11: no self-crediting route in production; bounded reads.
describe('receipt routes after the audit', () => {
  test('production app (no testRoutes): POST /api/receipts and /seed are 404', async () => {
    const prod = createApp({ rateLimit: false });
    const u = await registerUser(app);
    const one = await request(prod).post('/api/receipts').set(auth(u.token))
      .send({ storeName: 'X', category: 'Food', totalAmount: 1, items: [] });
    expect(one.status).toBe(404);
    expect((await request(prod).post('/api/receipts/seed').set(auth(u.token))).status).toBe(404);
    expect((await prisma.user.findUnique({ where: { id: u.user.id } })).loyaltyPoints).toBe(0);
  }, SLOW);

  test('GET /user/receipts rows have exactly the fields the app reads', async () => {
    const u = await registerUser(app);
    await request(app).post('/api/receipts/seed').set(auth(u.token));
    for (const query of [{}, { from: '2000-01-01T00:00:00Z', to: '2100-01-01T00:00:00Z' }]) {
      const res = await request(app).get('/api/user/receipts').set(auth(u.token)).query(query);
      expect(res.status).toBe(200);
      expect(res.body.length).toBeGreaterThan(0);
      for (const r of res.body) {
        expect(Object.keys(r).sort()).toEqual(
          ['category', 'createdAt', 'id', 'items', 'lineItems', 'pointsEarned', 'storeName', 'totalAmount']);
      }
    }
  }, SLOW);

  test('receiptsRead limiter: the 3rd GET gets 429', async () => {
    const limited = makeApp({ rateLimit: { receiptsRead: { limit: 2 } } });
    const u = await registerUser(app);
    jest.spyOn(console, 'log').mockImplementation(() => {});
    try {
      for (let i = 0; i < 2; i++) {
        expect((await request(limited).get('/api/user/receipts').set(auth(u.token))).status).toBe(200);
      }
      const blocked = await request(limited).get('/api/user/receipts').set(auth(u.token));
      expect(blocked.status).toBe(429);
      expect(blocked.body.error).toBe('Too many requests. Try again in a few minutes.');
    } finally {
      console.log.mockRestore();
    }
  }, SLOW);

  test('a ranged GET returns the newest 500', async () => {
    const u = await registerUser(app);
    const start = Date.UTC(2026, 0, 1);
    await prisma.receipt.createMany({
      data: Array.from({ length: 501 }, (_, i) => ({
        userId: u.user.id, storeName: 'S', category: 'Food', totalAmount: 1, items: [],
        createdAt: new Date(start + i * 60_000),
      })),
    });
    const res = await request(app).get('/api/user/receipts').set(auth(u.token))
      .query({ from: '2025-12-01T00:00:00Z', to: '2026-02-01T00:00:00Z' });
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(500);
    expect(new Date(res.body[0].createdAt).getTime()).toBe(start + 500 * 60_000);
    expect(new Date(res.body[499].createdAt).getTime()).toBe(start + 60_000);
  }, SLOW);
});
