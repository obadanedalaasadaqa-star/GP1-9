// lib/idToken.js with a key generated during the run and a fake fetch
// (no DB, no network, never Google).
const jwt = require('jsonwebtoken');
const { verifyIdToken, IdTokenInvalid } = require('../../src/lib/idToken');
const { makeKeyStore, JwksUnavailable } = require('../../src/lib/jwks');
const {
  GOOGLE_JWKS_URL, CLIENT_ID, makeKeyPair, claimsAt, signToken, rawToken, fakeJwksFetch,
} = require('../googleTokens');

const NOW = Date.UTC(2026, 10, 19, 12, 0, 0);
const now = () => NOW;
const pair = makeKeyPair('k1');
const attacker = makeKeyPair('k1'); // same kid, other key

function setup() {
  const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] });
  const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
  const getKey = jest.fn((kid) => store.getKey(kid));
  const verify = (token) => verifyIdToken(token, 'google', { getKey, now });
  return { fetchImpl, getKey, verify };
}

const token = (over = {}, header = {}, signer = pair) => signToken(signer, claimsAt(NOW, over), header);
const invalid = (p) => expect(p).rejects.toBeInstanceOf(IdTokenInvalid);

describe('valid token (U1)', () => {
  test('returns the normalized claims', async () => {
    const { verify } = setup();
    const claims = await verify(token({ email: '  Test_Google@Nexus.Test ' }));
    expect(claims).toEqual({
      subject: '100000000000000000001',
      email: 'test_google@nexus.test',
      emailVerified: true,
      trustedEmail: false,
      givenName: 'Test',
      familyName: 'Google',
    });
  });

  test('both Google issuers are accepted; no azp is fine', async () => {
    const { verify } = setup();
    await expect(verify(token({ iss: 'accounts.google.com' }))).resolves.toBeTruthy();
    await expect(verify(token({ azp: undefined }))).resolves.toBeTruthy();
  });
});

