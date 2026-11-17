jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { signChallenge } = require('../src/lib/token');
const { SESSION_SELECT } = require('../src/lib/session');
const {
  PASSWORD, makeApp, uniqueEmail, registerUser, verifyUser, allowEmailResend, cleanup,
} = require('./helpers');

// PATCH /api/user/security and the email-change rule (two-step sign-in is opt-in).
// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
// Turning it on ends older sessions and returns a new token: keep using that one.
async function setSecurity(u, body) {
  const res = await request(app).patch('/api/user/security').set(auth(u.token)).send(body);
  if (typeof res.body.token === 'string') u.token = res.body.token;
  return res;
}
const login = (u) => request(app).post('/api/auth/login').send({ email: u.email, password: u.password });
const dbValue = async (u) => (await prisma.user.findUnique({ where: { id: u.user.id } })).loginTwoFactor;

afterAll(cleanup);

test('S-1: off by default, and login is unchanged ({ token, user })', async () => {
  const u = await registerUser(app);
  expect(u.user.loginTwoFactor).toBe(false);
  const res = await login(u);
  expect(res.status).toBe(200);
  expect(typeof res.body.token).toBe('string');
  expect(res.body).not.toHaveProperty('twoFactorRequired');
  expect(res.body.user.loginTwoFactor).toBe(false);
  expect(Object.keys(res.body.user).sort()).toEqual(Object.keys(u.user).sort());
}, SLOW);

test('S-2: an unverified user cannot turn it on (403), and the DB stays false', async () => {
  const u = await registerUser(app);
  const res = await setSecurity(u, { loginTwoFactor: true });
  expect(res.status).toBe(403);
  expect(res.body.error).toBe('Verify your email before turning on two-step sign-in.');
  expect(await dbValue(u)).toBe(false);
}, SLOW);

test('S-3: a verified user turns it on without a password; again is a no-op 200', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  const res = await setSecurity(u, { loginTwoFactor: true });
  expect(res.status).toBe(200);
  expect(res.body.loginTwoFactor).toBe(true);
  expect(res.body).not.toHaveProperty('password');
  expect(res.body).not.toHaveProperty('tokenVersion');
  expect(typeof res.body.token).toBe('string'); // a real change: a new session token
  const { token, ...userKeys } = res.body;
  expect(Object.keys(userKeys).sort()).toEqual(Object.keys(u.user).sort());

  const again = await setSecurity(u, { loginTwoFactor: true });
  expect(again.status).toBe(200);
  expect(again.body.loginTwoFactor).toBe(true);
  expect(again.body).not.toHaveProperty('password');
  expect(again.body).not.toHaveProperty('token'); // no change: no new session
  expect(await dbValue(u)).toBe(true);
}, SLOW);

test('S-3b: an email change between the read and the write still gives 403 and stays off', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  // The route reads a verified user, then (like a PATCH /me on another device)
  // the email becomes unverified before the write. The session check's own
  // lookup (SESSION_SELECT) passes through untouched.
  const realFindUnique = prisma.user.findUnique.bind(prisma.user);
  let unverified = false;
  const spy = jest.spyOn(prisma.user, 'findUnique').mockImplementation(async (args) => {
    const row = await realFindUnique(args);
    if (args.select !== SESSION_SELECT && !unverified) {
      unverified = true;
      await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: false } });
    }
    return row;
  });
  try {
    const res = await setSecurity(u, { loginTwoFactor: true });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe('Verify your email before turning on two-step sign-in.');
  } finally {
    spy.mockRestore();
  }
  expect(await dbValue(u)).toBe(false);
}, SLOW);

