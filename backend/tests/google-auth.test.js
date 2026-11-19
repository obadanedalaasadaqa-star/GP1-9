jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const request = require('supertest');
const prisma = require('../src/lib/prisma');
const mailer = require('./mailerMock');
const { IdTokenInvalid, verifyIdToken, isTrustedEmail } = require('../src/lib/idToken');
const { JwksUnavailable, makeKeyStore } = require('../src/lib/jwks');
const { normalizeEmail } = require('../src/lib/email');
const { generateSerial } = require('../src/lib/serial');
const {
  PASSWORD, makeApp, uniqueEmail, track, registerUser, verifyUser, allowEmailResend, cleanup,
} = require('./helpers');
const {
  GOOGLE_JWKS_URL, CLIENT_ID, makeKeyPair, claimsAt, signToken, fakeJwksFetch,
} = require('./googleTokens');

// POST /api/auth/google (phase 12) and the passwordSet guards. Google is never
// called: a fake verifier turns 'fake.<base64url claims>.sig' into claims
// (G38 uses the real verifier with a key generated during the run). Mail is
// the mock. Every email is test_…@nexus.test.
const SLOW = 90_000;
const NEW_PASSWORD = 'Nexus@2027!';
const TEXT = {
  failed: "Google sign-in didn't go through. Try again.",
  unverified: "Your Google email isn't verified yet. Verify it in your Google account, then try again.",
  passwordRequired: 'This email already has a Nexus account. Enter its password once to connect Google.',
  wrongPassword: "That password doesn't match. Try again, or tap Forgot password.",
  otherGoogle: 'This Nexus account is connected to a different Google account. Use that one, or sign in with your password.',
  unavailable: "Google sign-in isn't available right now. Try again soon, or use your email and password.",
  emailTaken: "Google sign-in can't be used with this email. Sign in with your email and password instead.",
};

// 'fake.' + base64url(claims) + '.sig' (base64url, so the route's shape check passes).
const fakeGoogle = (claims) => `fake.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.sig`;
const newSub = () => `sub_${Date.now()}${crypto.randomInt(0, 1_000_000)}`;

// Same claim rules as lib/idToken.js, without the signature.
const fakeVerifier = jest.fn(async (token) => {
  if (token === 'fake.bad.sig') throw new IdTokenInvalid();
  if (token === 'fake.down.sig') throw new JwksUnavailable();
  const c = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
  const email = normalizeEmail(c.email);
  return {
    subject: c.sub,
    email,
    emailVerified: c.email_verified === true,
    trustedEmail: isTrustedEmail(email, c.hd),
    givenName: typeof c.given_name === 'string' ? c.given_name : '',
    familyName: typeof c.family_name === 'string' ? c.family_name : '',
  };
});

const app = makeApp({ resetFloorMs: 0, idTokenVerifiers: { google: fakeVerifier } });
const auth = (token) => ({ Authorization: `Bearer ${token}` });

// Every /google answer, for G18.
const replies = [];
async function google(claims, extra = {}, a = app) {
  const idToken = typeof claims === 'string' ? claims : fakeGoogle(claims);
  const res = await request(a).post('/api/auth/google').send({ idToken, ...extra });
  replies.push({ res, idToken });
  if (res.body?.user?.id) track(res.body.user.id);
  return res;
}
// Claims of a verified Google account (untrusted unless hd is given).
const gClaims = (over = {}) => ({
  sub: newSub(), email: uniqueEmail(), email_verified: true, given_name: 'Test', family_name: 'Google', ...over,
});
const login = (email, password) => request(app).post('/api/auth/login').send({ email, password });
const me = (token) => request(app).get('/api/user/me').set(auth(token));
const identities = (userId) => prisma.authIdentity.findMany({ where: { userId } });
const linkedCount = () => mailer.sentLinked.length;

