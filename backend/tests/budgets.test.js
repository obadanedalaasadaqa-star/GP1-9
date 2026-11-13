jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { monthWindow, LIMIT_ERROR, DECIMALS_ERROR, CATEGORY_ERROR, BODY_ERROR } = require('../src/lib/budgets');
const { TZ_ERROR } = require('../src/lib/aiDates');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const KNOWN = ['Clothing', 'Electronics', 'Food', 'Pharmacy', 'Supermarket'];

const getBudgets = (token, query = {}) => request(app).get('/api/budgets').set(auth(token)).query(query);
const putBudget = (token, body) => request(app).put('/api/budgets').set(auth(token)).send(body);
const deleteBudget = (token, category) =>
  request(app).delete(`/api/budgets/${encodeURIComponent(category)}`).set(auth(token));

function addReceipt(userId, category, totalAmount, createdAt = new Date()) {
  return prisma.receipt.create({
    data: { userId, storeName: 'Shop', category, totalAmount, items: ['Item'], createdAt },
  });
}

afterAll(cleanup);
beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

test('B-1 a new user has no budgets, the 5 known categories and this month at tz 180', async () => {
  const a = await registerUser(app);
  const res = await getBudgets(a.token);
  expect(res.status).toBe(200);
  const w = monthWindow(new Date(), 180);
  expect(res.body).toEqual({
    month: w.month, label: w.label, from: w.fromUtc.toISOString(), to: w.toUtc.toISOString(),
    tzOffsetMinutes: 180, budgets: [], categories: KNOWN,
  });
}, SLOW);

test('B-2/B-3 PUT creates, then updates the same row', async () => {
  const a = await registerUser(app);
  let res = await putBudget(a.token, { category: 'Food', limit: 50 });
  expect(res.status).toBe(200);
  expect(res.body.budgets).toEqual([{
    category: 'Food', limit: 50, spent: 0, remaining: 50, overBy: 0, percent: 0, level: 'ok',
  }]);

  res = await putBudget(a.token, { category: 'Food', limit: 25.5 });
  expect(res.status).toBe(200);
  expect(res.body.budgets).toHaveLength(1);
  expect(res.body.budgets[0].limit).toBe(25.5);
  expect(await prisma.budget.count({ where: { userId: a.user.id } })).toBe(1);
}, SLOW);

test('B-4 every 400 with its exact message', async () => {
  const a = await registerUser(app);
  const cases = [
    [[1, 2], BODY_ERROR],
    [{ category: '', limit: 10 }, CATEGORY_ERROR],
    [{ category: 'x'.repeat(41), limit: 10 }, CATEGORY_ERROR],
    [{ category: 'Food', limit: 0 }, LIMIT_ERROR],
    [{ category: 'Food', limit: '10' }, LIMIT_ERROR],
    [{ category: 'Food', limit: 100001 }, LIMIT_ERROR],
    [{ category: 'Food', limit: 10.1234 }, DECIMALS_ERROR],
    [{ category: 'Food', limit: 10, tzOffsetMinutes: 'x' }, TZ_ERROR],
  ];
  for (const [body, error] of cases) {
    const res = await putBudget(a.token, body);
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error });
  }
  expect(LIMIT_ERROR).toBe('Budget must be a number between 1 and 100000 JD.');

  // Broken JSON and broken percent-encoding are 400s, not 500s.
  const broken = await request(app).put('/api/budgets').set(auth(a.token))
    .set('Content-Type', 'application/json').send('{"category":');
  expect(broken.status).toBe(400);
  const badPath = await request(app).delete('/api/budgets/%E0').set(auth(a.token));
  expect(badPath.status).toBe(400);
  expect(badPath.body).toEqual({ error: 'Invalid request.' });
  const blank = await request(app).delete('/api/budgets/%20').set(auth(a.token));
  expect(blank.status).toBe(400);
  expect(blank.body).toEqual({ error: CATEGORY_ERROR });
  const badTz = await request(app).delete('/api/budgets/Food?tzOffsetMinutes=999').set(auth(a.token));
  expect(badTz.body).toEqual({ error: TZ_ERROR });
}, SLOW);

