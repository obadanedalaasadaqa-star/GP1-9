const { buildChart, shortMonth } = require('../../src/lib/aiChart');

// Plain tool outputs, as the runners in aiTools.js return them.
const CATEGORIES = {
  from: '2026-11-01', to: '2026-11-11', total: '287.99',
  categories: [
    { category: 'Electronics', total: '89.99', receipts: 1, sharePercent: 31 },
    { category: 'Supermarket', total: '76.75', receipts: 2, sharePercent: 27 },
    { category: 'Clothing', total: '67.00', receipts: 1, sharePercent: 23 },
  ],
};
const SUMMARY = {
  from: '2026-11-01', to: '2026-11-11', total: '287.99', receipts: 7, averageReceipt: '41.14',
  topStores: [
    { store: 'iStore', total: '89.99', receipts: 1 },
    { store: 'Zara', total: '67.00', receipts: 1 },
  ],
  topCategory: { category: 'Electronics', total: '89.99' },
};
const MONTHS = {
  months: [
    { month: 'September 2026', total: '120.50', receipts: 3 },
    { month: 'October 2026', total: '0.00', receipts: 0 },
    { month: 'November 2026', total: '287.99', receipts: 7 },
  ],
};
const COMPARE = {
  a: { from: '2026-11-01', to: '2026-11-11', total: '60.00', receipts: 2 },
  b: { from: '2026-10-01', to: '2026-10-11', total: '70.00', receipts: 3 },
  difference: '-10.00',
  change: '-14%',
  categories: [
    { category: 'Food', aTotal: '60.00', bTotal: '50.00', difference: '+10.00' },
    { category: 'Zara', aTotal: '0.00', bTotal: '20.00', difference: '-20.00' },
  ],
};
const TOP = (sort, extra = {}) => ({
  scope: 'all receipts', sort, receiptsChecked: 17, receiptsWithPrices: 3,
  firstReceipt: '2023-11-16', lastReceipt: '2026-11-10',
  products: [
    { name: 'Bread', timesBought: 5, quantity: 5, spent: null },
    { name: 'Milk', timesBought: 4, quantity: 7, spent: '2.30' },
    { name: 'Eggs', timesBought: 1, quantity: 12, spent: null },
  ],
  truncated: false, note: 'spent is only known for receipts sent by stores with prices.',
  ...extra,
});

// The exact compare chart for COMPARE. The Flutter test (chat_chart_test.dart)
// pastes this JSON as a Dart map, so both sides agree on the shape.
const COMPARE_CHART_JSON = JSON.stringify({
  kind: 'compare',
  title: '1 – 11 Nov 2026 vs 1 – 11 Oct 2026',
  unit: 'JD',
  items: [],
  a: { label: '1 – 11 Nov 2026', value: 60 },
  b: { label: '1 – 11 Oct 2026', value: 70 },
  change: '-14%',
  pairs: [{ label: 'Food', a: 60, b: 50 }, { label: 'Zara', a: 0, b: 20 }],
});

const run = (name, out) => ({ name, out });

