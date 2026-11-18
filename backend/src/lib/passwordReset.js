// Forgot password (routes/auth.js /forgot-password and /reset-password).
// Codes are rows in nexus_verification_codes with type 'reset', bound to the
// address they were sent to. Every answer is the same whether or not the
// email has an account, and is padded to a time floor.

const RESET_TYPE = 'reset';
const DEFAULT_FLOOR_MS = 700;
const MAX_EMAIL = 254;

const FORGOT_SENT   = 'If an account uses that email, we sent it a code.';
const RESET_FAILED  = 'That code is wrong or has expired. Check it, or send a new one.';
const EMAIL_INVALID = 'Enter your email.';
const CODE_INVALID  = 'Enter the 6-digit code.';

// Loose rule, same as /login: a trimmed string of 1-254 characters with an @,
// so older addresses such as a@b can still reset. Message or null.
function looseEmailError(raw) {
  if (typeof raw !== 'string') return EMAIL_INVALID;
  const trimmed = raw.trim();
  if (!trimmed || trimmed.length > MAX_EMAIL || !trimmed.includes('@')) return EMAIL_INVALID;
  return null;
}

// A string or a number of exactly 6 digits (arrays rejected: String(['123456'])
// would pass the pattern).
function codeError(code) {
  if ((typeof code !== 'string' && typeof code !== 'number') || !/^\d{6}$/.test(String(code).trim())) {
    return CODE_INVALID;
  }
  return null;
}

// Who may reset (Q2: everyone with an account, verified or not; a reset
// proves the inbox and marks it verified).
function isResetEligible(_user) {
  return true;
}

// Resolves once [floorMs] have passed since [startedMs] (at once if already later).
function padTo(startedMs, floorMs) {
  const rest = floorMs - (Date.now() - startedMs);
  return rest > 0 ? new Promise((resolve) => setTimeout(resolve, rest)) : Promise.resolve();
}

// The safe part of an error for a log line: never err.message, which can
// repeat the recipient address (Brevo / Gmail).
const errTag = (err) => err?.code ?? err?.status ?? err?.name ?? 'Error';

module.exports = {
  RESET_TYPE, DEFAULT_FLOOR_MS, FORGOT_SENT, RESET_FAILED, EMAIL_INVALID, CODE_INVALID,
  looseEmailError, codeError, isResetEligible, padTo, errTag,
};
