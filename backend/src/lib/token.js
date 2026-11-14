const crypto = require('crypto');
const jwt = require('jsonwebtoken');

// One place that signs and checks every JWT, so the HTTP middleware and the
// Socket.IO handshake share the same rules.
//   - Session tokens: { userId }, signed with JWT_SECRET, 7 days.
//   - Sign-in challenges (two-step sign-in): { sub, purpose, pwd }, signed
//     with a key derived from JWT_SECRET, 10 minutes. Because the keys differ,
//     a challenge can never pass as a session, and the other way round.

const CHALLENGE_TTL_SECONDS = 600;
const CHALLENGE_PURPOSE = 'login-2fa';

const hasUserId = (decoded) => typeof decoded?.userId === 'string' && decoded.userId.length > 0;

function signSession(userId) {
  return jwt.sign({ userId }, process.env.JWT_SECRET, { expiresIn: '7d', algorithm: 'HS256' });
}

// { userId, exp } for a valid session token, otherwise null. Never throws.
function verifySession(token) {
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET, { algorithms: ['HS256'] });
    // Only session tokens carry a userId. Without this check req.userId would
    // be undefined, and Prisma drops an undefined filter (all users' rows).
    if (!hasUserId(decoded)) return null;
    return { userId: decoded.userId, exp: decoded.exp };
  } catch {
    return null;
  }
}

// Computed on each call so it always follows process.env. No new secret env var.
function challengeKey() {
  return crypto.createHmac('sha256', process.env.JWT_SECRET).update('nexus-login-2fa').digest('hex');
}

// Ties a challenge to the password hash it was issued for, without putting
// the hash in the token. A password change voids every open challenge.
function passwordTag(hash) {
  return crypto.createHmac('sha256', challengeKey()).update(String(hash)).digest('hex').slice(0, 16);
}

function signChallenge(user) {
  return jwt.sign(
    { sub: user.id, purpose: CHALLENGE_PURPOSE, pwd: passwordTag(user.password) },
    challengeKey(),
    { algorithm: 'HS256', expiresIn: CHALLENGE_TTL_SECONDS },
  );
}

// { userId, pwd } for a valid sign-in challenge, otherwise null. Never throws.
function verifyChallenge(token) {
  try {
    const decoded = jwt.verify(token, challengeKey(), { algorithms: ['HS256'] });
    if (decoded?.purpose !== CHALLENGE_PURPOSE) return null;
    if (typeof decoded.sub !== 'string' || decoded.sub.length === 0) return null;
    if (typeof decoded.pwd !== 'string' || decoded.pwd.length === 0) return null;
    return { userId: decoded.sub, pwd: decoded.pwd };
  } catch {
    return null;
  }
}

module.exports = {
  hasUserId, signSession, verifySession, signChallenge, verifyChallenge, passwordTag,
  CHALLENGE_TTL_SECONDS,
};
