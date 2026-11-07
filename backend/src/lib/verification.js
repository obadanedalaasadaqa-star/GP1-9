const crypto = require('crypto');
const prisma = require('./prisma');

const CODE_TTL_MS     = 10 * 60 * 1000; // code valid for 10 minutes
const RESEND_WAIT_MS  = 60 * 1000;      // at most one new code per minute
const MAX_ATTEMPTS    = 5;

// Codes are short, so they're hashed with the user id as salt (never stored in plain text)
function hashCode(userId, code) {
  return crypto.createHash('sha256').update(`${userId}:${code}`).digest('hex');
}

/**
 * Create (or replace) the user's code of [type].
 * Returns { code } or { waitSeconds } if a code was sent less than a minute ago.
 */
async function issueCode(userId, type, { ignoreWait = false } = {}) {
  const existing = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  if (existing && !ignoreWait) {
    const elapsed = Date.now() - existing.lastSentAt.getTime();
    if (elapsed < RESEND_WAIT_MS) {
      return { waitSeconds: Math.ceil((RESEND_WAIT_MS - elapsed) / 1000) };
    }
  }

  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  const data = {
    codeHash: hashCode(userId, code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
    attempts: 0,
    lastSentAt: new Date(),
  };
  await prisma.verificationCode.upsert({
    where: { userId_type: { userId, type } },
    create: { userId, type, ...data },
    update: data,
  });
  return { code };
}

/**
 * Check [code]. Returns null on success (and deletes the code),
 * or an error message explaining why it failed.
 */
async function checkCode(userId, type, code) {
  const row = await prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
  if (!row) return 'No active code. Tap "Resend code" to get a new one.';
  if (row.expiresAt < new Date()) return 'This code has expired. Tap "Resend code" for a new one.';
  if (row.attempts >= MAX_ATTEMPTS) return 'Too many wrong attempts. Tap "Resend code" for a new one.';

  if (hashCode(userId, String(code).trim()) !== row.codeHash) {
    await prisma.verificationCode.update({
      where: { id: row.id },
      data: { attempts: { increment: 1 } },
    });
    const left = MAX_ATTEMPTS - row.attempts - 1;
    return left > 0
      ? `Incorrect code. ${left} attempt${left === 1 ? '' : 's'} left.`
      : 'Too many wrong attempts. Tap "Resend code" for a new one.';
  }

  await prisma.verificationCode.delete({ where: { id: row.id } });
  return null;
}

/**
 * Issue a fresh email code for [user] and send it. Never throws — a failed
 * send is logged so it can't break registration or a profile update.
 * Returns the issueCode() result ({ code } or { waitSeconds }) or { error }.
 */
async function sendEmailCode(user, opts) {
  const { sendVerificationEmail } = require('./mailer');
  try {
    const result = await issueCode(user.id, 'email', opts);
    if (result.code) await sendVerificationEmail(user.email, user.firstName, result.code);
    return result;
  } catch (err) {
    console.error('[verification/send]', err);
    return { error: 'Could not send the verification email. Please try again.' };
  }
}

module.exports = { issueCode, checkCode, sendEmailCode };
