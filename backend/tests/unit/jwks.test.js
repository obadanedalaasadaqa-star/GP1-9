// lib/jwks.js: the key store, with a fake fetch and a fake clock (no network).
const { makeKeyStore, JwksUnavailable, ttlFrom } = require('../../src/lib/jwks');
const { GOOGLE_JWKS_URL, makeKeyPair, fakeJwksFetch } = require('../googleTokens');

const MIN = 60 * 1000;
const pair = makeKeyPair('k1');
const other = makeKeyPair('k2');

function clock(start = 1_000_000) {
  let t = start;
  const now = () => t;
  now.advance = (ms) => { t += ms; };
  return now;
}

describe('cache lifetime (U10)', () => {
  test('max-age is used, clamped to 5 min .. 24 h, 1 h when missing', () => {
    expect(ttlFrom('public, max-age=3600')).toBe(60 * MIN);
    expect(ttlFrom('max-age=60')).toBe(5 * MIN);
    expect(ttlFrom('max-age=999999')).toBe(24 * 60 * MIN);
    expect(ttlFrom(null)).toBe(60 * MIN);
    expect(ttlFrom('no-cache')).toBe(60 * MIN);
  });

  test('keys are cached for max-age, then fetched again', async () => {
    const now = clock();
    const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] }, { cacheControl: 'max-age=600' });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
    expect(await store.getKey('k1')).toBeTruthy();
    now.advance(9 * MIN);
    expect(await store.getKey('k1')).toBeTruthy();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    now.advance(2 * MIN);
    expect(await store.getKey('k1')).toBeTruthy();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  test('fetches only the constant HTTPS URL, with a timeout signal', async () => {
    const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl });
    await store.getKey('k1');
    expect(fetchImpl.calls[0].url).toBe(GOOGLE_JWKS_URL);
    expect(fetchImpl.calls[0].opts.signal).toBeInstanceOf(AbortSignal);
    // A redirect is never followed (S7: the one constant URL only).
    expect(fetchImpl.calls[0].opts.redirect).toBe('error');
    expect(() => makeKeyStore({ url: 'http://www.googleapis.com/oauth2/v3/certs' })).toThrow();
  });
});

describe('unknown kid (U11)', () => {
  test('one refetch; a second unknown kid within 60 s → no fetch', async () => {
    const now = clock();
    const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
    await store.getKey('k1');
    now.advance(61 * 1000);
    expect(await store.getKey('nope-1')).toBeNull();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    now.advance(10 * 1000);
    expect(await store.getKey('nope-2')).toBeNull();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    now.advance(60 * 1000);
    expect(await store.getKey('nope-3')).toBeNull();
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  test('a rotated key is found by the refetch', async () => {
    const now = clock();
    let jwks = { keys: [pair.jwk] };
    const fetchImpl = jest.fn(async () => ({
      ok: true, headers: { get: () => 'max-age=3600' }, json: async () => jwks,
    }));
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
    await store.getKey('k1');
    jwks = { keys: [pair.jwk, other.jwk] };
    now.advance(61 * 1000);
    expect(await store.getKey('k2')).toBeTruthy();
  });

  test('kid longer than 256 or not a string → null without a fetch', async () => {
    const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl });
    expect(await store.getKey('x'.repeat(257))).toBeNull();
    expect(await store.getKey(42)).toBeNull();
    expect(await store.getKey('')).toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  test('prototype names are never keys (Map lookup)', async () => {
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl: fakeJwksFetch({ keys: [pair.jwk] }) });
    for (const kid of ['__proto__', 'constructor', 'toString', 'hasOwnProperty']) {
      expect(await store.getKey(kid)).toBeNull();
    }
  });
});

describe('failures (U12)', () => {
  test.each([
    ['non-200', () => fakeJwksFetch({ keys: [] }, { status: 500 })],
    ['bad JSON', () => jest.fn(async () => ({ ok: true, headers: { get: () => null }, json: async () => { throw new SyntaxError('x'); } }))],
    ['timeout', () => jest.fn(async () => { throw Object.assign(new Error('timeout'), { name: 'TimeoutError' }); })],
    ['no usable keys', () => fakeJwksFetch({ keys: [{ kty: 'EC', kid: 'k1' }] })],
  ])('%s with an empty cache → JwksUnavailable', async (_name, make) => {
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl: make() });
    await expect(store.getKey('k1')).rejects.toBeInstanceOf(JwksUnavailable);
  });

  test('after a failure, no new fetch for 60 s', async () => {
    const now = clock();
    const fetchImpl = fakeJwksFetch({}, { status: 503 });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
    await expect(store.getKey('k1')).rejects.toBeInstanceOf(JwksUnavailable);
    await expect(store.getKey('k1')).rejects.toBeInstanceOf(JwksUnavailable);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    now.advance(61 * 1000);
    await expect(store.getKey('k1')).rejects.toBeInstanceOf(JwksUnavailable);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});

describe('which keys are imported (U13)', () => {
  test('only RSA, alg RS256 if present, use sig if present', async () => {
    const ec = { kty: 'EC', crv: 'P-256', x: 'x', y: 'y', kid: 'ec' };
    const rs512 = { ...makeKeyPair('rs512').jwk, alg: 'RS512' };
    const enc = { ...makeKeyPair('enc').jwk, use: 'enc' };
    const bare = makeKeyPair('bare').jwk;
    delete bare.alg; delete bare.use;
    const store = makeKeyStore({
      url: GOOGLE_JWKS_URL, fetchImpl: fakeJwksFetch({ keys: [ec, rs512, enc, bare, pair.jwk] }),
    });
    expect(await store.getKey('k1')).toBeTruthy();
    expect(await store.getKey('bare')).toBeTruthy();
    expect(await store.getKey('ec')).toBeNull();
    expect(await store.getKey('rs512')).toBeNull();
    expect(await store.getKey('enc')).toBeNull();
  });
});

describe('S7b (U23, U24)', () => {
  test('10 concurrent getKey(unknown) → one fetch', async () => {
    const fetchImpl = fakeJwksFetch({ keys: [pair.jwk] });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl });
    const all = await Promise.all(Array.from({ length: 10 }, () => store.getKey('unknown')));
    expect(all.every((k) => k === null)).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  test('cached keys survive a failed refresh until they expire', async () => {
    const now = clock();
    let fail = false;
    const fetchImpl = jest.fn(async () => {
      if (fail) throw new Error('down');
      return { ok: true, headers: { get: () => 'max-age=600' }, json: async () => ({ keys: [pair.jwk] }) };
    });
    const store = makeKeyStore({ url: GOOGLE_JWKS_URL, fetchImpl, now });
    expect(await store.getKey('k1')).toBeTruthy();
    fail = true;
    now.advance(61 * 1000);
    expect(await store.getKey('rotated')).toBeNull(); // refresh fails quietly
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(await store.getKey('k1')).toBeTruthy(); // still cached
    now.advance(10 * MIN);
    await expect(store.getKey('k1')).rejects.toBeInstanceOf(JwksUnavailable);
  });
});
