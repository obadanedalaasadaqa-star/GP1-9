jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const http = require('http');
const request = require('supertest');
const { io: connectClient } = require('socket.io-client');
const { createApp } = require('../src/app');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const { initRealtime, closeRealtime } = require('../src/lib/realtime');
const { issueCode } = require('../src/lib/verification');
const {
  PASSWORD, makeApp, uniqueEmail, registerUser, allowEmailResend, cleanup,
} = require('./helpers');

// Forgot password (phase 10): POST /api/auth/forgot-password and
// /api/auth/reset-password. Mail is the mock; no real email is ever sent.
// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const NEW_PASSWORD = 'Nexus@2027!';
const RESET_FAILED = 'That code is wrong or has expired. Check it, or send a new one.';
const FORGOT_BODY = { message: 'If an account uses that email, we sent it a code.', expiresInSeconds: 600 };

const app = makeApp({ resetFloorMs: 0 });
const auth = (token) => ({ Authorization: `Bearer ${token}` });

const forgot = (email, a = app) => request(a).post('/api/auth/forgot-password').send({ email });
const reset = (email, code, newPassword = NEW_PASSWORD, a = app) =>
  request(a).post('/api/auth/reset-password').send({ email, code, newPassword });
const login = (email, password) => request(app).post('/api/auth/login').send({ email, password });
const me = (token) => request(app).get('/api/user/me').set(auth(token));

const resetRow = (u) => prisma.verificationCode.findUnique({
  where: { userId_type: { userId: u.user.id, type: 'reset' } },
});
// Skip the 60 s resend wait of the user's reset code.
const allowResetResend = (u) => prisma.verificationCode.updateMany({
  where: { userId: u.user.id, type: 'reset' },
  data: { lastSentAt: new Date(Date.now() - 61 * 1000) },
});
// A 6-digit code that is guaranteed to differ from [code].
const wrongCode = (code) => code.slice(0, 5) + String((Number(code[5]) + 1) % 10);

// Ask for a reset code and return it (read from the mailer mock).
async function resetCode(u) {
  const res = await forgot(u.email);
  expect(res.status).toBe(200);
  return mailer.lastResetCodeFor(u.email);
}

// Verify the email in the DB, then turn two-step sign-in on through the real route.
async function twoFactorUser() {
  const u = await registerUser(app);
  await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: true } });
  const res = await request(app).patch('/api/user/security').set(auth(u.token)).send({ loginTwoFactor: true });
  expect(res.status).toBe(200);
  u.token = res.body.token;
  return u;
}

afterAll(cleanup);

describe('forgot-password', () => {
  test('R1 a known email gets the 200 and a 6-digit code bound to the stored address', async () => {
    const u = await registerUser(app);
    const res = await forgot(u.email);
    expect(res.status).toBe(200);
    expect(res.body).toEqual(FORGOT_BODY);
    expect(mailer.lastResetCodeFor(u.email)).toMatch(/^\d{6}$/);
    const row = await resetRow(u);
    expect(row.email).toBe(u.email);
    expect(row.attempts).toBe(0);
  }, SLOW);

  test('R2 an unknown email gets the very same body and no mail', async () => {
    const before = mailer.sentReset.length;
    const res = await forgot(uniqueEmail());
    expect(res.status).toBe(200);
    expect(res.body).toEqual(FORGOT_BODY);
    expect(mailer.sentReset.length).toBe(before);
  }, SLOW);

  test('R3 unverified, 2FA-on and a second request within 60 s all get the same body', async () => {
    const unverified = await registerUser(app);
    const twoFa = await twoFactorUser();
    const a = await forgot(unverified.email);
    const b = await forgot(twoFa.email);
    const count = mailer.sentReset.length;
    const c = await forgot(twoFa.email); // within 60 s: no second mail
    for (const res of [a, b, c]) {
      expect(res.status).toBe(200);
      expect(res.text).toBe(JSON.stringify(FORGOT_BODY));
    }
    expect(mailer.sentReset.length).toBe(count);
  }, SLOW);

  test('R4 known and unknown emails both take at least the time floor', async () => {
    const slowApp = makeApp({ resetFloorMs: 300 });
    const u = await registerUser(app);
    for (const email of [u.email, uniqueEmail()]) {
      const t = Date.now();
      const res = await forgot(email, slowApp);
      expect(res.status).toBe(200);
      expect(Date.now() - t).toBeGreaterThanOrEqual(300);
    }
  }, SLOW);

  test('R5 + T4 a mixed-case, spaced email finds the account; mail goes to the stored address', async () => {
    const u = await registerUser(app);
    const res = await forgot(`  ${u.email.toUpperCase()} `);
    expect(res.status).toBe(200);
    expect(mailer.sentReset.at(-1).to).toBe(u.email);
  }, SLOW);

  test.each([
    ['empty', ''], ['a number', 123], ['an array', ['a@b']], ['no @', 'nobody.nexus.test'],
    ['255 characters', `${'a'.repeat(242)}@nexus.test.x`],
  ])('R6 %s email gets 400 "Enter your email." and no mail', async (_name, email) => {
    const before = mailer.sentReset.length;
    const res = await forgot(email);
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'Enter your email.' });
    expect(mailer.sentReset.length).toBe(before);
  }, SLOW);

  test('T7 a failed send still gives the 200, logs the user id only, and crashes nothing', async () => {
    const u = await registerUser(app);
    const unhandled = jest.fn();
    process.on('unhandledRejection', unhandled);
    const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
    try {
      mailer.failResetSendOnce(`${u.email} rejected`);
      const res = await forgot(u.email);
      expect(res.status).toBe(200);
      expect(res.body).toEqual(FORGOT_BODY);
      await new Promise(setImmediate);
      expect(errors).toHaveBeenCalledWith('[forgot-password] send failed', u.user.id, 'MAIL_FAIL');
      expect(JSON.stringify(errors.mock.calls)).not.toContain(u.email);
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off('unhandledRejection', unhandled);
      errors.mockRestore();
    }
  }, SLOW);

  test('a DB error still gives the same 200 and logs no email', async () => {
    const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
    const spy = jest.spyOn(prisma.user, 'findUnique').mockRejectedValueOnce(
      Object.assign(new Error('db down for x@nexus.test'), { code: 'P1001' }));
    try {
      const res = await forgot('x@nexus.test');
      expect(res.status).toBe(200);
      expect(res.body).toEqual(FORGOT_BODY);
      expect(errors).toHaveBeenCalledWith('[forgot-password] failed', 'P1001');
    } finally {
      spy.mockRestore();
      errors.mockRestore();
    }
  }, SLOW);
});