async function resetPassword(email) {
  const res = await request(app).post('/api/auth/forgot-password').send({ email });
  expect(res.status).toBe(200);
  const code = mailer.lastResetCodeFor(email);
  return request(app).post('/api/auth/reset-password').send({ email, code, newPassword: NEW_PASSWORD });
}

// A new Google-only account. Returns { res, claims, token, user }.
async function googleUser(over = {}) {
  const claims = gClaims(over);
  const res = await google(claims);
  expect(res.status).toBe(201);
  return { res, claims, token: res.body.token, user: res.body.user };
}

async function twoFactorOn(u) {
  await verifyUser(u.user.id);
  const res = await request(app).patch('/api/user/security').set(auth(u.token)).send({ loginTwoFactor: true });
  expect(res.status).toBe(200);
  u.token = res.body.token;
}

beforeEach(() => fakeVerifier.mockClear());
afterAll(cleanup);

describe('new and returning Google users', () => {
  test('G1 a new Google user gets 201, a working session, a verified email and no password', async () => {
    const { res, claims } = await googleUser();
    expect(res.body.created).toBe(true);
    expect(res.body.user).toMatchObject({ email: claims.email, emailVerified: true, passwordSet: false });
    const profile = await me(res.body.token);
    expect(profile.status).toBe(200);
    expect(profile.body.passwordSet).toBe(false);
    const rows = await identities(res.body.user.id);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ provider: 'google', subject: claims.sub });
    expect(await prisma.verificationCode.count({ where: { userId: res.body.user.id } })).toBe(0);
  }, SLOW);

  test('G2 the same sub again signs in to the same user and moves lastUsedAt', async () => {
    const { claims, user } = await googleUser();
    const [before] = await identities(user.id);
    const users = await prisma.user.count({ where: { email: claims.email } });
    const again = await google(claims);
    expect(again.status).toBe(200);
    expect(again.body.created).toBeUndefined();
    expect(again.body.user.id).toBe(user.id);
    expect(await prisma.user.count({ where: { email: claims.email } })).toBe(users);
    const [after] = await identities(user.id);
    expect(after.lastUsedAt.getTime()).toBeGreaterThan(before.lastUsedAt.getTime());
  }, SLOW);

  test('G3 after logout-all the old Google session is 401; a new Google sign-in works', async () => {
    const { claims, token } = await googleUser();
    expect((await request(app).post('/api/user/logout-all').set(auth(token))).status).toBe(200);
    expect((await me(token)).status).toBe(401);
    const again = await google(claims);
    expect(again.status).toBe(200);
    expect((await me(again.body.token)).status).toBe(200);
  }, SLOW);

  test('G4 same sub with a changed Google email → same user, Nexus email unchanged', async () => {
    const { claims, user } = await googleUser();
    const res = await google({ ...claims, email: uniqueEmail() });
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(user.id);
    expect(res.body.user.email).toBe(claims.email);
  }, SLOW);

  test('G5 an unverified Google email with no account → 403, no user', async () => {
    const claims = gClaims({ email_verified: false });
    const res = await google(claims);
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: TEXT.unverified, code: 'google_email_unverified' });
    expect(await prisma.user.count({ where: { email: claims.email } })).toBe(0);
  }, SLOW);

  test('G17 missing names → Nexus / member; control characters stripped; 80 characters cut to 50', async () => {
    const plain = await googleUser({ given_name: undefined, family_name: undefined });
    expect(plain.user).toMatchObject({ firstName: 'Nexus', lastName: 'member', name: 'Nexus member' });
    const odd = await googleUser({ given_name: 'Sa\u0000ra\nX', family_name: 'L'.repeat(80) });
    expect(odd.user.firstName).toBe('Sa ra X');
    expect(odd.user.lastName).toBe('L'.repeat(50));
  }, SLOW);

  test('G30 a password in the body of a create is ignored', async () => {
    const claims = gClaims();
    const res = await google(claims, { password: PASSWORD });
    expect(res.status).toBe(201);
    expect(res.body.user.passwordSet).toBe(false);
    expect((await login(claims.email, PASSWORD)).status).toBe(401);
  }, SLOW);

  test('G19 a Google-only user typing any password at /login gets the generic 401', async () => {
    const { claims } = await googleUser();
    const res = await login(claims.email, 'Anything@2026');
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: 'Invalid email or password.' });
  }, SLOW);

  test('G16 two parallel first sign-ins with the same sub → one user, one identity, same id', async () => {
    const claims = gClaims();
    const [a, b] = await Promise.all([google(claims), google(claims)]);
    expect([a.status, b.status].sort()).toEqual([200, 201]);
    expect(a.body.user.id).toBe(b.body.user.id);
    expect(await prisma.user.count({ where: { email: claims.email } })).toBe(1);
    expect(await identities(a.body.user.id)).toHaveLength(1);
  }, SLOW);
});