describe('rejections', () => {
  test('U2: wrong signature (other key, same kid)', async () => {
    const { verify } = setup();
    await invalid(verify(token({}, {}, attacker)));
  });

  test('U3: wrong aud, wrong iss, expired, nbf in the future, iat > 60 s ahead', async () => {
    const { verify } = setup();
    const s = Math.floor(NOW / 1000);
    await invalid(verify(token({ aud: '999-other.apps.googleusercontent.com' })));
    await invalid(verify(token({ iss: 'https://evil.test' })));
    await invalid(verify(token({ iat: s - 600, exp: s - 120 })));
    await invalid(verify(token({ nbf: s + 300 })));
    await invalid(verify(token({ iat: s + 120, exp: s + 3600 })));
    // Inside the 60 s tolerance: still fine.
    await expect(verify(token({ iat: s + 30 }))).resolves.toBeTruthy();
  });

  test('U4: alg none, HS256 with the public key as secret, missing kid; getKey not called for none/HS256', async () => {
    const { verify, getKey } = setup();
    const claims = claimsAt(NOW);
    await invalid(verify(rawToken({ alg: 'none', kid: 'k1' }, claims)));
    const pem = pair.publicKey.export({ type: 'spki', format: 'pem' });
    const hs = jwt.sign(claims, pem, { algorithm: 'HS256', noTimestamp: true, header: { kid: 'k1' } });
    await invalid(verify(hs));
    expect(getKey).not.toHaveBeenCalled();
    const noKid = jwt.sign(claims, pair.privateKey, { algorithm: 'RS256', noTimestamp: true });
    await invalid(verify(noKid));
    expect(getKey).not.toHaveBeenCalled();
  });

  test('U5: missing, empty or 256-char sub', async () => {
    const { verify } = setup();
    await invalid(verify(token({ sub: undefined })));
    await invalid(verify(token({ sub: '' })));
    await invalid(verify(token({ sub: 'x'.repeat(256) })));
    await invalid(verify(token({ sub: 12345 })));
    await expect(verify(token({ sub: 'x'.repeat(255) }))).resolves.toBeTruthy();
  });

  test('U8: non-string, longer than 4096, two parts → invalid before decoding', async () => {
    const { verify, getKey } = setup();
    await invalid(verify(12345));
    await invalid(verify(null));
    await invalid(verify(`${token()}${'a'.repeat(4096)}`));
    await invalid(verify('aaa.bbb'));
    await invalid(verify('a+b.c/d.e'));
    expect(getKey).not.toHaveBeenCalled();
  });

  test('U15: attacker key in jku/jwk/x5u/x5c → invalid; fetch saw only the Google URL', async () => {
    const { verify, fetchImpl } = setup();
    const evil = makeKeyPair('x');
    await invalid(verify(token({}, {
      kid: 'x', jku: 'https://evil.test/jwks', jwk: evil.jwk, x5u: 'https://evil.test/cert', x5c: ['AAAA'],
    }, evil)));
    expect(fetchImpl.calls.map((c) => c.url)).toEqual([GOOGLE_JWKS_URL]);
  });

  test('U16: kid __proto__, constructor, toString, 300 chars → invalid, no TypeError', async () => {
    const { verify } = setup();
    for (const kid of ['__proto__', 'constructor', 'toString', 'x'.repeat(300)]) {
      await invalid(verify(token({}, { kid })));
    }
  });

  test('U17: aud ours, azp another client', async () => {
    const { verify } = setup();
    await invalid(verify(token({ azp: '999-other.apps.googleusercontent.com' })));
    await invalid(verify(token({ azp: 42 })));
  });

  test('U18: aud as an array that contains ours', async () => {
    const { verify } = setup();
    await invalid(verify(token({ aud: [CLIENT_ID, 'other'] })));
    await invalid(verify(token({ aud: [CLIENT_ID] })));
  });

  test('U19: email not an email, 300 chars, a number, missing', async () => {
    const { verify } = setup();
    await invalid(verify(token({ email: 'not-an-email' })));
    await invalid(verify(token({ email: `${'a'.repeat(290)}@nexus.test` })));
    await invalid(verify(token({ email: 12345 })));
    await invalid(verify(token({ email: undefined })));
  });

  test('U22: iat 16 min ago (exp still future) → invalid; 14 min ago → valid', async () => {
    const { verify } = setup();
    const s = Math.floor(NOW / 1000);
    await invalid(verify(token({ iat: s - 16 * 60, exp: s + 600 })));
    await expect(verify(token({ iat: s - 14 * 60, exp: s + 600 }))).resolves.toBeTruthy();
  });

  test('an empty audience list rejects everything', async () => {
    const saved = process.env.GOOGLE_CLIENT_IDS;
    process.env.GOOGLE_CLIENT_IDS = '';
    try {
      const { verify } = setup();
      await invalid(verify(token()));
    } finally {
      process.env.GOOGLE_CLIENT_IDS = saved;
    }
  });

  test('the error message never carries the client ID or a jsonwebtoken message', async () => {
    const { verify } = setup();
    const err = await verify(token({ aud: '999-other.apps.googleusercontent.com' })).catch((e) => e);
    expect(err).toBeInstanceOf(IdTokenInvalid);
    expect(err.message).toBe('ID token invalid');
    expect(String(err.stack)).not.toContain('googleusercontent');
  });

  test('a provider that is not enabled (apple) → invalid, getKey never called', async () => {
    const { getKey } = setup();
    await invalid(verifyIdToken(token(), 'apple', { getKey, now }));
    await invalid(verifyIdToken(token(), 'nope', { getKey, now }));
    expect(getKey).not.toHaveBeenCalled();
  });

  test('JwksUnavailable is passed through (the route answers 503)', async () => {
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl: fakeJwksFetch({}, { status: 500 }), now });
    await expect(verifyIdToken(token(), 'google', { getKey: store.getKey, now }))
      .rejects.toBeInstanceOf(JwksUnavailable);
  });
});

describe('email flags', () => {
  test('U6: email_verified false / missing / "true" → false', async () => {
    const { verify } = setup();
    expect((await verify(token({ email_verified: false }))).emailVerified).toBe(false);
    expect((await verify(token({ email_verified: undefined }))).emailVerified).toBe(false);
    expect((await verify(token({ email_verified: 'true' }))).emailVerified).toBe(false);
    expect((await verify(token({ email_verified: true }))).emailVerified).toBe(true);
  });

  test('U7: trustedEmail for gmail.com, googlemail.com and any hd; case-insensitive', async () => {
    const { verify } = setup();
    // Address shapes only: these never reach a DB row or a mailbox.
    expect((await verify(token({ email: 'Test_U7@GMAIL.com' }))).trustedEmail).toBe(true);
    expect((await verify(token({ email: 'test_u7@googlemail.com' }))).trustedEmail).toBe(true);
    expect((await verify(token({ email: 'test_x@nexus.test', hd: 'nexus.test' }))).trustedEmail).toBe(true);
    expect((await verify(token({ email: 'test_x@nexus.test' }))).trustedEmail).toBe(false);
    expect((await verify(token({ email: 'test_u7@gmail.com.evil.test' }))).trustedEmail).toBe(false);
  });

  test('U20: hd "" or 123 with a non-Gmail email → not trusted', async () => {
    const { verify } = setup();
    expect((await verify(token({ email: 'test_x@nexus.test', hd: '' }))).trustedEmail).toBe(false);
    expect((await verify(token({ email: 'test_x@nexus.test', hd: 123 }))).trustedEmail).toBe(false);
  });
});
