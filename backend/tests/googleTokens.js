// Google-shaped ID tokens for tests, signed with an RSA key generated during
// the run (never a key file). No test ever calls Google.
const crypto = require('crypto');
const jwt = require('jsonwebtoken');

const GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
// Same fake value as tests/env.js; too short to look like a real client ID.
const CLIENT_ID = 'test-client.apps.googleusercontent.com';

// { publicKey, privateKey, kid, jwk } — jwk is the PUBLIC key only.
function makeKeyPair(kid = 'k1') {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const { n, e } = publicKey.export({ format: 'jwk' });
  return { publicKey, privateKey, kid, jwk: { kty: 'RSA', n, e, kid, alg: 'RS256', use: 'sig' } };
}

// Default Google claims at [nowMs]; [over] replaces or adds claims (a value
// of undefined removes the claim).
function claimsAt(nowMs = Date.now(), over = {}) {
  const iat = Math.floor(nowMs / 1000);
  const claims = {
    iss: 'https://accounts.google.com',
    aud: CLIENT_ID,
    azp: CLIENT_ID,
    sub: '100000000000000000001',
    email: 'test_google@nexus.test',
    email_verified: true,
    given_name: 'Test',
    family_name: 'Google',
    iat,
    exp: iat + 3600,
    ...over,
  };
  for (const k of Object.keys(claims)) if (claims[k] === undefined) delete claims[k];
  return claims;
}

// An RS256 token signed with [pair]; [header] adds header fields. The
// claims' own iat is kept (jsonwebtoken only fills it in when missing).
function signToken(pair, claims, header = {}) {
  return jwt.sign(claims, pair.privateKey, {
    algorithm: 'RS256', header: { kid: pair.kid, ...header },
  });
}

const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');

// A token with any header and payload and a junk signature (alg: none, etc.).
function rawToken(header, payload, sig = 'c2ln') {
  return `${b64url(header)}.${b64url(payload)}.${sig}`;
}

// A fake fetch that serves [jwks] (or an error) and records each call.
function fakeJwksFetch(jwks, { cacheControl = 'public, max-age=3600', status = 200 } = {}) {
  const calls = [];
  const impl = jest.fn(async (url, opts) => {
    calls.push({ url, opts });
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (h) => (h.toLowerCase() === 'cache-control' ? cacheControl : null) },
      json: async () => jwks,
    };
  });
  impl.calls = calls;
  return impl;
}

module.exports = {
  GOOGLE_JWKS_URL, CLIENT_ID, makeKeyPair, claimsAt, signToken, rawToken, b64url, fakeJwksFetch,
};