describe('linking to an existing account', () => {
  test('G6 verified account + trusted Google email → linked, one notice, password login still works', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    const before = linkedCount();
    const res = await google(gClaims({ email: u.email, hd: 'nexus.test' }));
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(u.user.id);
    expect(await identities(u.user.id)).toHaveLength(1);
    expect(linkedCount()).toBe(before + 1);
    expect((await login(u.email, PASSWORD)).status).toBe(200);
  }, SLOW);

  test('G7 verified account + untrusted Google email → 409 password_required, nothing linked', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    const res = await google(gClaims({ email: u.email }));
    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: TEXT.passwordRequired, code: 'password_required', email: u.email });
    expect(await identities(u.user.id)).toHaveLength(0);
  }, SLOW);

  test('G8 unverified account + trusted email → 409, nothing linked, still unverified', async () => {
    const u = await registerUser(app);
    const res = await google(gClaims({ email: u.email, hd: 'nexus.test' }));
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('password_required');
    expect(await identities(u.user.id)).toHaveLength(0);
    expect((await prisma.user.findUnique({ where: { id: u.user.id } })).emailVerified).toBe(false);
  }, SLOW);

  test('G9 G8 + the right password → linked, now verified (trusted), notice sent', async () => {
    const u = await registerUser(app);
    const before = linkedCount();
    const res = await google(gClaims({ email: u.email, hd: 'nexus.test' }), { password: PASSWORD });
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(u.user.id);
    expect(res.body.user.emailVerified).toBe(true);
    expect(await identities(u.user.id)).toHaveLength(1);
    expect(linkedCount()).toBe(before + 1);
  }, SLOW);

  test("G10 G8 + a wrong password → 401 password_required with design's text, nothing linked", async () => {
    const u = await registerUser(app);
    const res = await google(gClaims({ email: u.email, hd: 'nexus.test' }), { password: 'Wrong@2026' });
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: TEXT.wrongPassword, code: 'password_required', email: u.email });
    expect(await identities(u.user.id)).toHaveLength(0);
  }, SLOW);

  test('G35 unverified account + untrusted email + right password → linked, still unverified', async () => {
    const u = await registerUser(app);
    const res = await google(gClaims({ email: u.email }), { password: PASSWORD });
    expect(res.status).toBe(200);
    expect(res.body.user.emailVerified).toBe(false);
    expect(await identities(u.user.id)).toHaveLength(1);
  }, SLOW);

  test('G11 an account linked to another sub → 409 other_google', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    expect((await google(gClaims({ email: u.email, hd: 'nexus.test' }))).status).toBe(200);
    const res = await google(gClaims({ email: u.email, hd: 'nexus.test' }), { password: PASSWORD });
    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: TEXT.otherGoogle, code: 'other_google' });
    expect(await identities(u.user.id)).toHaveLength(1);
  }, SLOW);

  test('G12 an older address with capitals is found like /login', async () => {
    const lower = uniqueEmail();
    const stored = `T${lower.slice(1)}`; // Test_…@nexus.test
    const row = await prisma.user.create({
      data: {
        email: stored, password: await bcrypt.hash(PASSWORD, 4), emailVerified: true,
        firstName: 'Old', lastName: 'Case', name: 'Old Case',
        serialNumber: generateSerial(),
      },
    });
    track(row.id);
    const res = await google(gClaims({ email: lower, hd: 'nexus.test' }));
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(row.id);
    expect(mailer.lastLinkedFor(stored)).toBeTruthy();
  }, SLOW);

  test('G39 no Gmail dot folding: test_ab_… does not match test_a.b_…', async () => {
    const n = `${Date.now()}${crypto.randomInt(0, 1_000_000)}`;
    const first = await request(app).post('/api/auth/register').send({
      firstName: 'Test', lastName: 'User', email: `test_ab_${n}@nexus.test`, password: PASSWORD,
    });
    expect(first.status).toBe(201);
    track(first.body.user.id);
    await verifyUser(first.body.user.id);
    const res = await google(gClaims({ email: `test_a.b_${n}@nexus.test`, hd: 'nexus.test' }));
    expect(res.status).toBe(201);
    expect(res.body.user.id).not.toBe(first.body.user.id);
    expect(await identities(first.body.user.id)).toHaveLength(0);
  }, SLOW);

  test('G41 two older rows that differ only in case → 409 email_taken, no third account', async () => {
    const lower = uniqueEmail();
    for (const email of [`T${lower.slice(1)}`, lower.toUpperCase()]) {
      const row = await prisma.user.create({
        data: {
          email, password: await bcrypt.hash(PASSWORD, 4), emailVerified: true,
          firstName: 'Old', lastName: 'Case', name: 'Old Case', serialNumber: generateSerial(),
        },
      });
      track(row.id);
    }
    const res = await google(gClaims({ email: lower, hd: 'nexus.test' }));
    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: TEXT.emailTaken, code: 'email_taken' });
    expect(await prisma.user.findUnique({ where: { email: lower } })).toBeNull();
  }, SLOW);

  test('G32 verified account, unverified Google email → 403 (not 409), nothing read or changed', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    const before = await prisma.user.findUnique({ where: { id: u.user.id } });
    const res = await google(gClaims({ email: u.email, email_verified: false, hd: 'nexus.test' }));
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('google_email_unverified');
    expect(await identities(u.user.id)).toHaveLength(0);
    expect(await prisma.user.findUnique({ where: { id: u.user.id } })).toEqual(before);
  }, SLOW);

  test('G33 the notice goes to the stored Nexus address only; none on L1 or L4', async () => {
    const u = await registerUser(app);
    await verifyUser(u.user.id);
    const start = linkedCount();
    const claims = gClaims({ email: u.email, hd: 'nexus.test' });
    expect((await google(claims)).status).toBe(200);
    expect(mailer.sentLinked.slice(start)).toEqual([{ to: u.email, firstName: 'Test', providerLabel: 'Google' }]);
    expect((await google(claims)).status).toBe(200); // L1
    await googleUser(); // L4
    expect(linkedCount()).toBe(start + 1);
  }, SLOW);
});

