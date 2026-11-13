const { latestWeek, buildWeeklySummary } = require('../../src/lib/weeklySummary');

// Local wall time at tz as a UTC instant: local('2026-11-14T23:59', 180).
const local = (wall, tz) => new Date(new Date(`${wall}:00Z`).getTime() - tz * 60000);

describe('latestWeek', () => {
  test.each([
    ['Sat 14 Nov 23:59', '2026-11-14T23:59', '2026-11-01', '2026-11-07'],
    ['Sun 15 Nov 08:59', '2026-11-15T08:59', '2026-11-01', '2026-11-07'],
    ['Sun 15 Nov 09:00', '2026-11-15T09:00', '2026-11-08', '2026-11-14'],
    ['Wed 18 Nov', '2026-11-18T12:00', '2026-11-08', '2026-11-14'],
  ])('tz 180, %s', (_label, wall, from, to) => {
    const w = latestWeek(local(wall, 180), 180);
    expect(w).toMatchObject({ key: from, from, to });
  });

  test('a week crossing a month end and a year end', () => {
    expect(latestWeek(local('2026-12-01T10:00', 180), 180)).toMatchObject({
      from: '2026-11-22', to: '2026-11-28',
    });
    const w = latestWeek(local('2027-01-03T09:30', 180), 180);
    expect(w).toMatchObject({ from: '2026-12-27', to: '2027-01-02', label: '27 Dec 2026 – 2 Jan 2027' });
  });

  test('tz -300 where the UTC day is already Sunday but the local day is Saturday', () => {
    const now = new Date('2026-11-15T03:00:00Z'); // local Sat 14 Nov 22:00
    expect(latestWeek(now, -300)).toMatchObject({ from: '2026-11-01', to: '2026-11-07' });
    expect(latestWeek(now, 180)).toMatchObject({ from: '2026-11-01', to: '2026-11-07' }); // Sun 06:00
    expect(latestWeek(new Date('2026-11-15T14:00:00Z'), -300)).toMatchObject({ from: '2026-11-08' }); // Sun 09:00
  });

  test('label uses the app format', () => {
    expect(latestWeek(local('2026-11-18T12:00', 180), 180).label).toBe('8 – 14 Nov 2026');
  });
});

describe('buildWeeklySummary', () => {
  const week = { key: '2026-11-08', from: '2026-11-08', to: '2026-11-14', label: '8 – 14 Nov 2026' };
  const period = (total, count, byCategory = [], topStore = null) => ({
    total, count, average: count ? total / count : 0, byCategory, topStore,
  });
  const cats = [
    { category: 'Food', total: 40, count: 3 }, { category: 'Pharmacy', total: 20, count: 1 },
    { category: 'Clothing', total: 10, count: 1 }, { category: 'Electronics', total: 5, count: 1 },
  ];

  test('totals, difference, % and top 3 categories', () => {
    const s = buildWeeklySummary({
      week,
      current: period(75, 6, cats, { storeName: 'KFC', total: 30, count: 2 }),
      previous: period(50, 4),
      budgets: [{ category: 'Food', percent: 85 }],
      month: 'November 2026',
    });
    expect(s).toMatchObject({
      label: '8 – 14 Nov 2026', total: 75, receipts: 6, average: 12.5,
      previousTotal: 50, difference: 25, changePercent: 50, month: 'November 2026',
    });
    expect(s.topCategories.map((c) => c.category)).toEqual(['Food', 'Pharmacy', 'Clothing']);
    expect(s.topStore.storeName).toBe('KFC');
    expect(s.budgets).toEqual([{ category: 'Food', percent: 85 }]);
  });

  test('null % when the week before was 0; a drop is negative', () => {
    expect(buildWeeklySummary({ week, current: period(10, 1), previous: period(0, 0) }).changePercent).toBeNull();
    const down = buildWeeklySummary({ week, current: period(0.1 + 0.2, 1), previous: period(0.6, 1) });
    expect(down.difference).toBe(-0.3);
    expect(down.changePercent).toBe(-50);
  });
});
