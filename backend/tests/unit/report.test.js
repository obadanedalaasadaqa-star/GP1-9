const {
  ERR, resolvePeriod, buildReportNumbers, buildReportFacts, parseReport, generateReportText, REPORT_SCHEMA,
} = require('../../src/lib/report');
const { shapeStats } = require('../../src/lib/stats');
const { AiError } = require('../../src/lib/aiFormat');
const { SEED } = require('../fixtures/seedFacts');
const { makeFakeAi, json, reply, text } = require('../fakeAi');

const NOW = new Date('2026-11-11T10:00:00Z');
const span = (r) => [r.from, r.to, r.previous.from, r.previous.to];

describe('resolvePeriod', () => {
  test('presets are calendar months up to today; previous is N months earlier', () => {
    expect(span(resolvePeriod({ period: '1m' }, NOW, 180))).toEqual(['2026-11-01', '2026-11-11', '2026-10-01', '2026-10-11']);
    expect(span(resolvePeriod({ period: '3m' }, NOW, 180))).toEqual(['2026-09-01', '2026-11-11', '2026-06-01', '2026-08-11']);
    expect(resolvePeriod({ period: '6m' }, NOW, 180).from).toBe('2026-06-01');
    expect(span(resolvePeriod({ period: '1y' }, NOW, 180))).toEqual(['2025-12-01', '2026-11-11', '2024-12-01', '2025-11-11']);
  });

  test('1m on 31 March: previous ends on 28 Feb', () => {
    const r = resolvePeriod({ period: '1m' }, new Date('2026-03-31T10:00:00Z'), 180);
    expect(span(r)).toEqual(['2026-03-01', '2026-03-31', '2026-02-01', '2026-02-28']);
  });

  test('custom: previous is the same number of days just before', () => {
    const r = resolvePeriod({ period: 'custom', from: '2026-09-01', to: '2026-09-30' }, NOW, 180);
    expect(span(r)).toEqual(['2026-09-01', '2026-09-30', '2026-08-02', '2026-08-31']);
    expect(r.days).toBe(30);
    expect(r.label).toBe('1 – 30 Sep 2026');
    expect(r.soFar).toBe(false);
  });

  test('UTC bounds, rangeKey, labels, soFar', () => {
    const r = resolvePeriod({ period: '1m', from: 'junk', to: 'junk' }, NOW, 180);
    expect(r.fromUtc.toISOString()).toBe('2026-10-31T21:00:00.000Z');
    expect(r.toUtc.toISOString()).toBe('2026-11-11T21:00:00.000Z');
    expect(r.rangeKey).toBe('2026-10-31T21:00:00.000Z/2026-11-11T21:00:00.000Z');
    expect(r.label).toBe('1 – 11 Nov 2026');
    expect(r.previous.label).toBe('1 – 11 Oct 2026');
    expect(r.days).toBe(11);
    expect(r.soFar).toBe(true);
  });

  test.each([
    [{}, ERR.period],
    [{ period: '2m' }, ERR.period],
    [{ period: ['1m'] }, ERR.period],
    [{ period: 'custom' }, ERR.dates],
    [{ period: 'custom', from: '2026-02-30', to: '2026-03-01' }, ERR.dates],
    [{ period: 'custom', from: '2026-11-05', to: '2026-11-01' }, ERR.order],
    [{ period: 'custom', from: '2026-11-01', to: '2030-01-01' }, ERR.future],
    [{ period: 'custom', from: '2019-12-01', to: '2020-01-05' }, ERR.tooEarly],
    [{ period: 'custom', from: '2024-01-01', to: '2026-01-01' }, ERR.tooLong],
  ])('%p -> error', (params, error) => {
    expect(resolvePeriod(params, NOW, 180)).toEqual({ error });
  });

  test('messages are the planned texts', () => {
    expect(ERR).toEqual({
      period: 'period must be 1m, 3m, 6m, 1y or custom.',
      dates: 'from and to must be dates (YYYY-MM-DD).',
      order: 'from must be on or before to.',
      future: "The report can't end in the future.",
      tooLong: 'Reports can cover at most 2 years.',
      tooEarly: 'Reports start from 2020.',
    });
  });
});

// Fake queries built from the 7 seed receipts on 3 Nov 2026.
function seedQueries() {
  const receipts = SEED.map((r, i) => ({ ...r, id: `R${i}`, userId: 'U-SECRET', createdAt: new Date(`2026-11-03T0${i}:00:00Z`) }));
  const rowsFor = (list, idx = 1) => {
    if (!list.length) return [];
    const sum = (xs) => xs.reduce((s, r) => s + r.totalAmount, 0);
    const out = [{ idx, noCategory: 1, noStore: 1, total: sum(list), count: list.length }];
    const group = (key) => list.reduce((m, r) => m.set(r[key], [...(m.get(r[key]) ?? []), r]), new Map());
    for (const [category, xs] of group('category')) out.push({ idx, noCategory: 0, noStore: 1, category, total: sum(xs), count: xs.length });
    for (const [storeName, xs] of group('storeName')) out.push({ idx, noCategory: 1, noStore: 0, storeName, total: sum(xs), count: xs.length });
    return out;
  };
  const inRange = (a, b) => receipts.filter((r) => r.createdAt >= a && r.createdAt < b);
  return {
    queryRange: async (userId, a, b) => shapeStats(rowsFor(inRange(a, b)), [a, b], { allStores: true }).periods[0],
    queryStats: async (userId, bounds) => bounds.slice(0, -1).flatMap((a, i) => rowsFor(inRange(a, bounds[i + 1]), i + 1)),
    queryReceipts: async (userId, a, b, { limit }) => inRange(a, b).sort((x, y) => y.totalAmount - x.totalAmount).slice(0, limit),
  };
}

