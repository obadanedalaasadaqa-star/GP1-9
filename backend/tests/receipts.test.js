jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const { makeApp, registerUser, cleanup } = require('./helpers');

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
  });
});
