const { rateLimit } = require('express-rate-limit');

const MIN = 60 * 1000;

// Default limits. login only counts failed attempts. sendCode counts every
// request that reaches it, including ones the client aborts; the route's
// "already verified" 400 and "Please wait" 429 are answered by a precheck
// before the limiter, so they don't use up the hourly cap. sendCode/verifyCode
// are keyed by user (they run after authMiddleware), the others by IP.
const DEFAULT_LIMITS = {
  login:      { windowMs: 15 * MIN, limit: 10, byUser: false, skipSuccessfulRequests: true,
                error: 'Too many login attempts. Try again in a few minutes.' },
  register:   { windowMs: 60 * MIN, limit: 20, byUser: false,
                error: 'Too many accounts created from this network. Try again later.' },
  sendCode:   { windowMs: 60 * MIN, limit: 5,  byUser: true,
                error: 'Too many code requests. Try again later.' },
  verifyCode: { windowMs: 15 * MIN, limit: 10, byUser: true,
                error: 'Too many attempts. Try again later.' },
};

const passThrough = (_req, _res, next) => next();

function buildLimiter(name, {
  windowMs, limit, byUser, skipSuccessfulRequests = false, skipFailedRequests = false, error,
}) {
  return rateLimit({
    windowMs,
    limit,
    skipSuccessfulRequests,
    skipFailedRequests,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    ...(byUser && { keyGenerator: (req) => `user:${req.userId}` }),
    // Always JSON { error } — the app's _parse() only reads the error field.
    handler: (req, res) => {
      console.log(`[rate-limit] ${name} blocked ip=${req.ip} user=${req.userId ?? '-'}`);
      res.status(429).json({ error });
    },
  });
}

/**
 * Returns { login, register, sendCode, verifyCode } middlewares.
 * overrides: false = no limits (tests), or e.g. { login: { limit: 3 } }
 * to change windowMs/limit per limiter.
 */
function makeLimiters(overrides = {}) {
  const limiters = {};
  for (const [name, defaults] of Object.entries(DEFAULT_LIMITS)) {
    limiters[name] = overrides === false
      ? passThrough
      : buildLimiter(name, { ...defaults, ...(overrides[name] ?? {}) });
  }
  return limiters;
}

module.exports = { DEFAULT_LIMITS, makeLimiters };
