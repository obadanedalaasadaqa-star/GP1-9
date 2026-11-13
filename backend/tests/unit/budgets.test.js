const {
  KNOWN_CATEGORIES, CATEGORY_ERROR, LIMIT_ERROR, DECIMALS_ERROR, BODY_ERROR,
  cleanCategory, parseLimit, parseBudgetBody, monthWindow, levelFor, budgetStatus, sortStatuses,
} = require('../../src/lib/budgets');
const { TZ_ERROR } = require('../../src/lib/aiDates');

describe('cleanCategory', () => {
  test('trims and collapses inner spaces', () => {
    expect(cleanCategory('  Food  ')).toBe('Food');
    expect(cleanCategory('Food   &   Drinks')).toBe('Food & Drinks');
  });
  test('40 code points pass, 41 fail; an emoji counts as one', () => {
    expect(cleanCategory('a'.repeat(40))).toBe('a'.repeat(40));
    expect(cleanCategory('a'.repeat(41))).toBeNull();
    expect(cleanCategory('🍔'.repeat(40))).toBe('🍔'.repeat(40));
    expect(cleanCategory('🍔'.repeat(41))).toBeNull();
  });
  test.each(['', '   ', 5, null, undefined, {}, 'Fo\u0000od', 'Food\n', 'a\u007f'])('%p is null', (raw) => {
    expect(cleanCategory(raw)).toBeNull();
  });
  test('the known list has the 5 store categories', () => {
    expect(KNOWN_CATEGORIES).toEqual(['Supermarket', 'Food', 'Pharmacy', 'Clothing', 'Electronics']);
  });
});

describe('parseLimit', () => {
  test.each([1, 100000, 12.345, 50, 0.1 + 0.2 + 9.7])('%p passes', (x) => {
    expect(parseLimit(x)).toBe(x);
  });
  test.each([0.999, 100000.001, -5, 0, '50', NaN, Infinity, null, undefined])('%p is out of range', (x) => {
    expect(parseLimit(x)).toEqual({ error: LIMIT_ERROR });
  });
  test('more than 3 decimals', () => {
    expect(parseLimit(12.3456)).toEqual({ error: DECIMALS_ERROR });
  });
});

describe('parseBudgetBody', () => {
  test('rule order: body, category, limit, tz', () => {
    expect(parseBudgetBody(null)).toEqual({ error: BODY_ERROR });
    expect(parseBudgetBody([])).toEqual({ error: BODY_ERROR });
    expect(parseBudgetBody({ category: '', limit: 0, tzOffsetMinutes: 'x' })).toEqual({ error: CATEGORY_ERROR });
    expect(parseBudgetBody({ category: 'Food', limit: 0, tzOffsetMinutes: 'x' })).toEqual({ error: LIMIT_ERROR });
    expect(parseBudgetBody({ category: 'Food', limit: 5, tzOffsetMinutes: 'x' })).toEqual({ error: TZ_ERROR });
  });
  test('tz missing is undefined (keep the saved one), not 180', () => {
    expect(parseBudgetBody({ category: ' Food ', limit: 50 })).toEqual({ category: 'Food', limit: 50, tz: undefined });
    expect(parseBudgetBody({ category: 'Food', limit: 50, tzOffsetMinutes: -300 }).tz).toBe(-300);
    expect(parseBudgetBody({ category: 'Food', limit: 50, tzOffsetMinutes: 0 }).tz).toBe(0);
  });
});

describe('monthWindow', () => {
  test('mid-November in Jordan', () => {
    const w = monthWindow(new Date('2026-11-13T10:00:00Z'), 180);
    expect(w.month).toBe('2026-11');
    expect(w.label).toBe('November 2026');
    expect(w.fromUtc.toISOString()).toBe('2026-10-31T21:00:00.000Z');
    expect(w.toUtc.toISOString()).toBe('2026-11-30T21:00:00.000Z');
  });
  test('local 1 Nov 00:30 is already November', () => {
    expect(monthWindow(new Date('2026-10-31T21:30:00Z'), 180).month).toBe('2026-11');
    expect(monthWindow(new Date('2026-10-31T20:59:59Z'), 180).month).toBe('2026-10');
  });
  test('December rolls into January of the next year', () => {
    const w = monthWindow(new Date('2026-12-20T00:00:00Z'), 180);
    expect(w.month).toBe('2026-12');
    expect(w.toUtc.toISOString()).toBe('2026-12-31T21:00:00.000Z');
  });
  test('tz -300 and 0', () => {
    const ny = monthWindow(new Date('2026-12-01T03:00:00Z'), -300); // local 30 Nov 22:00
    expect(ny.month).toBe('2026-11');
    expect(ny.fromUtc.toISOString()).toBe('2026-11-01T05:00:00.000Z');
    expect(ny.toUtc.toISOString()).toBe('2026-12-01T05:00:00.000Z');
    const utc = monthWindow(new Date('2026-02-10T00:00:00Z'), 0);
    expect(utc.fromUtc.toISOString()).toBe('2026-02-01T00:00:00.000Z');
    expect(utc.toUtc.toISOString()).toBe('2026-03-01T00:00:00.000Z');
  });
});

describe('levelFor', () => {
  test.each([
    [39.999, 50, 0], [40, 50, 80], [49.999, 50, 80], [50, 50, 100], [120, 50, 100], [0, 50, 0],
  ])('%p of %p -> %p', (spent, limit, level) => {
    expect(levelFor(spent, limit)).toBe(level);
  });
  test('float sums at exactly 80% count as 80', () => {
    expect(0.1 + 0.7).not.toBe(0.8);
    expect(levelFor(0.1 + 0.7, 1)).toBe(80);
    expect(levelFor(0.1 + 0.2 + 7.7, 10)).toBe(80);
  });
});

describe('budgetStatus', () => {
  test('under', () => {
    expect(budgetStatus('Food', 50, 10)).toEqual({
      category: 'Food', limit: 50, spent: 10, remaining: 40, overBy: 0, percent: 20, level: 'ok',
    });
  });
  test('warning, percent floors', () => {
    expect(budgetStatus('Food', 50, 42.5)).toMatchObject({ remaining: 7.5, overBy: 0, percent: 85, level: 'warning' });
    expect(budgetStatus('Food', 3, 2.999).percent).toBe(99);
  });
  test('exactly 100 and 250%', () => {
    expect(budgetStatus('Food', 50, 50)).toMatchObject({ remaining: 0, overBy: 0, percent: 100, level: 'over' });
    expect(budgetStatus('Food', 10, 25)).toMatchObject({ remaining: 0, overBy: 15, percent: 250, level: 'over' });
  });
  test('rounds float noise to 3 decimals', () => {
    expect(budgetStatus('Food', 10, 0.1 + 0.2).spent).toBe(0.3);
  });
});

test('sortStatuses: percent desc, then name', () => {
  const list = [
    { category: 'Food', percent: 50 }, { category: 'Clothing', percent: 90 },
    { category: 'Bakery', percent: 50 }, { category: 'Pharmacy', percent: 120 },
  ];
  expect(sortStatuses(list).map((s) => s.category)).toEqual(['Pharmacy', 'Clothing', 'Bakery', 'Food']);
});
