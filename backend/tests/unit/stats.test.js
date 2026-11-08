const { MAX_BOUNDS, parseBounds, shapeStats, round3 } = require('../../src/lib/stats');

const REQUIRED = 'bounds is required.';
const COUNT = 'bounds must have 2 to 13 dates.';
const ISO = 'bounds must be ISO dates with a time zone (e.g. 2026-11-01T00:00:00.000Z).';
const ORDER = 'bounds must be in increasing order.';

// n increasing month starts (UTC), as ISO strings.
const months = (n) =>
  Array.from({ length: n }, (_, k) => new Date(Date.UTC(2026, k, 1)).toISOString());
const errorOf = (raw) => parseBounds(raw).error;

describe('parseBounds', () => {
  test('2 bounds give 2 dates', () => {
    const r = parseBounds('2026-10-31T21:00:00.000Z,2026-11-30T21:00:00.000Z');
    expect(r.error).toBeUndefined();
    expect(r.bounds.map((d) => d.toISOString()))
      .toEqual(['2026-10-31T21:00:00.000Z', '2026-11-30T21:00:00.000Z']);
  });

  test(`${MAX_BOUNDS} bounds are accepted`, () => {
    expect(parseBounds(months(MAX_BOUNDS).join(',')).bounds).toHaveLength(13);
  });

  test('+03:00 offsets, no milliseconds and spaces around parts are accepted', () => {
    const r = parseBounds(' 2026-11-01T00:00:00+03:00 , 2026-12-01T00:00+03:00 ');
    expect(r.bounds.map((d) => d.toISOString()))
      .toEqual(['2026-10-31T21:00:00.000Z', '2026-11-30T21:00:00.000Z']);
  });

  test('29 Feb in a leap year is valid', () => {
    expect(parseBounds('2028-02-29T00:00:00Z,2028-03-01T00:00:00Z').error).toBeUndefined();
  });

  test.each([undefined, null, '', '   ', ['2026-01-01T00:00:00Z', '2026-02-01T00:00:00Z'], 5])(
    '%p gives "bounds is required."', (raw) => {
      expect(errorOf(raw)).toBe(REQUIRED);
    });

  test.each([1, 14])('%i values give the count message', (n) => {
    expect(errorOf(months(n).join(','))).toBe(COUNT);
  });

  test.each([
    '2026-11-01',
    '2026-11-01T00:00:00',
    '2026-13-01T00:00:00Z',
    'abc',
    '',
    '2026-02-30T00:00:00Z',
    '2026-11-01T24:00:00Z',
    '2026-11-01T10:60:00Z',
    '2026-11-01T10:00:60Z',
    '2026-02-29T00:00:00+03:00',
  ])('%p gives the ISO message', (bad) => {
    expect(errorOf(`2025-01-01T00:00:00Z,${bad},2027-01-01T00:00:00Z`)).toBe(ISO);
  });

  test('an empty part (a,,b) gives the ISO message', () => {
    expect(errorOf('2026-01-01T00:00:00Z,,2026-03-01T00:00:00Z')).toBe(ISO);
  });

  test('equal neighbours give the order message', () => {
    // Same instant written in two zones still counts as equal.
    expect(errorOf('2026-11-01T00:00:00+03:00,2026-10-31T21:00:00Z')).toBe(ORDER);
  });

  test('decreasing values give the order message', () => {
    expect(errorOf('2026-12-01T00:00:00Z,2026-11-01T00:00:00Z')).toBe(ORDER);
  });
});

describe('shapeStats', () => {
  const bounds = months(4).map((s) => new Date(s)); // 3 periods
  const totalRow = (idx, total, count) =>
    ({ idx, noCategory: 1, noStore: 1, category: null, storeName: null, total, count });
  const catRow = (idx, category, total, count) =>
    ({ idx, noCategory: 0, noStore: 1, category, storeName: null, total, count });
  const storeRow = (idx, storeName, total, count) =>
    ({ idx, noCategory: 1, noStore: 0, category: null, storeName, total, count });

  test('no rows give one zero period per pair, with from/to echoed', () => {
    const { periods } = shapeStats([], bounds);
    expect(periods).toHaveLength(3);
    periods.forEach((p, i) => {
      expect(p).toEqual({
        from: bounds[i].toISOString(),
        to: bounds[i + 1].toISOString(),
        total: 0, count: 0, average: 0, byCategory: [], topStore: null,
      });
    });
  });

  test('totals are rounded to 3 decimals and average = round3(total / count)', () => {
    const { periods } = shapeStats([
      totalRow(1, 0.1 + 0.2, 3),
      catRow(1, 'Food', 0.1 + 0.2, 3),
    ], bounds);
    expect(periods[0].total).toBe(0.3);
    expect(periods[0].byCategory[0].total).toBe(0.3);
    expect(periods[0].average).toBe(0.1);

    const p = shapeStats([totalRow(1, 10, 3)], bounds).periods[0];
    expect(p.average).toBe(3.333);
    expect(round3(1.0005)).toBe(1.001);
  });

  test('byCategory is sorted by total desc, ties by name', () => {
    const { periods } = shapeStats([
      totalRow(1, 30, 4),
      catRow(1, 'Pharmacy', 5, 1),
      catRow(1, 'Food', 10, 1),
      catRow(1, 'Supermarket', 10, 1),
      catRow(1, 'Clothing', 5, 1),
    ], bounds);
    expect(periods[0].byCategory.map((c) => c.category))
      .toEqual(['Food', 'Supermarket', 'Clothing', 'Pharmacy']);
  });

  test('topStore is by total, ties by count, then by name', () => {
    const top = (rows) => shapeStats([totalRow(1, 1, 1), ...rows], bounds).periods[0].topStore;
    expect(top([storeRow(1, 'A', 5, 1), storeRow(1, 'B', 9, 1)]))
      .toEqual({ storeName: 'B', total: 9, count: 1 });
    expect(top([storeRow(1, 'A', 9, 1), storeRow(1, 'B', 9, 3)]).storeName).toBe('B');
    expect(top([storeRow(1, 'B', 9, 2), storeRow(1, 'A', 9, 2)]).storeName).toBe('A');
  });

  test('rows for idx 2 go to periods[1]; string numbers are accepted', () => {
    const { periods } = shapeStats([
      totalRow('2', '12.5', '2'),
      catRow(2, 'Food', 12.5, 2),
      storeRow(2, 'Shop', 12.5, 2),
    ], bounds);
    expect(periods[0].count).toBe(0);
    expect(periods[1]).toMatchObject({
      total: 12.5, count: 2, average: 6.25,
      byCategory: [{ category: 'Food', total: 12.5, count: 2 }],
      topStore: { storeName: 'Shop', total: 12.5, count: 2 },
    });
    expect(periods[2].count).toBe(0);
  });
});
