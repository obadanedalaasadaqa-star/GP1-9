jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { TZ_ERROR } = require('../src/lib/aiDates');
const { latestWeek } = require('../src/lib/weeklySummary');
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

describe('PATCH /api/user/notifications', () => {
  let u;
  beforeAll(async () => { u = await registerUser(app); }, SLOW);
  const patch = (body) => request(app).patch('/api/user/notifications').set(auth(u.token)).send(body);
  const internal = () => prisma.user.findUnique({
    where: { id: u.user.id }, select: { tzOffsetMinutes: true, weeklySummarySentWeek: true },
  });

  test('N-1 /me has the settings and never the internal columns', async () => {
    const res = await request(app).get('/api/user/me').set(auth(u.token));
    expect(res.body).toMatchObject({ budgetAlertEmails: true, weeklySummaryEmails: false });
    expect(res.body).not.toHaveProperty('tzOffsetMinutes');
    expect(res.body).not.toHaveProperty('weeklySummarySentWeek');
  });

  test('N-2 each field saves and comes back in the user', async () => {
    let res = await patch({ budgetAlertEmails: false });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ id: u.user.id, budgetAlertEmails: false, weeklySummaryEmails: false });
    expect(res.body).not.toHaveProperty('tzOffsetMinutes');
    res = await patch({ budgetAlertEmails: true, tzOffsetMinutes: -300, unknown: 1 });
    expect(res.status).toBe(200);
    expect(res.body.budgetAlertEmails).toBe(true);
    expect((await internal()).tzOffsetMinutes).toBe(-300);
    res = await patch({ tzOffsetMinutes: 180 });
    expect(res.status).toBe(200);
  }, SLOW);

  test('N-3 400s', async () => {
    const cases = [
      [{}, 'Nothing to update.'],
      [{ other: true }, 'Nothing to update.'],
      [{ budgetAlertEmails: 'true' }, 'budgetAlertEmails must be true or false.'],
      [{ weeklySummaryEmails: 1 }, 'weeklySummaryEmails must be true or false.'],
      [{ tzOffsetMinutes: 'x' }, TZ_ERROR],
    ];
    for (const [body, error] of cases) {
      const res = await patch(body);
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error });
    }
    expect((await request(app).patch('/api/user/notifications').send({ budgetAlertEmails: true })).status).toBe(401);
  }, SLOW);

  test('N-4 turning weekly on marks the latest week as done', async () => {
    let res = await patch({ weeklySummaryEmails: true, tzOffsetMinutes: 180 });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ weeklySummaryEmails: true, budgetAlertEmails: true });
    const key = latestWeek(new Date(), 180).key;
    expect((await internal()).weeklySummarySentWeek).toBe(key);

    // Already on: the key is not touched.
    await prisma.user.update({ where: { id: u.user.id }, data: { weeklySummarySentWeek: '2020-01-05' } });
    await patch({ weeklySummaryEmails: true });
    expect((await internal()).weeklySummarySentWeek).toBe('2020-01-05');

    // Off and on again: set again.
    await patch({ weeklySummaryEmails: false });
    res = await patch({ weeklySummaryEmails: true });
    expect(res.body.weeklySummaryEmails).toBe(true);
    expect((await internal()).weeklySummarySentWeek).toBe(key);
  }, SLOW);
});
