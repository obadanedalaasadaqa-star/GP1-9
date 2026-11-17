const prisma = require('./prisma');
const { verifySession } = require('./token');

// The session check shared by authMiddleware and the Socket.IO handshake:
// the token's signature and expiry (verifySession) plus one DB lookup, so a
// password change, 2FA on, an email change or "sign out everywhere" (each
// bumps tokenVersion) kills every older token at once.
// Exported so tests can tell this lookup apart from a route's own reads.
const SESSION_SELECT = { tokenVersion: true, emailVerified: true };

/**
 * { userId, exp, tv, emailVerified } for a live session, null when the token
 * is invalid, the user is gone or the token's version is old. Throws on a DB
 * error, so callers can answer "try again" instead of logging the user out.
 */
async function loadSession(token) {
  const s = verifySession(token);
  if (!s) return null;
  const row = await prisma.user.findUnique({ where: { id: s.userId }, select: SESSION_SELECT });
  if (!row || row.tokenVersion !== s.tv) return null;
  return { userId: s.userId, exp: s.exp, tv: s.tv, emailVerified: row.emailVerified };
}

// True while version [tv] is still the user's current one (the version only,
// not the expiry). Throws on a DB error.
async function sessionIsCurrent(userId, tv) {
  const row = await prisma.user.findUnique({ where: { id: userId }, select: SESSION_SELECT });
  return !!row && row.tokenVersion === tv;
}

module.exports = { SESSION_SELECT, loadSession, sessionIsCurrent };
