// Read-only tools for Ask AI. Each tool runs a spendingQueries.js query for the
// signed-in user only (userId comes from the route, never from the model).
// Outputs have no ids, emails, serials, names or phone numbers: only dates,
// store/category/item names (cleanLabel), counts and amounts (formatAmount).
const spendingQueries = require('./spendingQueries');
const { shapeStats } = require('./stats');
const { formatAmount, formatChange, cleanLabel } = require('./aiFormat');
const {
  parseLocalDate, localRangeToUtc, localDayToUtc, daysBetween, localDateOf, MONTHS_LONG,
} = require('./aiDates');

const MAX_SPAN_DAYS = 731;
const MAX_MONTHS_APART = 24;
const MAX_FILTER = 40;
const MAX_OUTPUT_BYTES = 8 * 1024;
const MAX_LINE_ITEMS = 30;
const FIRST_DATE = '2020-01-01';

class ToolInputError extends Error {}

// ── Definitions ────────────────────────────────────────────────────────────

const DATE = (what) => ({ type: 'string', description: `${what} local date, YYYY-MM-DD, inclusive.` });
const RANGE_PROPS = { from: DATE('First'), to: DATE('Last') };
const FILTER = (what) => ({ type: 'string', description: `Optional: only ${what} whose name contains this text (case-insensitive).` });

const tool = (name, description, properties, required) => ({
  name,
  description,
  strict: true,
  input_schema: { type: 'object', properties, required, additionalProperties: false },
});

const CHAT_TOOLS = [
  tool('get_spending_summary',
    'Total spent, number of receipts, average receipt, top stores and top category between two local dates (both inclusive). Use it for any total over a period.',
    RANGE_PROPS, ['from', 'to']),
  tool('get_category_breakdown',
    'Spending per category between two local dates (both inclusive), with each category\'s share of the total in percent.',
    RANGE_PROPS, ['from', 'to']),
  tool('get_monthly_totals',
    'Total spent and number of receipts for each calendar month from from_month to to_month (both inclusive, at most 24 months apart).',
    {
      from_month: { type: 'string', description: 'First month, YYYY-MM.' },
      to_month: { type: 'string', description: 'Last month, YYYY-MM.' },
    }, ['from_month', 'to_month']),
  tool('compare_periods',
    'Compares period A with period B (local dates, inclusive): totals, receipts, the difference A minus B, the change in percent, and per category. Use it for any comparison.',
    {
      a_from: DATE('Period A first'), a_to: DATE('Period A last'),
      b_from: DATE('Period B first'), b_to: DATE('Period B last'),
    }, ['a_from', 'a_to', 'b_from', 'b_to']),
  tool('list_receipts',
    'Lists receipts between two local dates (both inclusive): date, store, category, total and item count. Newest first, or largest first.',
    {
      ...RANGE_PROPS,
      category: FILTER('receipts in categories'),
      store: FILTER('receipts from stores'),
      sort: { type: 'string', enum: ['newest', 'largest'], description: 'Optional: newest (default) or largest.' },
      limit: { type: 'integer', description: 'Optional: how many receipts, 1 to 20 (default 10).' },
    }, ['from', 'to']),
  tool('get_line_items',
    'The items bought on receipts between two local dates (both inclusive), newest first: name, quantity, unit price and line total when the store sent them.',
    {
      ...RANGE_PROPS,
      store: FILTER('receipts from stores'),
      category: FILTER('receipts in categories'),
      limit: { type: 'integer', description: 'Optional: how many receipts, 1 to 10 (default 5).' },
    }, ['from', 'to']),
];

const TOOL_BY_NAME = new Map(CHAT_TOOLS.map((t) => [t.name, t]));
const LIMITS = { list_receipts: { def: 10, max: 20 }, get_line_items: { def: 5, max: 10 } };

// ── Validation ─────────────────────────────────────────────────────────────

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function checkRange(from, to) {
  if (!parseLocalDate(from) || !parseLocalDate(to)) {
    throw new ToolInputError('Dates must be real dates written YYYY-MM-DD.');
  }
  if (from < FIRST_DATE) throw new ToolInputError('Dates start from 2020-01-01.');
  if (from > to) throw new ToolInputError('The first date must be on or before the last date.');
  if (daysBetween(from, to) + 1 > MAX_SPAN_DAYS) {
    throw new ToolInputError(`A date range can cover at most ${MAX_SPAN_DAYS} days.`);
  }
}

const MONTH_RE = /^(\d{4})-(\d{2})$/;
function parseMonth(s) {
  const m = typeof s === 'string' ? MONTH_RE.exec(s) : null;
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) return null;
  return { y: Number(m[1]), m: Number(m[2]) };
}

function checkFilter(v) {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw new ToolInputError(`Text filters must be 1 to ${MAX_FILTER} characters.`);
  const t = v.trim();
  if (t.length < 1 || [...t].length > MAX_FILTER) {
    throw new ToolInputError(`Text filters must be 1 to ${MAX_FILTER} characters.`);
  }
  return t;
}

/**
 * Check a tool input before any SQL. Returns the cleaned input or throws
 * ToolInputError (sent back to the model as an is_error tool result).
 */
