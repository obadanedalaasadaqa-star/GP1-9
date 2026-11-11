jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const Anthropic = require('@anthropic-ai/sdk');
const prisma = require('../src/lib/prisma');
const { makeApp, registerUser, cleanup } = require('./helpers');
const { makeFakeAi, reply, text, toolUse } = require('./fakeAi');
const { REFUSAL_TEXT } = require('../src/lib/aiChat');
const { takeQuota, recordTokens } = require('../src/lib/aiUsage');
const { auth, seededUser, usageRow } = require('./aiHelpers');

const SLOW = 120_000;

const ai = makeFakeAi();
const app = makeApp({ aiClient: ai.client });
const QUESTION = 'How much did I spend this month?';
const ask = (token, body, a = app) => request(a).post('/api/ai/chat').set(auth(token)).send(body);
const askQ = (token, question = QUESTION, a = app) => ask(token, { question, tzOffsetMinutes: 180 }, a);
const sdkError = (status) => Anthropic.APIError.generate(status, { error: { type: 'x', message: 'm' } }, 'm', new Headers());
const todayFrom = (req) => /\((\d{4}-\d{2}-\d{2})\)/.exec(req.system[1].text)[1];
const thisMonth = (req) => ({ from: `${todayFrom(req).slice(0, 8)}01`, to: todayFrom(req) });

