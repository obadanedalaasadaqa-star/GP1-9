const Anthropic = require('@anthropic-ai/sdk');
const {
  answerQuestion, REFUSAL_TEXT, REPAIR_TEXT, TOO_MANY_LOOKUPS, todayLine,
} = require('../../src/lib/aiChat');
const { CHAT_TOOLS } = require('../../src/lib/aiTools');
const { AiError } = require('../../src/lib/aiFormat');
const { makeFakeAi, reply, text, toolUse } = require('../fakeAi');

const NOW = new Date('2026-11-11T10:00:00Z');
const USER = 'user-123-secret';

// queryRange always returns the seed month; every call is recorded.
function fakeQueries() {
  const q = {
    calls: 0,
    queryRange: jest.fn(async () => {
      q.calls++;
      return {
        total: 287.99, count: 7, average: 41.141,
        byCategory: [{ category: 'Food', total: 31.25, count: 2 }],
        stores: [{ storeName: 'iStore', total: 89.99, count: 1 }],
      };
    }),
    queryReceipts: jest.fn(async () => []),
    queryStats: jest.fn(async () => []),
  };
  return q;
}

const SUMMARY = { from: '2026-11-01', to: '2026-11-11' };
const toolReply = (blocks) => reply(blocks, { stop_reason: 'tool_use' });
const ask = (ai, queries, extra = {}, opts) => answerQuestion(ai.client, {
  userId: USER, tz: 180, history: [], question: 'How much did I spend this month?', now: NOW, queries, ...extra,
}, opts);

