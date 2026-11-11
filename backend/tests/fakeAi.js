// Fake Claude client for tests. No test ever calls the real API.
//   const ai = makeFakeAi();
//   makeApp({ aiClient: ai.client })
//   ai.next(handler)   one-time handler for the next call (queue)
//   ai.always(handler) handler for every call until reset()
//   ai.seen            deep copies of every request (the chat loop mutates
//                      `messages` after the call, so mock.calls would lie)
//   ai.create          the jest.fn behind both messages.create and
//                      beta.messages.create (fallbacks are off by default)
// Without a handler the defaults below answer, built from what was sent.
const { INSIGHT_SYSTEM } = require('../src/lib/insight');

const thinking = { type: 'thinking', thinking: '', signature: 'sig-abc' };

const reply = (content, extra = {}) => ({
  id: 'msg_fake',
  type: 'message',
  role: 'assistant',
  model: 'claude-haiku-5-5',
  stop_reason: 'end_turn',
  stop_details: null,
  usage: { input_tokens: 700, output_tokens: 400, cache_read_input_tokens: 0 },
  content: [thinking, ...content],
  ...extra,
});
const text = (t) => ({ type: 'text', text: t });
const toolUse = (id, name, input) => ({ type: 'tool_use', id, name, input });
const json = (obj, extra) => reply([text(JSON.stringify(obj))], extra);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// The user's local today from the chat system date line "(YYYY-MM-DD)".
const todayFrom = (req) => /\((\d{4}-\d{2}-\d{2})\)/.exec(req.system?.[1]?.text ?? '')?.[1];

function defaultInsight(req) {
  const f = JSON.parse(req.messages[0].content);
  return json({
    summary: `You spent ${f.thisMonth.total} JD so far this month.`,
    tip: `Keep an eye on ${f.thisMonth.categories[0]?.category ?? 'your spending'}.`,
  });
}

function defaultReport(req) {
  const f = JSON.parse(req.messages[0].content);
  const top = f.categories[0];
  return json({
    headline: `You spent ${f.total} JD in this period.`,
    narrative: top ? `${top.category} was the biggest category at ${top.total} JD.` : 'No spending yet.',
    tips: ['Review your biggest category before the month ends.'],
  });
}

function defaultChat(req) {
  const last = req.messages[req.messages.length - 1];
  const result = Array.isArray(last.content) && last.content.find((b) => b.type === 'tool_result');
  if (result) {
    return reply([text(`So far this month you spent ${JSON.parse(result.content).total} JD.`)]);
  }
  const today = todayFrom(req);
  return reply(
    [toolUse('toolu_1', 'get_spending_summary', { from: `${today.slice(0, 8)}01`, to: today })],
    { stop_reason: 'tool_use' },
  );
}

function defaultHandler(req) {
  if (req.tools) return defaultChat(req);
  if (req.system === INSIGHT_SYSTEM) return defaultInsight(req);
  return defaultReport(req);
}

function makeFakeAi() {
  const seen = [];
  const queue = [];
  let always = null;
  const create = jest.fn(async (req, opts) => {
    seen.push(structuredClone(req));
    const handler = queue.shift() ?? always ?? defaultHandler;
    return handler(req, opts, seen.length);
  });
  return {
    client: { beta: { messages: { create } }, messages: { create } },
    create,
    seen,
    next(handler) { queue.push(handler); return this; },
    always(handler) { always = handler; return this; },
    reset() { queue.length = 0; always = null; seen.length = 0; create.mockClear(); },
  };
}

module.exports = {
  makeFakeAi, reply, text, toolUse, json, wait, thinking,
  defaultHandler, defaultInsight, defaultReport, defaultChat,
};
