// The real Twilio Verify module with global fetch mocked. No network.
const {
  isSmsConfigured, startVerification, cancelVerification, checkVerification,
  TwilioError, CANNOT_RECEIVE_TEXT,
} = require('../../src/lib/twilioVerify');

const TWILIO_VARS = {
  TWILIO_ACCOUNT_SID: 'ACtest',
  TWILIO_AUTH_TOKEN: 'secret-token',
  TWILIO_VERIFY_SERVICE_SID: 'VAtest1234',
};
const PHONE = '+962791234567';
const SECRET_MESSAGE = `Invalid parameter To: ${PHONE}`; // what Twilio might say

const reply = (status, body) => ({ status, json: async () => body });
const lastCall = () => global.fetch.mock.calls.at(-1);
const lastForm = () => new URLSearchParams(lastCall()[1].body);

let realFetch;
beforeAll(() => { realFetch = global.fetch; });
afterAll(() => {
  global.fetch = realFetch;
  for (const name of Object.keys(TWILIO_VARS)) delete process.env[name];
});
beforeEach(() => {
  Object.assign(process.env, TWILIO_VARS);
  global.fetch = jest.fn();
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

describe('isSmsConfigured', () => {
  test('true only with all three vars', () => {
    expect(isSmsConfigured()).toBe(true);
    for (const name of Object.keys(TWILIO_VARS)) {
      const saved = process.env[name];
      delete process.env[name];
      expect(isSmsConfigured()).toBe(false);
      process.env[name] = saved;
    }
  });
});

describe('startVerification', () => {
  test('posts To, Channel=sms and CustomFriendlyName=Nexus with Basic auth', async () => {
    global.fetch.mockResolvedValue(reply(201, { sid: 'VE123', status: 'pending' }));
    await expect(startVerification(PHONE)).resolves.toBe('VE123');

    const [url, opts] = lastCall();
    expect(url).toBe('https://verify.twilio.com/v2/Services/VAtest1234/Verifications');
    expect(opts.method).toBe('POST');
    expect(opts.headers.authorization)
      .toBe(`Basic ${Buffer.from('ACtest:secret-token').toString('base64')}`);
    expect(opts.signal).toBeDefined();
    expect(lastForm().get('To')).toBe(PHONE);
    expect(lastForm().get('Channel')).toBe('sms');
    expect(lastForm().get('CustomFriendlyName')).toBe('Nexus');
  });

  test.each([
    [21211, 'invalidNumber'],
    [60200, 'invalidNumber'],
    [21614, 'notMobile'],
    [60205, 'notMobile'],
    [21608, 'trialOnly'],
    [21408, 'countryBlocked'],
    [21610, 'optedOut'],
    [60410, 'blocked'],
  ])('code %i gives cannotReceive / %s', async (code, reason) => {
    global.fetch.mockResolvedValue(reply(400, { code, message: SECRET_MESSAGE }));
    const err = await startVerification(PHONE).catch((e) => e);
    expect(err).toBeInstanceOf(TwilioError);
    expect(err).toMatchObject({ status: 400, code, kind: 'cannotReceive', reason });
  });

  test('an unmapped 400 code gives kind failed', async () => {
    global.fetch.mockResolvedValue(reply(400, { code: 12345, message: SECRET_MESSAGE }));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ kind: 'failed', reason: null });
  });

  test('HTTP 429 and code 60203 give tooMany', async () => {
    global.fetch.mockResolvedValue(reply(429, { code: 20429 }));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ kind: 'tooMany' });
    global.fetch.mockResolvedValue(reply(400, { code: 60203 }));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ kind: 'tooMany' });
  });

  test('5xx, a network error and a non-JSON body give kind failed', async () => {
    global.fetch.mockResolvedValue(reply(503, { code: 20503 }));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ status: 503, kind: 'failed' });

    global.fetch.mockRejectedValue(new Error(`connect ETIMEDOUT for ${PHONE}`));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ status: 0, kind: 'failed' });

    global.fetch.mockResolvedValue({ status: 502, json: async () => { throw new Error('html'); } });
    await expect(startVerification(PHONE)).rejects.toMatchObject({ status: 502, kind: 'failed' });
  });

  test('a 2xx without a sid is a failure', async () => {
    global.fetch.mockResolvedValue(reply(201, {}));
    await expect(startVerification(PHONE)).rejects.toMatchObject({ kind: 'failed' });
  });

  test('errors and logs never carry the number, the token or Twilio\'s message', async () => {
    for (const code of [21608, 12345]) {
      global.fetch.mockResolvedValue(reply(400, { code, message: SECRET_MESSAGE }));
      const err = await startVerification(PHONE).catch((e) => e);
      const text = `${err.message} ${JSON.stringify(err)}`;
      expect(text).not.toContain('791234567');
      expect(text).not.toContain('Invalid parameter');
    }
    const logged = JSON.stringify(console.error.mock.calls);
    expect(console.error).toHaveBeenCalledWith('[sms] start failed',
      expect.objectContaining({ code: 21608, reason: 'trialOnly', to: '079 *** 4567' }));
    expect(logged).not.toContain('791234567');
    expect(logged).not.toContain('secret-token');
    expect(logged).not.toContain('Invalid parameter');
  });
});

