const crypto = require('crypto');
const { rateLimit } = require('express-rate-limit');
const { ipKey } = require('./ipKey');
const { normalizeEmail } = require('./email');

const MIN = 60 * 1000;

// Default limits. login only counts failed attempts. sendCode counts every
// request that reaches it, including ones the client aborts; the route's
// "already verified" 400 and "Please wait" 429 are answered by a precheck
// before the limiter, so they don't use up the hourly cap. sendCode/verifyCode
// are keyed by user (they run after authMiddleware), loginSendCode/
// loginVerifyCode by the user of the sign-in challenge (they run after
// loginChallenge), security by user, storeReceipts by store
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
  // Two-step sign-in. A correct password for a 2FA user is a 200 challenge (not
  // counted by login), so code sends and checks are capped per user here:
  // at most 5 codes an hour x 5 tries = 25 guesses an hour.
  loginSendCode:   { windowMs: 60 * MIN, limit: 5,  byUser: true,
                     error: 'Too many sign-in codes. Try again later.' },
  loginVerifyCode: { windowMs: 15 * MIN, limit: 10, byUser: true,
                     error: 'Too many attempts. Try again later.' },
  // PATCH /api/user/security. Counts every request, so it also limits password
  // guessing on the turn-off branch.
  security:        { windowMs: 15 * MIN, limit: 10, byUser: true,
                     error: 'Too many attempts. Try again later.' },
  // PATCH /api/user/password and PATCH /api/user/me (email change). Only a
  // wrong current password (401) counts, so name edits, validation errors and
  // a normal password change never use it up. Stops a stolen session from
  // guessing the password to take the account over.
  passwordCheck:   { windowMs: 15 * MIN, limit: 5, byUser: true, skipSuccessfulRequests: true,
                     requestWasSuccessful: (_req, res) => res.statusCode !== 401,
                     error: 'Too many wrong passwords. Try again in 15 minutes.' },
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
  // Forgot password (no auth). The byEmail ones key on a hash of the typed
  // email in the same form findUserByEmail compares (trim + lowercase), so a
  // 429 means the same for real and unknown addresses. All count every
  // request. With the 5-try cap per code: at most 10 codes a day x 5 tries
  // = 50 guesses a day per email. They run before validation, so malformed
  // bodies share one 'email:none' bucket (no mail is sent for them).
  forgotPasswordIp:       { windowMs: 60 * MIN, limit: 10, byUser: false,
                            error: 'Too many reset requests. Try again later.' },
  forgotPasswordEmail:    { windowMs: 60 * MIN, limit: 5, byEmail: true,
                            error: 'Too many reset requests. Try again later.' },
  forgotPasswordEmailDay: { windowMs: 24 * 60 * MIN, limit: 10, byEmail: true,
                            error: 'Too many reset requests. Try again later.' },
  resetPasswordIp:        { windowMs: 15 * MIN, limit: 20, byUser: false,
                            error: 'Too many attempts. Try again later.' },
  resetPasswordEmail:     { windowMs: 15 * MIN, limit: 10, byEmail: true,
                            error: 'Too many attempts. Try again later.' },
  // POST /api/auth/google (no auth). Counts every request and runs before the
  // token check, so garbage tokens and key-id probing are capped too. A
  // request with a password (the link step) also passes the login limiter.
  oauth:         { windowMs: 15 * MIN, limit: 30, byUser: false,
                   error: 'Too many sign-in attempts. Try again in a few minutes.' },
  // GET /api/user/receipts (the Archive reloads on each period change and
  // realtime tick, so this leaves plenty of room).
  receiptsRead:  { windowMs: 10 * MIN, limit: 120, byUser: true,
                   error: 'Too many requests. Try again in a few minutes.' },
};

const passThrough = (_req, _res, next) => next();

// 'email:' + the first 32 hex characters of sha256(trimmed lowercase email).
// Never the plain address, so a key can't leak it.
function emailKey(req) {
  const e = normalizeEmail(req.body?.email);
  return e ? `email:${crypto.createHash('sha256').update(e).digest('hex').slice(0, 32)}` : 'email:none';
}

function buildLimiter(name, {
  windowMs, limit, byUser = false, byStore = false, byEmail = false,
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
    // By IP: IPv6 grouped by /64 (lib/ipKey.js), so one phone can't rotate
    // through its own addresses. IPv4 keys are the plain address.
    keyGenerator: byUser ? (req) => `user:${req.userId}`
      : byEmail ? emailKey
      : byStore ? (req) => `store:${req.store.id}`
      : (req) => `ip:${ipKey(req.ip)}`,
    // Always JSON { error } — the app's _parse() only reads the error field.
    // The log never holds the body or the key (no email, code or password).
    handler: (req, res) => {
      console.log(`[rate-limit] ${name} blocked ip=${req.ip} user=${req.userId ?? '-'}` +
        (req.store ? ` store=${req.store.id}` : ''));
      res.status(429).json({ error });
    },
  });
}

/**
 * Returns { login, register, sendCode, verifyCode, loginSendCode,
 * loginVerifyCode, security, passwordCheck, storeAuth, storeReceipts, aiInsight, aiChat,
 * aiReport, aiReportEmail, forgotPasswordIp, forgotPasswordEmail,
 * forgotPasswordEmailDay, resetPasswordIp, resetPasswordEmail, budgets,
 * oauth, receiptsRead } middlewares.
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

module.exports = { DEFAULT_LIMITS, makeLimiters, emailKey };