describe('reset-password', () => {
  test('R7 + R8 + T9 a non-2FA user resets, old sessions end, only the new password works', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const res = await reset(u.email, code);
    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe('string');
    expect(res.body.user).toMatchObject({ id: u.user.id, email: u.email });
    expect(JSON.stringify(res.body)).not.toMatch(/password"|tokenVersion|codeHash|attempts/);

    expect((await me(u.token)).status).toBe(401);
    expect((await me(res.body.token)).status).toBe(200);
    expect((await login(u.email, PASSWORD)).status).toBe(401);
    expect((await login(u.email, NEW_PASSWORD)).status).toBe(200);

    // R9: the same code again
    const again = await reset(u.email, code, 'Nexus@2028!');
    expect(again.status).toBe(400);
    expect(again.body).toEqual({ error: RESET_FAILED });
  }, SLOW);

  test('R10 a wrong code gets the one generic 400; after 5 wrong codes the right one fails too', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    for (let i = 0; i < 5; i++) {
      const res = await reset(u.email, wrongCode(code));
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: RESET_FAILED });
      expect(res.text).not.toMatch(/attempt/i);
    }
    expect((await reset(u.email, code)).body).toEqual({ error: RESET_FAILED });
    expect((await login(u.email, PASSWORD)).status).toBe(200);
  }, SLOW);

  test('R11 an expired code fails', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    await prisma.verificationCode.update({
      where: { userId_type: { userId: u.user.id, type: 'reset' } },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });
    const res = await reset(u.email, code);
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: RESET_FAILED });
  }, SLOW);

  test('R12 an unknown email gets the same 400 body', async () => {
    const res = await reset(uniqueEmail(), '123456');
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: RESET_FAILED });
  }, SLOW);

  test('R13 a weak password gets the rule text and uses no try', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const res = await reset(u.email, code, 'weak');
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/password/i);
    expect(res.body.error).not.toBe(RESET_FAILED);
    expect((await resetRow(u)).attempts).toBe(0);
  }, SLOW);

  test('R14 a malformed code gets "Enter the 6-digit code." and uses no try', async () => {
    const u = await registerUser(app);
    await resetCode(u);
    for (const code of ['12345', ['123456'], 'abcdef', 1234567]) {
      const res = await reset(u.email, code);
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: 'Enter the 6-digit code.' });
    }
    expect((await resetRow(u)).attempts).toBe(0);
  }, SLOW);

  test('R15 after an email change the old reset code fails on both addresses', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    await allowEmailResend(u.user.id);
    const B = uniqueEmail();
    const changed = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Test', lastName: 'User', email: B, currentPassword: PASSWORD });
    expect(changed.status).toBe(200);
    expect((await reset(B, code)).body).toEqual({ error: RESET_FAILED });
    expect((await reset(u.email, code)).body).toEqual({ error: RESET_FAILED });
  }, SLOW);

  test('a normal password change voids a pending reset code', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const changed = await request(app).patch('/api/user/password').set(auth(u.token))
      .send({ currentPassword: PASSWORD, newPassword: 'Nexus@2029!' });
    expect(changed.status).toBe(200);
    expect(await resetRow(u)).toBeNull();
    expect((await reset(u.email, code)).body).toEqual({ error: RESET_FAILED });
  }, SLOW);

  test('R16 a 2FA challenge from before the reset is refused after it', async () => {
    const u = await twoFactorUser();
    const challenge = (await login(u.email, PASSWORD)).body.challengeToken;
    expect((await request(app).post('/api/auth/login/send-code').send({ challengeToken: challenge })).status).toBe(200);
    const loginCode = mailer.lastLoginCodeFor(u.email);

    expect((await reset(u.email, await resetCode(u))).status).toBe(200);
    const res = await request(app).post('/api/auth/login/verify').send({ challengeToken: challenge, code: loginCode });
    expect(res.status).toBe(401);
  }, SLOW);

  test('R17 = T5 a 2FA user gets the challenge (no token) and then signs in with the sign-in code', async () => {
    const u = await twoFactorUser();
    const res = await reset(u.email, await resetCode(u));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ twoFactorRequired: true, method: 'email', expiresInSeconds: 600 });
    expect(typeof res.body.challengeToken).toBe('string');
    expect(res.body).not.toHaveProperty('token');
    expect((await me(u.token)).status).toBe(401);

    const sent = await request(app).post('/api/auth/login/send-code').send({ challengeToken: res.body.challengeToken });
    expect(sent.status).toBe(200);
    const verified = await request(app).post('/api/auth/login/verify')
      .send({ challengeToken: res.body.challengeToken, code: mailer.lastLoginCodeFor(u.email) });
    expect(verified.status).toBe(200);
    const after = await me(verified.body.token);
    expect(after.status).toBe(200);
    expect(after.body.loginTwoFactor).toBe(true);
  }, SLOW);

  test('R17b with LOGIN_2FA=off a 2FA user gets a session', async () => {
    const u = await twoFactorUser();
    const code = await resetCode(u);
    const saved = process.env.LOGIN_2FA;
    process.env.LOGIN_2FA = 'off';
    try {
      const res = await reset(u.email, code);
      expect(res.status).toBe(200);
      expect(typeof res.body.token).toBe('string');
      expect(res.body.user.loginTwoFactor).toBe(true);
    } finally {
      if (saved === undefined) delete process.env.LOGIN_2FA; else process.env.LOGIN_2FA = saved;
    }
  }, SLOW);

  test('R18 = T6 an unverified user resets and is verified', async () => {
    const u = await registerUser(app);
    expect(u.user.emailVerified).toBe(false);
    const res = await reset(u.email, await resetCode(u));
    expect(res.status).toBe(200);
    expect(res.body.user.emailVerified).toBe(true);
    expect((await prisma.user.findUnique({ where: { id: u.user.id } })).emailVerified).toBe(true);
  }, SLOW);

  test('T3 two correct resets at once: one 200, one generic 400, only the winner\'s password works', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const [a, b] = await Promise.all([
      reset(u.email, code, 'Nexus@2027!'),
      reset(u.email, code, 'Nexus@2028!'),
    ]);
    expect([a.status, b.status].sort()).toEqual([200, 400]);
    const loser = a.status === 400 ? a : b;
    expect(loser.body).toEqual({ error: RESET_FAILED });
    const winner = a.status === 200 ? 'Nexus@2027!' : 'Nexus@2028!';
    const other = winner === 'Nexus@2027!' ? 'Nexus@2028!' : 'Nexus@2027!';
    expect((await login(u.email, winner)).status).toBe(200);
    expect((await login(u.email, other)).status).toBe(401);
  }, SLOW);

  test('T10 reset and email codes stay separate', async () => {
    const u = await registerUser(app);
    const emailCode = mailer.lastCodeFor(u.email); // from registration
    const code = await resetCode(u);
    // (a) the reset code does not verify the email...
    const verify = await request(app).post('/api/user/email/verify').set(auth(u.token)).send({ code });
    if (code !== emailCode) expect(verify.status).toBe(400);
    // (b) ...an email code does not reset the password...
    if (code !== emailCode) {
      expect((await reset(u.email, emailCode)).body).toEqual({ error: RESET_FAILED });
    }
    // ...and the reset code still works.
    expect((await reset(u.email, code)).status).toBe(200);
  }, SLOW);

  test('T16 one "password changed" notice after a success, to the stored address; none after a failure', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const before = mailer.sentPasswordChanged.length;
    expect((await reset(u.email, wrongCode(code))).status).toBe(400);
    expect(mailer.sentPasswordChanged.length).toBe(before);

    expect((await reset(` ${u.email.toUpperCase()}`, code)).status).toBe(200);
    const notices = mailer.sentPasswordChanged.slice(before);
    expect(notices).toEqual([{ to: u.email, firstName: 'Test' }]);
    expect(JSON.stringify(notices)).not.toContain(code);
  }, SLOW);

  test('a DB error after the code was accepted gives 500 and logs no email', async () => {
    const u = await registerUser(app);
    const code = await resetCode(u);
    const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
    const spy = jest.spyOn(prisma, '$transaction').mockRejectedValueOnce(
      Object.assign(new Error(`db ${u.email}`), { code: 'P1001' }));
    try {
      const res = await reset(u.email, code);
      expect(res.status).toBe(500);
      expect(res.body).toEqual({ error: 'Reset failed. Please try again.' });
      expect(errors).toHaveBeenCalledWith('[reset-password]', u.user.id, 'P1001');
    } finally {
      spy.mockRestore();
      errors.mockRestore();
    }
    expect((await login(u.email, PASSWORD)).status).toBe(200);
  }, SLOW);
});

