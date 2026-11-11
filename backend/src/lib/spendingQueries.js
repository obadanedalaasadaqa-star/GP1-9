// Spending queries shared by /api/user/stats and the AI features.
// Every function takes the user id first; routes always pass req.userId, so a
// caller (or an AI tool input) can never name another user.
// prisma is used through the shared object at call time (never destructured),
// so tests can spy on prisma.receipt.* and prisma.$queryRaw.
const prisma = require('./prisma');
const { shapeStats } = require('./stats');

/**
 * Totals per period, per category and per store in one round trip
 * (GROUPING SETS). bounds: increasing Date[]; each neighbour pair is one
 * period [from, to). Returns the raw rows for shapeStats().
 */
function queryStats(userId, bounds) {
  const isoStrings = bounds.map((d) => d.toISOString());
  return prisma.$queryRaw`
    WITH b AS (
      SELECT i, lo, LEAD(lo) OVER (ORDER BY i) AS hi
        FROM unnest(${isoStrings}::timestamptz[]) WITH ORDINALITY AS t(lo, i)
    )
    SELECT b.i::int                      AS idx,
           GROUPING(r.category)::int     AS "noCategory",
           GROUPING(r."storeName")::int  AS "noStore",
           r.category,
           r."storeName",
           SUM(r."totalAmount")::float8  AS total,
           COUNT(*)::int                 AS count
      FROM b
      JOIN nexus_receipts r
        ON r."userId" = ${userId}
       AND r."createdAt" >= b.lo
       AND r."createdAt" <  b.hi
     WHERE b.hi IS NOT NULL
     GROUP BY GROUPING SETS ((b.i), (b.i, r.category), (b.i, r."storeName"))
  `;
}

// One period [fromUtc, toUtc) with totals, categories and every store.
async function queryRange(userId, fromUtc, toUtc) {
  const bounds = [fromUtc, toUtc];
  const rows = await queryStats(userId, bounds);
  return shapeStats(rows, bounds, { allStores: true }).periods[0];
}

// Only these fields leave the query: never ids or userId.
const RECEIPT_SELECT = {
  createdAt: true, storeName: true, category: true, totalAmount: true, items: true, lineItems: true,
};

/**
 * Receipts in [fromUtc, toUtc), newest first or largest first.
 * category/store: optional case-insensitive "contains" filters.
 */
function queryReceipts(userId, fromUtc, toUtc, { category, store, sort = 'newest', limit = 10 } = {}) {
  return prisma.receipt.findMany({
    where: {
      userId,
      createdAt: { gte: fromUtc, lt: toUtc },
      ...(category && { category: { contains: category, mode: 'insensitive' } }),
      ...(store && { storeName: { contains: store, mode: 'insensitive' } }),
    },
    orderBy: sort === 'largest'
      ? [{ totalAmount: 'desc' }, { createdAt: 'desc' }]
      : { createdAt: 'desc' },
    take: limit,
    select: RECEIPT_SELECT,
  });
}

function countReceipts(userId) {
  return prisma.receipt.count({ where: { userId } });
}

module.exports = { queryStats, queryRange, queryReceipts, countReceipts };
