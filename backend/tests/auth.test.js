jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const { sendVerificationEmail } = require('./mailerMock');
const {
  PASSWORD, makeApp, uniqueEmail, track, registerUser, cleanup,
} = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();

function newUserBody(overrides = {}) {
  return {
    firstName: 'Test',
    lastName: 'User',
    email: uniqueEmail(),
    password: PASSWORD,
    ...overrides,
  };
}

afterAll(cleanup);

describe('POST /api/auth/register', () => {
  test('201 with a token, a safe user and one verification email', async () => {
    const body = newUserBody();
    const res = await request(app).post('/api/auth/register').send(body);
    expect(res.status).toBe(201);
    track(res.body.user?.id);

    expect(typeof res.body.token).toBe('string');
    expect(res.body.user.email).toBe(body.email);
    expect(res.body.user).not.toHaveProperty('password');
    expect(res.body.user.emailVerified).toBe(false);
    expect(res.body.user.name).toBe('Test User');
    expect(res.body.user.serialNumber).toMatch(/^NXS-[0-9A-F]{5}-[0-9A-F]{5}$/);

    const calls = sendVerificationEmail.mock.calls.filter(([to]) => to === body.email);
    expect(calls).toHaveLength(1);
    expect(calls[0][2]).toMatch(/^\d{6}$/);
  });

  test.each(['firstName', 'lastName', 'email', 'password'])(
    '400 when %s is missing', async (field) => {
      const body = newUserBody();
      delete body[field];
      const res = await request(app).post('/api/auth/register').send(body);
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/required/);
    }
  );

  test('the required error no longer mentions a phone', async () => {
    const res = await request(app).post('/api/auth/register').send({});
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('First name, last name, email, and password are required.');
  });

  test('201 without a phone, and no phone key on the user (a sent phone is ignored)', async () => {
    const res = await request(app).post('/api/auth/register')
      .send(newUserBody({ phone: '0791234567' }));
    expect(res.status).toBe(201);
    track(res.body.user?.id);
    expect(res.body.user).not.toHaveProperty('phone');
  });

  test('400 for a weak password', async () => {
    const res = await request(app).post('/api/auth/register')
      .send(newUserBody({ password: 'weakpass' }));
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/^Password must contain/);
  });

  test('409 for an email that is already registered', async () => {
    const first = newUserBody();
    const res1 = await request(app).post('/api/auth/register').send(first);
    expect(res1.status).toBe(201);
    track(res1.body.user.id);

    const res2 = await request(app).post('/api/auth/register')
      .send(newUserBody({ email: first.email }));
    expect(res2.status).toBe(409);
    expect(res2.body.error).toBe('Email already registered.');
  }, SLOW);
});

describe('POST /api/auth/login', () => {
  let user;
  beforeAll(async () => { user = await registerUser(app); });

  test('200 with a token and no password for correct credentials', async () => {
    const res = await request(app).post('/api/auth/login')
      .send({ email: user.email, password: user.password });
    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe('string');
    expect(res.body.user.id).toBe(user.user.id);
    expect(res.body.user).not.toHaveProperty('password');
  });

  test('register and login bodies have the email settings and never the internal columns', async () => {
    const reg = await registerUser(app);
    const login = await request(app).post('/api/auth/login')
      .send({ email: reg.email, password: reg.password });
    for (const body of [reg.user, login.body.user]) {
      expect(body).toMatchObject({ budgetAlertEmails: true, weeklySummaryEmails: false });
      expect(body).not.toHaveProperty('tzOffsetMinutes');
      expect(body).not.toHaveProperty('weeklySummarySentWeek');
      expect(body).not.toHaveProperty('password');
    }
    expect(Object.keys(login.body.user).sort()).toEqual(Object.keys(reg.user).sort());
  }, SLOW);

  test('401 for a wrong password', async () => {
    const res = await request(app).post('/api/auth/login')
      .send({ email: user.email, password: 'Wrong@2026' });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('Invalid email or password.');
  });

  test('401 for an unknown email', async () => {
    const res = await request(app).post('/api/auth/login')
      .send({ email: uniqueEmail(), password: PASSWORD });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('Invalid email or password.');
  });

  test('400 when email or password is missing', async () => {
    const res1 = await request(app).post('/api/auth/login').send({ email: user.email });
    const res2 = await request(app).post('/api/auth/login').send({ password: PASSWORD });
    expect(res1.status).toBe(400);
    expect(res2.status).toBe(400);
  });
});
