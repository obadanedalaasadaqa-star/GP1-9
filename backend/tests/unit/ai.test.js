const Anthropic = require('@anthropic-ai/sdk');
const {
  AI_MODEL, useFallbacks, getAiClient, createMessage, AiError, aiErrorResponse, generateInsight,
} = require('../../src/lib/ai');

const thinking = { type: 'thinking', thinking: '', signature: 'sig' };
const reply = (text, extra = {}) => ({
  model: 'claude-haiku-5-5',
  stop_reason: 'end_turn',
  usage: { input_tokens: 700, output_tokens: 400, cache_read_input_tokens: 0 },
  content: [thinking, { type: 'text', text }],
  ...extra,
});
const facts = { thisMonth: { total: '287.99', receipts: 7 } };
const okJson = JSON.stringify({ summary: 'You spent 287.99 JD so far this month.', tip: 'Keep an eye on Electronics.' });

function fakeClient(impl = async () => reply(okJson)) {
  return { beta: { messages: { create: jest.fn(impl) } }, messages: { create: jest.fn(impl) } };
}

const headers = new Headers();
const apiError = (status) => Anthropic.APIError.generate(status, { error: { type: 'x', message: 'm' } }, 'm', headers);

afterEach(() => {
  delete process.env.AI_MODEL;
  delete process.env.AI_FALLBACKS;
  delete process.env.ANTHROPIC_API_KEY;
});

describe('createMessage', () => {
  test('default: Haiku 5.5 on messages.create, no fallbacks, options passed', async () => {
    const c = fakeClient();
    await createMessage(c, { max_tokens: 10, messages: [] }, { timeout: 15000, maxRetries: 1 });
    expect(AI_MODEL()).toBe('claude-haiku-5-5');
    expect(useFallbacks()).toBe(false);
    expect(c.beta.messages.create).not.toHaveBeenCalled();
    expect(c.messages.create).toHaveBeenCalledTimes(1);
    const [body, opts] = c.messages.create.mock.calls[0];
    expect(body.model).toBe('claude-haiku-5-5');
    expect(body).not.toHaveProperty('betas');
    expect(body).not.toHaveProperty('fallbacks');
    expect(opts).toEqual({ timeout: 15000, maxRetries: 1 });
  });

  test('AI_FALLBACKS=on with Haiku still sends no fallbacks', async () => {
    process.env.AI_FALLBACKS = 'on';
    const c = fakeClient();
    await createMessage(c, { max_tokens: 10, messages: [] }, { timeout: 1, maxRetries: 0 });
    expect(c.beta.messages.create).not.toHaveBeenCalled();
    expect(c.messages.create.mock.calls[0][0]).not.toHaveProperty('fallbacks');
  });

  test('AI_FALLBACKS=on with an Opus/Sonnet 5.5 model uses the fallback beta', async () => {
    process.env.AI_FALLBACKS = 'on';
    for (const model of ['claude-opus-5-5', 'claude-sonnet-5-5']) {
      process.env.AI_MODEL = model;
      const c = fakeClient();
      await createMessage(c, { max_tokens: 10, messages: [] }, { timeout: 20000, maxRetries: 0 });
      expect(c.messages.create).not.toHaveBeenCalled();
      const [body, opts] = c.beta.messages.create.mock.calls[0];
      expect(body.model).toBe(model);
      expect(body.betas).toContain('server-side-fallback-2026-07-01');
      expect(body.fallbacks).toBe('default');
      expect(opts).toEqual({ timeout: 20000, maxRetries: 0 });
    }
  });

  test('Opus model with fallbacks not on: plain messages.create', async () => {
    process.env.AI_MODEL = 'claude-opus-5-5';
    const c = fakeClient();
    await createMessage(c, { max_tokens: 10, messages: [] }, { timeout: 1, maxRetries: 0 });
    expect(c.messages.create.mock.calls[0][0].model).toBe('claude-opus-5-5');
    expect(c.beta.messages.create).not.toHaveBeenCalled();
  });
});

