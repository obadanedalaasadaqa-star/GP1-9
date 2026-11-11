const {
  TZ_ERROR, parseTz, todayLocal, localDateOf, parseLocalDate, localDayToUtc, localRangeToUtc,
  addDays, addMonthsClamped, daysBetween, monthsInRange, rangeLabel, longDate,
} = require('../../src/lib/aiDates');

describe('parseTz', () => {
  test('missing is Jordan (180); valid strings and numbers', () => {
    expect(parseTz(undefined)).toBe(180);
    expect(parseTz('')).toBe(180);
    expect(parseTz('-300')).toBe(-300);
    expect(parseTz(840)).toBe(840);
    expect(parseTz(-720)).toBe(-720);
    expect(parseTz('0')).toBe(0);
  });
  test.each(['841', 'abc', '1.5', 1.5, -721, 900, true, ['180'], {}])('%p is an error', (raw) => {
    expect(parseTz(raw)).toEqual({ error: TZ_ERROR });
  });
});

describe('dates', () => {
  test('localDayToUtc / localRangeToUtc', () => {
    expect(localDayToUtc('2026-11-01', 180).toISOString()).toBe('2026-10-31T21:00:00.000Z');
    const r = localRangeToUtc('2026-11-01', '2026-11-11', 180);
    expect(r.fromUtc.toISOString()).toBe('2026-10-31T21:00:00.000Z');
    expect(r.toUtc.toISOString()).toBe('2026-11-11T21:00:00.000Z');
    expect(localDayToUtc('2026-11-01', -300).toISOString()).toBe('2026-11-01T05:00:00.000Z');
  });

  test('parseLocalDate', () => {
    expect(parseLocalDate('2026-02-30')).toBeNull();
    expect(parseLocalDate('2026-13-01')).toBeNull();
    expect(parseLocalDate('2026-1-01')).toBeNull();
    expect(parseLocalDate(20260101)).toBeNull();
    expect(parseLocalDate('2028-02-29')).toEqual({ y: 2028, m: 2, d: 29 });
  });

  test('todayLocal and localDateOf', () => {
    expect(todayLocal(new Date('2026-11-11T22:30:00Z'), 180)).toBe('2026-11-12');
    expect(todayLocal(new Date('2026-11-11T20:30:00Z'), 180)).toBe('2026-11-11');
    expect(localDateOf('2026-10-31T21:30:00.000Z', 180)).toBe('2026-11-01');
  });

  test('addDays, addMonthsClamped, daysBetween', () => {
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(addMonthsClamped('2026-03-31', -1)).toBe('2026-02-28');
    expect(addMonthsClamped('2028-03-31', -1)).toBe('2028-02-29');
    expect(addMonthsClamped('2026-11-11', -12)).toBe('2025-11-11');
    expect(addMonthsClamped('2026-01-15', -3)).toBe('2025-10-15');
    expect(daysBetween('2026-11-01', '2026-11-11')).toBe(10);
  });

  test('monthsInRange clips the first and last month', () => {
    const m = monthsInRange('2026-09-15', '2026-11-11');
    expect(m.map((x) => x.month)).toEqual(['2026-09', '2026-10', '2026-11']);
    expect(m[0]).toEqual({ month: '2026-09', label: 'September 2026', from: '2026-09-15', to: '2026-09-30', partial: true });
    expect(m[1]).toEqual({ month: '2026-10', label: 'October 2026', from: '2026-10-01', to: '2026-10-31', partial: false });
    expect(m[2].partial).toBe(true);
    expect(monthsInRange('2025-12-01', '2026-11-11')).toHaveLength(12);
  });

  test('rangeLabel matches Period._range', () => {
    expect(rangeLabel('2026-11-01', '2026-11-07')).toBe('1 – 7 Nov 2026');
    expect(rangeLabel('2026-11-29', '2026-12-05')).toBe('29 Nov – 5 Dec 2026');
    expect(rangeLabel('2025-12-28', '2026-01-03')).toBe('28 Dec 2025 – 3 Jan 2026');
    expect(rangeLabel('2026-11-03', '2026-11-03')).toBe('3 Nov 2026');
    expect(rangeLabel('2026-09-01', '2026-11-11')).toBe('1 Sep – 11 Nov 2026');
  });

  test('longDate', () => {
    expect(longDate('2026-11-11')).toBe('Wednesday, 11 November 2026 (2026-11-11)');
  });
});
