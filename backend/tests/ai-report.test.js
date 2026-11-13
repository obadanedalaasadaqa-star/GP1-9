jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const { makeApp, registerUser, verifyUser, cleanup } = require('./helpers');
const { makeFakeAi, json, wait, defaultReport } = require('./fakeAi');
const { auth, seededUser, addReceipt, usageRow, TZ } = require('./aiHelpers');
const { todayLocal, addMonthsClamped, localDayToUtc } = require('../src/lib/aiDates');

const SLOW = 120_000;

const ai = makeFakeAi();
const app = makeApp({ aiClient: ai.client });
const getReport = (token, query = 'period=1m', a = app) =>
  request(a).get(`/api/ai/report?${query}&tzOffsetMinutes=180`).set(auth(token));
const emailReport = (token, body = { period: '1m', tzOffsetMinutes: 180 }, a = app) =>
  request(a).post('/api/ai/report/email').set(auth(token)).send(body);
const today = () => todayLocal(new Date(), TZ);
const reportRows = (userId) => prisma.aiReport.findMany({ where: { userId } });

afterAll(cleanup);
beforeEach(() => {
  ai.reset();
  mailer.sentReports.length = 0;
  mailer.sendReportEmail.mockClear();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('GET /api/ai/report', () => {
  test('R-1 numbers for the demo data', async () => {
    const u = await seededUser(app);
    const res = await getReport(u.token);
    expect(res.status).toBe(200);
    const b = res.body;
    expect(b.range).toMatchObject({ period: '1m', from: `${today().slice(0, 8)}01`, to: today() });
    expect(b.totals).toEqual({ total: 287.99, receipts: 7, average: 41.141 });
    expect(b.byCategory.map((c) => [c.category, c.total, c.sharePercent])).toEqual([
      ['Electronics', 89.99, 31], ['Supermarket', 76.75, 27], ['Clothing', 67, 23], ['Food', 31.25, 11], ['Pharmacy', 23, 8],
    ]);
    expect(b.topStores[0]).toEqual({ storeName: 'iStore', total: 89.99, receipts: 1 });
    expect(b.biggestReceipts.map((r) => r.total)).toEqual([89.99, 67, 45.5, 31.25, 23]);
    expect(b.byMonth).toHaveLength(1);
    expect(b.byMonth[0]).toMatchObject({ total: 287.99, receipts: 7 });
    expect(b.comparison.isNew).toBe(true);
    expect(b.ai).toMatchObject({ status: 'ready', cached: false, headline: 'You spent 287.99 JD in this period.' });
    expect(JSON.stringify(b)).not.toMatch(/"id"|userId/);
  }, SLOW);

  test('R-2 numbers equal Trends (/stats) for the same month', async () => {
    const u = await seededUser(app);
    const first = `${today().slice(0, 8)}01`;
    const bounds = [localDayToUtc(first, TZ), localDayToUtc(addMonthsClamped(first, 1), TZ)].map((d) => d.toISOString());
    const stats = await request(app).get('/api/user/stats').set(auth(u.token)).query({ bounds: bounds.join(',') });
    const rep = await getReport(u.token);
    const p = stats.body.periods[0];
    expect(rep.body.totals.total).toBe(p.total);
    expect(rep.body.byCategory.map((c) => c.total)).toEqual(p.byCategory.map((c) => c.total));
  }, SLOW);

  test('R-3 the AI text is cached; a new receipt writes it again', async () => {
    const u = await seededUser(app);
    const first = await getReport(u.token);
    const second = await getReport(u.token);
    expect(second.body.ai.cached).toBe(true);
    expect(second.body.totals).toEqual(first.body.totals);
    expect(ai.create).toHaveBeenCalledTimes(1);
    await addReceipt(app, u.token, 'Shop', 'Food', 5);
    const third = await getReport(u.token);
    expect(third.body.ai.cached).toBe(false);
    expect(third.body.totals.total).toBe(292.99);
  }, SLOW);

  test('R-4 previous period', async () => {
    const u = await seededUser(app);
    const lastMonthFirst = addMonthsClamped(`${today().slice(0, 8)}01`, -1);
    await prisma.receipt.create({
      data: {
        userId: u.user.id, storeName: 'KFC', category: 'Food', totalAmount: 50, items: ['x'],
        createdAt: new Date(localDayToUtc(lastMonthFirst, TZ).getTime() + 12 * 3600_000),
      },
    });
    const res = await getReport(u.token);
    expect(res.body.comparison).toMatchObject({ previousTotal: 50, changePercent: 476, isNew: false });
    expect(res.body.byCategory.find((c) => c.category === 'Food').previousTotal).toBe(50);
  }, SLOW);

  test('R-5 custom ranges and validation', async () => {
    const u = await registerUser(app);
    const ok = await getReport(u.token, 'period=custom&from=2026-01-01&to=2026-01-31');
    expect(ok.status).toBe(200);
    expect(ok.body.range.label).toBe('1 – 31 Jan 2026');
    const cases = [
      ['period=2m', 'period must be 1m, 3m, 6m, 1y or custom.'],
      ['period=custom&from=abc&to=2026-01-02', 'from and to must be dates (YYYY-MM-DD).'],
      ['period=custom&from=2026-01-05&to=2026-01-02', 'from must be on or before to.'],
      ['period=custom&from=2026-01-05&to=2099-01-02', "The report can't end in the future."],
      ['period=custom&from=2023-01-01&to=2025-06-01', 'Reports can cover at most 2 years.'],
      ['period=custom&from=2019-12-01&to=2020-01-02', 'Reports start from 2020.'],
    ];
    for (const [q, error] of cases) {
      const res = await getReport(u.token, q);
      expect([res.status, res.body]).toEqual([400, { error }]);
    }
    const tz = await request(app).get('/api/ai/report?period=1m&tzOffsetMinutes=abc').set(auth(u.token));
    expect(tz.status).toBe(400);
    expect((await getReport(u.token, 'period=3m&from=junk&to=junk')).status).toBe(200);
  }, SLOW);

  test('R-6 AI failing never hides numbers; tokens still recorded', async () => {
    const u = await seededUser(app);
    ai.next(() => json({ headline: 'You spent 999.99 JD.', narrative: 'x', tips: ['y'] }));
    const res = await getReport(u.token);
    expect(res.status).toBe(200);
    expect(res.body.totals.total).toBe(287.99);
    expect(res.body.ai).toEqual({ status: 'unavailable', error: 'AI summary is not available right now.' });
    expect(await reportRows(u.user.id)).toHaveLength(0);
    expect(await usageRow(u.user.id, 'report')).toEqual({ count: 1, inputTokens: 700, outputTokens: 400 });

    const off = await getReport(u.token, 'period=1m', makeApp({ aiClient: null }));
    expect(off.body.ai).toEqual({ status: 'unavailable', error: 'AI summary is not set up on this server.' });
    expect(off.body.totals.total).toBe(287.99);

    const few = await registerUser(app);
    await addReceipt(app, few.token, 'A', 'Food', 1);
    expect((await getReport(few.token)).body.ai).toEqual({ status: 'not_enough_data', receiptCount: 1, minReceipts: 3 });
  }, SLOW);

  test('R-7 daily AI report cap', async () => {
    const capped = makeApp({ aiClient: ai.client, aiCaps: { reportPerDay: 1 } });
    const u = await seededUser(app);
    expect((await getReport(u.token, 'period=1m', capped)).body.ai.status).toBe('ready');
    const other = await getReport(u.token, 'period=3m', capped);
    expect(other.status).toBe(200);
    expect(other.body.totals.total).toBe(287.99);
    expect(other.body.ai).toEqual({
      status: 'unavailable', error: "You've reached today's limit of AI report summaries. The numbers are still up to date.",
    });
    const again = await getReport(u.token, 'period=1m', capped);
    expect(again.body.ai).toMatchObject({ status: 'ready', cached: true });
  }, SLOW);

  test('R-8 privacy', async () => {
    const u = await seededUser(app);
    await getReport(u.token);
    const sent = JSON.stringify(ai.seen);
    for (const bad of [u.email, u.user.serialNumber, u.user.id]) expect(sent).not.toContain(bad);
    expect(ai.seen[0].messages[0].content).not.toMatch(/"id"|userId/);
  }, SLOW);

  test('R-9 Express 4 survival: a failed save still returns the numbers', async () => {
    const u = await seededUser(app);
    const spy = jest.spyOn(prisma.aiReport, 'upsert').mockRejectedValueOnce(new Error('db'));
    const res = await getReport(u.token);
    expect(res.status).toBe(200);
    expect(res.body.totals.total).toBe(287.99);
    expect(res.body.ai).toEqual({ status: 'unavailable', error: 'Could not write the AI summary this time.' });
    expect(spy).toHaveBeenCalled();
    expect(await reportRows(u.user.id)).toHaveLength(0);
    expect((await request(app).get('/api/health')).status).toBe(200);

    const raw = jest.spyOn(prisma, '$queryRaw').mockRejectedValueOnce(new Error('db'));
    const failed = await getReport(u.token);
    expect([failed.status, failed.body]).toEqual([500, { error: 'Failed to build report.' }]);
    expect(raw).toHaveBeenCalled();
    expect((await getReport(u.token)).status).toBe(200);
  }, SLOW);

  test('R-10 one slot per shared call; a rejected shared promise is handled', async () => {
    const u = await seededUser(app);
    ai.next(async (req) => { await wait(300); return defaultReport(req); });
    const [a, b] = await Promise.all([getReport(u.token), getReport(u.token)]);
    expect(a.body.ai.status).toBe('ready');
    expect(b.body.ai.status).toBe('ready');
    expect(a.body.ai.createdAt).toBe(b.body.ai.createdAt);
    expect(ai.create).toHaveBeenCalledTimes(1);
    expect((await usageRow(u.user.id, 'report')).count).toBe(1);

    // (2) The re-read inside the shared promise rejects: 500, no unhandled
    // rejection (jest-circus would fail this test), and the next GET works.
    const spy = jest.spyOn(prisma.aiReport, 'findUnique')
      .mockResolvedValueOnce(null)
      .mockRejectedValueOnce(new Error('db'));
    const res = await getReport(u.token, 'period=3m');
    expect([res.status, res.body]).toEqual([500, { error: 'Failed to build report.' }]);
    await new Promise((r) => setImmediate(r));
    expect(spy).toHaveBeenCalledTimes(2);
    expect((await getReport(u.token, 'period=3m')).status).toBe(200);
  }, SLOW);

  test('R-11 the saved row is read again inside the shared promise', async () => {
    const u = await seededUser(app);
    expect((await getReport(u.token)).body.ai.cached).toBe(false);
    const spy = jest.spyOn(prisma.aiReport, 'findUnique').mockResolvedValueOnce(null);
    const res = await getReport(u.token);
    expect(res.body.ai).toMatchObject({ status: 'ready', cached: true });
    expect(ai.create).toHaveBeenCalledTimes(1);
    expect((await usageRow(u.user.id, 'report')).count).toBe(1);
    expect(spy).toHaveBeenCalled();
  }, SLOW);
});

describe('POST /api/ai/report/email', () => {
  test('E-1 unverified: 403, nothing sent, no slot', async () => {
    const u = await seededUser(app);
    const res = await emailReport(u.token);
    expect([res.status, res.body]).toEqual([403, { error: 'Verify your email first to get reports by email.' }]);
    expect(mailer.sentReports).toHaveLength(0);
    expect(await usageRow(u.user.id, 'report_email')).toBeNull();
  }, SLOW);

  test('E-2 verified: sent to their address; a viewed report is reused', async () => {
    const u = await seededUser(app);
    await verifyUser(u.user.id);
    await getReport(u.token);
    expect(ai.create).toHaveBeenCalledTimes(1);
    const res = await emailReport(u.token);
    expect([res.status, res.body]).toEqual([200, { message: `Report sent to ${u.email}.` }]);
    expect(mailer.sentReports).toHaveLength(1);
    expect(mailer.sentReports[0].to).toBe(u.email);
    expect(mailer.sentReports[0].report.totals.total).toBe(287.99);
    expect(mailer.sentReports[0].report.ai.cached).toBe(true);
    expect(ai.create).toHaveBeenCalledTimes(1);
  }, SLOW);

  test('E-8 no saved AI text: sent without a new Claude call; tz passed on', async () => {
    const u = await seededUser(app);
    await verifyUser(u.user.id);
    const res = await emailReport(u.token);
    expect(res.status).toBe(200);
    expect(ai.create).not.toHaveBeenCalled();
    expect(mailer.sentReports[0].report.ai.status).toBe('unavailable');
    expect(mailer.sentReports[0].report.totals.total).toBe(287.99);
    expect(mailer.sentReports[0].tz).toBe(180);
    expect(await usageRow(u.user.id, 'report')).toBeNull();
  }, SLOW);

  test('E-3 no key: still sent, AI unavailable', async () => {
    const u = await seededUser(app);
    await verifyUser(u.user.id);
    const res = await emailReport(u.token, undefined, makeApp({ aiClient: null }));
    expect(res.status).toBe(200);
    expect(mailer.sentReports[0].report.ai.status).toBe('unavailable');
  }, SLOW);

  test('E-4 burst limit and daily cap', async () => {
    const u = await seededUser(app);
    await verifyUser(u.user.id);
    const burst = makeApp({ aiClient: ai.client, rateLimit: { aiReportEmail: { limit: 1 } } });
    expect((await emailReport(u.token, undefined, burst)).status).toBe(200);
    const second = await emailReport(u.token, undefined, burst);
    expect([second.status, second.body]).toEqual([429, { error: 'Too many report emails. Try again later.' }]);
    // E-7: the burst rejection used no daily slot.
    expect((await usageRow(u.user.id, 'report_email')).count).toBe(1);

    const v = await seededUser(app);
    await verifyUser(v.user.id);
    const capped = makeApp({ aiClient: ai.client, aiCaps: { emailPerDay: 1 } });
    expect((await emailReport(v.token, undefined, capped)).status).toBe(200);
    const over = await emailReport(v.token, undefined, capped);
    expect([over.status, over.body]).toEqual([429, { error: "You've reached today's limit of 1 report emails. Try again tomorrow." }]);
  }, SLOW);

  test('E-5 mailer failure: 502', async () => {
    const u = await seededUser(app);
    await verifyUser(u.user.id);
    mailer.sendReportEmail.mockRejectedValueOnce(new Error('smtp down'));
    const res = await emailReport(u.token);
    expect([res.status, res.body]).toEqual([502, { error: 'Could not send the email. Try again later.' }]);
  }, SLOW);

  test('E-6 validation and auth', async () => {
    const u = await registerUser(app);
    const res = await emailReport(u.token, { period: 'week' });
    expect([res.status, res.body]).toEqual([400, { error: 'period must be 1m, 3m, 6m, 1y or custom.' }]);
    expect((await request(app).post('/api/ai/report/email').send({ period: '1m' })).status).toBe(401);
  }, SLOW);
});
