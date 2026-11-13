jest.mock('../src/lib/mailer', () => require('./mailerMock'));
jest.mock('../src/lib/twilioVerify', () => require('./twilioMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const twilio = require('./twilioMock');
const { lastCodeFor } = require('./mailerMock');
const { maskPhone, normalizeJordanPhone } = require('../src/lib/phone');
const { makeApp, registerUser, uniquePhone, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const send = (u) => request(app).post('/api/user/phone/send-code').set(auth(u.token));
const verify = (u, code) =>
  request(app).post('/api/user/phone/verify').set(auth(u.token)).send({ code });
const patchPhone = (u, phone) => request(app).patch('/api/user/me').set(auth(u.token))
  .send({ firstName: 'Test', lastName: 'User', phone });
const where = (u, type = 'phone') => ({ userId_type: { userId: u.user.id, type } });
const codeRow = (u, type) => prisma.verificationCode.findUnique({ where: where(u, type) });
// Skip the route's own 60 s resend wait by backdating the last send.
const allowResend = (u) => prisma.verificationCode.update({
  where: where(u), data: { lastSentAt: new Date(Date.now() - 2 * 60 * 1000) },
});
const phoneOf = (u) => u.user.phone; // register returns the normalized number
const codeFor = (u) => twilio.lastSmsCodeFor(phoneOf(u));

// A 6-digit code that is guaranteed to differ from [code].
function wrongCode(code) {
  return code.slice(0, 5) + String((Number(code[5]) + 1) % 10);
}

const NO_LONGER_VALID = 'This code is no longer valid. Tap "Resend code" for a new one.';

beforeAll(() => twilio.reset());
beforeEach(() => {
  twilio.resetCalls();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());
afterAll(cleanup);

describe('send and verify (Twilio mode, fake Twilio)', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('P-1: a new account is not verified; send-code texts the normalized number', async () => {
    expect(u.user.phoneVerified).toBe(false);
    const res = await send(u);
    expect(res.status).toBe(200);
    expect(res.body.message).toBe(`Code sent to ${maskPhone(phoneOf(u))}.`);
    expect(res.body.message).toMatch(/^Code sent to 07[789] \*\*\* \d{4}\.$/);
    expect(twilio.starts).toEqual([{ phone: phoneOf(u), sid: expect.stringMatching(/^VE/) }]);

    const row = await codeRow(u, 'phone');
    expect(row.codeHash).toBe(`twilio:${twilio.starts[0].sid}`);
    expect(row.sentTo).toBe(phoneOf(u));
  });

  test('P-2: a second send within a minute gives 429 with waitSeconds', async () => {
    const res = await send(u);
    expect(res.status).toBe(429);
    expect(res.body.waitSeconds).toBeGreaterThan(0);
    expect(twilio.startVerification).not.toHaveBeenCalled();
  });

  test('P-3: bad input and a wrong code', async () => {
    const bad = await verify(u, '12a');
    expect(bad.status).toBe(400);
    expect(bad.body.error).toBe('Enter the 6-digit code.');

    const wrong = await verify(u, wrongCode(codeFor(u)));
    expect(wrong.status).toBe(400);
    expect(wrong.body.error).toBe('Incorrect code. 4 attempts left.');
  });

  test('P-4: the right code verifies, deletes the row, and a second verify is a 400', async () => {
    const res = await verify(u, codeFor(u));
    expect(res.status).toBe(200);
    expect(res.body.phoneVerified).toBe(true);
    expect(res.body).not.toHaveProperty('password');
    expect(await codeRow(u, 'phone')).toBeNull();

    const me = await request(app).get('/api/user/me').set(auth(u.token));
    expect(me.body.phoneVerified).toBe(true);

    const again = await verify(u, codeFor(u));
    expect(again.status).toBe(400);
    expect(again.body.error).toBe('Phone number is already verified.');
    const resend = await send(u);
    expect(resend.status).toBe(400);
    expect(resend.body.error).toBe('Phone number is already verified.');
  });

  test('P-5: PATCH /me with the same number (another format) keeps the badge', async () => {
    const local = phoneOf(u).replace('+962', '0');
    const res = await patchPhone(u, local);
    expect(res.status).toBe(200);
    expect(res.body.phoneVerified).toBe(true);
  });

  test('P-6: PATCH /me with a new number resets the badge', async () => {
    const res = await patchPhone(u, uniquePhone());
    expect(res.status).toBe(200);
    expect(res.body.phoneVerified).toBe(false);
    u.user.phone = res.body.phone;
  });

  test('email verification is untouched by phone codes', async () => {
    const email = await codeRow(u, 'email');
    expect(email).not.toBeNull();
    expect(email.sentTo).toBeNull();
    const res = await request(app).post('/api/user/email/verify').set(auth(u.token))
      .send({ code: lastCodeFor(u.email) });
    expect(res.status).toBe(200);
    expect(res.body.emailVerified).toBe(true);
    expect(res.body.phoneVerified).toBe(false);
  });
});

describe('route guards', () => {
  test('P-7: no token gives 401', async () => {
    expect((await request(app).post('/api/user/phone/send-code')).status).toBe(401);
    expect((await request(app).post('/api/user/phone/verify').send({ code: '123456' })).status).toBe(401);
  });

  test('P-8: an account without a phone gets 400 and Twilio is not called', async () => {
    const u = await registerUser(app);
    await prisma.user.update({ where: { id: u.user.id }, data: { phone: null } });
    const res = await send(u);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Add a valid mobile number in Profile first.');
    expect(twilio.startVerification).not.toHaveBeenCalled();
  });
});

describe('Twilio start errors', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('P-9: cannot-receive reasons, and Twilio\'s own limit', async () => {
    twilio.state.startError = { code: 21608 };
    const trial = await send(u);
    expect(trial.status).toBe(400);
    expect(trial.body).toEqual({
      error: "This number can't receive Nexus SMS yet: our demo SMS account can only text the team's numbers.",
      reason: 'trialOnly',
    });

    twilio.state.startError = { code: 21211 };
    const invalid = await send(u);
    expect(invalid.status).toBe(400);
    expect(invalid.body.error)
      .toBe("This number can't receive Nexus SMS yet: the number isn't valid. Check it in Profile.");
    expect(invalid.body.reason).toBe('invalidNumber');

    twilio.state.startError = { code: 60203, status: 429 };
    const tooMany = await send(u);
    expect(tooMany.status).toBe(429);
    expect(tooMany.body.error).toBe('Too many SMS to this number. Try again later.');

    // Nothing was saved, so there is no wait either.
    expect(await codeRow(u, 'phone')).toBeNull();
  });

  test('P-12: any other start error gives 502 and saves nothing', async () => {
    twilio.state.startError = { code: 20003, status: 401 };
    const res = await send(u);
    expect(res.status).toBe(502);
    expect(res.body.error).toBe('Could not send the SMS. Please try again.');
    expect(await codeRow(u, 'phone')).toBeNull();
  });
});

describe('resends', () => {
  test('P-10: a resend cancels the old verification; only the new code works', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    const firstSid = twilio.starts[0].sid;
    const firstCode = codeFor(u);

    await allowResend(u);
    expect((await send(u)).status).toBe(200);
    expect(twilio.cancelledSids).toEqual([firstSid]);
    const second = twilio.starts[1];
    expect(second.sid).not.toBe(firstSid);
    expect((await codeRow(u, 'phone')).codeHash).toBe(`twilio:${second.sid}`);

    if (firstCode !== codeFor(u)) {
      const old = await verify(u, firstCode);
      expect(old.status).toBe(400);
      expect(old.body.error).toBe('Incorrect code. 4 attempts left.');
    }
    expect((await verify(u, codeFor(u))).status).toBe(200);
  }, SLOW);

  test('P-11: a failed cancel is logged and the send goes on', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    await allowResend(u);
    twilio.state.cancelFails = true;
    const res = await send(u);
    expect(res.status).toBe(200);
    expect(twilio.cancelVerification).toHaveBeenCalledTimes(1);
    expect(twilio.startVerification).toHaveBeenCalledTimes(2);
  }, SLOW);
});

