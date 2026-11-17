jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { lastCodeFor } = require('./mailerMock');
const {
  PASSWORD, makeApp, uniqueEmail, registerUser, allowEmailResend, cleanup,
} = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });

// A 6-digit code that is guaranteed to differ from [code].
function wrongCode(code) {
  return code.slice(0, 5) + String((Number(code[5]) + 1) % 10);
}

afterAll(cleanup);

describe('email verification', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('registration sends a code, so resending right away must wait', async () => {
    expect(lastCodeFor(u.email)).toMatch(/^\d{6}$/);
    const res = await request(app).post('/api/user/email/send-code').set(auth(u.token));
    expect(res.status).toBe(429);
    expect(res.body.waitSeconds).toBeGreaterThan(0);
    expect(res.body.error).toMatch(/^Please wait \d+s/);
  });

  test('the code from registration verifies the email', async () => {
    const res = await request(app).post('/api/user/email/verify').set(auth(u.token))
      .send({ code: lastCodeFor(u.email) });
    expect(res.status).toBe(200);
    expect(res.body.emailVerified).toBe(true);
  });

  test('send-code on a verified email gives 400', async () => {
    const res = await request(app).post('/api/user/email/send-code').set(auth(u.token));
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Email is already verified.');
  });
});

describe('wrong codes', () => {
  let v;
  beforeAll(async () => { v = await registerUser(app); });

  test('400 for a code that is not 6 digits', async () => {
    const res = await request(app).post('/api/user/email/verify').set(auth(v.token))
      .send({ code: '12a' });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Enter the 6-digit code.');
  });

  test('a wrong code counts down, and 5 wrong codes lock it', async () => {
    const bad = wrongCode(lastCodeFor(v.email));

    const first = await request(app).post('/api/user/email/verify').set(auth(v.token))
      .send({ code: bad });
    expect(first.status).toBe(400);
    expect(first.body.error).toBe('Incorrect code. 4 attempts left.');

    let last;
    for (let i = 0; i < 4; i++) {
      last = await request(app).post('/api/user/email/verify').set(auth(v.token))
        .send({ code: bad });
    }
    expect(last.status).toBe(400);
    expect(last.body.error).toBe('Too many wrong attempts. Tap "Resend code" for a new one.');

    // Now even the right code is refused until a new one is sent.
    const right = await request(app).post('/api/user/email/verify').set(auth(v.token))
      .send({ code: lastCodeFor(v.email) });
    expect(right.status).toBe(400);
    expect(right.body.error).toMatch(/Too many wrong attempts/);
  }, SLOW);
});

// Audit L7: a code only verifies the address it was sent to.
describe('codes are bound to their address', () => {
  const verify = (token, code) => request(app).post('/api/user/email/verify').set(auth(token)).send({ code });
  const codeRow = (u) => prisma.verificationCode.findUnique({
    where: { userId_type: { userId: u.user.id, type: 'email' } },
  });
  const verified = async (u) => (await prisma.user.findUnique({ where: { id: u.user.id } })).emailVerified;

  test('V-1 the email changed under a code (no new code): "different address", stays unverified', async () => {
    const u = await registerUser(app);
    const codeA = lastCodeFor(u.email);
    await prisma.user.update({ where: { id: u.user.id }, data: { email: uniqueEmail() } });
    const res = await verify(u.token, codeA);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('This code was sent to a different address. Tap "Resend code" for a new one.');
    expect(await verified(u)).toBe(false);
  }, SLOW);

  test('V-2 after an email change only the new address\'s code verifies', async () => {
    const u = await registerUser(app);
    const codeA = lastCodeFor(u.email);
    await allowEmailResend(u.user.id);
    const B = uniqueEmail();
    const changed = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Test', lastName: 'User', email: B, currentPassword: PASSWORD });
    expect(changed.status).toBe(200);
    const token = changed.body.token;
    expect((await codeRow(u)).email).toBe(B);

    const codeB = lastCodeFor(B);
    if (codeA !== codeB) expect((await verify(token, codeA)).status).toBe(400);
    const ok = await verify(token, codeB);
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ email: B, emailVerified: true });
  }, SLOW);

  test('V-3 a code from before codes had an address: "no longer valid"', async () => {
    const u = await registerUser(app);
    const code = lastCodeFor(u.email);
    await prisma.verificationCode.update({
      where: { userId_type: { userId: u.user.id, type: 'email' } }, data: { email: null },
    });
    const res = await verify(u.token, code);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('This code is no longer valid. Tap "Resend code" for a new one.');
    expect(await verified(u)).toBe(false);
  }, SLOW);

  test('V-4 a failed email-change transaction changes nothing', async () => {
    const u = await registerUser(app);
    await allowEmailResend(u.user.id);
    const before = await codeRow(u);
    jest.spyOn(console, 'error').mockImplementation(() => {});
    const spy = jest.spyOn(prisma, '$transaction').mockRejectedValueOnce(new Error('db'));
    try {
      const res = await request(app).patch('/api/user/me').set(auth(u.token))
        .send({ firstName: 'Test', lastName: 'User', email: uniqueEmail(), currentPassword: PASSWORD });
      expect(res.status).toBe(500);
    } finally {
      spy.mockRestore();
      console.error.mockRestore();
    }
    expect((await prisma.user.findUnique({ where: { id: u.user.id } })).email).toBe(u.email);
    expect(await codeRow(u)).toEqual(before);
    expect((await request(app).get('/api/user/me').set(auth(u.token))).status).toBe(200); // no bump
  }, SLOW);
});
