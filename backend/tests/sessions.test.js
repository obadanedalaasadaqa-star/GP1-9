jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const jwt = require('jsonwebtoken');
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const {
  PASSWORD, makeApp, uniqueEmail, registerUser, verifyUser, allowEmailResend, cleanup,
} = require('./helpers');
const { jordanBounds } = require('./aiHelpers');

// Audit L2: a password change, 2FA on, an email change and "sign out
// everywhere" end every older session; the device that made the change gets
// a new token (except sign out everywhere).
const SLOW = 90_000;
const app = makeApp({ aiClient: null });
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const me = (token) => request(app).get('/api/user/me').set(auth(token));
const login = (email, password = PASSWORD) =>
  request(app).post('/api/auth/login').send({ email, password });

afterAll(cleanup);

test('S-1: a password change kills the old token on every route; the new one works', async () => {
  const u = await registerUser(app);
  const res = await request(app).patch('/api/user/password').set(auth(u.token))
    .send({ currentPassword: PASSWORD, newPassword: 'Better@2027' });
  expect(res.status).toBe(200);
  expect(res.body.message).toBe('Password updated.');
  expect(typeof res.body.token).toBe('string');

  const bounds = jordanBounds().join(',');
  for (const req of [
    () => request(app).get('/api/user/me'),
    () => request(app).get('/api/user/receipts'),
    () => request(app).get('/api/budgets'),
    () => request(app).get('/api/ai/insight').query({ bounds }),
  ]) {
    const old = await req().set(auth(u.token));
    expect(old.status).toBe(401);
    expect(old.body).toEqual({ error: 'Unauthorized — invalid token' });
    expect((await req().set(auth(res.body.token))).status).not.toBe(401);
  }
  expect((await me(res.body.token)).status).toBe(200);
}, SLOW);

test('S-2: turning 2FA on kills the old token; turning it off does not', async () => {
  const u = await registerUser(app);
  await verifyUser(u.user.id);
  const on = await request(app).patch('/api/user/security').set(auth(u.token)).send({ loginTwoFactor: true });
  expect(on.status).toBe(200);
  expect((await me(u.token)).status).toBe(401);
  const t2 = on.body.token;
  expect((await me(t2)).status).toBe(200);

  const off = await request(app).patch('/api/user/security').set(auth(t2))
    .send({ loginTwoFactor: false, currentPassword: PASSWORD });
  expect(off.status).toBe(200);
  expect(off.body).not.toHaveProperty('token');
  expect((await me(t2)).status).toBe(200);
}, SLOW);

test('S-3: an email change kills the old token; a name-only edit does not', async () => {
  const u = await registerUser(app);
  const rename = await request(app).patch('/api/user/me').set(auth(u.token))
    .send({ firstName: 'New', lastName: 'Name', email: u.email });
  expect(rename.status).toBe(200);
  expect(rename.body).not.toHaveProperty('token');
  expect((await me(u.token)).status).toBe(200);

  await allowEmailResend(u.user.id);
  const res = await request(app).patch('/api/user/me').set(auth(u.token))
    .send({ firstName: 'New', lastName: 'Name', email: uniqueEmail(), currentPassword: PASSWORD });
  expect(res.status).toBe(200);
  expect(res.body).not.toHaveProperty('tokenVersion');
  expect((await me(u.token)).status).toBe(401);
  expect((await me(res.body.token)).status).toBe(200);
}, SLOW);

test('S-4: logout-all ends this session and every other one', async () => {
  const u = await registerUser(app);
  const other = await login(u.email); // a second device, signed in before
  expect(other.status).toBe(200);
  const res = await request(app).post('/api/user/logout-all').set(auth(u.token));
  expect(res.status).toBe(200);
  expect(res.body).toEqual({ message: 'Signed out on all devices.' });
  expect((await me(u.token)).status).toBe(401);
  expect((await me(other.body.token)).status).toBe(401);

  const again = await login(u.email);
  expect(again.status).toBe(200);
  expect((await me(again.body.token)).status).toBe(200);
  expect((await request(app).post('/api/user/logout-all')).status).toBe(401);
}, SLOW);

test('S-4b: logout-all is limited by the security limiter', async () => {
  const limited = makeApp({ rateLimit: { security: { limit: 1 } } });
  const u = await registerUser(app);
  jest.spyOn(console, 'log').mockImplementation(() => {});
  try {
    const first = await request(limited).post('/api/user/logout-all').set(auth(u.token));
    expect(first.status).toBe(200);
    const fresh = (await login(u.email)).body.token;
    const blocked = await request(limited).post('/api/user/logout-all').set(auth(fresh));
    expect(blocked.status).toBe(429);
    expect((await me(fresh)).status).toBe(200); // nothing ended
  } finally {
    console.log.mockRestore();
  }
}, SLOW);

test('S-5: a token from before session versions works until the first bump', async () => {
  const u = await registerUser(app);
  const legacy = jwt.sign({ userId: u.user.id }, process.env.JWT_SECRET, { expiresIn: '7d' });
  expect((await me(legacy)).status).toBe(200);
  const res = await request(app).patch('/api/user/password').set(auth(legacy))
    .send({ currentPassword: PASSWORD, newPassword: 'Better@2027' });
  expect(res.status).toBe(200);
  expect((await me(legacy)).status).toBe(401);
}, SLOW);

test('S-6: a deleted user\'s token gets 401', async () => {
  const u = await registerUser(app);
  await prisma.user.delete({ where: { id: u.user.id } });
  expect((await me(u.token)).status).toBe(401);
}, SLOW);

test('S-7: tokenVersion is never in a user answer', async () => {
  const u = await registerUser(app);
  expect(u.user).not.toHaveProperty('tokenVersion');
  expect((await me(u.token)).body).not.toHaveProperty('tokenVersion');
  const res = await login(u.email);
  expect(res.body.user).not.toHaveProperty('tokenVersion');
}, SLOW);

test('S-8: a DB error in the session check gives 503, not 401', async () => {
  const u = await registerUser(app);
  jest.spyOn(console, 'error').mockImplementation(() => {});
  const spy = jest.spyOn(prisma.user, 'findUnique').mockRejectedValueOnce(new Error('db down'));
  try {
    const res = await me(u.token);
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ error: 'Could not check your session. Try again.' });
  } finally {
    spy.mockRestore();
    console.error.mockRestore();
  }
  expect((await me(u.token)).status).toBe(200);
}, SLOW);