describe('check errors and used-up codes', () => {
  test('P-13: a Twilio check failure gives 502 and does not count an attempt', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    twilio.state.checkFails = true;
    const res = await verify(u, codeFor(u));
    expect(res.status).toBe(502);
    expect(res.body.error).toBe('Could not check the code. Please try again.');
    expect((await codeRow(u, 'phone')).attempts).toBe(0);
  });

  test('P-14: 5 wrong codes lock it; a resend cancels the used-up verification', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    const sid = twilio.starts[0].sid;
    const bad = wrongCode(codeFor(u));
    let last;
    for (let i = 0; i < 5; i++) last = await verify(u, bad);
    expect(last.body.error).toBe('Too many wrong attempts. Tap "Resend code" for a new one.');

    const right = await verify(u, codeFor(u));
    expect(right.status).toBe(400);
    expect(right.body.error).toMatch(/Too many wrong attempts/);
    expect(twilio.checkVerification).toHaveBeenCalledTimes(5); // the 6th never reached Twilio

    await allowResend(u);
    expect((await send(u)).status).toBe(200);
    expect(twilio.cancelledSids).toEqual([sid]);
    expect((await verify(u, codeFor(u))).status).toBe(200);
  }, SLOW);

  test('P-15: a verification Twilio no longer has gives the Resend 400, and the SID is kept', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    const sid = twilio.starts[0].sid;
    twilio.useUpChecks(phoneOf(u)); // e.g. checked from somewhere else

    const res = await verify(u, codeFor(u));
    expect(res.status).toBe(400);
    expect(res.body.error).toBe(NO_LONGER_VALID);
    const row = await codeRow(u, 'phone');
    expect(row.codeHash).toBe(`twilio:${sid}`);
    expect(row.expiresAt.getTime()).toBeLessThanOrEqual(Date.now());

    await allowResend(u);
    expect((await send(u)).status).toBe(200);
    expect(twilio.cancelledSids).toEqual([sid]);
    expect((await verify(u, codeFor(u))).status).toBe(200);
  }, SLOW);

  test('P-16: a Twilio row while Twilio is not configured gives the Resend 400 without calling Twilio', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    twilio.state.configured = false;
    const res = await verify(u, codeFor(u));
    expect(res.status).toBe(400);
    expect(res.body.error).toBe(NO_LONGER_VALID);
    expect(twilio.checkVerification).not.toHaveBeenCalled();
  });
});