describe('buildChart', () => {
  test('category breakdown: bars with share notes', () => {
    expect(buildChart([run('get_category_breakdown', CATEGORIES)])).toEqual({
      kind: 'bars', title: 'By category · 1 – 11 Nov 2026', unit: 'JD',
      items: [
        { label: 'Electronics', value: 89.99, note: '31%' },
        { label: 'Supermarket', value: 76.75, note: '27%' },
        { label: 'Clothing', value: 67, note: '23%' },
      ],
    });
  });

  test('spending summary: top store bars, no note', () => {
    expect(buildChart([run('get_spending_summary', SUMMARY)])).toEqual({
      kind: 'bars', title: 'Top stores · 1 – 11 Nov 2026', unit: 'JD',
      items: [{ label: 'iStore', value: 89.99 }, { label: 'Zara', value: 67 }],
    });
  });

  test('monthly totals: columns with short month labels', () => {
    expect(buildChart([run('get_monthly_totals', MONTHS)])).toEqual({
      kind: 'columns', title: 'Monthly spending', unit: 'JD',
      items: [
        { label: 'Sep 26', value: 120.5 },
        { label: 'Oct 26', value: 0 },
        { label: 'Nov 26', value: 287.99 },
      ],
    });
  });

  test('compare: totals, change copied, pairs, items always []', () => {
    const chart = buildChart([run('compare_periods', COMPARE)]);
    expect(JSON.stringify(chart)).toBe(COMPARE_CHART_JSON);
    expect(chart.items).toEqual([]);
    expect(buildChart([run('compare_periods', { ...COMPARE, change: '0%' })]).change).toBe('0%');
  });

  test('every chart has the four keys and items', () => {
    for (const r of [
      run('get_category_breakdown', CATEGORIES), run('get_spending_summary', SUMMARY),
      run('get_monthly_totals', MONTHS), run('compare_periods', COMPARE), run('get_top_products', TOP('times')),
    ]) {
      const chart = buildChart([r]);
      for (const key of ['kind', 'title', 'unit', 'items']) expect(chart).toHaveProperty(key);
      expect(Array.isArray(chart.items)).toBe(true);
    }
  });

  test('top products: times, quantity, spend, and a missing sort', () => {
    const times = buildChart([run('get_top_products', TOP('times'))]);
    expect(times).toEqual({
      kind: 'bars', title: 'Most bought · all receipts', unit: 'times',
      items: [{ label: 'Bread', value: 5 }, { label: 'Milk', value: 4 }, { label: 'Eggs', value: 1 }],
    });
    const qty = buildChart([run('get_top_products', TOP('quantity'))]);
    expect(qty.unit).toBe('items');
    expect(qty.title).toBe('Most bought by quantity · all receipts');
    expect(qty.items.map((i) => i.value)).toEqual([5, 7, 12]);
    // Only Milk has a price: fewer than 2 left, so no chart.
    expect(buildChart([run('get_top_products', TOP('spend'))])).toBeNull();
    const spend = buildChart([run('get_top_products', TOP('spend', {
      products: [
        { name: 'Milk', timesBought: 4, quantity: 7, spent: '2.30' },
        { name: 'Bread', timesBought: 5, quantity: 5, spent: null },
        { name: 'Cheese', timesBought: 1, quantity: 1, spent: '4.10' },
      ],
    }))]);
    expect(spend).toEqual({
      kind: 'bars', title: 'Most spent on · all receipts', unit: 'JD',
      items: [{ label: 'Milk', value: 2.3 }, { label: 'Cheese', value: 4.1 }],
    });
    const { sort: _ignored, ...noSort } = TOP('times');
    expect(buildChart([run('get_top_products', noSort)]).unit).toBe('times');
    const dated = buildChart([run('get_top_products', TOP('times', { scope: { from: '2026-11-01', to: '2026-11-11' } }))]);
    expect(dated.title).toBe('Most bought · 1 – 11 Nov 2026');
  });

  test('the last chartable run wins; a null builder falls back to the run before', () => {
    expect(buildChart([run('get_category_breakdown', CATEGORIES), run('get_spending_summary', SUMMARY)]).title)
      .toBe('Top stores · 1 – 11 Nov 2026');
    const oneStore = { ...SUMMARY, topStores: SUMMARY.topStores.slice(0, 1) };
    expect(buildChart([run('get_category_breakdown', CATEGORIES), run('get_spending_summary', oneStore)]).title)
      .toBe('By category · 1 – 11 Nov 2026');
    // A non-chart tool after a chart tool doesn't hide it.
    expect(buildChart([run('get_category_breakdown', CATEGORIES), run('list_receipts', { receipts: [] })]).kind)
      .toBe('bars');
  });

  test('list and line-item tools, no runs → null', () => {
    expect(buildChart([run('list_receipts', { receipts: [] })])).toBeNull();
    expect(buildChart([run('get_line_items', { receipts: [] })])).toBeNull();
    expect(buildChart([])).toBeNull();
  });

  test('too little data → null', () => {
    expect(buildChart([run('get_category_breakdown', { ...CATEGORIES, categories: CATEGORIES.categories.slice(0, 1) })])).toBeNull();
    expect(buildChart([run('get_category_breakdown', {
      ...CATEGORIES, categories: CATEGORIES.categories.map((c) => ({ ...c, total: '0.00' })),
    })])).toBeNull();
    expect(buildChart([run('get_spending_summary', { ...SUMMARY, topStores: [] })])).toBeNull();
    expect(buildChart([run('get_monthly_totals', { months: MONTHS.months.map((m) => ({ ...m, total: '0.00' })) })])).toBeNull();
    expect(buildChart([run('compare_periods', {
      ...COMPARE, a: { ...COMPARE.a, total: '0.00' }, b: { ...COMPARE.b, total: '0.00' },
    })])).toBeNull();
    expect(buildChart([run('get_top_products', TOP('times', { products: TOP('times').products.slice(0, 1) }))])).toBeNull();
  });

  test('month labels: short form, unknown name → null for that run', () => {
    expect(shortMonth('November 2026')).toBe('Nov 26');
    expect(shortMonth('January 2025')).toBe('Jan 25');
    expect(shortMonth('Brumaire 2026')).toBeNull();
    expect(buildChart([run('get_monthly_totals', {
      months: [...MONTHS.months, { month: 'Brumaire 2026', total: '1.00', receipts: 1 }],
    })])).toBeNull();
  });

  test('at most 8 bars, 25 columns and 5 pairs', () => {
    const cats = Array.from({ length: 12 }, (_, i) => ({ category: `C${i}`, total: `${i + 1}.00`, receipts: 1, sharePercent: 1 }));
    expect(buildChart([run('get_category_breakdown', { ...CATEGORIES, categories: cats })]).items).toHaveLength(8);
    const months = Array.from({ length: 30 }, () => ({ month: 'May 2026', total: '1.00', receipts: 1 }));
    expect(buildChart([run('get_monthly_totals', { months })]).items).toHaveLength(25);
    const pairs = Array.from({ length: 9 }, (_, i) => ({ category: `C${i}`, aTotal: '1.00', bTotal: '2.00', difference: '-1.00' }));
    expect(buildChart([run('compare_periods', { ...COMPARE, categories: pairs })]).pairs).toHaveLength(5);
    const products = Array.from({ length: 12 }, (_, i) => ({ name: `P${i}`, timesBought: 12 - i, quantity: 1, spent: null }));
    expect(buildChart([run('get_top_products', TOP('times', { products }))]).items).toHaveLength(8);
  });

  test('labels are cleaned (control characters, 40 runes); values are finite and >= 0', () => {
    const chart = buildChart([run('get_top_products', TOP('times', {
      products: [
        { name: `Bad\u0007name ${'x'.repeat(60)}`, timesBought: 2, quantity: 1, spent: null },
        { name: 'Ok', timesBought: 1.23456, quantity: 1, spent: null },
      ],
    }))]);
    expect(chart.items[0].label).not.toMatch(/\u0007/);
    expect([...chart.items[0].label].length).toBeLessThanOrEqual(40);
    expect(chart.items[1].value).toBe(1.235);
    const weird = buildChart([run('get_spending_summary', {
      ...SUMMARY, topStores: [{ store: 'A', total: 'abc' }, { store: 'B', total: '-5' }],
    })]);
    expect(weird.items.map((i) => i.value)).toEqual([0, 0]);
  });
});

module.exports = { COMPARE_CHART_JSON };