let ai;
let queries;
beforeEach(() => {
  ai = makeFakeAi();
  queries = fakeQueries();
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('tool loop', () => {
  test('tool_use then answer; thinking blocks sent back unchanged; one tool_result message', async () => {
    const out = await ask(ai, queries);
    expect(out.answer).toBe('So far this month you spent 287.99 JD.');
    expect(out.toolsUsed).toEqual(['get_spending_summary']);
    expect(out.calls).toBe(2);
    expect(out.usage).toEqual({ input: 1400, output: 800, cacheRead: 0 });

    const second = ai.seen[1].messages;
    expect(second).toHaveLength(3);
    expect(second[1]).toEqual({ role: 'assistant', content: [
      { type: 'thinking', thinking: '', signature: 'sig-abc' },
      { type: 'tool_use', id: 'toolu_1', name: 'get_spending_summary', input: SUMMARY },
    ] });
    expect(second[2].role).toBe('user');
    expect(second[2].content).toHaveLength(1);
    expect(second[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1' });
    expect(JSON.parse(second[2].content[0].content)).toMatchObject({ total: '287.99', receipts: 7 });
  });

  test('two tool_use blocks in one response: both run, results in one message, in order', async () => {
    ai.next(() => toolReply([
      toolUse('a1', 'get_spending_summary', SUMMARY),
      toolUse('a2', 'get_category_breakdown', SUMMARY),
    ]));
    ai.next(() => reply([text('You spent 287.99 JD.')]));
    const out = await ask(ai, queries);
    expect(out.toolsUsed).toEqual(['get_spending_summary', 'get_category_breakdown']);
    const results = ai.seen[1].messages[2].content;
    expect(results.map((r) => r.tool_use_id)).toEqual(['a1', 'a2']);
  });

  test('tool-run cap: 12 blocks run 10, the last 2 get is_error', async () => {
    ai.next(() => toolReply(Array.from({ length: 12 }, (_, i) => toolUse(`t${i}`, 'get_spending_summary', SUMMARY))));
    ai.next(() => reply([text('You spent 287.99 JD.')]));
    const out = await ask(ai, queries);
    expect(queries.calls).toBe(10);
    expect(out.toolsUsed).toHaveLength(10);
    const results = ai.seen[1].messages[2].content;
    expect(results).toHaveLength(12);
    expect(results.map((r) => r.tool_use_id)).toEqual(Array.from({ length: 12 }, (_, i) => `t${i}`));
    expect(results.slice(10)).toEqual([
      { type: 'tool_result', tool_use_id: 't10', content: TOO_MANY_LOOKUPS, is_error: true },
      { type: 'tool_result', tool_use_id: 't11', content: TOO_MANY_LOOKUPS, is_error: true },
    ]);
    expect(results.slice(0, 10).every((r) => !r.is_error)).toBe(true);
  });

  test('tool-run cap counts across calls: 6 then 6', async () => {
    const six = (p) => toolReply(Array.from({ length: 6 }, (_, i) => toolUse(`${p}${i}`, 'get_spending_summary', SUMMARY)));
    ai.next(() => six('a')).next(() => six('b')).next(() => reply([text('You spent 287.99 JD.')]));
    await ask(ai, queries);
    const second = ai.seen[2].messages[4].content;
    expect(second.map((r) => !!r.is_error)).toEqual([false, false, false, false, true, true]);
    expect(queries.calls).toBe(10);
  });

  test('bad tool input and a throwing query become is_error results; the loop goes on', async () => {
    ai.next(() => toolReply([toolUse('b1', 'get_spending_summary', { from: '2026-13-01', to: '2026-11-11' })]));
    ai.next(() => toolReply([toolUse('b2', 'get_spending_summary', SUMMARY)]));
    ai.next(() => reply([text('Done.')]));
    queries.queryRange.mockRejectedValueOnce(new Error('db down'));
    const out = await ask(ai, queries);
    expect(out.answer).toBe('Done.');
    expect(ai.seen[1].messages.at(-1).content[0]).toMatchObject(
      { is_error: true, content: 'Dates must be real dates written YYYY-MM-DD.' });
    expect(ai.seen[2].messages.at(-1).content[0]).toMatchObject({ is_error: true, content: 'Could not load this data.' });
  });
});

describe('stop reasons', () => {
  test('refusal returns the polite text with usage', async () => {
    ai.next(() => reply([], { stop_reason: 'refusal', stop_details: { type: 'refusal' } }));
    const out = await ask(ai, queries);
    expect(out).toMatchObject({ answer: REFUSAL_TEXT, refused: true, usage: { input: 700, output: 400 } });
  });
  test('max_tokens throws even with a text block; unknown stop is bad_stop', async () => {
    ai.next(() => reply([text('You spent 287.99 JD.')], { stop_reason: 'max_tokens' }));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'max_tokens' });
    ai.next(() => reply([text('x')], { stop_reason: 'stop_sequence' }));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'bad_stop' });
  });
  test('empty and too-long answers', async () => {
    ai.next(() => reply([]));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'no_text' });
    ai.next(() => reply([text('a'.repeat(1501))]));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'bad_fields' });
    ai.next(() => reply([text('😀'.repeat(1500))]));
    expect((await ask(ai, queries)).answer).toHaveLength(3000); // 1500 code points
  });
});

describe('number guard', () => {
  test('an invented amount gets one repair turn, then success', async () => {
    ai.next(() => reply([text('You spent 999.99 JD.')]));
    ai.next(() => reply([text('Ask me about this month.')]));
    const out = await ask(ai, queries);
    expect(out.answer).toBe('Ask me about this month.');
    expect(ai.seen[1].messages.at(-1)).toEqual({ role: 'user', content: REPAIR_TEXT });
    expect(ai.seen[1].messages.at(-2).role).toBe('assistant');
  });

  test('"save 10 JD" (no 10 in any source) is repaired with a quoted number', async () => {
    ai.next(() => toolReply([toolUse('s1', 'get_spending_summary', SUMMARY)]));
    ai.next(() => reply([text('You could save 10 JD a month on Food.')]));
    ai.next(() => reply([text('Food is 31.25 JD so far this month.')]));
    queries.queryRange.mockImplementation(async () => ({
      total: 287.99, count: 7, average: 41.141, byCategory: [{ category: 'Food', total: 31.25, count: 2 }], stores: [],
    }));
    const out = await ask(ai, queries);
    expect(out.answer).toBe('Food is 31.25 JD so far this month.');
    expect(ai.seen[2].messages.at(-1).content).toBe(REPAIR_TEXT);
  });

  test('a second invented number throws invented_number with the usage of both calls', async () => {
    ai.always(() => reply([text('You spent 999.99 JD.')]));
    await expect(ask(ai, queries)).rejects.toMatchObject({
      reason: 'invented_number', usage: { input: 1400, output: 800 }, calls: 2,
    });
  });

  test('numbers from the question and the history pass; Arabic-Indic digits fail', async () => {
    ai.next(() => reply([text('You asked about 55.5 JD and 12.25 JD.')]));
    const history = [
      { role: 'user', text: 'Was it 12.25 JD?' },
      { role: 'assistant', text: 'I can check that.' },
    ];
    expect((await ask(ai, queries, { history, question: 'Or 55.5 JD?' })).answer).toContain('55.5');

    ai.always(() => reply([text('٢٨٧ JD')]));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'invented_number' });
  });
});

