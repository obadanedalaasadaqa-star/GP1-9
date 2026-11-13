jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const prisma = require('../src/lib/prisma');
const { runWeeklySummaries } = require('../src/lib/weeklyJob');
const { latestWeek } = require('../src/lib/weeklySummary');
const { localDayToUtc, addDays } = require('../src/lib/aiDates');
const { sendWeeklySummaryEmail, sentWeekly } = require('./mailerMock');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many DB round trips per test; the default 30 s is too tight on the pooler.
const SLOW = 120_000;

// Always userIds: the job must never touch real accounts in the shared DB.
const NOW = new Date();
const WEEK = latestWeek(NOW, 180);
const app = makeApp();

// A user with the weekly email set as given and receipts on [days] of the
// latest week (0 = its Sunday) and [previousDays] of the week before.
async function weeklyUser({ on = true, verified = true, days = [1, 3], previousDays = [2] } = {}) {
  const u = await registerUser(app);
  await prisma.user.update({
    where: { id: u.user.id },
    data: { weeklySummaryEmails: on, emailVerified: verified, tzOffsetMinutes: 180 },
  });
  const at = (date) => new Date(localDayToUtc(date, 180).getTime() + 12 * 3600 * 1000); // local noon
  const rows = [
    ...days.map((d) => ({ date: addDays(WEEK.from, d), amount: 10, category: 'Food' })),
    ...previousDays.map((d) => ({ date: addDays(WEEK.from, d - 7), amount: 5, category: 'Food' })),
  ];
  for (const r of rows) {
    await prisma.receipt.create({
      data: { userId: u.user.id, storeName: 'KFC', category: r.category, totalAmount: r.amount, items: ['x'], createdAt: at(r.date) },
    });
  }
  return { id: u.user.id, email: u.user.email };
}

const run = (users, opts = {}) => runWeeklySummaries({ now: NOW, userIds: users.map((u) => u.id), ...opts });
const mailsTo = (u) => sentWeekly.filter((m) => m.to === u.email);
const sentWeek = async (u) => (await prisma.user.findUnique({ where: { id: u.id } })).weeklySummarySentWeek;

afterAll(cleanup);
beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

test('W-1 one email with the right totals; a second run sends nothing', async () => {
  const u = await weeklyUser();
  expect(await run([u])).toEqual({ sent: 1, skipped: 0, failed: 0 });
  const [mail] = mailsTo(u);
  expect(mail.summary).toMatchObject({
    label: WEEK.label, total: 20, receipts: 2, previousTotal: 5, difference: 15, changePercent: 300,
  });
  expect(mail.summary.topCategories).toEqual([{ category: 'Food', total: 20, count: 2 }]);
  expect(await sentWeek(u)).toBe(WEEK.key);

  expect(await run([u])).toEqual({ sent: 0, skipped: 1, failed: 0 });
  expect(mailsTo(u)).toHaveLength(1);
}, SLOW);

test('W-2/W-3 opted out or unverified: nothing', async () => {
  const off = await weeklyUser({ on: false });
  const unverified = await weeklyUser({ verified: false });
  expect(await run([off, unverified])).toEqual({ sent: 0, skipped: 0, failed: 0 });
  expect(mailsTo(off)).toHaveLength(0);
  expect(mailsTo(unverified)).toHaveLength(0);
}, SLOW);

test('W-4 no receipts in the week: no email, skipped, week saved', async () => {
  const u = await weeklyUser({ days: [] });
  expect(await run([u])).toEqual({ sent: 0, skipped: 1, failed: 0 });
  expect(mailsTo(u)).toHaveLength(0);
  expect(await sentWeek(u)).toBe(WEEK.key);
}, SLOW);

test('W-5 the mailer throws once: failed, week given back, the next run sends', async () => {
  const u = await weeklyUser();
  const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
  sendWeeklySummaryEmail.mockRejectedValueOnce(new Error('smtp down'));
  expect(await run([u])).toEqual({ sent: 0, skipped: 0, failed: 1 });
  expect(await sentWeek(u)).toBeNull();
  expect(errors).toHaveBeenCalledWith(`[weekly] user=${u.id} failed`, 'smtp down');
  expect(await run([u])).toEqual({ sent: 1, skipped: 0, failed: 0 });
}, SLOW);

test('W-6 force sends again for the same week', async () => {
  const u = await weeklyUser();
  await run([u]);
  expect(await run([u], { force: true })).toEqual({ sent: 1, skipped: 0, failed: 0 });
  expect(mailsTo(u)).toHaveLength(2);
}, SLOW);

test('W-7 two runs in parallel send one email', async () => {
  const u = await weeklyUser();
  const results = await Promise.all([run([u]), run([u])]);
  expect(results.reduce((n, r) => n + r.sent, 0)).toBe(1);
  expect(mailsTo(u)).toHaveLength(1);
}, SLOW);

test('W-8 with a batch of 1, the next run takes the user still behind', async () => {
  const a = await weeklyUser();
  const b = await weeklyUser();
  expect((await run([a, b], { limit: 1 })).sent).toBe(1);
  expect((await run([a, b], { limit: 1 })).sent).toBe(1);
  expect(mailsTo(a)).toHaveLength(1);
  expect(mailsTo(b)).toHaveLength(1);
}, SLOW);
