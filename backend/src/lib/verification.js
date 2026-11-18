const crypto = require('crypto');
const prisma = require('./prisma');

const CODE_TTL_MS     = 10 * 60 * 1000; // code valid for 10 minutes
const RESEND_WAIT_MS  = 60 * 1000;      // at most one new code per minute
const MAX_ATTEMPTS    = 5;
const CODE_TTL_SECONDS = CODE_TTL_MS / 1000;

// Codes are short, so they're hashed with the user id as salt (never stored in plain text)
function hashCode(userId, code) {
  return crypto.createHash('sha256').update(`${userId}:${code}`).digest('hex');
}

// Seconds left before a new code may be sent for [row] (0 = can send now).
function waitSecondsFor(row) {
  if (!row) return 0;
  const elapsed = Date.now() - row.lastSentAt.getTime();
  return elapsed < RESEND_WAIT_MS ? Math.ceil((RESEND_WAIT_MS - elapsed) / 1000) : 0;
}

/**
 * Read-only: seconds the user must wait before a new code of [type] can be
 * sent (0 = can send now). Same check issueCode() does, without writing.
 */
async function resendWaitSeconds(userId, type) {
  const row = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  return waitSecondsFor(row);
}

/**
 * Create (or replace) the user's code of [type]. [email]: the address an
 * email code is sent to (it only verifies that address); null for sign-in codes.
 * Returns { code } or { waitSeconds } if a code was sent less than a minute ago.
 */
async function issueCode(userId, type, { ignoreWait = false, email } = {}) {
  const existing = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  if (!ignoreWait) {
    const waitSeconds = waitSecondsFor(existing);
    if (waitSeconds > 0) return { waitSeconds };
  }

  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  const data = {
    codeHash: hashCode(userId, code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
    attempts: 0,
    lastSentAt: new Date(),
    email: email ?? null,
  };
  await prisma.verificationCode.upsert({
    where: { userId_type: { userId, type } },
    create: { userId, type, ...data },
    update: data,
  });
  return { code };
}

const NO_CODE   = 'No active code. Tap "Resend code" to get a new one.';
const EXPIRED   = 'This code has expired. Tap "Resend code" for a new one.';
const TOO_MANY  = 'Too many wrong attempts. Tap "Resend code" for a new one.';

// Why the attempt could not be taken: the code expired, was replaced or used
// in between, or the 5 tries are really used up. Re-reads the row, so a
// resend or an expiry never shows as "Too many wrong attempts".
async function takenProblem(userId, type, row) {
  const now = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  if (!now || now.id !== row.id || now.codeHash !== row.codeHash) return NO_CODE;
  if (now.expiresAt <= new Date()) return EXPIRED;
  if (now.attempts >= MAX_ATTEMPTS) return TOO_MANY;
  return NO_CODE;
}

// The rules shared by checkCode, checkEmailCode and checkResetCode: { row } on
// success (the code is deleted), otherwise { problem } with the error message.
// Race-safe: the attempt is taken atomically before the hash is compared, so
// parallel guesses can't get more than 5 comparisons (phase 10, S3), and only
// the request whose delete removes the row wins (S4).
async function consumeCode(userId, type, code) {
  const row = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  if (!row) return { problem: NO_CODE };
  const now = new Date();
  if (row.expiresAt < now) return { problem: EXPIRED };
  if (row.attempts >= MAX_ATTEMPTS) return { problem: TOO_MANY };

  // codeHash in the filter: a code re-issued in between is not charged for the old one.
  const taken = await prisma.verificationCode.updateMany({
    where: { id: row.id, codeHash: row.codeHash, attempts: { lt: MAX_ATTEMPTS }, expiresAt: { gt: now } },
    data: { attempts: { increment: 1 } },
  });
  if (taken.count === 0) return { problem: await takenProblem(userId, type, row) };

  if (hashCode(userId, String(code).trim()) !== row.codeHash) {
    const left = MAX_ATTEMPTS - (row.attempts + 1);
    return {
      problem: left > 0 ? `Incorrect code. ${left} attempt${left === 1 ? '' : 's'} left.` : TOO_MANY,
    };
  }

  // Never delete() (a lost race would throw P2025 and give a 500).
  const gone = await prisma.verificationCode.deleteMany({ where: { id: row.id, codeHash: row.codeHash } });
  if (gone.count !== 1) return { problem: NO_CODE };
  return { row };
}

/**
 * Check [code]. Returns null on success (and deletes the code),
 * or an error message explaining why it failed.
 */
async function checkCode(userId, type, code) {
  const { problem } = await consumeCode(userId, type, code);
  return problem ?? null;
}

/**
 * Check an email verification code. { problem } when it fails, otherwise
 * { email }: the address it was sent to (null for a code from before codes
 * were bound to an address). The code is deleted on success.
 */
async function checkEmailCode(userId, code) {
  const { problem, row } = await consumeCode(userId, 'email', code);
  if (problem) return { problem };
  return { email: row.email ?? null };
}

/**
 * Check a password reset code (type 'reset'). True only when the code is
 * right, unexpired, under the try cap, was sent to [currentEmail] (the
 * account's address now), and this request removed it. Never says why.
 */
async function checkResetCode(userId, currentEmail, code) {
  const { row } = await consumeCode(userId, 'reset', code);
  return Boolean(row) && row.email === currentEmail;
}

/**
 * Issue a fresh email code for [user] and send it. Never throws — a failed
 * send is logged so it can't break registration or a profile update.
 * Returns the issueCode() result ({ code } or { waitSeconds }) or { error }.
 */
async function sendEmailCode(user, opts) {
  const { sendVerificationEmail } = require('./mailer');
  try {
    const result = await issueCode(user.id, 'email', { ...opts, email: user.email });
    if (result.code) await sendVerificationEmail(user.email, user.firstName, result.code);
    return result;
  } catch (err) {
    console.error('[verification/send]', err);
    return { error: 'Could not send the verification email. Please try again.' };
  }
}

module.exports = {
  issueCode, resendWaitSeconds, checkCode, checkEmailCode, checkResetCode, sendEmailCode, MAX_ATTEMPTS, CODE_TTL_SECONDS,
};
