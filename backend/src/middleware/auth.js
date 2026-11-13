const jwt = require('jsonwebtoken');

const hasUserId = (decoded) => typeof decoded?.userId === 'string' && decoded.userId.length > 0;

module.exports = function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized — no token' });
  }

  const token = authHeader.slice(7);
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    // Only session tokens carry a userId. Without this check req.userId would
    // be undefined, and Prisma drops an undefined filter (all users' rows).
    if (!hasUserId(decoded)) throw new Error('no userId');
    req.userId = decoded.userId;
    next();
  } catch {
    res.status(401).json({ error: 'Unauthorized — invalid token' });
  }
};

module.exports.hasUserId = hasUserId;
