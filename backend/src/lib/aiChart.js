// The one small chart under an Ask AI answer. Built only from the outputs of
// the tools that answer ran (server-made, validated data), never from the
// model's text or its raw tool input. The last chartable tool wins; if its
// builder has too little data, the one before it is tried.
const { cleanLabel } = require('./aiFormat');
const { rangeLabel, MONTHS_LONG } = require('./aiDates');

const MAX_BARS = 8;
const MAX_STORES = 5;
const MAX_COLUMNS = 25;
const MAX_PAIRS = 5;

// A finite number >= 0, rounded to 3 decimals; anything else is 0.
function num(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.round(n * 1000) / 1000;
}

const label = (s) => cleanLabel(s, 40);
const item = (l, v, note) => ({ label: label(l), value: num(v), ...(note !== undefined && { note }) });

// 'November 2026' -> 'Nov 26'; null when the month name is unknown.
function shortMonth(s) {
  const m = /^(\S+) (\d{4})$/.exec(String(s ?? ''));
  if (!m || !MONTHS_LONG.includes(m[1])) return null;
  return `${m[1].slice(0, 3)} ${m[2].slice(2)}`;
}

function categoryChart(out) {
  const cats = (out.categories ?? []).slice(0, MAX_BARS);
  if (cats.length < 2) return null;
  const items = cats.map((c) => item(c.category, c.total, `${c.sharePercent}%`));
  if (items.every((i) => i.value === 0)) return null;
  return { kind: 'bars', title: `By category · ${rangeLabel(out.from, out.to)}`, unit: 'JD', items };
}

function summaryChart(out) {
  const stores = (out.topStores ?? []).slice(0, MAX_STORES);
  if (stores.length < 2) return null;
  return {
    kind: 'bars',
    title: `Top stores · ${rangeLabel(out.from, out.to)}`,
    unit: 'JD',
    items: stores.map((s) => item(s.store, s.total)),
  };
}

function monthlyChart(out) {
  const months = (out.months ?? []).slice(0, MAX_COLUMNS);
  if (months.length === 0) return null;
  const items = [];
  for (const m of months) {
    const short = shortMonth(m.month);
    if (!short) return null;
    items.push(item(short, m.total));
  }
  if (items.every((i) => i.value === 0)) return null;
  return { kind: 'columns', title: 'Monthly spending', unit: 'JD', items };
}

function compareChart(out) {
  if (!out.a || !out.b) return null;
  const a = num(out.a.total);
  const b = num(out.b.total);
  if (a === 0 && b === 0) return null;
  return {
    kind: 'compare',
    title: `${rangeLabel(out.a.from, out.a.to)} vs ${rangeLabel(out.b.from, out.b.to)}`,
    unit: 'JD',
    items: [],
    a: { label: label(rangeLabel(out.a.from, out.a.to)), value: a },
    b: { label: label(rangeLabel(out.b.from, out.b.to)), value: b },
    change: out.change,
    pairs: (out.categories ?? []).slice(0, MAX_PAIRS).map((c) => ({
      label: label(c.category), a: num(c.aTotal), b: num(c.bTotal),
    })),
  };
}

function topProductsChart(out) {
  const scope = typeof out.scope === 'object' && out.scope
    ? rangeLabel(out.scope.from, out.scope.to)
    : 'all receipts';
  const products = out.products ?? [];
  let title;
  let unit;
  let items;
  if (out.sort === 'spend') {
    title = `Most spent on · ${scope}`;
    unit = 'JD';
    items = products.filter((p) => p.spent != null).slice(0, MAX_BARS).map((p) => item(p.name, p.spent));
  } else if (out.sort === 'quantity') {
    title = `Most bought by quantity · ${scope}`;
    unit = 'items';
    items = products.slice(0, MAX_BARS).map((p) => item(p.name, p.quantity));
  } else {
    // 'times', and the default if sort were ever missing.
    title = `Most bought · ${scope}`;
    unit = 'times';
    items = products.slice(0, MAX_BARS).map((p) => item(p.name, p.timesBought));
  }
  if (items.length < 2) return null;
  return { kind: 'bars', title, unit, items };
}

const BUILDERS = {
  get_category_breakdown: categoryChart,
  get_spending_summary: summaryChart,
  get_monthly_totals: monthlyChart,
  compare_periods: compareChart,
  get_top_products: topProductsChart,
};

/**
 * runs: [{ name, out }] for every tool run that succeeded, in order.
 * Returns one chart object or null.
 */
function buildChart(runs) {
  for (let i = (runs?.length ?? 0) - 1; i >= 0; i--) {
    const build = BUILDERS[runs[i].name];
    if (!build || !runs[i].out) continue;
    const chart = build(runs[i].out);
    if (chart) return chart;
  }
  return null;
}

module.exports = { buildChart, shortMonth };