describe('two-step sign-in (S18)', () => {
  test('G13 a 2FA user via L1 gets the challenge; send-code + verify give a session', async () => {
    const g = await googleUser();
    await prisma.user.update({ where: { id: g.user.id }, data: { loginTwoFactor: true } });
    const res = await google(g.claims);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ twoFactorRequired: true, method: 'email', expiresInSeconds: 600 });
    expect(res.body.token).toBeUndefined();
    const sent = await request(app).post('/api/auth/login/send-code').send({ challengeToken: res.body.challengeToken });
    expect(sent.status).toBe(200);
    const done = await request(app).post('/api/auth/login/verify')
      .send({ challengeToken: res.body.challengeToken, code: mailer.lastLoginCodeFor(g.claims.email) });
    expect(done.status).toBe(200);
    expect((await me(done.body.token)).status).toBe(200);
  }, SLOW);

  test('G31 2FA users on the auto-link and the password-link paths get the challenge', async () => {
    const auto = await registerUser(app);
    await twoFactorOn(auto);
    const a = await google(gClaims({ email: auto.email, hd: 'nexus.test' }));
    expect(a.status).toBe(200);
    expect(a.body.twoFactorRequired).toBe(true);
    expect(a.body.challengeToken).toEqual(expect.any(String));
    expect(a.body.token).toBeUndefined();
    expect(await identities(auto.user.id)).toHaveLength(1);

    const pw = await registerUser(app);
    await twoFactorOn(pw);
    const b = await google(gClaims({ email: pw.email }), { password: PASSWORD });
    expect(b.status).toBe(200);
    expect(b.body.twoFactorRequired).toBe(true);
    expect(b.body.token).toBeUndefined();
    expect(await identities(pw.user.id)).toHaveLength(1);
  }, SLOW);
  test('G42 the challenge names the stored Nexus address (where the code goes); /login\'s has no email', async () => {
    const g = await googleUser();
    await prisma.user.update({ where: { id: g.user.id }, data: { loginTwoFactor: true } });
    // The Google email changed since the account was made (G4): the code
    // still goes to the stored one.
    const res = await google({ ...g.claims, email: uniqueEmail() });
    expect(res.status).toBe(200);
    expect(res.body.twoFactorRequired).toBe(true);
    expect(res.body.email).toBe(g.claims.email);
    const sent = await request(app).post('/api/auth/login/send-code').send({ challengeToken: res.body.challengeToken });
    expect(sent.status).toBe(200);
    expect(mailer.lastLoginCodeFor(g.claims.email)).toBeTruthy();

    const u = await registerUser(app);
    await twoFactorOn(u);
    const pw = await login(u.email, PASSWORD);
    expect(pw.body.twoFactorRequired).toBe(true);
    expect(pw.body.email).toBeUndefined();
  }, SLOW);
});

