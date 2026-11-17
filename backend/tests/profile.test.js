jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const { TZ_ERROR } = require('../src/lib/aiDates');
const { latestWeek } = require('../src/lib/weeklySummary');
const {
  PASSWORD, makeApp, uniqueEmail, track, registerUser, verifyUser, allowEmailResend, cleanup,
} = require('./helpers');

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
    expect(res.body).not.toHaveProperty('phone');
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

  test('a phone sent by an old app build is ignored', async () => {
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sara', lastName: 'Ali', phone: '12345' });
    expect(res.status).toBe(200);
    expect(res.body).not.toHaveProperty('phone');
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
    await allowEmailResend(u.user.id); // the register code was sent under a minute ago
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

// Audit L5/L6: email changes obey the code limits; names are cleaned.
describe('PATCH /api/user/me: email change limits and names', () => {
  const change = (u, email, a = app) => request(a).patch('/api/user/me').set(auth(u.token))
    .send({ firstName: 'Test', lastName: 'User', email, currentPassword: u.password });
  const dbUser = (u) => prisma.user.findUnique({ where: { id: u.user.id } });
  beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
  afterEach(() => jest.restoreAllMocks());

  test('E-1 a second change within 60 s: 429 with waitSeconds, email unchanged, one email sent', async () => {
    const u = await registerUser(app);
    await allowEmailResend(u.user.id);
    mailer.sendVerificationEmail.mockClear();
    const first = await change(u, uniqueEmail());
    expect(first.status).toBe(200);
    u.token = first.body.token;

    const second = await change(u, uniqueEmail());
    expect(second.status).toBe(429);
    expect(second.body.error).toMatch(/^Please wait \d+s before requesting a new code\.$/);
    expect(second.body.waitSeconds).toBeGreaterThan(0);
    expect((await dbUser(u)).email).toBe(first.body.email);
    expect(mailer.sendVerificationEmail).toHaveBeenCalledTimes(1);
  }, SLOW);

  test('E-2 changes share the hourly sendCode limit with /email/send-code', async () => {
    const limited = makeApp({ rateLimit: { sendCode: { limit: 2 } } });
    const u = await registerUser(app);
    for (let i = 0; i < 2; i++) {
      await allowEmailResend(u.user.id);
      const res = await change(u, uniqueEmail(), limited);
      expect(res.status).toBe(200);
      u.token = res.body.token;
    }
    const before = (await dbUser(u)).email;
    await allowEmailResend(u.user.id);
    const blocked = await change(u, uniqueEmail(), limited);
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('Too many code requests. Try again later.');
    expect((await dbUser(u)).email).toBe(before);

    const send = await request(limited).post('/api/user/email/send-code').set(auth(u.token));
    expect(send.status).toBe(429);
    expect(send.body.error).toBe('Too many code requests. Try again later.');
  }, SLOW);

  test('E-3 name-only edits are never limited', async () => {
    const limited = makeApp({ rateLimit: { sendCode: { limit: 1 } } });
    const u = await registerUser(app);
    for (let i = 0; i < 10; i++) {
      const res = await request(limited).patch('/api/user/me').set(auth(u.token))
        .send({ firstName: `Name${i}`, lastName: 'User', email: u.email });
      expect(res.status).toBe(200);
    }
  }, SLOW);

  test('E-4 another case or surrounding spaces is not a change: no password, still verified', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    const mixed = u.email.replace('test_', 'Test_').replace('@nexus.test', '@Nexus.Test');
    await prisma.user.update({ where: { id: u.user.id }, data: { email: mixed } });
    for (const sent of [mixed.toLowerCase(), mixed.toUpperCase(), ` ${mixed} `]) {
      const res = await request(app).patch('/api/user/me').set(auth(u.token))
        .send({ firstName: 'Same', lastName: 'Email', email: sent });
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ email: mixed, emailVerified: true });
      expect(res.body).not.toHaveProperty('token');
    }

    const padded = `  ${u.email} `;
    await prisma.user.update({ where: { id: u.user.id }, data: { email: padded } });
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Same', lastName: 'Email', email: u.email });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ email: padded, emailVerified: true });
    expect((await request(app).get('/api/user/me').set(auth(u.token))).status).toBe(200); // no bump
  }, SLOW);

  test('E-4b a stored email that fails the format check still saves a name edit', async () => {
    const u = await registerUser(app);
    const odd = u.email.replace('@nexus.test', '@nexus'); // like a@b
    await prisma.user.update({ where: { id: u.user.id }, data: { email: odd } });
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Renamed', lastName: 'User', email: odd });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ firstName: 'Renamed', email: odd });
  }, SLOW);

  test('E-5 names: control characters become spaces, URL text stays, 51 characters is 400', async () => {
    const u = await registerUser(app);
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Sa\nra\t\u2028x  http://x', lastName: ' Ali\u0007 ' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ firstName: 'Sa ra x http://x', lastName: 'Ali', name: 'Sa ra x http://x Ali' });

    const long = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'x'.repeat(51), lastName: 'Ali' });
    expect(long.status).toBe(400);
    expect(long.body.error).toBe('First and last name must be at most 50 characters.');
    const fifty = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'x'.repeat(50), lastName: 'Ali' });
    expect(fifty.status).toBe(200);

    // The same rules at register.
    const reg = await request(app).post('/api/auth/register').send({
      firstName: 'A\nB', lastName: 'C\u2029D', email: uniqueEmail(), password: PASSWORD,
    });
    expect(reg.status).toBe(201);
    track(reg.body.user.id);
    expect(reg.body.user).toMatchObject({ firstName: 'A B', lastName: 'C D' });
    const regLong = await request(app).post('/api/auth/register').send({
      firstName: 'x'.repeat(51), lastName: 'C', email: uniqueEmail(), password: PASSWORD,
    });
    expect(regLong.status).toBe(400);
    expect(regLong.body.error).toBe('First and last name must be at most 50 characters.');
  }, SLOW);

  test('E-6 an invalid name with an email change is rejected before any code is sent', async () => {
    const u = await registerUser(app);
    await allowEmailResend(u.user.id);
    mailer.sendVerificationEmail.mockClear();
    const res = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'x'.repeat(51), lastName: 'User', email: uniqueEmail(), currentPassword: u.password });
    expect(res.status).toBe(400);
    expect(mailer.sendVerificationEmail).not.toHaveBeenCalled();
    expect((await request(app).get('/api/user/me').set(auth(u.token))).status).toBe(200);
  }, SLOW);
});
