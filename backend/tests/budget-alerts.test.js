jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const http = require('http');
const request = require('supertest');
const { io: connectClient } = require('socket.io-client');
const prisma = require('../src/lib/prisma');
const { createApp } = require('../src/app');
const { initRealtime, closeRealtime } = require('../src/lib/realtime');
const { monthWindow } = require('../src/lib/budgets');
const { budgetChecksIdle } = require('../src/lib/budgetAlerts');
const { sendBudgetAlertEmail, sentBudgetAlerts } = require('./mailerMock');
const { registerUser, verifyUser, createTestStore, cleanup } = require('./helpers');

// Many DB round trips per test; the default 30 s is too tight on the pooler.
const SLOW = 120_000;
const STORE_KEYS = ['createdAt', 'customerFirstName', 'pointsEarned', 'receiptId', 'totalAmount'];

let server, url, app, food, market;
const sockets = [];

const auth = (token) => ({ Authorization: `Bearer ${token}` });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Poll fn() until it returns a truthy value (or fail after ms).
async function waitFor(fn, ms = 5000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > end) throw new Error('waitFor timed out');
    await sleep(50);
  }
}

// A connected socket that records every budget:alert and receipt:new, in order.
async function listen(token) {
  const socket = connectClient(url, {
    auth: { token }, transports: ['websocket'], reconnection: false, forceNew: true,
  });
  sockets.push(socket);
  const events = [];
  socket.on('receipt:new', (e) => events.push({ type: 'receipt', id: e.receipt.id }));
  socket.on('budget:alert', (e) => events.push({ type: 'alert', ...e }));
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve);
    socket.once('connect_error', reject);
  });
  return { socket, events, alerts: () => events.filter((e) => e.type === 'alert') };
}

// A store receipt of [amount] JD; resolves after the background budget check
// has finished (and a short pause for the socket to deliver).
async function buy(user, amount, shop = food) {
  const res = await request(app).post('/api/store/receipts').set('X-Store-Key', shop.key)
    .send({ customerSerial: user.user.serialNumber, items: [{ name: 'Meal', qty: 1, unitPrice: amount }], totalAmount: amount });
  expect(res.status).toBe(201);
  await budgetChecksIdle();
  await sleep(150);
  return res;
}

const setBudget = (user, category, limit) =>
  request(app).put('/api/budgets').set(auth(user.token)).send({ category, limit });
const emailsTo = (user) => sentBudgetAlerts.filter((m) => m.to === user.email);
const alertRows = (user) => prisma.budgetAlert.findMany({
  where: { userId: user.user.id }, orderBy: { level: 'asc' },
});

// A verified user with a Food budget of [limit] JD and an open socket.
async function verifiedWithBudget(limit = 10, { verified = true } = {}) {
  const user = await registerUser(app);
  if (verified) await verifyUser(user.user.id);
  user.email = user.user.email;
  expect((await setBudget(user, 'Food', limit)).status).toBe(200);
  user.live = await listen(user.token);
  return user;
}

beforeAll(async () => {
  app = createApp({ rateLimit: false });
  server = http.createServer(app);
  initRealtime(server);
  await new Promise((r) => server.listen(0, r));
  url = `http://localhost:${server.address().port}`;
  food = await createTestStore('Food');
  market = await createTestStore('Supermarket');
}, SLOW);

afterAll(async () => {
  await budgetChecksIdle();
  for (const s of sockets) s.disconnect();
  await closeRealtime();
  await new Promise((r) => server.close(r));
  await cleanup();
});

beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

test('A-1 done-when: crossing 80% then 100% alerts the phone and emails, once each', async () => {
  const u = await verifiedWithBudget(10);

  const first = await buy(u, 8.5);
  const a80 = await waitFor(() => u.live.alerts()[0]);
  expect(a80).toMatchObject({
    receiptId: first.body.receiptId, category: 'Food', level: 80, percent: 85,
    spent: 8.5, limit: 10, remaining: 1.5, overBy: 0, month: monthWindow(new Date(), 180).month,
  });
  // receipt:new first, then its budget:alert.
  expect(u.live.events.map((e) => e.type)).toEqual(['receipt', 'alert']);
  expect(emailsTo(u)).toHaveLength(1);
  expect(emailsTo(u)[0].alert.level).toBe(80);

  await buy(u, 1); // 95%: 80 already fired
  expect(u.live.alerts()).toHaveLength(1);
  expect(emailsTo(u)).toHaveLength(1);

  const third = await buy(u, 1); // 105%
  const a100 = await waitFor(() => u.live.alerts()[1]);
  expect(a100).toMatchObject({ receiptId: third.body.receiptId, level: 100, percent: 105, overBy: 0.5 });
  expect(emailsTo(u)).toHaveLength(2);

  await buy(u, 1); // nothing left to fire
  expect(u.live.alerts()).toHaveLength(2);
  expect(emailsTo(u)).toHaveLength(2);

  const list = await request(app).get('/api/budgets').set(auth(u.token));
  expect(list.body.budgets[0]).toMatchObject({ category: 'Food', spent: 11.5, level: 'over' });
  expect((await alertRows(u)).map((r) => [r.level, r.emailed])).toEqual([[80, true], [100, true]]);
}, SLOW);

