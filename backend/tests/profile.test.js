jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const { makeApp, uniqueEmail, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });

afterAll(cleanup);

describe('GET /api/user/me', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('200 with the profile', async () => {
    const res = await request(app).get('/api/user/me').set(auth(u.token));
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(u.user.id);
    expect(res.body.email).toBe(u.email);
    expect(res.body).not.toHaveProperty('password');
  });

  test('401 without a token', async () => {
    const res = await request(app).get('/api/user/me');
    expect(res.status).toBe(401);
  });

  test('401 with a bad token', async () => {
    const res = await request(app).get('/api/user/me').set(auth('not-a-jwt'));
    expect(res.status).toBe(401);
  });
});

describe('PATCH /api/user/me', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('200 updates the names', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: ' Sara ', lastName: 'Ali' });
    expect(res.status).toBe(200);
    expect(res.body.firstName).toBe('Sara');
    expect(res.body.lastName).toBe('Ali');
    expect(res.body.name).toBe('Sara Ali');
  });

  test('400 when a name is missing', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara' });
    expect(res.status).toBe(400);
  });

  test('400 for a bad phone', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', phone: '12345' });
    expect(res.status).toBe(400);
  });

  test('email change: 400 without the current password', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', email: uniqueEmail() });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/Current password is required/);
  });

  test('email change: 401 with a wrong current password', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', email: uniqueEmail(), currentPassword: 'Wrong@2026' });
    expect(res.status).toBe(401);
  });

  test('email change: 409 for an email that is already taken', async () => {
    const other = await registerUser(app);
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', email: other.email, currentPassword: u.password });
    expect(res.status).toBe(409);
    expect(res.body.error).toBe('Email already registered.');
  }, SLOW);

  test('email change: 200 with the right password, and the email is unverified again', async () => {
    const newEmail = uniqueEmail();
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', email: newEmail, currentPassword: u.password });
    expect(res.status).toBe(200);
    expect(res.body.email).toBe(newEmail);
    expect(res.body.emailVerified).toBe(false);
  });
});

describe('PATCH /api/user/password', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); });

  test('401 for a wrong current password', async () => {
    const res = await request(app).patch('/api/user/password').set(auth(u.token))
      .send({ currentPassword: 'Wrong@2026', newPassword: 'Better@2027' });
    expect(res.status).toBe(401);
  });

  test('400 for a weak new password', async () => {
    const res = await request(app).patch('/api/user/password').set(auth(u.token))
      .send({ currentPassword: u.password, newPassword: 'weak' });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/^Password must contain/);
  });

  test('400 when the new password equals the current one', async () => {
    const res = await request(app).patch('/api/user/password').set(auth(u.token))
      .send({ currentPassword: u.password, newPassword: u.password });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/must be different/);
  });

  test('200, and login works with the new password', async () => {
    const res = await request(app).patch('/api/user/password').set(auth(u.token))
      .send({ currentPassword: u.password, newPassword: 'Better@2027' });
    expect(res.status).toBe(200);

    const oldLogin = await request(app).post('/api/auth/login')
      .send({ email: u.email, password: u.password });
    expect(oldLogin.status).toBe(401);
    const newLogin = await request(app).post('/api/auth/login')
      .send({ email: u.email, password: 'Better@2027' });
    expect(newLogin.status).toBe(200);
  });
});