test('B-5 at most 20 budgets; one of the 20 can still be changed', async () => {
  const a = await registerUser(app);
  await prisma.budget.createMany({
    data: Array.from({ length: 20 }, (_, i) => ({ userId: a.user.id, category: `Cat ${i}`, monthlyLimit: 10 })),
  });
  const res = await putBudget(a.token, { category: 'Food', limit: 10 });
  expect(res.status).toBe(400);
  expect(res.body).toEqual({ error: 'You can have up to 20 budgets.' });
  const update = await putBudget(a.token, { category: 'Cat 3', limit: 99 });
  expect(update.status).toBe(200);
  expect(update.body.budgets).toHaveLength(20);
  expect(update.body.budgets.find((b) => b.category === 'Cat 3').limit).toBe(99);
}, SLOW);

test('B-5 two parallel PUTs at 19 budgets give 20, not 21', async () => {
  const a = await registerUser(app);
  await prisma.budget.createMany({
    data: Array.from({ length: 19 }, (_, i) => ({ userId: a.user.id, category: `Cat ${i}`, monthlyLimit: 10 })),
  });
  const results = await Promise.all([
    putBudget(a.token, { category: 'New A', limit: 10 }),
    putBudget(a.token, { category: 'New B', limit: 10 }),
  ]);
  expect(results.map((r) => r.status).sort()).toEqual([200, 400]);
  expect(await prisma.budget.count({ where: { userId: a.user.id } })).toBe(20);
}, SLOW);

test('B-6 DELETE removes, a second DELETE is 404, names with spaces work', async () => {
  const a = await registerUser(app);
  await putBudget(a.token, { category: 'Food & Drinks', limit: 30 });
  await putBudget(a.token, { category: 'Food', limit: 30 });
  let res = await deleteBudget(a.token, 'Food & Drinks');
  expect(res.status).toBe(200);
  expect(res.body.budgets.map((b) => b.category)).toEqual(['Food']);
  res = await deleteBudget(a.token, 'Food & Drinks');
  expect(res.status).toBe(404);
  expect(res.body).toEqual({ error: 'No budget for this category.' });
}, SLOW);

test('B-7 no token is 401 on all three', async () => {
  for (const req of [
    request(app).get('/api/budgets'),
    request(app).put('/api/budgets').send({ category: 'Food', limit: 5 }),
    request(app).delete('/api/budgets/Food'),
  ]) {
    expect((await req).status).toBe(401);
  }
});

test('B-8 each bar equals the Trends category total for the same month', async () => {
  const a = await registerUser(app);
  const w = monthWindow(new Date(), 180);
  await addReceipt(a.user.id, 'Food', 12.345, new Date(w.fromUtc.getTime() + 60_000));
  await addReceipt(a.user.id, 'Food', 0.1);
  await addReceipt(a.user.id, 'Food', 0.2);
  await addReceipt(a.user.id, 'Pharmacy', 7.5);
  // Last month (one second before the window) and a category without a budget.
  await addReceipt(a.user.id, 'Food', 100, new Date(w.fromUtc.getTime() - 1000));
  await addReceipt(a.user.id, 'Clothing', 40);
  await putBudget(a.token, { category: 'Food', limit: 20 });
  const res = await putBudget(a.token, { category: 'Pharmacy', limit: 10 });

  const stats = await request(app).get('/api/user/stats').set(auth(a.token))
    .query({ bounds: `${res.body.from},${res.body.to}` });
  expect(stats.status).toBe(200);
  const byCategory = Object.fromEntries(stats.body.periods[0].byCategory.map((c) => [c.category, c.total]));
  for (const b of res.body.budgets) {
    expect(b.spent).toBeCloseTo(byCategory[b.category], 3);
  }
  expect(res.body.budgets.find((b) => b.category === 'Food').spent).toBe(12.645);
  // Budgets sorted by percent: Pharmacy 75%, Food 63%.
  expect(res.body.budgets.map((b) => [b.category, b.percent])).toEqual([['Pharmacy', 75], ['Food', 63]]);
}, SLOW);