describe('number changes', () => {
  test('P-17: after a number change the old code fails, and a resend is allowed at once', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    const oldCode = codeFor(u);

    const patched = await patchPhone(u, uniquePhone());
    expect(patched.status).toBe(200);
    expect(patched.body.phoneVerified).toBe(false);

    const res = await verify(u, oldCode);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Your number changed after the code was sent. Tap "Resend code".');
    expect(twilio.checkVerification).not.toHaveBeenCalled();

    u.user.phone = patched.body.phone;
    const resend = await send(u);
    expect(resend.status).toBe(200);
    expect(twilio.starts.at(-1).phone).toBe(normalizeJordanPhone(patched.body.phone));
    expect((await verify(u, codeFor(u))).status).toBe(200);
  }, SLOW);

  test('a 409 on PATCH /me expires nothing', async () => {
    const a = await registerUser(app);
    const b = await registerUser(app);
    expect((await send(a)).status).toBe(200);
    const res = await patchPhone(a, phoneOf(b));
    expect(res.status).toBe(409);
    expect((await codeRow(a, 'phone')).expiresAt.getTime()).toBeGreaterThan(Date.now());
    expect((await verify(a, codeFor(a))).status).toBe(200);
  }, SLOW);
});

describe('double submit', () => {
  test('P-18: two verifies with the right code at once give one 200 and one 400, no 500', async () => {
    const u = await registerUser(app);
    expect((await send(u)).status).toBe(200);
    const code = codeFor(u);
    const results = await Promise.all([verify(u, code), verify(u, code)]);
    const statuses = results.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 400]);
    const loser = results.find((r) => r.status === 400);
    expect(loser.body.error).toMatch(/already verified|No active code|no longer valid/);
  });
});

describe('dev mode (no Twilio)', () => {
  test('the code is printed masked, and it verifies', async () => {
    const u = await registerUser(app);
    twilio.state.configured = false;
    const res = await send(u);
    expect(res.status).toBe(200);
    expect(twilio.startVerification).not.toHaveBeenCalled();

    const line = console.log.mock.calls.map((c) => c[0]).find((l) => /^\[sms:dev\]/.test(l));
    expect(line).toMatch(/^\[sms:dev\] Phone code for 07[789] \*\*\* \d{4}: \d{6}$/);
    expect(line).not.toContain(phoneOf(u).slice(4));
    const code = line.slice(-6);

    const row = await codeRow(u, 'phone');
    expect(row.codeHash).not.toMatch(/^twilio:/);
    expect(row.sentTo).toBe(phoneOf(u));

    const wrong = await verify(u, wrongCode(code));
    expect(wrong.body.error).toBe('Incorrect code. 4 attempts left.');
    const ok = await verify(u, code);
    expect(ok.status).toBe(200);
    expect(ok.body.phoneVerified).toBe(true);
    expect(await codeRow(u, 'phone')).toBeNull();
  }, SLOW);

  test('in production without Twilio, send-code is a 502 and nothing is printed', async () => {
    const u = await registerUser(app);
    twilio.state.configured = false;
    const saved = process.env.NODE_ENV;
    process.env.NODE_ENV = 'production';
    try {
      const res = await send(u);
      expect(res.status).toBe(502);
      expect(res.body.error).toBe('Could not send the SMS. Please try again.');
    } finally {
      process.env.NODE_ENV = saved;
    }
    expect(console.log.mock.calls.some((c) => /^\[sms:dev\]/.test(c[0]))).toBe(false);
    expect(await codeRow(u, 'phone')).toBeNull();
  });
});
