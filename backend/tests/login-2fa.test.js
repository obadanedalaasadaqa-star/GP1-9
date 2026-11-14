jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const { signSession } = require('../src/lib/token');
const {
  PASSWORD, makeApp, registerUser, cleanup,
} = require('./helpers');

// Two-step sign-in: /login challenge, /login/send-code, /login/verify.
// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const EXPIRED = 'Your sign-in expired. Please log in again.';

const login = (u, password = u.password) =>
  request(app).post('/api/auth/login').send({ email: u.email, password });
const sendCode = (challengeToken) =>
  request(app).post('/api/auth/login/send-code').send({ challengeToken });
const verify = (challengeToken, code) =>
  request(app).post('/api/auth/login/verify').send({ challengeToken, code });

// Skip the 60 s resend wait of the user's sign-in code.
const allowLoginResend = (u) => prisma.verificationCode.updateMany({
  where: { userId: u.user.id, type: 'login' },
  data: { lastSentAt: new Date(Date.now() - 61 * 1000) },
});
const codeRow = (u, type) => prisma.verificationCode.findUnique({
  where: { userId_type: { userId: u.user.id, type } },
});
// A 6-digit code that is guaranteed to differ from [code].
const wrongCode = (code) => code.slice(0, 5) + String((Number(code[5]) + 1) % 10);

// Verify the email in the DB, then turn two-step sign-in on through the real route.
async function enableTwoFactor(u) {
  await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: true } });
  const res = await request(app).patch('/api/user/security').set(auth(u.token)).send({ loginTwoFactor: true });
  expect(res.status).toBe(200);
  expect(res.body.loginTwoFactor).toBe(true);
}

async function twoFactorUser() {
  const u = await registerUser(app);
  await enableTwoFactor(u);
  return u;
}

// Log in, send a code, return { challenge, code }.
async function challengeWithCode(u) {
  const res = await login(u);
  expect(res.body.twoFactorRequired).toBe(true);
  const sent = await sendCode(res.body.challengeToken);
  expect(sent.status).toBe(200);
  return { challenge: res.body.challengeToken, code: mailer.lastLoginCodeFor(u.email) };
}

afterAll(cleanup);

test('L-1: a correct password gives only a challenge, and sends no email', async () => {
  const u = await twoFactorUser();
  const before = mailer.sentLogin.length;
  const res = await login(u);
  expect(res.status).toBe(200);
  expect(res.body).toEqual({
    twoFactorRequired: true,
    challengeToken: expect.any(String),
    method: 'email',
    expiresInSeconds: 600,
  });
  expect(res.body).not.toHaveProperty('token');
  expect(res.body).not.toHaveProperty('user');
  expect(mailer.sentLogin.length).toBe(before);

  // A wrong password is still a plain 401 (no hint that 2FA is on).
  const wrong = await login(u, 'Wrong@2026');
  expect(wrong.status).toBe(401);
  expect(wrong.body).toEqual({ error: 'Invalid email or password.' });
}, SLOW);

test('L-2: a challenge as Bearer gets 401 on every session route', async () => {
  const u = await twoFactorUser();
  const challenge = (await login(u)).body.challengeToken;
  const routes = [
    request(app).get('/api/user/me'),
    request(app).post('/api/receipts/seed'),
    request(app).get('/api/user/receipts'),
    request(app).get('/api/budgets'),
    request(app).get('/api/user/stats'),
    request(app).patch('/api/user/security').send({ loginTwoFactor: false, currentPassword: PASSWORD }),
  ];
  for (const r of routes) {
    const res = await r.set(auth(challenge));
    expect(res.status).toBe(401);
  }
  expect(await prisma.receipt.count({ where: { userId: u.user.id } })).toBe(0);
}, SLOW);

test('L-3: send-code, a wrong code, the right code, then a replay', async () => {
  const u = await twoFactorUser();
  const challenge = (await login(u)).body.challengeToken;

  const sent = await sendCode(challenge);
  expect(sent.status).toBe(200);
  expect(sent.body).toEqual({ message: `Code sent to ${u.email}.` });
  const code = mailer.lastLoginCodeFor(u.email);
  expect(code).toMatch(/^\d{6}$/);

  const bad = await verify(challenge, wrongCode(code));
  expect(bad.status).toBe(400);
  expect(bad.body.error).toBe('Incorrect code. 4 attempts left.');

  const ok = await verify(challenge, code);
  expect(ok.status).toBe(200);
  expect(typeof ok.body.token).toBe('string');
  expect(ok.body.user.id).toBe(u.user.id);
  expect(ok.body.user).not.toHaveProperty('password');
  expect(Object.keys(ok.body.user).sort()).toEqual(Object.keys(u.user).sort());
  expect((await request(app).get('/api/user/me').set(auth(ok.body.token))).status).toBe(200);

  const replay = await verify(challenge, code);
  expect(replay.status).toBe(400);
  expect(replay.body.error).toMatch(/^No active code/);
}, SLOW);

