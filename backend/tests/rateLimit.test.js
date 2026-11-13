jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const http = require('http');
const request = require('supertest');
const { createApp } = require('../src/app');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const {
  PASSWORD, makeApp, uniqueEmail, track, registerUser, createTestStore, cleanup,
} = require('./helpers');

// Users are created on the unlimited app, so the limited apps' register
// limiter never affects them. Each createApp() has its own counters.
const auth = (token) => ({ Authorization: `Bearer ${token}` });
// Many DB round trips per test; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const login = (app, email, password) =>
  request(app).post('/api/auth/login').send({ email, password });

let u1, u2;
beforeAll(async () => {
  u1 = await registerUser(makeApp());
  u2 = await registerUser(makeApp());
}, SLOW);
afterAll(cleanup);

// Silence the "[rate-limit] ... blocked" log lines during tests.
beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

describe('login limiter', () => {
  test('the 4th failed login gets a JSON 429 with RateLimit headers', async () => {
    const app = createApp({ rateLimit: { login: { limit: 3 } } });
    for (let i = 0; i < 3; i++) {
      const res = await login(app, u1.email, 'Wrong@2026');
      expect(res.status).toBe(401);
    }
    const blocked = await login(app, u1.email, 'Wrong@2026');
    expect(blocked.status).toBe(429);
    expect(blocked.headers['content-type']).toMatch(/json/);
    expect(blocked.body.error).toBe('Too many login attempts. Try again in a few minutes.');
    expect(blocked.headers).toHaveProperty('ratelimit');
    expect(console.log).toHaveBeenCalledWith(expect.stringMatching(/^\[rate-limit\] login blocked ip=\S+ user=-$/));
  });

  test('successful logins do not count toward the limit', async () => {
    const app = createApp({ rateLimit: { login: { limit: 3 } } });
    expect((await login(app, u1.email, 'Wrong@2026')).status).toBe(401);
    expect((await login(app, u1.email, 'Wrong@2026')).status).toBe(401);
    for (let i = 0; i < 3; i++) {
      expect((await login(app, u1.email, PASSWORD)).status).toBe(200);
    }
    expect((await login(app, u1.email, 'Wrong@2026')).status).toBe(401);
    expect((await login(app, u1.email, 'Wrong@2026')).status).toBe(429);
  }, SLOW);
});

describe('verifyCode limiter', () => {
  test('is counted per user, not per IP', async () => {
    const app = createApp({ rateLimit: { verifyCode: { limit: 2 } } });
    const verify = (u) =>
      request(app).post('/api/user/email/verify').set(auth(u.token)).send({ code: '12a' });

    expect((await verify(u1)).status).toBe(400);
    expect((await verify(u1)).status).toBe(400);
    const blocked = await verify(u1);
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('Too many attempts. Try again later.');

    // Same IP, different user: still allowed.
    expect((await verify(u2)).status).toBe(400);
  });
});