test("B-9 user B never sees or deletes A's budgets", async () => {
  const a = await registerUser(app);
  const b = await registerUser(app);
  await putBudget(a.token, { category: 'Food', limit: 10 });
  expect((await getBudgets(b.token)).body.budgets).toEqual([]);
  expect((await deleteBudget(b.token, 'Food')).status).toBe(404);
  expect((await getBudgets(a.token)).body.budgets).toHaveLength(1);
}, SLOW);

test('B-10 tz: a PUT saves it, a PUT without it keeps it, GET is read-only', async () => {
  const a = await registerUser(app);
  const savedTz = async () => (await prisma.user.findUnique({ where: { id: a.user.id } })).tzOffsetMinutes;

  await putBudget(a.token, { category: 'Food', limit: 10, tzOffsetMinutes: -300 });
  expect(await savedTz()).toBe(-300);
  const res = await putBudget(a.token, { category: 'Food', limit: 12 });
  expect(res.body.tzOffsetMinutes).toBe(-300);
  expect(await savedTz()).toBe(-300);

  const get = await getBudgets(a.token, { tzOffsetMinutes: 60 });
  expect(get.body.tzOffsetMinutes).toBe(60);
  expect(get.body.from).toBe(monthWindow(new Date(), 60).fromUtc.toISOString());
  expect(await savedTz()).toBe(-300);
  expect((await getBudgets(a.token)).body.tzOffsetMinutes).toBe(-300);

  const bad = await getBudgets(a.token, { tzOffsetMinutes: 'bad' });
  expect(bad.status).toBe(400);
  expect(bad.body).toEqual({ error: TZ_ERROR });
}, SLOW);

test('B-11 deleting the user deletes its budgets and alert rows', async () => {
  const a = await registerUser(app);
  await putBudget(a.token, { category: 'Food', limit: 10 });
  await prisma.budgetAlert.create({
    data: { userId: a.user.id, category: 'Food', month: '2026-11', level: 80, spent: 8, monthlyLimit: 10 },
  });
  await prisma.user.delete({ where: { id: a.user.id } });
  expect(await prisma.budget.count({ where: { userId: a.user.id } })).toBe(0);
  expect(await prisma.budgetAlert.count({ where: { userId: a.user.id } })).toBe(0);
}, SLOW);

test('categories add recent receipt categories and budgeted ones, A-Z', async () => {
  const a = await registerUser(app);
  await addReceipt(a.user.id, 'Bakery', 3);
  await addReceipt(a.user.id, 'Old Stuff', 3, new Date(Date.now() - 200 * 24 * 3600 * 1000));
  await addReceipt(a.user.id, '  Spaced  ', 3);
  const res = await putBudget(a.token, { category: 'Zoo', limit: 5 });
  expect(res.body.categories).toEqual(['Bakery', ...KNOWN, 'Zoo']);
}, SLOW);

test('the budgets limiter runs after auth on PUT and DELETE, never on GET', async () => {
  const limited = makeApp({ rateLimit: { budgets: { limit: 2 } } });
  const a = await registerUser(limited);
  const put = () => request(limited).put('/api/budgets').set(auth(a.token)).send({ category: 'Food', limit: 5 });
  expect((await put()).status).toBe(200);
  expect((await put()).status).toBe(200);
  const third = await put();
  expect(third.status).toBe(429);
  expect(third.body).toEqual({ error: 'Too many budget changes. Try again in a few minutes.' });
  const del = await request(limited).delete('/api/budgets/Food').set(auth(a.token));
  expect(del.status).toBe(429);
  for (let i = 0; i < 3; i++) {
    expect((await request(limited).get('/api/budgets').set(auth(a.token))).status).toBe(200);
  }
  // Keyed by user: another user still has their own budget.
  const b = await registerUser(limited);
  const other = await request(limited).put('/api/budgets').set(auth(b.token)).send({ category: 'Food', limit: 5 });
  expect(other.status).toBe(200);
}, SLOW);