describe('bad tokens, bad bodies, configuration', () => {
  test('G14 invalid → 401; keys down → 503; no client IDs → 503 without calling the verifier', async () => {
    const bad = await google('fake.bad.sig');
    expect(bad.status).toBe(401);
    expect(bad.body).toEqual({ error: TEXT.failed });
    const down = await google('fake.down.sig');
    expect(down.status).toBe(503);
    expect(down.body).toEqual({ error: TEXT.unavailable });

    const saved = process.env.GOOGLE_CLIENT_IDS;
    process.env.GOOGLE_CLIENT_IDS = '';
    try {
      fakeVerifier.mockClear();
      const off = await google(gClaims());
      expect(off.status).toBe(503);
      expect(off.body).toEqual({ error: TEXT.unavailable });
      expect(fakeVerifier).not.toHaveBeenCalled();
    } finally {
      process.env.GOOGLE_CLIENT_IDS = saved;
    }
  }, SLOW);

  test('G15 bad bodies → 400 and the verifier is never called', async () => {
    const good = fakeGoogle(gClaims());
    const bodies = [
      {}, { idToken: 123 }, { idToken: ['a.b.c'] }, { idToken: 'a'.repeat(5000) },
      { idToken: 'not-a-token' }, { idToken: 'a+b.c/d.e' }, { idToken: '' },
      { idToken: good, password: 123 }, { idToken: good, password: '' }, { idToken: good, password: 'x'.repeat(1025) },
    ];
    for (const body of bodies) {
      const res = await request(app).post('/api/auth/google').send(body);
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: TEXT.failed });
    }
    expect(fakeVerifier).not.toHaveBeenCalled();
  }, SLOW);

  test('G22 POST /api/auth/apple is a 404', async () => {
    expect((await request(app).post('/api/auth/apple').send({ idToken: 'a.b.c' })).status).toBe(404);
  });

  test('G38 the real verifier: wrong aud, expired, bad signature → the same 401, no client ID', async () => {
    const pair = makeKeyPair('g38');
    const other = makeKeyPair('g38');
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl: fakeJwksFetch({ keys: [pair.jwk] }) });
    const real = makeApp({ idTokenVerifiers: { google: (t) => verifyIdToken(t, 'google', { getKey: store.getKey }) } });
    const now = Date.now();
    const tokens = [
      signToken(pair, claimsAt(now, { aud: '999-other.apps.googleusercontent.com' })),
      signToken(pair, claimsAt(now - 2 * 3600 * 1000)),
      signToken(other, claimsAt(now)),
    ];
    for (const idToken of tokens) {
      const res = await request(real).post('/api/auth/google').send({ idToken });
      expect(res.status).toBe(401);
      expect(res.body).toEqual({ error: TEXT.failed });
      expect(res.text).not.toContain(CLIENT_ID);
      expect(res.text).not.toContain('googleusercontent');
    }
  }, SLOW);
});

