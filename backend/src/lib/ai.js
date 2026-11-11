// Claude API access for the AI features. The only file that imports the SDK.
const Anthropic = require('@anthropic-ai/sdk');
const { AiError, addUsage, numbersOk } = require('./aiFormat');
const { INSIGHT_SYSTEM, INSIGHT_SCHEMA, parseInsight } = require('./insight');

const DEFAULT_MODEL = 'claude-haiku-5-5';
const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

// Read on every call, so tests and Render can switch them with no code change.
const AI_MODEL = () => process.env.AI_MODEL || DEFAULT_MODEL;

// Server-side fallbacks: off unless AI_FALLBACKS=on, and only for Opus/Sonnet
// 5.5 models (Haiku 5.5 has no server-side refusal fallback).
const useFallbacks = () =>
  process.env.AI_FALLBACKS === 'on' && /^claude-(opus|sonnet)-5-5/.test(AI_MODEL());

let client = null;
let clientKey = null;

// A shared client for ANTHROPIC_API_KEY, or null when no key is set.
function getAiClient() {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return null;
  if (!client || clientKey !== key) {
    client = new Anthropic.Anthropic({ apiKey: key });
    clientKey = key;
  }
  return client;
}

/**
 * The one wrapper every feature uses. Adds the model (and the fallback beta
 * when on). Never sends thinking (adaptive thinking is on by default),
 * temperature, top_p, top_k, an assistant prefill, metadata or a forced
 * tool_choice: Haiku 5.5 answers 400 to most of them, and a forced tool_choice
 * skips thinking.
 */
function createMessage(aiClient, params, { timeout, maxRetries }) {
  const body = { ...params, model: AI_MODEL() };
  if (useFallbacks()) {
    return aiClient.beta.messages.create(
      { ...body, betas: [FALLBACK_BETA], fallbacks: 'default' },
      { timeout, maxRetries },
    );
  }
  return aiClient.messages.create(body, { timeout, maxRetries });
}

const TEXTS = {
  insight: {
    failed: 'Could not create an insight right now. Try again later.',
    busy: 'The AI service is busy. Try again in a minute.',
    auth: 'AI insights are not available right now.',
    slow: 'The AI took too long. Try again.',
    deadline: 'The AI took too long. Try again.',
  },
  chat: {
    failed: "I couldn't answer that right now. Try asking in a different way.",
    busy: 'The AI service is busy. Try again in a minute.',
    auth: 'Ask AI is not available right now.',
    slow: 'The AI took too long. Try a simpler question.',
    deadline: 'The AI took too long. Try a simpler question.',
  },
  report: {
    failed: 'AI summary is not available right now.',
    busy: 'The AI service is busy. Try again later.',
    auth: 'AI summary is not available right now.',
    slow: 'The AI took too long this time.',
    deadline: 'The AI took too long this time.',
  },
};

/**
 * { status, error, reason } for an AI failure, most specific check first,
 * or null for anything that is not an AI failure (the route answers 500).
 * For reports only `error` is used (the text of ai.error in a 200 reply).
 */
function aiErrorResponse(err, feature) {
  const t = TEXTS[feature];
  if (err instanceof AiError) {
    if (err.reason === 'deadline') return { status: 504, error: t.deadline, reason: 'deadline' };
    return { status: 502, error: t.failed, reason: err.reason };
  }
  if (err instanceof Anthropic.RateLimitError || (err instanceof Anthropic.APIError && err.status === 529)) {
    return { status: 503, error: t.busy, reason: 'busy' };
  }
  if (err instanceof Anthropic.AuthenticationError) {
    console.error('[ai] AUTH FAILED - check ANTHROPIC_API_KEY');
    return { status: 503, error: t.auth, reason: 'auth' };
  }
  if (err instanceof Anthropic.BadRequestError) {
    return { status: 502, error: t.failed, reason: err.message };
  }
  if (err instanceof Anthropic.APIConnectionTimeoutError) {
    return { status: 504, error: t.slow, reason: 'timeout' };
  }
  if (err instanceof Anthropic.APIError) {
    return { status: 502, error: t.failed, reason: err.message };
  }
  return null;
}

/**
 * Summary + tip for the insight facts. Returns { summary, tip, model, usage }
 * or throws (AiError with the tokens paid, or an SDK error).
 */
async function generateInsight(aiClient, facts) {
  const res = await createMessage(aiClient, {
    max_tokens: 3000, // thinking counts against it
    system: INSIGHT_SYSTEM,
    messages: [{ role: 'user', content: JSON.stringify(facts) }],
    output_config: { effort: 'low', format: { type: 'json_schema', schema: INSIGHT_SCHEMA } },
  }, { timeout: 15000, maxRetries: 1 });
  const usage = addUsage({ input: 0, output: 0, cacheRead: 0 }, res.usage);
  try {
    const { summary, tip } = parseInsight(res);
    if (!numbersOk(`${summary} ${tip}`, [JSON.stringify(facts)])) throw new AiError('invented_number');
    return { summary, tip, model: res.model ?? AI_MODEL(), usage };
  } catch (err) {
    if (err instanceof AiError) err.usage = usage;
    throw err;
  }
}

module.exports = {
  Anthropic, DEFAULT_MODEL, FALLBACK_BETA, AI_MODEL, useFallbacks, getAiClient,
  createMessage, AiError, aiErrorResponse, generateInsight,
};