describe('CANNOT_RECEIVE_TEXT', () => {
  test('every reason has a text with no digits and no +962', () => {
    expect(Object.keys(CANNOT_RECEIVE_TEXT).sort()).toEqual(
      ['blocked', 'countryBlocked', 'invalidNumber', 'notMobile', 'optedOut', 'trialOnly']);
    for (const text of Object.values(CANNOT_RECEIVE_TEXT)) {
      expect(text).not.toMatch(/\d/);
      expect(text).not.toContain('+962');
      expect(text).not.toMatch(/[.]$/); // the route adds the full stop
    }
  });
});

describe('cancelVerification', () => {
  test('posts Status=canceled to the verification', async () => {
    global.fetch.mockResolvedValue(reply(200, { status: 'canceled' }));
    await expect(cancelVerification('VEabc')).resolves.toBeUndefined();
    expect(lastCall()[0]).toBe('https://verify.twilio.com/v2/Services/VAtest1234/Verifications/VEabc');
    expect(lastForm().get('Status')).toBe('canceled');
  });

  test('a 404 counts as done', async () => {
    global.fetch.mockResolvedValue(reply(404, { code: 20404 }));
    await expect(cancelVerification('VEabc')).resolves.toBeUndefined();
  });

  test('other errors throw', async () => {
    global.fetch.mockResolvedValue(reply(500, { code: 20500 }));
    await expect(cancelVerification('VEabc')).rejects.toMatchObject({ status: 500, kind: 'failed' });
  });
});

describe('checkVerification', () => {
  test('posts To and Code to VerificationCheck', async () => {
    global.fetch.mockResolvedValue(reply(200, { status: 'approved' }));
    await expect(checkVerification(PHONE, '123456')).resolves.toBe('approved');
    expect(lastCall()[0]).toBe('https://verify.twilio.com/v2/Services/VAtest1234/VerificationCheck');
    expect(lastForm().get('To')).toBe(PHONE);
    expect(lastForm().get('Code')).toBe('123456');
  });

  test('pending is a wrong code', async () => {
    global.fetch.mockResolvedValue(reply(200, { status: 'pending' }));
    await expect(checkVerification(PHONE, '123456')).resolves.toBe('wrong');
  });

  test.each([
    ['200 canceled', reply(200, { status: 'canceled' })],
    ['200 expired', reply(200, { status: 'expired' })],
    ['404', reply(404, { code: 20404 })],
    ['429', reply(429, { code: 60202 })],
    ['60202 on a 400', reply(400, { code: 60202 })],
  ])('%s is gone', async (_label, answer) => {
    global.fetch.mockResolvedValue(answer);
    await expect(checkVerification(PHONE, '123456')).resolves.toBe('gone');
  });

  test('anything else throws a masked TwilioError', async () => {
    global.fetch.mockResolvedValue(reply(500, { code: 20500, message: SECRET_MESSAGE }));
    const err = await checkVerification(PHONE, '123456').catch((e) => e);
    expect(err).toMatchObject({ status: 500, kind: 'failed' });
    expect(err.message).toBe('Twilio request failed (500/20500)');
    expect(JSON.stringify(console.error.mock.calls)).not.toContain('791234567');
  });
});
