jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const { lastCodeFor } = require('./mailerMock');
const { makeApp, registerUser, cleanup } = require('./helpers');

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
  });
});
