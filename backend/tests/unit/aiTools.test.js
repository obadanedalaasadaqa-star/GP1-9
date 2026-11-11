const {
  CHAT_TOOLS, ToolInputError, validateToolInput, runTool, MAX_OUTPUT_BYTES,
} = require('../../src/lib/aiTools');

// A period as queryRange returns it, with extra id-like fields the tools must drop.
const period = (total, count, byCategory = [], stores = []) => ({
  from: 'x', to: 'y', total, count, average: count ? Math.round((total / count) * 1000) / 1000 : 0,
  byCategory, topStore: stores[0] ?? null, stores, id: 'ID-1', userId: 'U-SECRET',
});

// Fake queries that record every call.
function fakeQueries({ range, ranges, receipts = [], statsRows = [] } = {}) {
  const calls = [];
  let n = 0;
  return {
    calls,
    queryRange: jest.fn(async (...args) => { calls.push(['queryRange', ...args]); return ranges ? ranges[n++] : range; }),
    queryReceipts: jest.fn(async (...args) => { calls.push(['queryReceipts', ...args]); return receipts; }),
    queryStats: jest.fn(async (...args) => { calls.push(['queryStats', ...args]); return statsRows; }),
  };
}

const ctx = (queries) => ({ userId: 'U1', tz: 180, queries });
const R = { from: '2026-11-01', to: '2026-11-11' };
const msg = (fn) => {
  try { fn(); } catch (e) { expect(e).toBeInstanceOf(ToolInputError); return e.message; }
  return 'no error';
};

describe('definitions', () => {
  test('6 unique names, strict, closed object schemas, required lists, descriptions', () => {
    expect(new Set(CHAT_TOOLS.map((t) => t.name)).size).toBe(6);
    const closed = (schema) => {
      if (schema.type === 'object') {
        expect(schema.additionalProperties).toBe(false);
        Object.values(schema.properties).forEach(closed);
      }
    };
    for (const t of CHAT_TOOLS) {
      expect(t.strict).toBe(true);
      expect(t.input_schema.type).toBe('object');
      closed(t.input_schema);
      expect(t.description.length).toBeGreaterThan(20);
      for (const r of t.input_schema.required) expect(t.input_schema.properties).toHaveProperty(r);
    }
    const lr = CHAT_TOOLS.find((t) => t.name === 'list_receipts').input_schema;
    expect(lr.required).toEqual(['from', 'to']);
  });
});

describe('validateToolInput', () => {
  test.each([
    ['bad date', { from: '2026-13-01', to: '2026-11-11' }, 'Dates must be real dates written YYYY-MM-DD.'],
    ['from > to', { from: '2026-11-12', to: '2026-11-11' }, 'The first date must be on or before the last date.'],
    ['732 days', { from: '2024-11-11', to: '2026-11-12' }, 'A date range can cover at most 731 days.'],
    ['before 2020', { from: '2019-12-31', to: '2020-01-05' }, 'Dates start from 2020-01-01.'],
    ['unknown key', { ...R, userId: 'x' }, 'Unknown field: userId.'],
    ['inherited key constructor', { ...R, constructor: 'x' }, 'Unknown field: constructor.'],
    ['inherited key toString', { ...R, toString: 'y' }, 'Unknown field: toString.'],
  ])('%s', (_name, input, text) => {
    expect(msg(() => validateToolInput('get_spending_summary', input))).toBe(text);
  });

  test('731 days pass', () => {
    expect(validateToolInput('get_spending_summary', { from: '2024-11-12', to: '2026-11-12' })).toEqual(
      { from: '2024-11-12', to: '2026-11-12' });
  });

  test('limits, filters, sort, unknown tool, not an object', () => {
    expect(msg(() => validateToolInput('list_receipts', { ...R, limit: 21 }))).toBe('limit must be a whole number from 1 to 20.');
    expect(msg(() => validateToolInput('list_receipts', { ...R, limit: 0 }))).toBe('limit must be a whole number from 1 to 20.');
    expect(msg(() => validateToolInput('list_receipts', { ...R, limit: 2.5 }))).toBe('limit must be a whole number from 1 to 20.');
    expect(msg(() => validateToolInput('get_line_items', { ...R, limit: 11 }))).toBe('limit must be a whole number from 1 to 10.');
    expect(msg(() => validateToolInput('list_receipts', { ...R, store: 'x'.repeat(41) }))).toBe('Text filters must be 1 to 40 characters.');
    expect(msg(() => validateToolInput('list_receipts', { ...R, store: '   ' }))).toBe('Text filters must be 1 to 40 characters.');
    expect(msg(() => validateToolInput('list_receipts', { ...R, sort: 'oldest' }))).toBe('sort must be newest or largest.');
    expect(msg(() => validateToolInput('delete_everything', R))).toBe('Unknown tool.');
    expect(msg(() => validateToolInput('get_spending_summary', 'x'))).toBe('The input must be an object.');
    expect(msg(() => validateToolInput('get_spending_summary', { from: '2026-11-01' }))).toBe('Missing field: to.');
    expect(validateToolInput('list_receipts', { ...R, store: ' Zara ' }))
      .toEqual({ ...R, store: 'Zara', category: undefined, sort: 'newest', limit: 10 });
  });

  test('months', () => {
    expect(msg(() => validateToolInput('get_monthly_totals', { from_month: '2026-13', to_month: '2026-11' }))).toBe('Months must be written YYYY-MM.');
    expect(msg(() => validateToolInput('get_monthly_totals', { from_month: '2024-10', to_month: '2026-11' }))).toBe('Months can be at most 24 apart.');
    expect(msg(() => validateToolInput('get_monthly_totals', { from_month: '2026-11', to_month: '2026-10' }))).toBe('from_month must be on or before to_month.');
    expect(validateToolInput('get_monthly_totals', { from_month: '2024-11', to_month: '2026-11' })).toBeDefined();
  });
});