let seeded;
beforeAll(async () => { seeded = await seededUser(app); }, SLOW);
afterAll(cleanup);
beforeEach(() => {
  ai.reset();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('POST /api/ai/chat', () => {
  test('C-1 done-when: the demo answer comes from the tool result', async () => {
    const res = await askQ(seeded.token);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      answer: 'So far this month you spent 287.99 JD.', toolsUsed: ['get_spending_summary'], remainingToday: 29,
    });
    const result = ai.seen[1].messages.at(-1).content[0];
    expect(result.content).toContain('"total":"287.99"');
    expect(result.content).toContain('"receipts":7');
  }, SLOW);

  test('C-2 tools only read the caller\'s receipts', async () => {
    const a = await seededUser(app);
    const b = await registerUser(app);
    await request(app).post('/api/receipts').set(auth(b.token))
      .send({ storeName: 'OtherUserStore', category: 'Food', totalAmount: 77.77, items: ['x'] });
    const listThenAnswer = () => {
      ai.next((req) => reply([toolUse('l1', 'list_receipts', { ...thisMonth(req), limit: 20 })], { stop_reason: 'tool_use' }));
      ai.next(() => reply([text('Here are your receipts.')]));
    };

    listThenAnswer();
    expect((await askQ(a.token, 'List my receipts')).status).toBe(200);
    const forA = ai.seen[1].messages.at(-1).content[0].content;
    for (const s of ['Carrefour', 'City Pharmacy', 'Hashem Restaurant', 'Zara', 'Co-op Supermarket', 'Books@Cafe', 'iStore']) {
      expect(forA).toContain(s);
    }
    expect(forA).not.toContain('OtherUserStore');
    expect(forA).not.toContain('77.77');

    ai.reset();
    listThenAnswer();
    expect((await askQ(b.token, 'List my receipts')).status).toBe(200);
    const forB = JSON.parse(ai.seen[1].messages.at(-1).content[0].content);
    expect(forB.receipts).toHaveLength(1);
    expect(forB.receipts[0]).toMatchObject({ store: 'OtherUserStore', total: '77.77' });
  }, SLOW);

  test('C-3 privacy: nothing personal is sent; tool outputs have no ids', async () => {
    const u = seeded;
    ai.next((req) => reply([toolUse('l1', 'get_line_items', thisMonth(req))], { stop_reason: 'tool_use' }));
    ai.next(() => reply([text('Done.')]));
    await askQ(u.token, 'What did I buy?');
    const sent = JSON.stringify(ai.seen);
    for (const bad of [u.email, u.user.serialNumber, u.user.phone, u.user.id, '"userId"']) {
      expect(sent).not.toContain(bad);
    }
    // Tool outputs have no id keys (the API's own tool_use ids are allowed).
    const output = ai.seen[1].messages.at(-1).content[0].content;
    expect(output).toContain('Carrefour');
    expect(output).not.toMatch(/"id"|"storeId"|"userId"/);
  }, SLOW);

  test('C-4 validation 400s (code points, history rules, tz)', async () => {
    const Q = 'Type a question (up to 500 characters).';
    const H = 'Invalid chat history.';
    const pair = [{ role: 'user', text: 'Hi' }, { role: 'assistant', text: 'Hello' }];
    const cases = [
      [{ question: '' }, Q],
      [{ question: '   \n ' }, Q],
      [{ question: 'x'.repeat(501) }, Q],
      [{ question: 42 }, Q],
      [{ question: '😀'.repeat(501) }, Q],
      [{ question: 'ok', history: Array.from({ length: 6 }, () => pair).flat().slice(0, 11) }, H],
      [{ question: 'ok', history: [{ role: 'system', text: 'x' }, pair[1]] }, H],
      [{ question: 'ok', history: [{ ...pair[0], extra: 1 }, pair[1]] }, H],
      [{ question: 'ok', history: [pair[0], pair[0]] }, H],
      [{ question: 'ok', history: [pair[0]] }, H],
      [{ question: 'ok', history: 'nope' }, H],
      [{ question: 'ok', history: [{ role: 'user', text: 'x'.repeat(501) }, pair[1]] }, H],
      [{ question: 'ok', history: [pair[0], { role: 'assistant', text: 'x'.repeat(1501) }] }, H],
      [{ question: 'ok', tzOffsetMinutes: 900 }, 'tzOffsetMinutes must be a whole number of minutes between -720 and 840.'],
    ];
    for (const [body, error] of cases) {
      const res = await ask(seeded.token, body);
      expect([res.status, res.body]).toEqual([400, { error }]);
    }
    expect(ai.create).not.toHaveBeenCalled();

    // Limits that pass: 500 emoji (1000 UTF-16 units) and a 1500-character answer in history.
    const emoji = await ask(seeded.token, { question: '😀'.repeat(500) });
    expect(emoji.status).toBe(200);
    expect(ai.seen[0].messages.at(-1).content).toBe('😀'.repeat(500));
    ai.reset();
    const long = await ask(seeded.token, {
      question: 'ok', history: [pair[0], { role: 'assistant', text: 'x'.repeat(1500) }],
    });
    expect(long.status).toBe(200);
  }, SLOW);

  test('C-5 no key: 503 and no usage row', async () => {
    const u = await seededUser(app);
    const res = await askQ(u.token, QUESTION, makeApp({ aiClient: null }));
    expect([res.status, res.body]).toEqual([503, { error: 'Ask AI is not set up on this server.' }]);
    expect(await usageRow(u.user.id, 'chat')).toBeNull();
  }, SLOW);

  test('C-6 no receipts: fixed answer, no Claude call, no usage row', async () => {
    const u = await registerUser(app);
    const res = await askQ(u.token);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      answer: "You don't have any receipts in Nexus yet. Scan your QR code at a store or add a receipt, then ask me again.",
      toolsUsed: [], remainingToday: null,
    });
    expect(ai.create).not.toHaveBeenCalled();
    expect(await usageRow(u.user.id, 'chat')).toBeNull();
  }, SLOW);

  test('C-7 daily cap', async () => {
    const capped = makeApp({ aiClient: ai.client, aiCaps: { chatPerDay: 2 } });
    const u = await seededUser(app);
    expect((await askQ(u.token, QUESTION, capped)).body.remainingToday).toBe(1);
    expect((await askQ(u.token, QUESTION, capped)).body.remainingToday).toBe(0);
    const third = await askQ(u.token, QUESTION, capped);
    expect([third.status, third.body]).toEqual([429, { error: "You've reached today's limit of 2 questions. Try again tomorrow." }]);
    expect(ai.create).toHaveBeenCalledTimes(4); // 2 calls per answered question
  }, SLOW);

  test('C-8 burst limiter rejects before the daily slot', async () => {
    const limited = makeApp({ aiClient: ai.client, rateLimit: { aiChat: { limit: 1 } } });
    const u = await seededUser(app);
    expect((await askQ(u.token, QUESTION, limited)).status).toBe(200);
    const second = await askQ(u.token, QUESTION, limited);
    expect([second.status, second.body]).toEqual([429, { error: 'Too many questions. Wait a few minutes and try again.' }]);
    expect((await usageRow(u.user.id, 'chat')).count).toBe(1);
  }, SLOW);

  test('C-9 the number guard: invented amounts are never shown', async () => {
    for (const bad of ['You spent 999.99 JD.', 'You could save 10 JD.']) {
      const u = await seededUser(app);
      ai.reset();
      ai.always(() => reply([text(bad)]));
      const res = await askQ(u.token);
      expect([res.status, res.body]).toEqual([502, { error: "I couldn't answer that right now. Try asking in a different way." }]);
      expect(ai.create).toHaveBeenCalledTimes(2);
    }
  }, SLOW);

  test('C-10 refusal is a polite 200', async () => {
    ai.next(() => reply([], { stop_reason: 'refusal', stop_details: { type: 'refusal' } }));
    const res = await askQ(seeded.token, 'Something unsafe');
    expect(res.status).toBe(200);
    expect(res.body.answer).toBe(REFUSAL_TEXT);
  }, SLOW);

  test('C-11 off-topic: one sentence, no tools', async () => {
    const line = 'I can only help with your Nexus spending. Try asking: how much did I spend this month?';
    ai.next(() => reply([text(line)]));
    const res = await askQ(seeded.token, 'Write me a poem about cats');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ answer: line, toolsUsed: [] });
  }, SLOW);

  test('C-12 SDK errors', async () => {
    const cases = [
      [sdkError(429), 503, 'The AI service is busy. Try again in a minute.'],
      [sdkError(401), 503, 'Ask AI is not available right now.'],
      [new Anthropic.APIConnectionTimeoutError(), 504, 'The AI took too long. Try a simpler question.'],
    ];
    for (const [err, status, error] of cases) {
      ai.next(() => { throw err; });
      const res = await askQ(seeded.token);
      expect([res.status, res.body]).toEqual([status, { error }]);
    }
  }, SLOW);

  test('C-13 Express 4 survival', async () => {
    const spy = jest.spyOn(prisma.receipt, 'count').mockRejectedValueOnce(new Error('db'));
    const res = await askQ(seeded.token);
    expect([res.status, res.body]).toEqual([500, { error: 'Failed to answer.' }]);
    expect(spy).toHaveBeenCalled();
    expect((await askQ(seeded.token)).status).toBe(200);

    const raw = jest.spyOn(prisma, '$queryRaw').mockRejectedValueOnce(new Error('db'));
    const quota = await askQ(seeded.token);
    expect([quota.status, quota.body]).toEqual([500, { error: 'Failed to answer.' }]);
    expect(raw).toHaveBeenCalled();
    expect((await askQ(seeded.token)).status).toBe(200);
    expect((await request(app).get('/api/health')).status).toBe(200);
  }, SLOW);

  test('C-14 usage row: one question = count 1 and the tokens of 2 calls', async () => {
    const u = await seededUser(app);
    expect((await askQ(u.token)).status).toBe(200);
    expect(await usageRow(u.user.id, 'chat')).toEqual({ count: 1, inputTokens: 1400, outputTokens: 800 });
  }, SLOW);

  test('C-15 401 without a token', async () => {
    const res = await request(app).post('/api/ai/chat').send({ question: QUESTION });
    expect(res.status).toBe(401);
  });

  test('C-16 tokens are recorded on failure too', async () => {
    const u = await seededUser(app);
    ai.next(() => reply([text('You spent 999.99 JD.')])).next(() => reply([text('You spent 999.99 JD.')]));
    expect((await askQ(u.token)).status).toBe(502);
    expect(await usageRow(u.user.id, 'chat')).toEqual({ count: 1, inputTokens: 1400, outputTokens: 800 });
    ai.next(() => reply([], { stop_reason: 'refusal' }));
    expect((await askQ(u.token)).status).toBe(200);
    expect(await usageRow(u.user.id, 'chat')).toEqual({ count: 2, inputTokens: 2100, outputTokens: 1200 });
  }, SLOW);

  test('C-17 recordTokens is an upsert; a bad kind is only logged', async () => {
    const u = await registerUser(app);
    await recordTokens(u.user.id, 'chat', { input: 5, output: 6 });
    expect(await usageRow(u.user.id, 'chat')).toEqual({ count: 0, inputTokens: 5, outputTokens: 6 });
    expect(await takeQuota(u.user.id, 'chat', 30)).toBe(29);
    expect((await usageRow(u.user.id, 'chat')).count).toBe(1);
    await expect(recordTokens(u.user.id, 'bogus', { input: 1, output: 1 })).resolves.toBeUndefined();
    expect(console.error).toHaveBeenCalledWith('[ai/usage]', 'bad usage kind');
    await expect(takeQuota(u.user.id, 'bogus', 30)).rejects.toThrow('bad usage kind');
  }, SLOW);
});
