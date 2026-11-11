// Local-date helpers for Ask AI and reports. Pure, no DB.
// A local date is a 'YYYY-MM-DD' string in the user's time zone; tz is the
// offset in minutes east of UTC (Jordan: 180, no DST since 2022).

const DEFAULT_TZ = 180;
const TZ_ERROR = 'tzOffsetMinutes must be a whole number of minutes between -720 and 840.';
const DAY_MS = 24 * 3600 * 1000;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTHS_LONG = ['January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'];

const pad = (n, w = 2) => String(n).padStart(w, '0');

// tz offset in minutes, or { error }. Missing means Jordan.
function parseTz(raw) {
  if (raw === undefined || raw === null || raw === '') return DEFAULT_TZ;
  if ((typeof raw !== 'string' && typeof raw !== 'number') || !/^-?\d{1,4}$/.test(String(raw))) {
    return { error: TZ_ERROR };
  }
  const n = Number(raw);
  if (n < -720 || n > 840) return { error: TZ_ERROR };
  return n;
}

// 'YYYY-MM-DD' of a UTC Date's fields.
const isoDate = (d) => `${pad(d.getUTCFullYear(), 4)}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;

// Today's local date at instant [now].
function todayLocal(now, tz) {
  return isoDate(new Date(now.getTime() + tz * 60000));
}

// The local date of an instant (a receipt's createdAt).
const localDateOf = (instant, tz) => todayLocal(new Date(instant), tz);

// { y, m, d } of a real 'YYYY-MM-DD' date, or null.
function parseLocalDate(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const [y, m, d] = s.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  return { y, m, d };
}

const toUtcMidnight = (date) => {
  const { y, m, d } = parseLocalDate(date);
  return Date.UTC(y, m - 1, d);
};

// Local 00:00 of [date] as a UTC instant. '2026-11-01' at 180 -> 2026-10-31T21:00Z.
function localDayToUtc(date, tz) {
  return new Date(toUtcMidnight(date) - tz * 60000);
}

// [from, to] local dates (to inclusive) as UTC instants [fromUtc, toUtc).
function localRangeToUtc(from, to, tz) {
  return { fromUtc: localDayToUtc(from, tz), toUtc: localDayToUtc(addDays(to, 1), tz) };
}

function addDays(date, n) {
  return isoDate(new Date(toUtcMidnight(date) + n * DAY_MS));
}

// Move by n months, clamping the day (Mar 31 - 1 month = Feb 28/29).
function addMonthsClamped(date, n) {
  const { y, m, d } = parseLocalDate(date);
  const first = new Date(Date.UTC(y, m - 1 + n, 1));
  const last = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return isoDate(new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), Math.min(d, last))));
}

// Whole days from a to b (b - a).
function daysBetween(a, b) {
  return Math.round((toUtcMidnight(b) - toUtcMidnight(a)) / DAY_MS);
}

const monthKey = (date) => date.slice(0, 7);
const lastDayOfMonth = (date) => {
  const { y, m } = parseLocalDate(date);
  return isoDate(new Date(Date.UTC(y, m, 0)));
};

/**
 * The calendar months touching [from, to], clipped to the range:
 * [{ month: '2026-09', label: 'September 2026', from, to, partial }].
 */
function monthsInRange(from, to) {
  const out = [];
  let start = from;
  while (start <= to) {
    const end = lastDayOfMonth(start) < to ? lastDayOfMonth(start) : to;
    const { y, m } = parseLocalDate(start);
    out.push({
      month: monthKey(start),
      label: `${MONTHS_LONG[m - 1]} ${y}`,
      from: start,
      to: end,
      partial: start.slice(8) !== '01' || end !== lastDayOfMonth(start),
    });
    start = addDays(end, 1);
  }
  return out;
}

// "1 – 11 Nov 2026", "29 Nov – 5 Dec 2026", "28 Dec 2025 – 3 Jan 2026"
// (the app's Period._range format).
function rangeLabel(from, to) {
  const a = parseLocalDate(from);
  const b = parseLocalDate(to);
  const short = (x) => `${x.d} ${MONTHS[x.m - 1]}`;
  if (from === to) return `${short(a)} ${a.y}`;
  if (a.y !== b.y) return `${short(a)} ${a.y} – ${short(b)} ${b.y}`;
  if (a.m !== b.m) return `${short(a)} – ${short(b)} ${b.y}`;
  return `${a.d} – ${short(b)} ${b.y}`;
}

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// "Wednesday, 11 November 2026 (2026-11-11)" for the user's local today.
function longDate(date) {
  const { y, m, d } = parseLocalDate(date);
  const wd = WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  return `${wd}, ${d} ${MONTHS_LONG[m - 1]} ${y} (${date})`;
}

module.exports = {
  DEFAULT_TZ, TZ_ERROR, parseTz, todayLocal, localDateOf, parseLocalDate, localDayToUtc,
  localRangeToUtc, addDays, addMonthsClamped, daysBetween, monthsInRange, rangeLabel, longDate,
  MONTHS_LONG,
};