test('S-4: turning off needs the current password', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  expect((await setSecurity(u, { loginTwoFactor: true })).status).toBe(200);

  const none = await setSecurity(u, { loginTwoFactor: false });
  expect(none.status).toBe(400);
  expect(none.body.error).toBe('Current password is required to turn off two-step sign-in.');

  const wrong = await setSecurity(u, { loginTwoFactor: false, currentPassword: 'Wrong@2026' });
  expect(wrong.status).toBe(401);
  expect(wrong.body.error).toBe('Current password is incorrect.');
  expect(await dbValue(u)).toBe(true);

  const right = await setSecurity(u, { loginTwoFactor: false, currentPassword: PASSWORD });
  expect(right.status).toBe(200);
  expect(right.body.loginTwoFactor).toBe(false);
  const res = await login(u);
  expect(res.status).toBe(200);
  expect(typeof res.body.token).toBe('string');
}, SLOW);

describe('S-5: validation', () => {
  let u;
  beforeAll(async () => {
    u = await registerUser(app);
    await verifyUser(u.user.id);
  }, SLOW);

  test.each([[{}], [{ loginTwoFactor: 'true' }], [{ loginTwoFactor: 1 }], [{ loginTwoFactor: null }]])(
    '400 for body %j', async (body) => {
      const res = await setSecurity(u, body);
      expect(res.status).toBe(400);
      expect(res.body.error).toBe('loginTwoFactor must be true or false.');
    });

  test('400 for a non-string currentPassword when turning off', async () => {
    expect((await setSecurity(u, { loginTwoFactor: true })).status).toBe(200);
    const res = await setSecurity(u, { loginTwoFactor: false, currentPassword: 12345678 });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Current password is required to turn off two-step sign-in.');
    expect(await dbValue(u)).toBe(true);
  }, SLOW);

  test('401 without a session token', async () => {
    const res = await request(app).patch('/api/user/security').send({ loginTwoFactor: true });
    expect(res.status).toBe(401);
  });

  test('401 with a sign-in challenge as Bearer', async () => {
    const full = await prisma.user.findUnique({ where: { id: u.user.id } });
    const res = await request(app).patch('/api/user/security')
      .set(auth(signChallenge(full))).send({ loginTwoFactor: false, currentPassword: PASSWORD });
    expect(res.status).toBe(401);
    expect(await dbValue(u)).toBe(true);
  });
});

test('S-6: turning off when already off is 200 without a password', async () => {
  const u = await registerUser(app);
  const before = await prisma.user.findUnique({ where: { id: u.user.id } });
  const res = await setSecurity(u, { loginTwoFactor: false });
  expect(res.status).toBe(200);
  expect(res.body.loginTwoFactor).toBe(false);
  const after = await prisma.user.findUnique({ where: { id: u.user.id } });
  expect(after).toEqual(before);
}, SLOW);

test('S-7 (Q15): an email change turns two-step sign-in off', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  expect((await setSecurity(u, { loginTwoFactor: true })).status).toBe(200);

  const newEmail = uniqueEmail();
  await allowEmailResend(u.user.id); // the register code was sent under a minute ago
  const res = await request(app).patch('/api/user/me').set(auth(u.token))
    .send({ firstName: 'Test', lastName: 'User', email: newEmail, currentPassword: PASSWORD });
  expect(res.status).toBe(200);
  expect(res.body).toMatchObject({ email: newEmail, emailVerified: false, loginTwoFactor: false });
  const db = await prisma.user.findUnique({ where: { id: u.user.id } });
  expect(db).toMatchObject({ emailVerified: false, loginTwoFactor: false });

  const loginRes = await request(app).post('/api/auth/login').send({ email: newEmail, password: PASSWORD });
  expect(loginRes.status).toBe(200);
  expect(typeof loginRes.body.token).toBe('string');
}, SLOW);

test('a name-only update leaves two-step sign-in on', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  expect((await setSecurity(u, { loginTwoFactor: true })).status).toBe(200);
  const res = await request(app).patch('/api/user/me').set(auth(u.token))
    .send({ firstName: 'New', lastName: 'Name', email: u.email });
  expect(res.status).toBe(200);
  expect(res.body.loginTwoFactor).toBe(true);
}, SLOW);
