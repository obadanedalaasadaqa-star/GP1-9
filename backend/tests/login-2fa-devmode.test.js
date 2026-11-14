// L-13: two-step sign-in with the real mailer in dev mode (tests/env.js removes
// every mail variable), so the sign-in code is only printed to the log.
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const app = makeApp();

let logSpy;
afterAll(async () => {
  logSpy?.mockRestore();
  await cleanup(); // also disconnects Prisma
});

test('L-13: the [mail:dev] sign-in code line is printed and that code signs in', async () => {
  logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
  const u = await registerUser(app);
  await prisma.user.update({ where: { id: u.user.id }, data: { emailVerified: true } });
  const on = await request(app).patch('/api/user/security')
    .set({ Authorization: `Bearer ${u.token}` }).send({ loginTwoFactor: true });
  expect(on.status).toBe(200);

  const login = await request(app).post('/api/auth/login').send({ email: u.email, password: u.password });
  expect(login.body.twoFactorRequired).toBe(true);
  const sent = await request(app).post('/api/auth/login/send-code').send({ challengeToken: login.body.challengeToken });
  expect(sent.status).toBe(200);

  const pattern = new RegExp(`^\\[mail:dev\\] Sign-in code for ${u.email.replace(/\./g, '\\.')}: (\\d{6})$`);
  const line = logSpy.mock.calls.map(([msg]) => String(msg)).find((msg) => pattern.test(msg));
  expect(line).toBeDefined();
  const code = line.match(pattern)[1];

  const res = await request(app).post('/api/auth/login/verify')
    .send({ challengeToken: login.body.challengeToken, code });
  expect(res.status).toBe(200);
  expect(typeof res.body.token).toBe('string');
  expect(res.body.user.id).toBe(u.user.id);
}, SLOW);