describe('generateInsight', () => {
  test('request shape: Haiku-safe params only, low effort, JSON schema', async () => {
    const c = fakeClient();
    const out = await generateInsight(c, facts);
    const [body, opts] = c.messages.create.mock.calls[0];
    expect(body.max_tokens).toBe(3000);
    expect(body.output_config.effort).toBe('low');
    expect(body.output_config.format.type).toBe('json_schema');
    expect(opts).toEqual({ timeout: 15000, maxRetries: 1 });
    for (const k of ['thinking', 'temperature', 'top_p', 'top_k', 'metadata', 'tool_choice']) {
      expect(body).not.toHaveProperty(k);
    }
    // No assistant prefill: the last message is the user's.
    expect(body.messages.at(-1).role).toBe('user');
    expect(out).toEqual({
      summary: 'You spent 287.99 JD so far this month.',
      tip: 'Keep an eye on Electronics.',
      model: 'claude-haiku-5-5',
      usage: { input: 700, output: 400, cacheRead: 0 },
    });
  });

  test('refusal and invented numbers throw AiError with usage', async () => {
    const refusal = fakeClient(async () => reply(okJson, { stop_reason: 'refusal', stop_details: { type: 'refusal' } }));
    await expect(generateInsight(refusal, facts)).rejects.toMatchObject({ reason: 'refusal', usage: { input: 700 } });

    const invented = fakeClient(async () => reply(JSON.stringify({ summary: 'You spent 999.99 JD.', tip: 'Save.' })));
    await expect(generateInsight(invented, facts)).rejects.toMatchObject({ reason: 'invented_number' });

    const save = fakeClient(async () => reply(JSON.stringify({ summary: 'You spent 287.99 JD.', tip: 'You could save 10 JD.' })));
    await expect(generateInsight(save, facts)).rejects.toBeInstanceOf(AiError);
  });
});

describe('AiError', () => {
  test('keeps usage', () => {
    expect(new AiError('x', { input: 1, output: 2 }).usage).toEqual({ input: 1, output: 2 });
  });
});

describe('aiErrorResponse', () => {
  beforeEach(() => jest.spyOn(console, 'error').mockImplementation(() => {}));
  afterEach(() => jest.restoreAllMocks());

  test('built SDK errors are real instances', () => {
    expect(apiError(429)).toBeInstanceOf(Anthropic.RateLimitError);
    expect(apiError(401)).toBeInstanceOf(Anthropic.AuthenticationError);
    expect(apiError(400)).toBeInstanceOf(Anthropic.BadRequestError);
  });

  test.each([
    ['insight', new AiError('bad_json'), 502, 'Could not create an insight right now. Try again later.'],
    ['chat', new AiError('bad_json'), 502, "I couldn't answer that right now. Try asking in a different way."],
    ['chat', new AiError('deadline'), 504, 'The AI took too long. Try a simpler question.'],
    ['insight', apiError(429), 503, 'The AI service is busy. Try again in a minute.'],
    ['chat', apiError(429), 503, 'The AI service is busy. Try again in a minute.'],
    ['insight', apiError(529), 503, 'The AI service is busy. Try again in a minute.'],
    ['insight', apiError(401), 503, 'AI insights are not available right now.'],
    ['chat', apiError(401), 503, 'Ask AI is not available right now.'],
    ['insight', apiError(400), 502, 'Could not create an insight right now. Try again later.'],
    ['chat', apiError(400), 502, "I couldn't answer that right now. Try asking in a different way."],
    ['insight', new Anthropic.APIConnectionTimeoutError(), 504, 'The AI took too long. Try again.'],
    ['chat', new Anthropic.APIConnectionTimeoutError(), 504, 'The AI took too long. Try a simpler question.'],
    ['insight', new Anthropic.APIConnectionError({ message: 'x' }), 502, 'Could not create an insight right now. Try again later.'],
    ['insight', apiError(500), 502, 'Could not create an insight right now. Try again later.'],
    ['report', apiError(429), 503, 'The AI service is busy. Try again later.'],
    ['report', new AiError('invented_number'), 502, 'AI summary is not available right now.'],
    ['report', new Anthropic.APIConnectionTimeoutError(), 504, 'The AI took too long this time.'],
  ])('%s %p -> %i', (feature, err, status, error) => {
    expect(aiErrorResponse(err, feature)).toMatchObject({ status, error });
  });

  test('auth failure is logged; a plain Error is not an AI failure', () => {
    expect(aiErrorResponse(apiError(401), 'insight').reason).toBe('auth');
    expect(console.error).toHaveBeenCalledWith('[ai] AUTH FAILED - check ANTHROPIC_API_KEY');
    expect(aiErrorResponse(new Error('db'), 'insight')).toBeNull();
  });
});

describe('getAiClient', () => {
  test('null with no key, a client with one', () => {
    expect(getAiClient()).toBeNull();
    process.env.ANTHROPIC_API_KEY = 'sk-test-not-real';
    const c = getAiClient();
    expect(c).toBeInstanceOf(Anthropic.Anthropic);
    expect(typeof c.messages.create).toBe('function');
    expect(getAiClient()).toBe(c);
  });
});
