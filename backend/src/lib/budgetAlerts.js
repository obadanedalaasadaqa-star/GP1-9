// Budget alerts: after a store receipt is saved, warn the user live
// (Socket.IO 'budget:alert') and by email when a category reaches 80% or 100%
// of its monthly budget. Each level fires at most once per category per month
// (the primary key of nexus_budget_alerts).
// prisma and mailer are used through the shared objects at call time (never
// destructured), so tests can spy on them.
const prisma = require('./prisma');
const mailer = require('./mailer');
const { emitToUser } = require('./realtime');
const { LEVELS, monthWindow, levelFor, budgetStatus } = require('./budgets');

// Checks still running (they start after the store's 201), so tests can wait
// for them before closing the DB.
const pending = new Set();

/**
 * Check the receipt's category against its budget. receipt = { id, userId,
 * category, createdAt }. Returns the alert payload, or null when nothing
 * fired (no budget, under 80%, or this level already fired this month).
 * Never throws for the email: mail errors are logged.
 */
function checkBudgetAfterReceipt(receipt) {
  const run = runCheck(receipt);
  pending.add(run);
  const done = () => pending.delete(run);
  run.then(done, done);
  return run;
}

async function runCheck({ id, userId, category, createdAt }) {
  const rows = await prisma.$queryRaw`
    SELECT b."monthlyLimit", u."tzOffsetMinutes", u."budgetAlertEmails", u."emailVerified",
           u.email, u."firstName"
      FROM nexus_budgets b
      JOIN nexus_users u ON u.id = b."userId"
     WHERE b."userId" = ${userId} AND b.category = ${category}
  `;
  if (!rows.length) return null;
  const user = rows[0];
  const limit = user.monthlyLimit;

  // This month in the user's zone, this receipt included.
  const w = monthWindow(createdAt, user.tzOffsetMinutes);
  const [{ spent }] = await prisma.$queryRaw`
    SELECT COALESCE(SUM("totalAmount"), 0)::float8 AS spent
      FROM nexus_receipts
     WHERE "userId" = ${userId} AND category = ${category}
       AND "createdAt" >= ${w.fromUtc} AND "createdAt" < ${w.toUtc}
  `;
  const reached = levelFor(spent, limit);
  if (reached === 0) return null;

  // Claim every level reached in one statement; parallel receipts can't both
  // fire the same level. Crossing 80 and 100 at once gives one alert (100).
  const levels = LEVELS.filter((l) => l <= reached);
  const inserted = await prisma.$queryRaw`
    INSERT INTO nexus_budget_alerts ("userId", category, month, level, spent, "monthlyLimit", "receiptId")
    SELECT ${userId}, ${category}, ${w.month}, l.level, ${spent}::float8, ${limit}::float8, ${id}
      FROM unnest(${levels}::int[]) AS l(level)
    ON CONFLICT DO NOTHING
    RETURNING level
  `;
  if (!inserted.length) return null;
  const level = Math.max(...inserted.map((r) => Number(r.level)));

  const status = budgetStatus(category, limit, spent);
  const payload = {
    receiptId: id,
    category,
    level,
    percent: status.percent,
    spent: status.spent,
    limit: status.limit,
    remaining: status.remaining,
    overBy: status.overBy,
    month: w.month,
    monthLabel: w.label,
  };

  try {
    emitToUser(userId, 'budget:alert', payload);
  } catch (err) {
    console.error('[budget/alert] live push failed', err.message);
  }

  if (user.budgetAlertEmails && user.emailVerified) {
    try {
      await mailer.sendBudgetAlertEmail(user.email, user.firstName, payload);
      await prisma.$executeRaw`
        UPDATE nexus_budget_alerts SET emailed = true
         WHERE "userId" = ${userId} AND category = ${category} AND month = ${w.month} AND level = ${level}
      `;
    } catch (err) {
      console.error(`[budget/alert] email failed user=${userId}`, err.message);
    }
  }
  return payload;
}

// Resolves once every running check has finished (for tests).
async function budgetChecksIdle() {
  while (pending.size) await Promise.allSettled([...pending]);
}

module.exports = { checkBudgetAfterReceipt, budgetChecksIdle };