describe('limits', () => {
  test('G20 the 31st request in 15 minutes from one IP → 429 with the oauth text', async () => {
    const limited = makeApp({ rateLimit: {}, idTokenVerifiers: { google: fakeVerifier } });
    for (let i = 0; i < 30; i++) {
      expect((await request(limited).post('/api/auth/google').send({})).status).toBe(400);
    }
    const res = await request(limited).post('/api/auth/google').send({});
    expect(res.status).toBe(429);
    expect(res.body).toEqual({ error: 'Too many sign-in attempts. Try again in a few minutes.' });
  }, SLOW);

  test('G21 wrong passwords count toward the login limiter, with its own text', async () => {
    const limited = makeApp({ rateLimit: { login: { limit: 2 } }, idTokenVerifiers: { google: fakeVerifier } });
    const u = await registerUser(app);
    const claims = gClaims({ email: u.email });
    for (let i = 0; i < 2; i++) {
      expect((await google(claims, { password: 'Wrong@2026' }, limited)).status).toBe(401);
    }
    const res = await google(claims, { password: 'Wrong@2026' }, limited);
    expect(res.status).toBe(429);
    expect(res.body).toEqual({ error: 'Too many login attempts. Try again in a few minutes.' });
  }, SLOW);
});

describe('passwordSet and Forgot password', () => {
  test('G23 a Google-only user sets a password with a reset; the link is removed and comes back', async () => {
    const g = await googleUser({ hd: 'nexus.test' });
    const before = await prisma.user.findUnique({ where: { id: g.user.id } });
    const reset = await resetPassword(g.claims.email);
    expect(reset.status).toBe(200);
    expect(reset.body.user.passwordSet).toBe(true);
    const after = await prisma.user.findUnique({ where: { id: g.user.id } });
    expect(after.tokenVersion).toBe(before.tokenVersion + 1);
    expect(await identities(g.user.id)).toHaveLength(0);
    expect((await login(g.claims.email, NEW_PASSWORD)).status).toBe(200);

    const start = linkedCount();
    const again = await google(g.claims);
    expect(again.status).toBe(200);
    expect(again.body.user.id).toBe(g.user.id);
    expect(linkedCount()).toBe(start + 1);
    expect(await identities(g.user.id)).toHaveLength(1);
  }, SLOW);

  test('G24 PATCH /user/password for a Google-only user → 409 no_password before bcrypt.compare', async () => {
    const g = await googleUser();
    const compare = jest.spyOn(bcrypt, 'compare');
    try {
      const res = await request(app).patch('/api/user/password').set(auth(g.token))
        .send({ currentPassword: 'Anything@2026', newPassword: NEW_PASSWORD });
      expect(res.status).toBe(409);
      expect(res.body).toEqual({ error: 'You sign in with Google. Use Set a password in Profile first.', code: 'no_password' });
      expect(compare).not.toHaveBeenCalled();
    } finally {
      compare.mockRestore();
    }
  }, SLOW);

  test('G25 PATCH /user/me: a new email → 409 no_password; a name-only save → 200', async () => {
    const g = await googleUser();
    const change = await request(app).patch('/api/user/me').set(auth(g.token))
      .send({ firstName: 'A', lastName: 'B', email: uniqueEmail() });
    expect(change.status).toBe(409);
    expect(change.body).toEqual({ error: 'Set a password before changing your email.', code: 'no_password' });
    const names = await request(app).patch('/api/user/me').set(auth(g.token))
      .send({ firstName: 'A', lastName: 'B', email: g.claims.email });
    expect(names.status).toBe(200);
    expect(names.body).toMatchObject({ firstName: 'A', lastName: 'B', passwordSet: false });
  }, SLOW);

  test('G26 turning 2FA on needs a password; after a reset it works', async () => {
    const g = await googleUser();
    const on = await request(app).patch('/api/user/security').set(auth(g.token)).send({ loginTwoFactor: true });
    expect(on.status).toBe(403);
    expect(on.body).toEqual({ error: 'Set a password before turning on two-step sign-in.', code: 'no_password' });
    const reset = await resetPassword(g.claims.email);
    expect(reset.status).toBe(200);
    const again = await request(app).patch('/api/user/security').set(auth(reset.body.token)).send({ loginTwoFactor: true });
    expect(again.status).toBe(200);
    expect(again.body.loginTwoFactor).toBe(true);
  }, SLOW);

  test('G29 a reset evicts a Google account linked by someone with the password', async () => {
    const u = await registerUser(app);
    const aEmail = u.email;
    const a = gClaims({ email: aEmail, hd: 'nexus.test' });
    expect((await google(a, { password: PASSWORD })).status).toBe(200); // G9 path
    expect(await identities(u.user.id)).toHaveLength(1);

    await allowEmailResend(u.user.id);
    const newEmail = uniqueEmail();
    const moved = await request(app).patch('/api/user/me').set(auth(u.token))
      .send({ firstName: 'Test', lastName: 'User', email: newEmail, currentPassword: PASSWORD });
    expect(moved.status).toBe(200);
    const reset = await resetPassword(newEmail);
    expect(reset.status).toBe(200);
    expect(await identities(u.user.id)).toHaveLength(0);

    const res = await google(a);
    expect(res.status).toBe(201);
    expect(res.body.user.id).not.toBe(u.user.id);
    expect((await login(newEmail, NEW_PASSWORD)).status).toBe(200);
  }, SLOW);

  test('G40 a reset that lands during the link\'s password check wins: nothing stays linked', async () => {
    const u = await registerUser(app);
    const realCompare = bcrypt.compare;
    // The owner's reset commits while the link request is in bcrypt.compare
    // with the old password (the same writes as /reset-password).
    const spy = jest.spyOn(bcrypt, 'compare').mockImplementationOnce(async (pw, hash) => {
      const ok = await realCompare(pw, hash);
      await prisma.$transaction([
        prisma.user.update({
          where: { id: u.user.id },
          data: { password: await bcrypt.hash(NEW_PASSWORD, 4), tokenVersion: { increment: 1 } },
        }),
        prisma.authIdentity.deleteMany({ where: { userId: u.user.id } }),
      ]);
      return ok;
    });
    try {
      const res = await google(gClaims({ email: u.email }), { password: PASSWORD });
      // The second pass compares against the new hash.
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('password_required');
    } finally {
      spy.mockRestore();
    }
    expect(await identities(u.user.id)).toHaveLength(0);
    // The owner's new password still links normally.
    const ok = await google(gClaims({ email: u.email }), { password: NEW_PASSWORD });
    expect(ok.status).toBe(200);
    expect(await identities(u.user.id)).toHaveLength(1);
  }, SLOW);

  test('G43 a reset that lands as a linked stranger signs in (L1) leaves no live session', async () => {
    const u = await registerUser(app);
    // A stranger who knows the old password links their own Google (G9 path,
    // untrusted email, so the account stays unverified and a post-reset L2
    // cannot auto-link).
    const stranger = gClaims({ email: u.email });
    expect((await google(stranger, { password: PASSWORD })).status).toBe(200);
    expect(await identities(u.user.id)).toHaveLength(1);

    const realFindFirst = prisma.user.findFirst.bind(prisma.user);
    // The owner's reset commits just before L1 reads (the same writes as
    // /reset-password); then the real read runs.
    const spy = jest.spyOn(prisma.user, 'findFirst').mockImplementationOnce(async (args) => {
      await prisma.$transaction([
        prisma.user.update({
          where: { id: u.user.id },
          data: { password: await bcrypt.hash(NEW_PASSWORD, 4), tokenVersion: { increment: 1 } },
        }),
        prisma.authIdentity.deleteMany({ where: { userId: u.user.id } }),
      ]);
      return realFindFirst(args);
    });
    let res;
    try {
      res = await google(stranger);
    } finally {
      spy.mockRestore();
    }
    if (res.status === 200) {
      // Any session it got must already be dead.
      expect((await me(res.body.token)).status).toBe(401);
    } else {
      expect([201, 401, 409]).toContain(res.status);
    }
    expect(await identities(u.user.id)).toHaveLength(0);
  }, SLOW);

  test('G28 passwordSet is true in /register, /login and /me for password users', async () => {
    const u = await registerUser(app);
    expect(u.user.passwordSet).toBe(true);
    const signedIn = await login(u.email, PASSWORD);
    expect(signedIn.body.user.passwordSet).toBe(true);
    expect((await me(u.token)).body.passwordSet).toBe(true);
  }, SLOW);
});