function validateToolInput(name, input) {
  const def = TOOL_BY_NAME.get(name);
  if (!def) throw new ToolInputError('Unknown tool.');
  if (!isPlainObject(input)) throw new ToolInputError('The input must be an object.');
  const props = def.input_schema.properties;
  for (const key of Object.keys(input)) {
    if (!Object.hasOwn(props, key)) throw new ToolInputError(`Unknown field: ${key}.`);
  }
  for (const key of def.input_schema.required) {
    if (input[key] === undefined || input[key] === null) throw new ToolInputError(`Missing field: ${key}.`);
  }

  const out = {};
  if (name === 'get_monthly_totals') {
    const a = parseMonth(input.from_month);
    const b = parseMonth(input.to_month);
    if (!a || !b) throw new ToolInputError('Months must be written YYYY-MM.');
    if (a.y < 2020) throw new ToolInputError('Months start from 2020-01.');
    const apart = (b.y - a.y) * 12 + (b.m - a.m);
    if (apart < 0) throw new ToolInputError('from_month must be on or before to_month.');
    if (apart > MAX_MONTHS_APART) throw new ToolInputError(`Months can be at most ${MAX_MONTHS_APART} apart.`);
    return { from_month: input.from_month, to_month: input.to_month };
  }
  if (name === 'compare_periods') {
    checkRange(input.a_from, input.a_to);
    checkRange(input.b_from, input.b_to);
    return { a_from: input.a_from, a_to: input.a_to, b_from: input.b_from, b_to: input.b_to };
  }

  checkRange(input.from, input.to);
  out.from = input.from;
  out.to = input.to;
  if ('category' in props) out.category = checkFilter(input.category);
  if ('store' in props) out.store = checkFilter(input.store);
  if ('sort' in props) {
    const sort = input.sort ?? 'newest';
    if (sort !== 'newest' && sort !== 'largest') throw new ToolInputError('sort must be newest or largest.');
    out.sort = sort;
  }
  if (LIMITS[name]) {
    const { def: d, max } = LIMITS[name];
    const limit = input.limit ?? d;
    if (!Number.isInteger(limit) || limit < 1 || limit > max) {
      throw new ToolInputError(`limit must be a whole number from 1 to ${max}.`);
    }
    out.limit = limit;
  }
  return out;
}

// ── Running ────────────────────────────────────────────────────────────────

// Cut [listKey] until the JSON is under the output cap; mark it truncated.
function capOutput(out, listKey) {
  let json = JSON.stringify(out);
  if (Buffer.byteLength(json) <= MAX_OUTPUT_BYTES) return out;
  const copy = { ...out, [listKey]: [...out[listKey]], truncated: true };
  while (copy[listKey].length > 0) {
    copy[listKey].pop();
    json = JSON.stringify(copy);
    if (Buffer.byteLength(json) <= MAX_OUTPUT_BYTES) break;
  }
  return copy;
}

const sharePercent = (part, total) => (total > 0 ? Math.round((part / total) * 100) : 0);

// "+12.50", "-3.00" or "0.00" (server-computed difference).
function signedAmount(n) {
  const s = formatAmount(n);
  if (s === '0.00' || s === '-0.00') return '0.00';
  return n > 0 ? `+${s}` : s;
}

async function summary(userId, { from, to }, tz, queries) {
  const { fromUtc, toUtc } = localRangeToUtc(from, to, tz);
  const p = await queries.queryRange(userId, fromUtc, toUtc);
  return {
    from, to,
    total: formatAmount(p.total),
    receipts: p.count,
    averageReceipt: formatAmount(p.average),
    topStores: (p.stores ?? []).slice(0, 5).map((s) => ({
      store: cleanLabel(s.storeName), total: formatAmount(s.total), receipts: s.count,
    })),
    topCategory: p.byCategory[0]
      ? { category: cleanLabel(p.byCategory[0].category), total: formatAmount(p.byCategory[0].total) }
      : null,
  };
}

async function categoryBreakdown(userId, { from, to }, tz, queries) {
  const { fromUtc, toUtc } = localRangeToUtc(from, to, tz);
  const p = await queries.queryRange(userId, fromUtc, toUtc);
  return capOutput({
    from, to,
    total: formatAmount(p.total),
    categories: p.byCategory.slice(0, 20).map((c) => ({
      category: cleanLabel(c.category),
      total: formatAmount(c.total),
      receipts: c.count,
      sharePercent: sharePercent(c.total, p.total),
    })),
    ...(p.byCategory.length > 20 && { truncated: true }),
  }, 'categories');
}