describe('buildReportNumbers + buildReportFacts on the demo data', () => {
  test('numbers and facts', async () => {
    const r = resolvePeriod({ period: '1m' }, NOW, 180);
    const n = await buildReportNumbers('U1', r, 180, seedQueries());
    expect(n.totals).toEqual({ total: 287.99, receipts: 7, average: 41.141 });
    expect(n.comparison).toEqual({ previousTotal: 0, previousReceipts: 0, difference: 287.99, changePercent: null, isNew: true });
    expect(n.byCategory.map((c) => c.sharePercent)).toEqual([31, 27, 23, 11, 8]);
    expect(n.byMonth).toEqual([{ month: '2026-11', label: 'November 2026', total: 287.99, receipts: 7, partial: true }]);
    expect(n.biggestReceipts.map((b) => b.total)).toEqual([89.99, 67, 45.5, 31.25, 23]);

    const f = buildReportFacts(n, { soFar: true, tz: 180 });
    expect(f).toMatchObject({
      currency: 'JD', period: '1 – 11 Nov 2026', previousPeriod: '1 – 11 Oct 2026', periodSoFar: true,
      total: '287.99', receipts: 7, averageReceipt: '41.14', change: 'new', difference: '+287.99',
    });
    expect(f.categories.map((c) => c.sharePercent)).toEqual([31, 27, 23, 11, 8]);
    expect(f.topStores.map((s) => s.store)).toEqual(['iStore', 'Zara', 'Carrefour', 'Co-op Supermarket', 'City Pharmacy']);
    expect(f.biggestReceipts.map((b) => b.total)).toEqual(['89.99', '67.00', '45.50']);
    expect(f.biggestReceipts[0].date).toBe('2026-11-03');
    const s = JSON.stringify(f);
    for (const bad of ['"id"', 'userId', 'email', 'U-SECRET', 'R0']) expect(s).not.toContain(bad);
  });
});

describe('parseReport', () => {
  const facts = { total: '287.99', receipts: 7, categories: [{ category: 'Food', total: '31.25', sharePercent: 11 }] };
  const ok = { headline: 'You spent 287.99 JD.', narrative: 'Food was 31.25 JD, 11% of the total.', tips: ['Plan meals.'] };
  const res = (obj, extra) => json(obj, extra);
  const reason = (fn) => { try { fn(); } catch (e) { expect(e).toBeInstanceOf(AiError); return e.reason; } return 'none'; };

  test('OK', () => {
    expect(parseReport(res(ok), facts)).toEqual(ok);
  });
  test('stop reason before text', () => {
    expect(reason(() => parseReport(res(ok, { stop_reason: 'refusal' }), facts))).toBe('refusal');
    expect(reason(() => parseReport(res(ok, { stop_reason: 'max_tokens' }), facts))).toBe('max_tokens');
  });
  test('bad answers', () => {
    expect(reason(() => parseReport(reply([text('nope')]), facts))).toBe('bad_json');
    expect(reason(() => parseReport(res({ ...ok, tips: [] }), facts))).toBe('bad_fields');
    expect(reason(() => parseReport(res({ ...ok, tips: ['a', 'b', 'c', 'd'] }), facts))).toBe('bad_fields');
    expect(reason(() => parseReport(res({ ...ok, narrative: 'x'.repeat(901) }), facts))).toBe('bad_fields');
    expect(reason(() => parseReport(res({ ...ok, headline: 'x'.repeat(121) }), facts))).toBe('bad_fields');
    expect(reason(() => parseReport(res({ ...ok, narrative: 'You could save 15 JD.' }), facts))).toBe('invented_number');
  });
  test('schema is closed', () => {
    expect(REPORT_SCHEMA.additionalProperties).toBe(false);
  });
});

describe('generateReportText', () => {
  test('a guard failure carries the usage of the paid call', async () => {
    const ai = makeFakeAi();
    ai.next(() => json({ headline: 'You spent 999.99 JD.', narrative: 'x', tips: ['y'] }));
    await expect(generateReportText(ai.client, { total: '287.99' }))
      .rejects.toMatchObject({ reason: 'invented_number', usage: { input: 700, output: 400 } });
    const [body, opts] = ai.create.mock.calls[0];
    expect(body).toMatchObject({ max_tokens: 4000, output_config: { effort: 'low', format: { type: 'json_schema' } } });
    expect(opts).toEqual({ timeout: 20000, maxRetries: 1 });
  });

  test('a response without model falls back to the configured model', async () => {
    const ai = makeFakeAi();
    ai.next(() => json({ headline: 'You spent 287.99 JD.', narrative: 'x', tips: ['y'] }, { model: undefined }));
    const out = await generateReportText(ai.client, { total: '287.99' });
    expect(out.model).toBe(process.env.AI_MODEL || 'claude-haiku-5-5');
  });
});