test('L-4: a second send within 60 s waits; after the wait a new code replaces the old', async () => {
  const u = await twoFactorUser();
  const { challenge, code: first } = await challengeWithCode(u);

  const again = await sendCode(challenge);
  expect(again.status).toBe(429);
  expect(again.body.waitSeconds).toBeGreaterThan(0);
  expect(again.body.error).toMatch(/^Please wait \d+s before requesting a new code\.$/);

  await allowLoginResend(u);
  expect((await sendCode(challenge)).status).toBe(200);
  const second = mailer.lastLoginCodeFor(u.email);
  if (second !== first) {
    expect((await verify(challenge, first)).status).toBe(400);
  }
  expect((await verify(challenge, second)).status).toBe(200);
}, SLOW);

test('L-5: 5 wrong codes lock the code; a resend gives a working one', async () => {
  const u = await twoFactorUser();
  const { challenge, code } = await challengeWithCode(u);
  for (let i = 0; i < 5; i++) await verify(challenge, wrongCode(code));
  const locked = await verify(challenge, code);
  expect(locked.status).toBe(400);
  expect(locked.body.error).toMatch(/^Too many wrong attempts/);

  await allowLoginResend(u);
  expect((await sendCode(challenge)).status).toBe(200);
  expect((await verify(challenge, mailer.lastLoginCodeFor(u.email))).status).toBe(200);
}, SLOW);

describe('L-6: validation', () => {
  let u, challenge;
  beforeAll(async () => {
    u = await twoFactorUser();
    challenge = (await login(u)).body.challengeToken;
  }, SLOW);

  test('400 for a code that is not 6 digits', async () => {
    const res = await verify(challenge, '12ab');
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Enter the 6-digit code.');
  });

  test('400 for the right code inside an array or an object; the string still works', async () => {
    expect((await sendCode(challenge)).status).toBe(200);
    const code = mailer.lastLoginCodeFor(u.email);
    for (const wrapped of [[code], { code }]) {
      const res = await verify(challenge, wrapped);
      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Enter the 6-digit code.');
      expect(res.body).not.toHaveProperty('token');
    }
    const ok = await verify(challenge, code);
    expect(ok.status).toBe(200);
    expect(typeof ok.body.token).toBe('string');
  }, SLOW);

  test('401 without a challengeToken, and without a body (not 500)', async () => {
    for (const path of ['/api/auth/login/send-code', '/api/auth/login/verify']) {
      const noToken = await request(app).post(path).send({ code: '123456' });
      expect(noToken.status).toBe(401);
      expect(noToken.body.error).toBe(EXPIRED);
      const noBody = await request(app).post(path);
      expect(noBody.status).toBe(401);
      expect(noBody.body.error).toBe(EXPIRED);
    }
  });

  test('401 for a tampered, an expired, and a session token as the challenge', async () => {
    // Same signature, payload changed to another user id.
    const [h, , s] = challenge.split('.');
    const forged = Buffer.from(JSON.stringify({ ...jwt.decode(challenge), sub: 'someone-else' })).toString('base64url');
    const tampered = `${h}.${forged}.${s}`;
    const key = crypto.createHmac('sha256', process.env.JWT_SECRET).update('nexus-login-2fa').digest('hex');
    const expired = jwt.sign(
      { sub: u.user.id, purpose: 'login-2fa', pwd: jwt.decode(challenge).pwd, exp: Math.floor(Date.now() / 1000) - 5 },
      key,
    );
    for (const token of [tampered, expired, signSession(u.user.id)]) {
      expect((await sendCode(token)).status).toBe(401);
      const res = await verify(token, '123456');
      expect(res.status).toBe(401);
      expect(res.body.error).toBe(EXPIRED);
    }
  });
});

test('L-7: a password change voids the open challenge', async () => {
  const u = await twoFactorUser();
  const { challenge, code } = await challengeWithCode(u);
  const changed = await request(app).patch('/api/user/password').set(auth(u.token))
    .send({ currentPassword: PASSWORD, newPassword: 'Nexus@2027' });
  expect(changed.status).toBe(200);

  await allowLoginResend(u);
  const send = await sendCode(challenge);
  expect(send.status).toBe(401);
  expect(send.body.error).toBe(EXPIRED);
  const res = await verify(challenge, code);
  expect(res.status).toBe(401);

  const fresh = await login(u, 'Nexus@2027');
  expect(fresh.body.twoFactorRequired).toBe(true);
  expect((await sendCode(fresh.body.challengeToken)).status).toBe(200);
  expect((await verify(fresh.body.challengeToken, mailer.lastLoginCodeFor(u.email))).status).toBe(200);
}, SLOW);

