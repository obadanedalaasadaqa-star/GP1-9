jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const Anthropic = require('@anthropic-ai/sdk');
const prisma = require('../src/lib/prisma');
const { makeApp, registerUser, createTestStore, cleanup } = require('./helpers');
const { makeFakeAi, json, reply, wait, defaultInsight } = require('./fakeAi');
const { seedFacts } = require('./fixtures/seedFacts');
const { formatAmount } = require('../src/lib/aiFormat');
const { auth, jordanBounds, monthLabels, seededUser, addReceipt } = require('./aiHelpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 120_000;

const ai = makeFakeAi();
const app = makeApp({ aiClient: ai.client });
const BOUNDS = jordanBounds();
const getInsight = (token, bounds = BOUNDS, a = app) =>
  request(a).get('/api/ai/insight').set(auth(token)).query({ bounds: bounds.join(',') });

const sdkError = (status) => Anthropic.APIError.generate(status, { error: { type: 'x', message: 'm' } }, 'm', new Headers());
const insightRow = (userId) => prisma.aiInsight.findUnique({ where: { userId } });

afterAll(cleanup);
beforeEach(() => {
  ai.reset();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('GET /api/ai/insight', () => {
  test('I-1 done-when: a second request within 24 h costs nothing', async () => {
    const u = await seededUser(app);
    const first = await getInsight(u.token);
    expect(first.status).toBe(200);
    expect(first.body).toMatchObject({ status: 'ready', cached: false, summary: 'You spent 287.99 JD so far this month.' });

    const second = await getInsight(u.token);
    expect(second.status).toBe(200);
    expect(second.body.cached).toBe(true);
    for (const k of ['summary', 'tip', 'createdAt']) expect(second.body[k]).toEqual(first.body[k]);
    expect(ai.create).toHaveBeenCalledTimes(1);

    // A fresh app (a server restart) still uses the saved row.
    const third = await getInsight(u.token, BOUNDS, makeApp({ aiClient: ai.client }));
    expect(third.body.cached).toBe(true);
    expect(ai.create).toHaveBeenCalledTimes(1);
  }, SLOW);

  test('I-2 done-when: the facts for the demo data, equal to /stats', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    const facts = JSON.parse(ai.seen[0].messages[0].content);
    expect(facts).toEqual(seedFacts(monthLabels()));

    const stats = await request(app).get('/api/user/stats').set(auth(u.token)).query({ bounds: BOUNDS.join(',') });
    const cur = stats.body.periods.at(-1);
    expect(facts.thisMonth.total).toBe(formatAmount(cur.total));
    expect(facts.thisMonth.categories.map((c) => c.total)).toEqual(cur.byCategory.map((c) => formatAmount(c.total)));
    expect(facts.months.map((m) => m.total)).toEqual(stats.body.periods.map((p) => formatAmount(p.total)));
  }, SLOW);

  test('I-3 privacy: no email, serial or user id sent', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    const sent = JSON.stringify(ai.seen);
    for (const bad of [u.email, u.user.serialNumber, u.user.id, 'Test User']) {
      expect(sent).not.toContain(bad);
    }
  }, SLOW);

  test('I-4 a new receipt (manual or from a store) makes it stale', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    expect((await addReceipt(app, u.token, 'Shop', 'Food', 5)).status).toBe(201);
    const res = await getInsight(u.token);
    expect(res.body.cached).toBe(false);
    expect(res.body.summary).toContain('292.99');
    expect(ai.create).toHaveBeenCalledTimes(2);

    const shop = await createTestStore();
    const sent = await request(app).post('/api/store/receipts').set('X-Store-Key', shop.key).send({
      customerSerial: u.user.serialNumber, items: [{ name: 'Milk', qty: 2, unitPrice: 0.5 }], totalAmount: 1,
    });
    expect(sent.status).toBe(201);
    const after = await getInsight(u.token);
    expect(after.body.cached).toBe(false);
    expect(after.body.summary).toContain('293.99');
  }, SLOW);

  test('I-5 the 24 h rule', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    const hoursAgo = (h) => new Date(Date.now() - h * 3600_000);
    await prisma.aiInsight.update({ where: { userId: u.user.id }, data: { createdAt: hoursAgo(23) } });
    expect((await getInsight(u.token)).body.cached).toBe(true);
    await prisma.aiInsight.update({ where: { userId: u.user.id }, data: { createdAt: hoursAgo(25) } });
    expect((await getInsight(u.token)).body.cached).toBe(false);
    expect(ai.create).toHaveBeenCalledTimes(2);
  }, SLOW);

  test('I-6 next month\'s bounds give a new insight', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    const res = await getInsight(u.token, jordanBounds({ shift: 1 }));
    expect(res.status).toBe(200);
    expect(res.body.cached).toBe(false);
  }, SLOW);

  test('I-7 not enough data below 3 receipts', async () => {
    const u = await registerUser(app);
    expect((await getInsight(u.token)).body).toEqual({ status: 'not_enough_data', receiptCount: 0, minReceipts: 3 });
    await addReceipt(app, u.token, 'A', 'Food', 10);
    await addReceipt(app, u.token, 'B', 'Food', 15.5);
    expect((await getInsight(u.token)).body).toEqual({ status: 'not_enough_data', receiptCount: 2, minReceipts: 3 });
    expect(ai.create).not.toHaveBeenCalled();
    expect(await insightRow(u.user.id)).toBeNull();
    await addReceipt(app, u.token, 'C', 'Food', 20.25);
    const res = await getInsight(u.token);
    expect(res.body.status).toBe('ready');
    expect(res.body.summary).toContain('45.75');
  }, SLOW);

  test('I-8 failures save nothing and the next GET tries again', async () => {
    const u = await seededUser(app);
    const ok = JSON.stringify({ summary: 'You spent 287.99 JD.', tip: 'Fine.' });
    const failures = [
      () => json({ summary: 'You spent 287.99 JD.', tip: 'Fine.' }, { stop_reason: 'refusal', stop_details: { type: 'refusal' } }),
      () => reply([{ type: 'text', text: ok }], { stop_reason: 'max_tokens' }),
      () => reply([{ type: 'text', text: 'not json' }]),
      () => json({ summary: 'You spent 999.99 JD so far this month.', tip: 'Fine.' }),
      () => json({ summary: 'You spent 287.99 JD.', tip: 'You could save 10 JD.' }),
    ];
    for (const f of failures) {
      ai.next(f);
      const res = await getInsight(u.token);
      expect(res.status).toBe(502);
      expect(res.body).toEqual({ error: 'Could not create an insight right now. Try again later.' });
      expect(await insightRow(u.user.id)).toBeNull();
    }
    expect(ai.create).toHaveBeenCalledTimes(5);
    expect((await getInsight(u.token)).body.cached).toBe(false);
    expect(ai.create).toHaveBeenCalledTimes(6);
  }, SLOW);

  test('I-9 SDK errors', async () => {
    const u = await seededUser(app);
    const cases = [
      [sdkError(429), 503, 'The AI service is busy. Try again in a minute.'],
      [sdkError(401), 503, 'AI insights are not available right now.'],
      [new Anthropic.APIConnectionTimeoutError(), 504, 'The AI took too long. Try again.'],
      [sdkError(400), 502, 'Could not create an insight right now. Try again later.'],
    ];
    for (const [err, status, error] of cases) {
      ai.next(() => { throw err; });
      const res = await getInsight(u.token);
      expect(res.status).toBe(status);
      expect(res.body).toEqual({ error });
    }
  }, SLOW);

  test('I-10 not configured: 503, but saved insights and not_enough_data still work', async () => {
    const off = makeApp({ aiClient: null });
    const u = await seededUser(app);
    const res = await getInsight(u.token, BOUNDS, off);
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ error: 'AI insights are not set up on this server.' });
    await getInsight(u.token); // saved with the fake
    const saved = await getInsight(u.token, BOUNDS, off);
    expect(saved.status).toBe(200);
    expect(saved.body.cached).toBe(true);

    const fresh = await registerUser(app);
    await addReceipt(app, fresh.token, 'A', 'Food', 1);
    expect((await getInsight(fresh.token, BOUNDS, off)).body.status).toBe('not_enough_data');
  }, SLOW);

  test('I-11 parallel requests share one call; failures never leave an unhandled rejection', async () => {
    const u = await seededUser(app);
    // (1) Two parallel GETs, one Claude call, the same row.
    ai.next(async (req) => { await wait(300); return defaultInsight(req); });
    const [a, b] = await Promise.all([getInsight(u.token), getInsight(u.token)]);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(a.body.createdAt).toBe(b.body.createdAt);
    expect(ai.create).toHaveBeenCalledTimes(1);

    // (2) Stale, then the shared call fails: both get 503.
    await addReceipt(app, u.token, 'Shop', 'Food', 5);
    ai.next(async () => { await wait(300); throw sdkError(429); });
    const failed = await Promise.all([getInsight(u.token), getInsight(u.token)]);
    expect(failed.map((r) => r.status)).toEqual([503, 503]);
    expect(ai.create).toHaveBeenCalledTimes(2);

    // (3) The next GET works.
    const next = await getInsight(u.token);
    expect(next.body.cached).toBe(false);
    expect(ai.create).toHaveBeenCalledTimes(3);

    // (4) Failing shared calls (busy, then an invented number). jest-circus
    // fails the running test on any unhandled rejection; the setImmediate
    // wait keeps the test alive long enough for one to surface.
    await addReceipt(app, u.token, 'Shop', 'Food', 1);
    ai.next(async () => { await wait(200); throw sdkError(429); });
    expect((await Promise.all([getInsight(u.token), getInsight(u.token)])).map((r) => r.status)).toEqual([503, 503]);
    await new Promise((r) => setImmediate(r));
    ai.next(async () => { await wait(200); return json({ summary: 'You spent 999.99 JD.', tip: 'x' }); });
    expect((await Promise.all([getInsight(u.token), getInsight(u.token)])).map((r) => r.status)).toEqual([502, 502]);
    await new Promise((r) => setImmediate(r));
    await wait(50);
  }, SLOW);

  test('I-12 rate limit only counts requests that would call Claude', async () => {
    const limited = makeApp({ aiClient: ai.client, rateLimit: { aiInsight: { limit: 1 } } });
    const u = await seededUser(app);
    expect((await getInsight(u.token, BOUNDS, limited)).body.cached).toBe(false);
    expect((await getInsight(u.token, BOUNDS, limited)).body.cached).toBe(true);
    await addReceipt(app, u.token, 'Shop', 'Food', 5);
    const res = await getInsight(u.token, BOUNDS, limited);
    expect(res.status).toBe(429);
    expect(res.body).toEqual({ error: 'Too many new insights. Try again later.' });
  }, SLOW);

  test('I-13 bounds errors and auth', async () => {
    const u = await registerUser(app);
    const bad = await request(app).get('/api/ai/insight').set(auth(u.token)).query({ bounds: 'abc' });
    expect(bad.status).toBe(400);
    expect(bad.body.error).toMatch(/^bounds must have 2 to 13 dates\.|^bounds must be ISO/);
    const iso = await request(app).get('/api/ai/insight').set(auth(u.token)).query({ bounds: 'abc,def' });
    expect(iso.body).toEqual({ error: 'bounds must be ISO dates with a time zone (e.g. 2026-11-01T00:00:00.000Z).' });
    expect((await request(app).get('/api/ai/insight').set(auth(u.token))).body).toEqual({ error: 'bounds is required.' });
    expect((await request(app).get('/api/ai/insight').query({ bounds: BOUNDS.join(',') })).status).toBe(401);
    const badToken = await request(app).get('/api/ai/insight').set(auth('nope')).query({ bounds: BOUNDS.join(',') });
    expect(badToken.status).toBe(401);
  }, SLOW);

  test('I-14 deleting the user removes the row', async () => {
    const u = await seededUser(app);
    await getInsight(u.token);
    expect(await insightRow(u.user.id)).not.toBeNull();
    await prisma.user.delete({ where: { id: u.user.id } });
    expect(await insightRow(u.user.id)).toBeNull();
  }, SLOW);

  test('I-15 the answering model is saved but never hashed', async () => {
    const u = await seededUser(app);
    ai.next((req) => ({ ...defaultInsight(req), model: 'some-fallback-model' }));
    expect((await getInsight(u.token)).body.cached).toBe(false);
    expect((await insightRow(u.user.id)).model).toBe('some-fallback-model');
    expect((await getInsight(u.token)).body.cached).toBe(true);
    expect(ai.create).toHaveBeenCalledTimes(1);
  }, SLOW);

  test('I-17 the saved row is read again inside the shared promise', async () => {
    const u = await seededUser(app);
    const first = await getInsight(u.token);
    const spy = jest.spyOn(prisma.aiInsight, 'findUnique').mockResolvedValueOnce(null);
    const res = await getInsight(u.token);
    expect(res.status).toBe(200);
    expect(res.body.cached).toBe(true);
    expect(res.body.createdAt).toBe(first.body.createdAt);
    expect(ai.create).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalled();
  }, SLOW);

  test('I-16 Express 4 survival: DB errors give 500 and the server keeps working', async () => {
    const u = await seededUser(app);
    const upsert = jest.spyOn(prisma.aiInsight, 'upsert').mockRejectedValueOnce(new Error('db'));
    let res = await getInsight(u.token);
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'Failed to load insight.' });
    expect(upsert).toHaveBeenCalled();
    expect((await getInsight(u.token)).status).toBe(200);

    const find = jest.spyOn(prisma.aiInsight, 'findUnique').mockRejectedValueOnce(new Error('db'));
    res = await getInsight(u.token);
    expect(res.status).toBe(500);
    expect(find).toHaveBeenCalled();
    expect((await getInsight(u.token)).status).toBe(200);
    expect((await request(app).get('/api/health')).status).toBe(200);
  }, SLOW);
});
