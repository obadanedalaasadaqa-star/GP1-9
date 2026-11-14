const { hasUserId, verifySession } = require('../lib/token');

module.exports = function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized — no token' });
  }

  // verifySession only accepts HS256 session tokens with a non-empty userId
  // (never a sign-in challenge), and never throws.
  const s = verifySession(authHeader.slice(7));
  if (!s) return res.status(401).json({ error: 'Unauthorized — invalid token' });
  req.userId = s.userId;
  next();
};

module.exports.hasUserId = hasUserId;
