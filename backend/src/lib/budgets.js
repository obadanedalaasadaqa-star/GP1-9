// Monthly budgets: validation and the numbers behind a budget bar. Pure, no DB.
// Amounts are JD (FLOAT8 in the DB); levels are compared in whole fils so
// float sums like 0.1 + 0.2 can never flip a level.
const {
  parseTz, todayLocal, localDayToUtc, addMonthsClamped, parseLocalDate, MONTHS_LONG,
} = require('./aiDates');

const MAX_BUDGETS = 20;
const MIN_LIMIT = 1;
const MAX_LIMIT = 100000;
const MAX_CATEGORY = 40;
// The same list as scripts/create-store.js and the app's CategoryColors.
const KNOWN_CATEGORIES = ['Supermarket', 'Food', 'Pharmacy', 'Clothing', 'Electronics'];
const LEVELS = [80, 100];

const CATEGORY_ERROR = 'Pick a category (1 to 40 characters).';
const LIMIT_ERROR = `Budget must be a number between ${MIN_LIMIT} and ${MAX_LIMIT} JD.`;
const DECIMALS_ERROR = 'Budget can have at most 3 decimals.';
const BODY_ERROR = 'Invalid request body.';

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const round3 = (x) => Math.round(x * 1000) / 1000;
const toFils = (x) => Math.round(x * 1000);

// Trimmed category with inner whitespace collapsed, or null.
function cleanCategory(raw) {
  if (typeof raw !== 'string') return null;
  if (/[\u0000-\u001f\u007f]/.test(raw)) return null;
  const s = raw.trim().replace(/\s+/g, ' ');
  const length = [...s].length;
  return length >= 1 && length <= MAX_CATEGORY ? s : null;
}

// A JD amount between MIN_LIMIT and MAX_LIMIT with at most 3 decimals, or { error }.
function parseLimit(raw) {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < MIN_LIMIT || raw > MAX_LIMIT) {
    return { error: LIMIT_ERROR };
  }
  // Same tolerance check as hasPriceDecimals in storeReceipt.js.
  const scaled = raw * 1000;
  if (Math.abs(scaled - Math.round(scaled)) >= 1e-9) return { error: DECIMALS_ERROR };
  return raw;
}

/**
 * Check a PUT /api/budgets body. Returns { category, limit, tz } or { error }.
 * Rule order: body, category, limit, tzOffsetMinutes. tz is undefined when the
 * key is missing ("keep the saved one"): parseTz alone would turn a missing
 * value into 180.
 */
function parseBudgetBody(body) {
  if (!isPlainObject(body)) return { error: BODY_ERROR };
  const category = cleanCategory(body.category);
  if (!category) return { error: CATEGORY_ERROR };
  const limit = parseLimit(body.limit);
  if (limit.error) return limit;
  let tz;
  if (body.tzOffsetMinutes !== undefined) {
    tz = parseTz(body.tzOffsetMinutes);
    if (tz.error) return tz;
  }
  return { category, limit, tz };
}

/**
 * The calendar month containing [instant] in the user's zone:
 * { month: '2026-11', label: 'November 2026', fromUtc, toUtc } where
 * [fromUtc, toUtc) runs from local 00:00 on the 1st to local 00:00 on the 1st
 * of the next month (the same instants the app sends to /stats).
 */
function monthWindow(instant, tz) {
  const first = `${todayLocal(new Date(instant), tz).slice(0, 7)}-01`;
  const { y, m } = parseLocalDate(first);
  return {
    month: first.slice(0, 7),
    label: `${MONTHS_LONG[m - 1]} ${y}`,
    fromUtc: localDayToUtc(first, tz),
    toUtc: localDayToUtc(addMonthsClamped(first, 1), tz),
  };
}

// 0, 80 or 100: the highest alert level [spent] has reached. Exactly 80% is 80.
function levelFor(spent, limit) {
  const sF = toFils(spent);
  const lF = toFils(limit);
  if (sF * 100 >= lF * 100) return 100;
  if (sF * 100 >= lF * 80) return 80;
  return 0;
}

const LEVEL_NAMES = { 0: 'ok', 80: 'warning', 100: 'over' };

// One budget bar: { category, limit, spent, remaining, overBy, percent, level }.
function budgetStatus(category, limit, spent) {
  const sF = toFils(spent);
  const lF = toFils(limit);
  return {
    category,
    limit,
    spent: round3(spent),
    remaining: round3(Math.max(0, limit - spent)),
    overBy: round3(Math.max(0, spent - limit)),
    percent: Math.floor((sF * 100) / lF),
    level: LEVEL_NAMES[levelFor(spent, limit)],
  };
}

// Highest percent first, then category A-Z.
function sortStatuses(list) {
  return [...list].sort((a, b) => b.percent - a.percent || a.category.localeCompare(b.category));
}

module.exports = {
  MAX_BUDGETS, MIN_LIMIT, MAX_LIMIT, MAX_CATEGORY, KNOWN_CATEGORIES, LEVELS,
  CATEGORY_ERROR, LIMIT_ERROR, DECIMALS_ERROR, BODY_ERROR,
  cleanCategory, parseLimit, parseBudgetBody, monthWindow, toFils, round3, levelFor,
  budgetStatus, sortStatuses,
};