describe('R19 live sessions', () => {
  let server, url;
  const sockets = [];
  beforeAll(async () => {
    server = http.createServer(app);
    initRealtime(server);
    await new Promise((r) => server.listen(0, r));
    url = `http://localhost:${server.address().port}`;
  });
  afterAll(async () => {
    for (const s of sockets) s.disconnect();
    await closeRealtime();
    await new Promise((r) => server.close(r));
  });

  test('a socket opened with the old token is dropped by the reset', async () => {
    const u = await registerUser(app);
    const socket = connectClient(url, {
      auth: { token: u.token }, transports: ['websocket'], reconnection: false, forceNew: true,
    });
    sockets.push(socket);
    await new Promise((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('connect_error', reject);
    });
    const dropped = new Promise((resolve) => socket.once('disconnect', resolve));
    expect((await reset(u.email, await resetCode(u))).status).toBe(200);
    // The wait starts after the answer: the reset itself can be slow on the pooler.
    let timer;
    const late = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('not disconnected')), 5000);
    });
    try {
      expect(await Promise.race([dropped, late])).toBe('io server disconnect');
    } finally {
      clearTimeout(timer);
    }
  }, SLOW);
});

describe('T8 logs hold no email, code or password', () => {
  test('across forgot, reset, a failed send and a 429', async () => {
    const lines = [];
    const capture = (...args) => { lines.push(args.map(String).join(' ')); };
    const spies = ['log', 'error', 'warn'].map((m) => jest.spyOn(console, m).mockImplementation(capture));
    const limited = createApp({ rateLimit: { forgotPasswordEmail: { limit: 1 } }, resetFloorMs: 0 });
    let u, code;
    try {
      u = await registerUser(app);
      code = await resetCode(u);                               // known
      await forgot(uniqueEmail());                             // unknown
      await reset(u.email, wrongCode(code));                   // wrong code
      expect((await reset(u.email, code)).status).toBe(200);   // correct
      await allowResetResend(u);
      mailer.failResetSendOnce(`could not deliver to ${u.email}`);
      await forgot(u.email);                                   // failed send
      await new Promise(setImmediate);
      await forgot(u.email, limited);
      expect((await forgot(u.email, limited)).status).toBe(429); // 429
    } finally {
      spies.forEach((s) => s.mockRestore());
    }
    const all = lines.join('\n');
    expect(all.toLowerCase()).not.toContain(u.email.toLowerCase());
    expect(all).not.toContain(code);
    expect(all).not.toContain(NEW_PASSWORD);
    expect(all).toMatch(/\[forgot-password\] send failed/);
    expect(all).toMatch(/\[rate-limit\] forgotPasswordEmail blocked/);
  }, SLOW);
});

// S20: no new table; a reset code is a normal nexus_verification_codes row.
test('a reset row is a normal code row of type "reset"', async () => {
  const u = await registerUser(app);
  const { code } = await issueCode(u.user.id, 'reset', { email: u.email });
  expect(code).toMatch(/^\d{6}$/);
  expect((await resetRow(u)).type).toBe('reset');
}, SLOW);
