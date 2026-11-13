// Budget queries shared by /api/budgets, the budget alerts and the weekly email.
// Every function takes the user id first; routes always pass req.userId.
// prisma is used through the shared object at call time (never destructured),
// so tests can spy on prisma.$queryRaw. db: pass a transaction client to run
// inside a transaction.
const prisma = require('./prisma');
const {
  KNOWN_CATEGORIES, cleanCategory, monthWindow, budgetStatus, sortStatuses,
} = require('./budgets');

const SUGGEST_MONTHS = 6;

/**
 * Each budget with what was spent in its category in [fromUtc, toUtc): the
 * same [from, to) rule as /api/user/stats, so a bar equals the Trends total.
 * Rows: { category, monthlyLimit, spent }.
 */
function queryBudgets(userId, fromUtc, toUtc, db = prisma) {
  return db.$queryRaw`
    SELECT b.category, b."monthlyLimit",
           COALESCE(SUM(r."totalAmount"), 0)::float8 AS spent
      FROM nexus_budgets b
      LEFT JOIN nexus_receipts r
        ON r."userId" = b."userId" AND r.category = b.category
       AND r."createdAt" >= ${fromUtc} AND r."createdAt" < ${toUtc}
     WHERE b."userId" = ${userId}
     GROUP BY b.category, b."monthlyLimit"
  `;
}

// Budget bars for [fromUtc, toUtc), highest percent first.
async function budgetStatuses(userId, fromUtc, toUtc, db = prisma) {
  const rows = await queryBudgets(userId, fromUtc, toUtc, db);
  return sortStatuses(rows.map((r) => budgetStatus(r.category, r.monthlyLimit, r.spent)));
}

/**
 * Categories the app offers in its picker, A-Z: the known store categories,
 * the user's receipt categories from the last 6 months, and every category
 * that already has a budget. Names cleanCategory would change are left out,
 * so a picked name always matches the receipts exactly.
 */
async function suggestCategories(userId, now = new Date(), db = prisma) {
  const since = new Date(now);
  since.setUTCMonth(since.getUTCMonth() - SUGGEST_MONTHS);
  const rows = await db.$queryRaw`
    SELECT DISTINCT category FROM nexus_receipts
     WHERE "userId" = ${userId} AND "createdAt" >= ${since}
    UNION
    SELECT category FROM nexus_budgets WHERE "userId" = ${userId}
  `;
  const names = new Set(KNOWN_CATEGORIES);
  for (const { category } of rows) {
    if (cleanCategory(category) === category) names.add(category);
  }
  return [...names].sort((a, b) => a.localeCompare(b));
}

// The user's saved time zone, or null when the user does not exist.
async function savedTz(userId, db = prisma) {
  const rows = await db.$queryRaw`
    SELECT "tzOffsetMinutes" FROM nexus_users WHERE id = ${userId}
  `;
  return rows.length ? rows[0].tzOffsetMinutes : null;
}

// The list response of every /api/budgets route, for the month containing [now].
async function budgetList(userId, tz, now = new Date()) {
  const w = monthWindow(now, tz);
  const [budgets, categories] = await Promise.all([
    budgetStatuses(userId, w.fromUtc, w.toUtc),
    suggestCategories(userId, now),
  ]);
  return {
    month: w.month,
    label: w.label,
    from: w.fromUtc.toISOString(),
    to: w.toUtc.toISOString(),
    tzOffsetMinutes: tz,
    budgets,
    categories,
  };
}

module.exports = { queryBudgets, budgetStatuses, suggestCategories, savedTz, budgetList };
