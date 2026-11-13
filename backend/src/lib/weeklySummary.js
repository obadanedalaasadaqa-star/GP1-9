// Weekly summary email: which week to send and what it says. Pure, no DB.
// Weeks run Sunday to Saturday like the app's Period week; dates are local
// 'YYYY-MM-DD' strings in the user's zone (tz = minutes east of UTC).
const { todayLocal, addDays, parseLocalDate, rangeLabel } = require('./aiDates');

const SEND_HOUR = 9; // local time on Sunday
const TOP_CATEGORIES = 3;

const round3 = (x) => Math.round(x * 1000) / 1000;

/**
 * The latest full week that may be emailed at [now]: { key, from, to, label }
 * (to inclusive, key = from). S = the most recent local Sunday (today if
 * Sunday). From S 09:00 on it is S-7 … S-1; before that, the week before.
 */
function latestWeek(now, tz) {
  const local = new Date(now.getTime() + tz * 60000);
  const today = todayLocal(now, tz);
  const { y, m, d } = parseLocalDate(today);
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const sunday = addDays(today, -weekday);
  const beforeSendTime = weekday === 0 && local.getUTCHours() < SEND_HOUR;
  const from = addDays(sunday, beforeSendTime ? -14 : -7);
  const to = addDays(from, 6);
  return { key: from, from, to, label: rangeLabel(from, to) };
}

/**
 * The facts of one weekly email. current/previous: spendingQueries.queryRange
 * periods for the week and the week before; budgets: this month's sorted
 * budget statuses; month: their label ('November 2026').
 * changePercent is null when the week before had no spending.
 */
function buildWeeklySummary({ week, current, previous, budgets = [], month }) {
  const difference = round3(current.total - previous.total);
  return {
    label: week.label,
    from: week.from,
    to: week.to,
    total: current.total,
    receipts: current.count,
    average: current.average,
    previousTotal: previous.total,
    difference,
    changePercent: previous.total > 0 ? Math.round((difference / previous.total) * 100) : null,
    topCategories: current.byCategory.slice(0, TOP_CATEGORIES),
    topStore: current.topStore,
    budgets,
    month,
  };
}

module.exports = { SEND_HOUR, latestWeek, buildWeeklySummary };
