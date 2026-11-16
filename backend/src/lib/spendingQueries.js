// Spending queries shared by /api/user/stats and the AI features.
// Every function takes the user id first; routes always pass req.userId, so a
// caller (or an AI tool input) can never name another user.
// prisma is used through the shared object at call time (never destructured),
// so tests can spy on prisma.receipt.* and prisma.$queryRaw.
const { Prisma } = require('@prisma/client');
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

// ── Top products ───────────────────────────────────────────────────────────

// The regexes are bound parameters in normal JS strings on purpose: inside a
// JS template literal "\s" or "\d" (one backslash) loses its backslash with no
// error, so Postgres would get "s+" instead of "\s+". No backslash may appear
// in the SQL templates below.
const QTY_RE = '^(.*\\S)\\s+x(\\d{1,3})$'; // Postgres gets ^(.*\S)\s+x(\d{1,3})$
const WS_RE = '\\s+';                         // Postgres gets \s+

// LIKE pattern text: backslash (Postgres' default LIKE escape), % and _ match
// literally.
const escapeLike = (s) => s.replace(/[\\%_]/g, (c) => '\\' + c);

const TOP_PRODUCTS_ORDER = {
  times: Prisma.sql`"timesBought" DESC, quantity DESC, name`,
  quantity: Prisma.sql`quantity DESC, "timesBought" DESC, name`,
  spend: Prisma.sql`spent DESC NULLS LAST, "timesBought" DESC, name`,
};

/**
 * The items a user buys most, over every receipt (or [fromUtc, toUtc) when
 * both are given). Store receipts count their lineItems (with prices); other
 * receipts count their item strings, where a trailing "xN" is N units.
 * Names merge by case and whitespace; the spelling is from the newest receipt.
 * Every JSON read is inside CASE, so a malformed row can never raise.
 * Returns { products (limit + 1 rows, for "truncated"), receiptsChecked,
 * receiptsWithPrices, firstAt, lastAt }. No ids or userId leave the query.
 */
async function queryTopProducts(userId, { fromUtc, toUtc, store, category, sort = 'times', limit = 10 } = {}) {
  const order = TOP_PRODUCTS_ORDER[sort];
  if (!order) throw new Error(`Unknown top products sort: ${sort}`);
  const dates = fromUtc && toUtc
    ? Prisma.sql`AND "createdAt" >= ${fromUtc} AND "createdAt" < ${toUtc}`
    : Prisma.empty;
  const storeFilter = store
    ? Prisma.sql`AND "storeName" ILIKE ${'%' + escapeLike(store) + '%'}`
    : Prisma.empty;
  const categoryFilter = category
    ? Prisma.sql`AND category ILIKE ${'%' + escapeLike(category) + '%'}`
    : Prisma.empty;

  const rows = await prisma.$queryRaw`
    WITH scope AS (
      SELECT id, "createdAt", items, "lineItems",
             CASE WHEN jsonb_typeof("lineItems") = 'array'
                  THEN jsonb_array_length("lineItems") > 0 ELSE false END AS "hasLines"
        FROM nexus_receipts
       WHERE "userId" = ${userId} ${dates} ${storeFilter} ${categoryFilter}
    ),
    raw_lines AS (
      SELECT s.id, s."createdAt", t.pos,
             CASE WHEN jsonb_typeof(t.e->'name') = 'string' THEN t.e->>'name' END AS name,
             CASE WHEN jsonb_typeof(t.e->'qty') = 'number' THEN (t.e->>'qty')::numeric ELSE 1 END AS qty,
             CASE WHEN jsonb_typeof(t.e->'qty') = 'number' AND jsonb_typeof(t.e->'unitPrice') = 'number'
                  THEN (t.e->>'qty')::numeric * (t.e->>'unitPrice')::numeric END AS spent
        FROM scope s
        CROSS JOIN LATERAL jsonb_array_elements(
               CASE WHEN jsonb_typeof(s."lineItems") = 'array' THEN s."lineItems" ELSE '[]'::jsonb END
             ) WITH ORDINALITY AS t(e, pos)
       WHERE s."hasLines"
      UNION ALL
      SELECT s.id, s."createdAt", t.pos,
             COALESCE(q.m[1], r.raw) AS name,
             COALESCE(q.m[2]::numeric, 1) AS qty,
             NULL::numeric AS spent
        FROM scope s
        CROSS JOIN LATERAL jsonb_array_elements(
               CASE WHEN jsonb_typeof(s.items) = 'array' THEN s.items ELSE '[]'::jsonb END
             ) WITH ORDINALITY AS t(e, pos)
        CROSS JOIN LATERAL (
          SELECT CASE WHEN jsonb_typeof(t.e) = 'string' THEN t.e #>> '{}' END AS raw
        ) r
        CROSS JOIN LATERAL (SELECT regexp_match(r.raw, ${QTY_RE}, 'i') AS m) q
       WHERE NOT s."hasLines"
    ),
    lines AS (
      SELECT id, "createdAt", pos, name, qty,
             CASE WHEN spent >= 0 THEN spent END AS spent,
             lower(regexp_replace(btrim(name), ${WS_RE}, ' ', 'g')) AS key
        FROM raw_lines
       WHERE name IS NOT NULL AND btrim(name) <> ''
    ),
    grouped AS (
      SELECT (array_agg(btrim(name) ORDER BY "createdAt" DESC, id DESC, pos ASC))[1] AS name,
             COUNT(DISTINCT id)::int  AS "timesBought",
             SUM(qty)::float8         AS quantity,
             SUM(spent)::float8       AS spent,
             COUNT(spent)::int        AS "pricedLines"
        FROM lines
       GROUP BY key
    ),
    ranked AS (
      SELECT *, ROW_NUMBER() OVER (ORDER BY ${order}) AS rn FROM grouped
    ),
    totals AS (
      SELECT COUNT(*)::int                               AS "receiptsChecked",
             (COUNT(*) FILTER (WHERE "hasLines"))::int   AS "receiptsWithPrices",
             MIN("createdAt")                            AS "firstAt",
             MAX("createdAt")                            AS "lastAt"
        FROM scope
    )
    SELECT t."receiptsChecked", t."receiptsWithPrices", t."firstAt", t."lastAt",
           p.name, p."timesBought", p.quantity, p.spent, p."pricedLines"
      FROM totals t
      LEFT JOIN ranked p ON p.rn <= ${limit + 1}
     ORDER BY p.rn
  `;

  const head = rows[0] ?? {};
  return {
    products: rows.filter((r) => r.name != null).map((r) => ({
      name: r.name,
      timesBought: Number(r.timesBought),
      quantity: Number(r.quantity),
      spent: r.spent == null ? null : Number(r.spent),
      pricedLines: Number(r.pricedLines),
    })),
    receiptsChecked: Number(head.receiptsChecked ?? 0),
    receiptsWithPrices: Number(head.receiptsWithPrices ?? 0),
    firstAt: head.firstAt ?? null,
    lastAt: head.lastAt ?? null,
  };
}

module.exports = {
  queryStats, queryRange, queryReceipts, countReceipts, queryTopProducts, escapeLike,
};