describe('sendCode limiter', () => {
  const setLastSent = (u, date) => prisma.verificationCode.update({
    where: { userId_type: { userId: u.user.id, type: 'email' } },
    data: { lastSentAt: date },
  });
  // Skip the route's own 60 s resend wait by backdating the last send.
  const allowResend = (u) => setLastSent(u, new Date(Date.now() - 2 * 60 * 1000));

  test('only successfully sent codes count toward the limit', async () => {
    const app = createApp({ rateLimit: { sendCode: { limit: 2 } } });
    const sendCode = () =>
      request(app).post('/api/user/email/send-code').set(auth(u1.token));

    // Mark a code as just sent: these are the route's "Please wait" 429s,
    // which must not use up the limit.
    await setLastSent(u1, new Date());
    for (let i = 0; i < 3; i++) {
      const res = await sendCode();
      expect(res.status).toBe(429);
      expect(res.body.waitSeconds).toBeGreaterThan(0);
    }

    await allowResend(u1);
    expect((await sendCode()).status).toBe(200);
    await allowResend(u1);
    expect((await sendCode()).status).toBe(200);

    await allowResend(u1);
    const blocked = await sendCode();
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('Too many code requests. Try again later.');
    expect(blocked.body.waitSeconds).toBeUndefined();
  }, SLOW);

  test('a request the client aborts still counts toward the limit', async () => {
    const app = createApp({ rateLimit: { sendCode: { limit: 2 } } });
    const server = app.listen(0);
    try {
      // Hold the mailer so the client can abort while the route is mid-send.
      let release;
      const mailerCalled = new Promise((resolve) => {
        mailer.sendVerificationEmail.mockImplementationOnce(() => {
          resolve();
          return new Promise((r) => { release = r; });
        });
      });
      const serverClosed = new Promise((resolve) => {
        server.once('request', (_req, res) => res.once('close', resolve));
      });

      await allowResend(u2);
      const req = http.request({
        port: server.address().port,
        method: 'POST',
        path: '/api/user/email/send-code',
        headers: auth(u2.token),
      });
      req.on('error', () => {}); // ECONNRESET from destroy() is expected
      req.end();

      await mailerCalled;
      req.destroy();
      await serverClosed;
      release();
      await new Promise((r) => setTimeout(r, 100)); // let the handler finish

      // The aborted send used 1 of the 2, so the 2nd send is already blocked.
      await allowResend(u2);
      expect((await request(app).post('/api/user/email/send-code').set(auth(u2.token))).status).toBe(200);
      await allowResend(u2);
      const blocked = await request(app).post('/api/user/email/send-code').set(auth(u2.token));
      expect(blocked.status).toBe(429);
      expect(blocked.body.error).toBe('Too many code requests. Try again later.');
    } finally {
      await new Promise((r) => server.close(r));
    }
  }, SLOW);
});

describe('register limiter', () => {
  test('the 2nd register gets 429 when the limit is 1', async () => {
    const app = createApp({ rateLimit: { register: { limit: 1 } } });
    const body = () => ({
      firstName: 'Test', lastName: 'User', email: uniqueEmail(), password: PASSWORD,
    });

    const first = await request(app).post('/api/auth/register').send(body());
    expect(first.status).toBe(201);
    track(first.body.user.id);

    const second = await request(app).post('/api/auth/register').send(body());
    expect(second.status).toBe(429);
    expect(second.body.error).toBe('Too many accounts created from this network. Try again later.');
  });
});

describe('store limiters', () => {
  const ITEMS = [{ name: 'Milk', qty: 1, unitPrice: 1 }];
  const sendReceipt = (app, key, customerSerial) => request(app).post('/api/store/receipts')
    .set('X-Store-Key', key).send({ customerSerial, items: ITEMS, totalAmount: 1 });

  test('storeAuth only counts 401s: 3 wrong keys, then 429', async () => {
    const shop = await createTestStore();
    const app = createApp({ rateLimit: { storeAuth: { limit: 3 } } });

    // A valid key with an unknown serial (404) does not count.
    for (let i = 0; i < 4; i++) {
      expect((await sendReceipt(app, shop.key, 'NXS-00000-00000')).status).toBe(404);
    }
    for (let i = 0; i < 3; i++) {
      const res = await request(app).get('/api/store/me').set('X-Store-Key', 'nxs_sk_wrong');
      expect(res.status).toBe(401);
    }
    const blocked = await request(app).get('/api/store/me').set('X-Store-Key', 'nxs_sk_wrong');
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('Too many wrong store keys. Try again in a few minutes.');
  }, SLOW);

  test('storeReceipts is counted per store', async () => {
    const shopA = await createTestStore();
    const shopB = await createTestStore();
    const app = createApp({ rateLimit: { storeReceipts: { limit: 2 } } });
    const serial = u1.user.serialNumber;

    expect((await sendReceipt(app, shopA.key, serial)).status).toBe(201);
    expect((await sendReceipt(app, shopA.key, serial)).status).toBe(201);
    const blocked = await sendReceipt(app, shopA.key, serial);
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('Too many receipts from this store. Try again in a minute.');

    // Same IP, another store: still allowed.
    expect((await sendReceipt(app, shopB.key, serial)).status).toBe(201);
  }, SLOW);
});
