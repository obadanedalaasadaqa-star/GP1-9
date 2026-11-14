jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const path = require('path');
const { execFile } = require('child_process');
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { resetDemoAccount, buildDemoData } = require('../src/lib/demoData');
const { PASSWORD, makeApp, registerUser, track, cleanup } = require('./helpers');

// resetDemoAccount on a throwaway test user (never the real demo account).
// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 120_000;
const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });

afterAll(cleanup);

test('reset replaces the data, keeps the account, and is repeatable', async () => {
  const u = await registerUser(app);
  const id = u.user.id;
  for (const totalAmount of [5, 7.5]) {
    const res = await request(app).post('/api/receipts').set(auth(u.token))
      .send({ storeName: 'Old Shop', category: 'Food', totalAmount, items: ['x'] });
    expect(res.status).toBe(201);
  }
  await prisma.budget.create({ data: { userId: id, category: 'Pharmacy', monthlyLimit: 9 } });
  await prisma.aiInsight.create({
    data: { userId: id, inputHash: 'h', summary: 's', tip: 't', model: 'm' },
  });
  await prisma.user.update({ where: { id }, data: { emailVerified: true, loginTwoFactor: true } });
  const before = await prisma.user.findUnique({ where: { id } });

  const now = new Date();
  const expected = buildDemoData(now, before.tzOffsetMinutes);
  const first = await resetDemoAccount(prisma, id, now);
  expect(first).toEqual({
    receipts: expected.receipts.length, budgets: expected.budgets.length, points: expected.points,
  });

  const receipts = await prisma.receipt.findMany({ where: { userId: id } });
  expect(receipts).toHaveLength(expected.receipts.length);
  expect(receipts.some((r) => r.storeName === 'Old Shop')).toBe(false);
  const budgets = await prisma.budget.findMany({ where: { userId: id } });
  expect(budgets.map((b) => b.category).sort()).toEqual(expected.budgets.map((b) => b.category).sort());
  expect(await prisma.aiInsight.findUnique({ where: { userId: id } })).toBeNull();
  expect(await prisma.verificationCode.count({ where: { userId: id } })).toBe(0);

  const after = await prisma.user.findUnique({ where: { id } });
  expect(after.loyaltyPoints).toBe(expected.points);
  expect(after.loginTwoFactor).toBe(false);
  for (const key of ['email', 'password', 'serialNumber', 'emailVerified', 'firstName', 'lastName',
    'tzOffsetMinutes', 'budgetAlertEmails', 'weeklySummaryEmails']) {
    expect(after[key]).toEqual(before[key]);
  }
  // The session still works.
  expect((await request(app).get('/api/user/me').set(auth(u.token))).status).toBe(200);

  const second = await resetDemoAccount(prisma, id, now);
  expect(second).toEqual(first);
  expect(await prisma.receipt.count({ where: { userId: id } })).toBe(expected.receipts.length);
  expect(await prisma.budget.count({ where: { userId: id } })).toBe(expected.budgets.length);
}, SLOW);

test('an unknown user id throws and writes nothing', async () => {
  await expect(resetDemoAccount(prisma, '00000000-0000-0000-0000-000000000000')).rejects.toThrow('User not found.');
});

// The script itself, as a dry run only (never --yes on a real match). DEMO_EMAIL
// is '' in the child so a developer's .env value is not used.
const SCRIPT = path.join(__dirname, '..', 'scripts', 'demo-reset.js');
const runScript = (...args) => new Promise((resolve) => {
  execFile('node', [SCRIPT, ...args], { env: { ...process.env, DEMO_EMAIL: '' } },
    (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr }));
});

test('script: the email must match exactly (letter case too)', async () => {
  // Not test_…: the script refuses those. Tracked, so cleanup() deletes it.
  const email = `demoreset_${Date.now()}@nexus.test`;
  const res = await request(app).post('/api/auth/register')
    .send({ firstName: 'Demo', lastName: 'Reset', email, password: PASSWORD });
  expect(res.status).toBe(201);
  track(res.body.user.id);

  const exact = await runScript(email);
  expect(exact.code).toBe(0);
  expect(exact.stdout).toContain(`Account: ${email}`);
  expect(exact.stdout).toContain('Dry run.');

  const upper = email.toUpperCase();
  const otherCase = await runScript(upper);
  expect(otherCase.code).toBe(1);
  expect(otherCase.stderr).toContain(`No user with the email ${upper}.`);
}, SLOW);
