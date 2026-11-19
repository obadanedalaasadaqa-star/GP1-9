const jwt = require('jsonwebtoken');
const { provider, audiences } = require('./oauthProviders');
const { normalizeEmail, emailError } = require('./email');
const { JwksUnavailable } = require('./jwks');

// Checks an outside provider's ID token (Google) and returns its claims.
// Every failure throws IdTokenInvalid with one fixed message: jsonwebtoken's
// own messages can contain our client ID ("jwt audience invalid. expected:
// ..."), so they never leave this module. JwksUnavailable (keys can't be
// loaded) is passed through so the route can answer 503.

const MAX_TOKEN = 4096;
const TOKEN_RE = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const MAX_KID = 256;
const MAX_SUB = 255;
const CLOCK_TOLERANCE_S = 60;
const MAX_AGE = '15m';
const TRUSTED_DOMAINS = ['@gmail.com', '@googlemail.com'];

class IdTokenInvalid extends Error {
  constructor() {
    super('ID token invalid');
    this.name = 'IdTokenInvalid';
  }
}

const isNonEmptyString = (v) => typeof v === 'string' && v.length > 0;

// The header's alg and kid, read without trusting anything else in it
// (jku, x5u, jwk and x5c are never looked at). Throws on a broken header.
function readHeader(token) {
  const header = JSON.parse(Buffer.from(token.split('.')[0], 'base64url').toString('utf8'));
  if (!header || typeof header !== 'object' || Array.isArray(header)) throw new IdTokenInvalid();
  return { alg: header.alg, kid: header.kid };
}

// L3: the Google address still belongs to the person who signs in. Gmail
// addresses always do; for any other domain only a Workspace account (hd) does.
function isTrustedEmail(email, hd) {
  if (isNonEmptyString(hd)) return true;
  const lower = email.toLowerCase();
  return TRUSTED_DOMAINS.some((d) => lower.endsWith(d));
}

/**
 * verifyIdToken(idToken, providerName, { getKey, now }) →
 *   { subject, email, emailVerified, trustedEmail, givenName, familyName }
 * getKey(kid) resolves to a public KeyObject or null (lib/jwks.js); now() is
 * the clock in ms (tests move it).
 */
async function verifyIdToken(idToken, providerName, { getKey, now = Date.now } = {}) {
  const p = provider(providerName);
  // A provider that isn't turned on (Apple) never verifies anything.
  if (!p || p.enabled !== true || typeof getKey !== 'function') throw new IdTokenInvalid();

  try {
    // 1. Shape, before any decoding.
    if (typeof idToken !== 'string' || idToken.length > MAX_TOKEN || !TOKEN_RE.test(idToken)) {
      throw new IdTokenInvalid();
    }

    // 2. Header: only RS256 is ever tried, and the kid is just a lookup string.
    const { alg, kid } = readHeader(idToken);
    if (alg !== 'RS256') throw new IdTokenInvalid();
    if (typeof kid !== 'string' || kid.length < 1 || kid.length > MAX_KID) throw new IdTokenInvalid();

    // 3. The provider's key for that kid.
    const key = await getKey(kid);
    if (!key) throw new IdTokenInvalid();

    // 4. Signature, issuer, exp, nbf and an iat at most 15 minutes old.
    const nowSeconds = Math.floor(now() / 1000);
    const claims = jwt.verify(idToken, key, {
      algorithms: ['RS256'],
      issuer: p.issuers,
      clockTolerance: CLOCK_TOLERANCE_S,
      maxAge: MAX_AGE,
      clockTimestamp: nowSeconds,
    });

    // 5. Not issued in the future.
    if (typeof claims.iat !== 'number' || claims.iat > nowSeconds + CLOCK_TOLERANCE_S) {
      throw new IdTokenInvalid();
    }

    // 6. Audience and authorized party: ours. aud must be one string (an
    // array that happens to contain our ID is refused), and azp, when sent,
    // must be one of our IDs too.
    const ours = audiences(providerName);
    if (typeof claims.aud !== 'string' || !ours.includes(claims.aud)) throw new IdTokenInvalid();
    if (claims.azp !== undefined && (typeof claims.azp !== 'string' || !ours.includes(claims.azp))) {
      throw new IdTokenInvalid();
    }

    // 7. Subject.
    if (typeof claims.sub !== 'string' || claims.sub.length < 1 || claims.sub.length > MAX_SUB) {
      throw new IdTokenInvalid();
    }

    // 8. Email, in the form Nexus stores it.
    if (typeof claims.email !== 'string') throw new IdTokenInvalid();
    const email = normalizeEmail(claims.email);
    if (emailError(email)) throw new IdTokenInvalid();

    return {
      subject: claims.sub,
      email,
      // 9. Only the boolean true counts.
      emailVerified: claims.email_verified === true,
      // 10. L3.
      trustedEmail: isTrustedEmail(email, claims.hd),
      givenName: typeof claims.given_name === 'string' ? claims.given_name : '',
      familyName: typeof claims.family_name === 'string' ? claims.family_name : '',
    };
  } catch (err) {
    if (err instanceof JwksUnavailable) throw err;
    // Every other error (ours or jsonwebtoken's) becomes the one fixed error.
    throw new IdTokenInvalid();
  }
}

module.exports = { verifyIdToken, IdTokenInvalid, isTrustedEmail, TOKEN_RE, MAX_TOKEN };
