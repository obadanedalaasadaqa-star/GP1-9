const { hasUserId } = require('../lib/token');
const { loadSession } = require('../lib/session');

module.exports = async function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized — no token' });
  }

  // loadSession only accepts HS256 session tokens with a non-empty userId
  // (never a sign-in challenge) whose version still matches the user's row.
  let s;
  try {
    s = await loadSession(authHeader.slice(7));
  } catch (err) {
    // DB down: never 401, because the app logs out on 401.
    console.error('[auth]', err.message);
    return res.status(503).json({ error: 'Could not check your session. Try again.' });
  }
  if (!s) return res.status(401).json({ error: 'Unauthorized — invalid token' });
  req.userId = s.userId;
  req.emailVerified = s.emailVerified;
  next();
};

module.exports.hasUserId = hasUserId;