describe('what never leaves the server', () => {
  test('G34 logs hold no token, sub, email or password (G1, G6, G10, G14 paths)', async () => {
    const lines = [];
    const spies = ['log', 'error', 'warn'].map((m) => jest.spyOn(console, m).mockImplementation((...a) => {
      lines.push(a.map(String).join(' '));
    }));
    const secrets = [];
    try {
      const c1 = gClaims();
      await google(c1); // G1
      const u6 = await registerUser(app);
      await verifyUser(u6.user.id);
      const c6 = gClaims({ email: u6.email, hd: 'nexus.test' });
      await google(c6); // G6
      const u10 = await registerUser(app);
      const c10 = gClaims({ email: u10.email, hd: 'nexus.test' });
      await google(c10, { password: 'Wrong@2026x' }); // G10
      await google('fake.bad.sig'); // G14
      await google('fake.down.sig');
      for (const c of [c1, c6, c10]) secrets.push(fakeGoogle(c), c.sub, c.email);
      secrets.push('Wrong@2026x');
    } finally {
      spies.forEach((s) => s.mockRestore());
    }
    expect(lines.some((l) => l.startsWith('[auth/google]'))).toBe(true);
    for (const line of lines) {
      for (const s of secrets) expect(line).not.toContain(s);
    }
  }, SLOW);

  test('G18 no /google answer carries password, tokenVersion, subject, the identity email or the ID token', async () => {
    // The answers of every test above in this file.
    expect(replies.length).toBeGreaterThan(20);
    const keysOf = (v, out = []) => {
      if (v && typeof v === 'object') {
        for (const [k, x] of Object.entries(v)) { out.push(k); keysOf(x, out); }
      }
      return out;
    };
    for (const { res, idToken } of replies) {
      const keys = keysOf(res.body);
      for (const k of ['password', 'tokenVersion', 'subject', 'identities', 'sub']) expect(keys).not.toContain(k);
      expect(res.text).not.toContain(idToken);
    }
    // G4: the changed Google email (the identity row's email) is never returned.
    const { claims } = await googleUser();
    const changed = uniqueEmail();
    const res = await google({ ...claims, email: changed });
    expect(res.text).not.toContain(changed);
    expect(res.text).not.toContain(claims.sub);
  }, SLOW);
});