async function monthlyTotals(userId, { from_month, to_month }, tz, queries) {
  const a = parseMonth(from_month);
  const b = parseMonth(to_month);
  const n = (b.y - a.y) * 12 + (b.m - a.m) + 1;
  const months = [];
  for (let k = 0; k <= n; k++) {
    const d = new Date(Date.UTC(a.y, a.m - 1 + k, 1));
    months.push(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`);
  }
  const bounds = months.map((m) => localDayToUtc(m, tz));
  const rows = await queries.queryStats(userId, bounds);
  const { periods } = shapeStats(rows, bounds);
  return {
    months: periods.map((p, i) => {
      const [y, m] = months[i].split('-').map(Number);
      return { month: `${MONTHS_LONG[m - 1]} ${y}`, total: formatAmount(p.total), receipts: p.count };
    }),
  };
}

async function comparePeriods(userId, input, tz, queries) {
  const ra = localRangeToUtc(input.a_from, input.a_to, tz);
  const rb = localRangeToUtc(input.b_from, input.b_to, tz);
  const [a, b] = await Promise.all([
    queries.queryRange(userId, ra.fromUtc, ra.toUtc),
    queries.queryRange(userId, rb.fromUtc, rb.toUtc),
  ]);
  const aCat = new Map(a.byCategory.map((c) => [c.category, c.total]));
  const bCat = new Map(b.byCategory.map((c) => [c.category, c.total]));
  const names = [...new Set([...aCat.keys(), ...bCat.keys()])];
  names.sort((x, y) => (aCat.get(y) ?? 0) - (aCat.get(x) ?? 0)
    || (bCat.get(y) ?? 0) - (bCat.get(x) ?? 0) || (x < y ? -1 : x > y ? 1 : 0));
  return capOutput({
    a: { from: input.a_from, to: input.a_to, total: formatAmount(a.total), receipts: a.count },
    b: { from: input.b_from, to: input.b_to, total: formatAmount(b.total), receipts: b.count },
    difference: signedAmount(a.total - b.total),
    change: formatChange(a.total, b.total),
    categories: names.slice(0, 20).map((name) => ({
      category: cleanLabel(name),
      aTotal: formatAmount(aCat.get(name) ?? 0),
      bTotal: formatAmount(bCat.get(name) ?? 0),
      difference: signedAmount((aCat.get(name) ?? 0) - (bCat.get(name) ?? 0)),
    })),
    ...(names.length > 20 && { truncated: true }),
  }, 'categories');
}

async function listReceipts(userId, input, tz, queries) {
  const { fromUtc, toUtc } = localRangeToUtc(input.from, input.to, tz);
  const rows = await queries.queryReceipts(userId, fromUtc, toUtc, {
    category: input.category, store: input.store, sort: input.sort, limit: input.limit + 1,
  });
  return capOutput({
    receipts: rows.slice(0, input.limit).map((r) => ({
      date: localDateOf(r.createdAt, tz),
      store: cleanLabel(r.storeName),
      category: cleanLabel(r.category),
      total: formatAmount(r.totalAmount),
      itemCount: Array.isArray(r.lineItems) ? r.lineItems.length
        : Array.isArray(r.items) ? r.items.length : 0,
    })),
    truncated: rows.length > input.limit,
  }, 'receipts');
}

// One receipt line: store lines have prices; older/manual receipts only have
// the "Milk x2" strings.
function lineItem(item) {
  if (item && typeof item === 'object' && !Array.isArray(item)) {
    const qty = Number(item.qty);
    const unitFils = Math.round(Number(item.unitPrice) * 1000);
    if (Number.isFinite(qty) && Number.isFinite(unitFils)) {
      return {
        name: cleanLabel(item.name, 60),
        qty,
        unitPrice: formatAmount(unitFils / 1000),
        lineTotal: formatAmount((qty * unitFils) / 1000),
      };
    }
    return { name: cleanLabel(item.name, 60), qty: null, unitPrice: null, lineTotal: null };
  }
  return { name: cleanLabel(item, 60), qty: null, unitPrice: null, lineTotal: null };
}

async function lineItems(userId, input, tz, queries) {
  const { fromUtc, toUtc } = localRangeToUtc(input.from, input.to, tz);
  const rows = await queries.queryReceipts(userId, fromUtc, toUtc, {
    category: input.category, store: input.store, sort: 'newest', limit: input.limit,
  });
  return capOutput({
    receipts: rows.map((r) => {
      const all = Array.isArray(r.lineItems) && r.lineItems.length > 0 ? r.lineItems
        : Array.isArray(r.items) ? r.items : [];
      return {
        date: localDateOf(r.createdAt, tz),
        store: cleanLabel(r.storeName),
        total: formatAmount(r.totalAmount),
        items: all.slice(0, MAX_LINE_ITEMS).map(lineItem),
        ...(all.length > MAX_LINE_ITEMS && { truncated: true }),
      };
    }),
  }, 'receipts');
}

const RUNNERS = {
  get_spending_summary: summary,
  get_category_breakdown: categoryBreakdown,
  get_monthly_totals: monthlyTotals,
  compare_periods: comparePeriods,
  list_receipts: listReceipts,
  get_line_items: lineItems,
};

/**
 * Validate and run one tool for [userId]. queries defaults to the real
 * spendingQueries (unit tests pass fakes).
 */
async function runTool(name, input, { userId, tz, queries = spendingQueries }) {
  const clean = validateToolInput(name, input);
  return RUNNERS[name](userId, clean, tz, queries);
}

module.exports = {
  CHAT_TOOLS, ToolInputError, validateToolInput, runTool, MAX_OUTPUT_BYTES, MAX_LINE_ITEMS,
};
