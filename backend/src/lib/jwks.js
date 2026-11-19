const crypto = require('crypto');

// Public signing keys of an outside sign-in provider (Google), fetched from
// one constant HTTPS URL and cached. Every request that triggers a fetch is
// unauthenticated, so the store is careful about how often it fetches:
//   - the cache lives for the reply's Cache-Control max-age (5 min .. 24 h,
//     1 h when missing);
//   - an unknown kid refetches at most once per 60 s for the whole store
//     (one store per process), and concurrent refetches share one request;
//   - a failed refresh keeps the cached keys that have not expired yet.
// Only RSA signing keys are imported. Key material is never logged.

const MIN = 60 * 1000;
const FETCH_TIMEOUT_MS = 5000;
const REFETCH_GAP_MS = 60 * 1000;
const MIN_TTL_MS = 5 * MIN;
const MAX_TTL_MS = 24 * 60 * MIN;
const DEFAULT_TTL_MS = 60 * MIN;
const MAX_KID = 256;

class JwksUnavailable extends Error {
  constructor() {
    super('Signing keys unavailable');
    this.name = 'JwksUnavailable';
  }
}

// Cache lifetime in ms from a Cache-Control header value.
function ttlFrom(cacheControl) {
  const m = typeof cacheControl === 'string' ? /max-age=(\d+)/i.exec(cacheControl) : null;
  if (!m) return DEFAULT_TTL_MS;
  return Math.min(MAX_TTL_MS, Math.max(MIN_TTL_MS, Number(m[1]) * 1000));
}

const isKid = (kid) => typeof kid === 'string' && kid.length >= 1 && kid.length <= MAX_KID;

// Map kid → KeyObject of the usable keys in a JWKS body. Anything that is not
// an RSA signing key for RS256 is skipped.
function importKeys(body) {
  const keys = new Map();
  const list = Array.isArray(body?.keys) ? body.keys : [];
  for (const jwk of list) {
    if (!jwk || typeof jwk !== 'object') continue;
    if (jwk.kty !== 'RSA') continue;
    if (jwk.alg !== undefined && jwk.alg !== 'RS256') continue;
    if (jwk.use !== undefined && jwk.use !== 'sig') continue;
    if (!isKid(jwk.kid)) continue;
    try {
      // Only the public parts, so a key with private fields stays public.
      const key = crypto.createPublicKey({ key: { kty: 'RSA', n: jwk.n, e: jwk.e }, format: 'jwk' });
      keys.set(jwk.kid, key);
    } catch {
      // A malformed key is skipped.
    }
  }
  return keys;
}

/**
 * makeKeyStore({ url, fetchImpl, now }) → { getKey(kid) }.
 * getKey resolves to a KeyObject, or null for a kid the provider doesn't have.
 * It throws JwksUnavailable only when no usable key could be loaded.
 */
function makeKeyStore({ url, fetchImpl = (...a) => fetch(...a), now = Date.now } = {}) {
  if (typeof url !== 'string' || !url.startsWith('https://')) {
    throw new Error('makeKeyStore needs an https:// URL');
  }
  let keys = new Map();
  let expiresAt = 0;
  let lastFetchAt = -Infinity;
  let lastFetchFailed = false;
  let inflight = null;

  async function load() {
    lastFetchAt = now();
    try {
      const res = await fetchImpl(url, {
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
        headers: { accept: 'application/json' },
        // Only ever the one constant URL: a redirect is a failure (S7).
        redirect: 'error',
      });
      if (!res || !res.ok) throw new JwksUnavailable();
      const fresh = importKeys(await res.json());
      if (fresh.size === 0) throw new JwksUnavailable();
      keys = fresh;
      expiresAt = now() + ttlFrom(res.headers?.get?.('cache-control'));
      lastFetchFailed = false;
    } catch {
      lastFetchFailed = true;
      throw new JwksUnavailable();
    }
  }

  // One request at a time: callers that arrive during a fetch wait for it.
  function refresh() {
    if (!inflight) inflight = load().finally(() => { inflight = null; });
    return inflight;
  }

  const cacheFresh = () => now() < expiresAt;

  async function getKey(kid) {
    if (!isKid(kid)) return null;
    if (cacheFresh() && keys.has(kid)) return keys.get(kid);

    if (!cacheFresh()) {
      // Expired or never loaded. After a failure, wait out the gap instead of
      // fetching on every request while the provider is down.
      if (!inflight && lastFetchFailed && now() - lastFetchAt < REFETCH_GAP_MS) throw new JwksUnavailable();
      await refresh();
      return keys.get(kid) ?? null;
    }

    // Fresh cache, unknown kid: maybe the provider rotated its keys.
    if (inflight) {
      await inflight.catch(() => {});
    } else if (now() - lastFetchAt >= REFETCH_GAP_MS) {
      // A failed refresh keeps the keys we still have.
      await refresh().catch(() => {});
    }
    return cacheFresh() ? keys.get(kid) ?? null : null;
  }

  return { getKey };
}

module.exports = { makeKeyStore, JwksUnavailable, ttlFrom, importKeys, FETCH_TIMEOUT_MS, REFETCH_GAP_MS };
