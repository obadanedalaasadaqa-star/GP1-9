// lib/demoData.js buildDemoData (pure, no DB).
const { buildDemoData } = require('../../src/lib/demoData');
const { monthWindow, parseLimit } = require('../../src/lib/budgets');

// Local wall time [iso] (no zone) in zone [tz] as a UTC instant.
const local = (iso, tz) => new Date(Date.parse(`${iso}Z`) - tz * 60000);

const CASES = [
  ['mid-month, Jordan', local('2026-11-14T21:00:00', 180), 180],
  ['the 1st at 00:30 local', local('2026-11-01T00:30:00', 180), 180],
  ['the last day at 23:30 local', local('2026-11-30T23:30:00', 180), 180],
  ['UTC (tz 0)', local('2026-03-01T00:30:00', 0), 0],
];

describe.each(CASES)('%s', (_label, now, tz) => {
  const data = buildDemoData(now, tz);

  test('deterministic for a fixed now and tz', () => {
    expect(buildDemoData(new Date(now), tz)).toEqual(data);
  });

  test('6 month windows from monthWindow, the last one is this month', () => {
    expect(data.months).toHaveLength(6);
    expect(data.months[5]).toEqual(monthWindow(now, tz));
    for (let i = 1; i < 6; i++) expect(data.months[i].fromUtc).toEqual(data.months[i - 1].toUtc);
  });

  test('every receipt is inside a window and not in the future; at least 4 per month', () => {
    for (const m of data.months) {
      const inside = data.receipts.filter((r) => r.createdAt >= m.fromUtc && r.createdAt < m.toUtc);
      expect(inside.length).toBeGreaterThanOrEqual(4);
    }
    for (const r of data.receipts) {
      expect(r.createdAt.getTime()).toBeLessThan(now.getTime());
      expect(r.createdAt.getTime()).toBeGreaterThanOrEqual(data.months[0].fromUtc.getTime());
    }
    expect(data.receipts.length).toBeGreaterThanOrEqual(28);
    expect(data.receipts.length).toBeLessThanOrEqual(34);
  });

  test('points are floor(total) per receipt and the sum is returned', () => {
    for (const r of data.receipts) expect(r.pointsEarned).toBe(Math.floor(r.totalAmount));
    expect(data.points).toBe(data.receipts.reduce((s, r) => s + r.pointsEarned, 0));
  });

  test('3 valid budgets; the Food budget is 65-79% used this month', () => {
    expect(data.budgets).toHaveLength(3);
    for (const b of data.budgets) expect(parseLimit(b.monthlyLimit)).toBe(b.monthlyLimit);
    const cur = data.months[5];
    const food = data.budgets.find((b) => b.category === 'Food');
    const spent = data.receipts
      .filter((r) => r.category === 'Food' && r.createdAt >= cur.fromUtc && r.createdAt < cur.toUtc)
      .reduce((s, r) => s + r.totalAmount, 0);
    const ratio = spent / food.monthlyLimit;
    expect(ratio).toBeGreaterThanOrEqual(0.65);
    expect(ratio).toBeLessThan(0.80);
  });

  test('several categories and stores, items are strings', () => {
    expect(new Set(data.receipts.map((r) => r.category)).size).toBeGreaterThanOrEqual(4);
    expect(new Set(data.receipts.map((r) => r.storeName)).size).toBeGreaterThanOrEqual(5);
    for (const r of data.receipts) expect(r.items.every((i) => typeof i === 'string')).toBe(true);
  });
});
