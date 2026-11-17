// lib/token.js: session tokens and sign-in challenges (no server, no DB).
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const {
  signSession, verifySession, signChallenge, verifyChallenge, passwordTag, CHALLENGE_TTL_SECONDS,
} = require('../../src/lib/token');

const SECRET = process.env.JWT_SECRET;
const USER = { id: 'user-1', password: '$2a$12$somebcrypthashvalue' };
// The same derivation token.js uses, to build hand-made challenges.
const challengeKey = () => crypto.createHmac('sha256', SECRET).update('nexus-login-2fa').digest('hex');
const past = () => Math.floor(Date.now() / 1000) - 10;

describe('sessions', () => {
  test('round trip returns userId and exp', () => {
    const s = verifySession(signSession('user-1', 0));
    expect(s.userId).toBe('user-1');
    expect(s.exp).toBeGreaterThan(Date.now() / 1000 + 6 * 24 * 3600);
  });

  test.each([
    ['no userId', () => jwt.sign({ sub: 'user-1' }, SECRET)],
    ['an empty userId', () => jwt.sign({ userId: '' }, SECRET)],
    ['a wrong secret', () => jwt.sign({ userId: 'user-1' }, 'wrong-secret')],
    ['an expired token', () => jwt.sign({ userId: 'user-1', exp: past() }, SECRET)],
    ['an HS384 token', () => jwt.sign({ userId: 'user-1' }, SECRET, { algorithm: 'HS384' })],
    ['garbage', () => 'not-a-jwt'],
    ['undefined', () => undefined],
  ])('verifySession gives null for %s', (_label, make) => {
    expect(verifySession(make())).toBeNull();
  });

  test('a challenge is never accepted as a session', () => {
    expect(verifySession(signChallenge(USER))).toBeNull();
  });
});

describe('challenges', () => {
  test('round trip returns userId and the password tag', () => {
    const token = signChallenge(USER);
    expect(verifyChallenge(token)).toEqual({ userId: 'user-1', pwd: passwordTag(USER.password) });
    const decoded = jwt.decode(token);
    expect(decoded.exp - decoded.iat).toBe(CHALLENGE_TTL_SECONDS);
    expect(JSON.stringify(decoded)).not.toContain(USER.password);
  });

  test.each([
    ['an expired challenge', () => jwt.sign({ sub: 'u', purpose: 'login-2fa', pwd: 'x', exp: past() }, challengeKey())],
    ['a session token', () => signSession('user-1', 0)],
    ['a challenge signed with plain JWT_SECRET', () => jwt.sign({ sub: 'u', purpose: 'login-2fa', pwd: 'x' }, SECRET)],
    ['a wrong purpose', () => jwt.sign({ sub: 'u', purpose: 'other', pwd: 'x' }, challengeKey())],
    ['a missing sub', () => jwt.sign({ purpose: 'login-2fa', pwd: 'x' }, challengeKey())],
    ['an empty sub', () => jwt.sign({ sub: '', purpose: 'login-2fa', pwd: 'x' }, challengeKey())],
    ['a missing pwd', () => jwt.sign({ sub: 'u', purpose: 'login-2fa' }, challengeKey())],
    ['garbage', () => 'nope'],
  ])('verifyChallenge gives null for %s', (_label, make) => {
    expect(verifyChallenge(make())).toBeNull();
  });

  test('passwordTag changes when the hash changes', () => {
    expect(passwordTag('hash-a')).toHaveLength(16);
    expect(passwordTag('hash-a')).toBe(passwordTag('hash-a'));
    expect(passwordTag('hash-a')).not.toBe(passwordTag('hash-b'));
  });
});

describe('session version (tv)', () => {
  test('signSession puts the version in; verifySession gives it back', () => {
    expect(verifySession(signSession('u', 3))).toMatchObject({ userId: 'u', tv: 3 });
    expect(jwt.decode(signSession('u', 3)).tv).toBe(3);
  });

  test('a token without tv (from before versions) counts as version 0', () => {
    expect(verifySession(jwt.sign({ userId: 'u' }, SECRET, { expiresIn: '7d' })).tv).toBe(0);
  });

  test.each([[-1], ['1'], [1.5], [null]])('tv %p gives null', (tv) => {
    expect(verifySession(jwt.sign({ userId: 'u', tv }, SECRET))).toBeNull();
  });

  test.each([[undefined], [-1], ['0'], [1.5], [null]])('signSession with version %p throws', (v) => {
    expect(() => signSession('u', v)).toThrow();
  });
});