describe('runTool', () => {
  test('scope: queries always get the caller user id first', async () => {
    const q = fakeQueries({ range: period(10, 1) });
    await runTool('get_spending_summary', R, ctx(q));
    await runTool('get_category_breakdown', R, ctx(q));
    await runTool('compare_periods', { a_from: '2026-11-01', a_to: '2026-11-11', b_from: '2026-10-01', b_to: '2026-10-11' }, ctx(q));
    await runTool('list_receipts', R, ctx(q));
    await runTool('get_line_items', R, ctx(q));
    await runTool('get_monthly_totals', { from_month: '2026-09', to_month: '2026-11' }, ctx(q));
    expect(q.calls.length).toBeGreaterThan(6);
    for (const call of q.calls) expect(call[1]).toBe('U1');
  });

  test('summary: amounts as strings, local dates to UTC bounds, no ids', async () => {
    const q = fakeQueries({
      range: period(287.99, 7, [{ category: 'Electronics', total: 89.99, count: 1 }],
        [{ storeName: 'iStore', total: 89.99, count: 1, storeId: 'S-1' }]),
    });
    const out = await runTool('get_spending_summary', R, ctx(q));
    expect(q.calls[0][2].toISOString()).toBe('2026-10-31T21:00:00.000Z');
    expect(q.calls[0][3].toISOString()).toBe('2026-11-11T21:00:00.000Z');
    expect(out).toEqual({
      from: '2026-11-01', to: '2026-11-11', total: '287.99', receipts: 7, averageReceipt: '41.14',
      topStores: [{ store: 'iStore', total: '89.99', receipts: 1 }],
      topCategory: { category: 'Electronics', total: '89.99' },
    });
    const json = JSON.stringify(out);
    for (const bad of ['ID-1', 'U-SECRET', 'S-1', '"id"', 'userId', 'storeId']) expect(json).not.toContain(bad);
  });

  test('category breakdown shares', async () => {
    const q = fakeQueries({ range: period(100, 3, [{ category: 'Food', total: 75, count: 2 }, { category: 'Pharmacy', total: 25, count: 1 }]) });
    const out = await runTool('get_category_breakdown', R, ctx(q));
    expect(out.categories.map((c) => c.sharePercent)).toEqual([75, 25]);
  });

  test('compare_periods: a = 60, b = 70', async () => {
    const q = fakeQueries({ ranges: [period(60, 2, [{ category: 'Food', total: 60, count: 2 }]), period(70, 3, [{ category: 'Food', total: 50, count: 2 }, { category: 'Zara', total: 20, count: 1 }])] });
    const out = await runTool('compare_periods', { a_from: '2026-11-01', a_to: '2026-11-11', b_from: '2026-10-01', b_to: '2026-10-11' }, ctx(q));
    expect(out.difference).toBe('-10.00');
    expect(out.change).toBe('-14%');
    expect(out.categories).toEqual([
      { category: 'Food', aTotal: '60.00', bTotal: '50.00', difference: '+10.00' },
      { category: 'Zara', aTotal: '0.00', bTotal: '20.00', difference: '-20.00' },
    ]);
  });

  test('list_receipts: local dates, truncated, filters passed, no ids', async () => {
    const rows = Array.from({ length: 3 }, (_, i) => ({
      id: `R-${i}`, userId: 'U-SECRET', createdAt: new Date('2026-10-31T21:30:00Z'),
      storeName: 'Carrefour', category: 'Supermarket', totalAmount: 45.5, items: ['Milk x2', 'Bread'], lineItems: null,
    }));
    const q = fakeQueries({ receipts: rows });
    const out = await runTool('list_receipts', { ...R, store: 'carre', sort: 'largest', limit: 2 }, ctx(q));
    expect(q.calls[0][4]).toEqual({ category: undefined, store: 'carre', sort: 'largest', limit: 3 });
    expect(out.truncated).toBe(true);
    expect(out.receipts).toHaveLength(2);
    expect(out.receipts[0]).toEqual({ date: '2026-11-01', store: 'Carrefour', category: 'Supermarket', total: '45.50', itemCount: 2 });
    expect(JSON.stringify(out)).not.toMatch(/R-0|U-SECRET/);
  });

  test('get_line_items: store lines priced in fils, strings without prices, 30-item cut', async () => {
    const many = Array.from({ length: 35 }, (_, i) => `Item ${i}`);
    const q = fakeQueries({
      receipts: [
        { createdAt: new Date('2026-11-03T09:00:00Z'), storeName: 'Shop', category: 'Supermarket', totalAmount: 1.9, items: ['Milk x2'], lineItems: [{ name: 'Milk', qty: 2, unitPrice: 0.95 }] },
        { createdAt: new Date('2026-11-02T09:00:00Z'), storeName: 'Old', category: 'Food', totalAmount: 5, items: ['Milk x2'], lineItems: null },
        { createdAt: new Date('2026-11-01T09:00:00Z'), storeName: 'Big', category: 'Food', totalAmount: 5, items: many, lineItems: null },
      ],
    });
    const out = await runTool('get_line_items', R, ctx(q));
    expect(out.receipts[0].items).toEqual([{ name: 'Milk', qty: 2, unitPrice: '0.95', lineTotal: '1.90' }]);
    expect(out.receipts[1].items).toEqual([{ name: 'Milk x2', qty: null, unitPrice: null, lineTotal: null }]);
    expect(out.receipts[2].items).toHaveLength(30);
    expect(out.receipts[2].truncated).toBe(true);
  });

  test('output over 8 KB is cut and marked truncated', async () => {
    const rows = Array.from({ length: 20 }, (_, i) => ({
      createdAt: new Date('2026-11-03T09:00:00Z'), storeName: 'S'.repeat(40), category: 'C'.repeat(40),
      totalAmount: i, items: Array.from({ length: 30 }, () => 'x'.repeat(60)), lineItems: null,
    }));
    const q = fakeQueries({ receipts: rows });
    const out = await runTool('get_line_items', { ...R, limit: 10 }, ctx(q));
    expect(Buffer.byteLength(JSON.stringify(out))).toBeLessThanOrEqual(MAX_OUTPUT_BYTES);
    expect(out.truncated).toBe(true);
  });

  test('monthly totals: one bound per month, labels', async () => {
    const q = fakeQueries({ statsRows: [{ idx: 3, noCategory: 1, noStore: 1, total: 287.99, count: 7 }] });
    const out = await runTool('get_monthly_totals', { from_month: '2026-09', to_month: '2026-11' }, ctx(q));
    expect(q.calls[0][2].map((d) => d.toISOString())).toEqual([
      '2026-08-31T21:00:00.000Z', '2026-09-30T21:00:00.000Z', '2026-10-31T21:00:00.000Z', '2026-11-30T21:00:00.000Z',
    ]);
    expect(out.months).toEqual([
      { month: 'September 2026', total: '0.00', receipts: 0 },
      { month: 'October 2026', total: '0.00', receipts: 0 },
      { month: 'November 2026', total: '287.99', receipts: 7 },
    ]);
  });

  test('bad input never reaches a query', async () => {
    const q = fakeQueries();
    await expect(runTool('get_spending_summary', { ...R, userId: 'other' }, ctx(q))).rejects.toBeInstanceOf(ToolInputError);
    expect(q.calls).toHaveLength(0);
  });
});