describe('limits', () => {
  test('a model that always calls tools stops after exactly 6 calls', async () => {
    ai.always(() => toolReply([toolUse('x', 'get_spending_summary', SUMMARY)]));
    await expect(ask(ai, queries)).rejects.toMatchObject({ reason: 'too_many_steps', calls: 6 });
    expect(ai.create).toHaveBeenCalledTimes(6);
  });

  test('deadline: 15 s per call, thrown before call 4; timeouts never above the time left', async () => {
    let clock = 0;
    const nowMs = () => clock;
    ai.always((req, opts) => {
      clock += 15000;
      return toolReply([toolUse('x', 'get_spending_summary', SUMMARY)]);
    });
    const err = await ask(ai, queries, {}, { nowMs }).catch((e) => e);
    expect(err).toBeInstanceOf(AiError);
    expect(err.reason).toBe('deadline');
    expect(ai.create).toHaveBeenCalledTimes(3);
    const timeouts = ai.create.mock.calls.map(([, o]) => o.timeout);
    expect(timeouts).toEqual([20000, 20000, 15000]);
    expect(err.usage).toEqual({ input: 2100, output: 1200, cacheRead: 0 });
  });

  test('an SDK error on call 2 carries the usage of call 1', async () => {
    ai.next(() => toolReply([toolUse('x', 'get_spending_summary', SUMMARY)]));
    ai.next(() => { throw Anthropic.APIError.generate(429, { error: { message: 'busy' } }, 'busy', new Headers()); });
    const err = await ask(ai, queries).catch((e) => e);
    expect(err).toBeInstanceOf(Anthropic.RateLimitError);
    expect(err.usage).toEqual({ input: 700, output: 400, cacheRead: 0 });
  });
});

describe('request shape and privacy', () => {
  test('tools, system cache breakpoint, date line, max_tokens, retries, history', async () => {
    const history = [
      { role: 'user', text: 'Hi there' },
      { role: 'assistant', text: 'Ask me about your spending.' },
    ];
    await ask(ai, queries, { history });
    const [req, opts] = ai.create.mock.calls[0];
    expect(req.tools).toBe(CHAT_TOOLS);
    expect(req).not.toHaveProperty('tool_choice');
    for (const k of ['thinking', 'temperature', 'top_p', 'top_k', 'metadata']) expect(req).not.toHaveProperty(k);
    expect(req.system[0].cache_control).toEqual({ type: 'ephemeral' });
    expect(req.system[1].text).toBe(todayLine(NOW, 180));
    expect(req.system[1].text).toBe("Today is Wednesday, 11 November 2026 (2026-11-11) in the user's time zone.");
    expect(req.max_tokens).toBe(4000);
    expect(req.output_config).toEqual({ effort: 'low' });
    expect(opts.maxRetries).toBe(0);
    expect(ai.seen[0].messages.slice(0, 3)).toEqual([
      { role: 'user', content: 'Hi there' },
      { role: 'assistant', content: 'Ask me about your spending.' },
      { role: 'user', content: 'How much did I spend this month?' },
    ]);
  });

  test('no user id in anything sent', async () => {
    await ask(ai, queries);
    expect(JSON.stringify(ai.seen)).not.toContain(USER);
  });
});