test('A-2 one receipt from 0 to 120% gives one alert (100) and one email', async () => {
  const u = await verifiedWithBudget(10);
  await buy(u, 12);
  expect(u.live.alerts().map((a) => a.level)).toEqual([100]);
  expect(emailsTo(u)).toHaveLength(1);
  expect((await alertRows(u)).map((r) => r.level)).toEqual([80, 100]);
  await buy(u, 1);
  expect(u.live.alerts()).toHaveLength(1);
}, SLOW);

test('A-3 budgetAlertEmails off: live alert, no email, emailed stays false', async () => {
  const u = await verifiedWithBudget(10);
  await request(app).patch('/api/user/notifications').set(auth(u.token)).send({ budgetAlertEmails: false });
  await buy(u, 9);
  expect(u.live.alerts()).toHaveLength(1);
  expect(emailsTo(u)).toHaveLength(0);
  expect((await alertRows(u))[0].emailed).toBe(false);
}, SLOW);

test('A-4 unverified email: live alert, no email', async () => {
  const u = await verifiedWithBudget(10, { verified: false });
  await buy(u, 9);
  expect(u.live.alerts()).toHaveLength(1);
  expect(emailsTo(u)).toHaveLength(0);
}, SLOW);

test('A-5 a Supermarket receipt with only a Food budget fires nothing', async () => {
  const u = await verifiedWithBudget(10);
  await buy(u, 50, market);
  expect(u.live.alerts()).toHaveLength(0);
  expect(await alertRows(u)).toHaveLength(0);
}, SLOW);

test('A-6 no budgets: the store reply keeps its keys, no alert', async () => {
  const u = await registerUser(app);
  const live = await listen(u.token);
  const res = await buy(u, 500);
  expect(Object.keys(res.body).sort()).toEqual(STORE_KEYS);
  expect(live.alerts()).toHaveLength(0);
}, SLOW);

test('A-7 a failing budget check never breaks the receipt', async () => {
  const u = await verifiedWithBudget(10);
  const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
  const real = prisma.$queryRaw.bind(prisma);
  jest.spyOn(prisma, '$queryRaw').mockImplementation((strings, ...values) => {
    if (strings.join('?').includes('JOIN nexus_users u ON u.id = b."userId"')) {
      return Promise.reject(new Error('db down'));
    }
    return real(strings, ...values);
  });
  const res = await buy(u, 9);
  expect(Object.keys(res.body).sort()).toEqual(STORE_KEYS);
  await waitFor(() => u.live.events.some((e) => e.type === 'receipt'));
  expect(u.live.alerts()).toHaveLength(0);
  expect(errors).toHaveBeenCalledWith('[store/receipts] budget check failed', 'db down');
}, SLOW);

test('A-8 two parallel receipts that each reach 80% fire one 80 alert', async () => {
  const u = await verifiedWithBudget(10);
  await prisma.receipt.create({
    data: { userId: u.user.id, storeName: 'Shop', category: 'Food', totalAmount: 7, items: ['x'] },
  });
  // Each alone: 80%; both: 90%.
  await Promise.all([buy(u, 1), buy(u, 1)]);
  await budgetChecksIdle();
  await sleep(200);
  expect(u.live.alerts().map((a) => a.level)).toEqual([80]);
  expect(emailsTo(u)).toHaveLength(1);
  expect(await alertRows(u)).toHaveLength(1);
}, SLOW);

test('A-9 a changed budget can warn again; the same amount resets nothing', async () => {
  const u = await verifiedWithBudget(10);
  await buy(u, 11.5);
  expect(u.live.alerts().map((a) => a.level)).toEqual([100]);

  await setBudget(u, 'Food', 20); // 57%: alerts for this month reset
  expect(await alertRows(u)).toHaveLength(0);
  await buy(u, 5); // 82%
  expect(u.live.alerts().map((a) => a.level)).toEqual([100, 80]);

  await setBudget(u, 'Food', 20); // same amount: the 80 row stays
  expect(await alertRows(u)).toHaveLength(1);
  await buy(u, 0.5); // 85%
  expect(u.live.alerts()).toHaveLength(2);
}, SLOW);

test("A-10 user B's socket gets no alert for A's receipt", async () => {
  const a = await verifiedWithBudget(10);
  const b = await registerUser(app);
  const liveB = await listen(b.token);
  await buy(a, 9);
  expect(a.live.alerts()).toHaveLength(1);
  expect(liveB.events).toHaveLength(0);
}, SLOW);

test('A-11 receipts from last month do not count', async () => {
  const u = await verifiedWithBudget(10);
  const w = monthWindow(new Date(), 180);
  await prisma.receipt.create({
    data: {
      userId: u.user.id, storeName: 'Shop', category: 'Food', totalAmount: 100, items: ['x'],
      createdAt: new Date(w.fromUtc.getTime() - 1000),
    },
  });
  await buy(u, 1);
  expect(u.live.alerts()).toHaveLength(0);
}, SLOW);

test('A-12 the mailer throws: the alert still arrives and the error is logged', async () => {
  const u = await verifiedWithBudget(10);
  const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
  sendBudgetAlertEmail.mockRejectedValueOnce(new Error('smtp down'));
  const res = await buy(u, 9);
  expect(Object.keys(res.body).sort()).toEqual(STORE_KEYS);
  expect(u.live.alerts()).toHaveLength(1);
  expect(errors).toHaveBeenCalledWith(`[budget/alert] email failed user=${u.user.id}`, 'smtp down');
  expect((await alertRows(u))[0].emailed).toBe(false);
}, SLOW);