test('L-8: the user is deleted after the challenge: send-code gives 404', async () => {
  const u = await twoFactorUser();
  const challenge = (await login(u)).body.challengeToken;
  await prisma.user.delete({ where: { id: u.user.id } });
  const res = await sendCode(challenge);
  expect(res.status).toBe(404);
  expect(res.body.error).toBe('User not found.');
}, SLOW);

test('L-9: sign-in codes and email codes never touch each other', async () => {
  const u = await registerUser(app); // has a pending email code from register
  const emailBefore = await codeRow(u, 'email');
  // Turn on with a still-pending email code row (verified in the DB only).
  await enableTwoFactor(u);

  const { challenge, code } = await challengeWithCode(u);
  expect(await codeRow(u, 'email')).toEqual(emailBefore);
  expect((await verify(challenge, code)).status).toBe(200);
  expect(await codeRow(u, 'email')).toEqual(emailBefore);

  // The other way round: a fresh email code does not touch a sign-in code.
  await allowLoginResend(u);
  const { challenge: c2 } = await challengeWithCode(u);
  const loginBefore = await codeRow(u, 'login');
  await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: false } });
  await prisma.verificationCode.update({
    where: { userId_type: { userId: u.user.id, type: 'email' } },
    data: { lastSentAt: new Date(Date.now() - 61 * 1000) },
  });
  expect((await request(app).post('/api/user/email/send-code').set(auth(u.token))).status).toBe(200);
  expect(await codeRow(u, 'login')).toEqual(loginBefore);
  expect((await verify(c2, mailer.lastLoginCodeFor(u.email))).status).toBe(200);
}, SLOW);

test('L-10 (Q5): signing in with a code does not change emailVerified', async () => {
  const u = await twoFactorUser();
  // Against the rule on purpose: 2FA on with an unverified email.
  await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: false } });
  const { challenge, code } = await challengeWithCode(u);
  const res = await verify(challenge, code);
  expect(res.status).toBe(200);
  expect(res.body.user.emailVerified).toBe(false);
  expect((await prisma.user.findUnique({ where: { id: u.user.id } })).emailVerified).toBe(false);
}, SLOW);

test('L-11: LOGIN_2FA=off gives a session to a 2FA user; the flag is read per request', async () => {
  const u = await twoFactorUser();
  process.env.LOGIN_2FA = 'off';
  try {
    const off = await login(u);
    expect(off.status).toBe(200);
    expect(typeof off.body.token).toBe('string');
    expect(off.body.user.loginTwoFactor).toBe(true);
  } finally {
    delete process.env.LOGIN_2FA;
  }
  const on = await login(u);
  expect(on.body.twoFactorRequired).toBe(true);
}, SLOW);

test('L-12: a mail provider error gives 502; the next send works', async () => {
  const u = await twoFactorUser();
  const challenge = (await login(u)).body.challengeToken;
  jest.spyOn(console, 'error').mockImplementation(() => {});
  mailer.sendLoginCodeEmail.mockRejectedValueOnce(new Error('Brevo 500'));
  const failed = await sendCode(challenge);
  console.error.mockRestore();
  expect(failed.status).toBe(502);
  expect(failed.body.error).toBe('Could not send the sign-in email. Please try again.');

  await allowLoginResend(u);
  expect((await sendCode(challenge)).status).toBe(200);
  expect((await verify(challenge, mailer.lastLoginCodeFor(u.email))).status).toBe(200);
}, SLOW);

test("L-14: user A's code fails on user B's challenge", async () => {
  const a = await twoFactorUser();
  const b = await twoFactorUser();
  const { code: codeA } = await challengeWithCode(a);
  const { challenge: challengeB, code: codeB } = await challengeWithCode(b);
  if (codeA !== codeB) {
    const res = await verify(challengeB, codeA);
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/^Incorrect code/);
  }
  expect((await verify(challengeB, codeB)).status).toBe(200);
}, SLOW);

test('L-15: a user with 2FA off logs in exactly as before', async () => {
  const u = await registerUser(app);
  const res = await login(u);
  expect(res.status).toBe(200);
  expect(typeof res.body.token).toBe('string');
  expect(res.body).not.toHaveProperty('twoFactorRequired');
  expect(Object.keys(res.body.user).sort()).toEqual(Object.keys(u.user).sort());
  expect(await codeRow(u, 'login')).toBeNull();
  expect(mailer.sentLogin.filter((m) => m.to === u.email)).toHaveLength(0);
}, SLOW);
