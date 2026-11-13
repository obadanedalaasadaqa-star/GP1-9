const { rateLimit } = require('express-rate-limit');

const MIN = 60 * 1000;

// Default limits. login only counts failed attempts. sendCode counts every
// request that reaches it, including ones the client aborts; the route's
// "already verified" 400 and "Please wait" 429 are answered by a precheck
// before the limiter, so they don't use up the hourly cap. sendCode/verifyCode
// are keyed by user (they run after authMiddleware), storeReceipts by store
// (it runs after storeAuth), the others by IP. storeAuth only counts 401s
// (wrong/missing store key), so a cashier who mistypes serials isn't blocked.
const DEFAULT_LIMITS = {
  login:      { windowMs: 15 * MIN, limit: 10, byUser: false, skipSuccessfulRequests: true,
                error: 'Too many login attempts. Try again in a few minutes.' },
  register:   { windowMs: 60 * MIN, limit: 20, byUser: false,
                error: 'Too many accounts created from this network. Try again later.' },
  sendCode:   { windowMs: 60 * MIN, limit: 5,  byUser: true,
                error: 'Too many code requests. Try again later.' },
  verifyCode: { windowMs: 15 * MIN, limit: 10, byUser: true,
                error: 'Too many attempts. Try again later.' },
  storeAuth:  { windowMs: 15 * MIN, limit: 20, byUser: false, skipSuccessfulRequests: true,
                requestWasSuccessful: (_req, res) => res.statusCode !== 401,
                error: 'Too many wrong store keys. Try again in a few minutes.' },
  storeReceipts: { windowMs: 1 * MIN, limit: 60, byStore: true,
                error: 'Too many receipts from this store. Try again in a minute.' },
  // aiInsight and aiChat only see requests that would call Claude (cache hits,
  // 'not enough data', 'no receipts' and validation errors are answered first).
  // aiReport counts every report request. Daily caps live in nexus_ai_usage and
  // are taken after these limiters.
  aiInsight:     { windowMs: 60 * MIN, limit: 20, byUser: true,
                   error: 'Too many new insights. Try again later.' },
  aiChat:        { windowMs: 10 * MIN, limit: 10, byUser: true,
                   error: 'Too many questions. Wait a few minutes and try again.' },
  aiReport:      { windowMs: 10 * MIN, limit: 30, byUser: true,
                   error: 'Too many reports. Try again in a few minutes.' },
  aiReportEmail: { windowMs: 60 * MIN, limit: 3,  byUser: true,
                   error: 'Too many report emails. Try again later.' },
  // Budget changes (PUT/DELETE /api/budgets) and PATCH /api/user/notifications.
  // Never on GET.
  budgets:       { windowMs: 10 * MIN, limit: 60, byUser: true,
                   error: 'Too many budget changes. Try again in a few minutes.' },
};

const passThrough = (_req, _res, next) => next();

function buildLimiter(name, {
  windowMs, limit, byUser = false, byStore = false,
  skipSuccessfulRequests = false, skipFailedRequests = false, requestWasSuccessful, error,
}) {
  return rateLimit({
    windowMs,
    limit,
    skipSuccessfulRequests,
    skipFailedRequests,
    ...(requestWasSuccessful && { requestWasSuccessful }),
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    ...(byUser && { keyGenerator: (req) => `user:${req.userId}` }),
    ...(byStore && { keyGenerator: (req) => `store:${req.store.id}` }),
    // Always JSON { error } — the app's _parse() only reads the error field.
    handler: (req, res) => {
      console.log(`[rate-limit] ${name} blocked ip=${req.ip} user=${req.userId ?? '-'}` +
        (req.store ? ` store=${req.store.id}` : ''));
      res.status(429).json({ error });
    },
  });
}

/**
 * Returns { login, register, sendCode, verifyCode, storeAuth, storeReceipts,
 * aiInsight, aiChat, aiReport, aiReportEmail, budgets } middlewares.
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
