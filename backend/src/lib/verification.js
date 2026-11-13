const crypto = require('crypto');
const prisma = require('./prisma');
const { normalizeJordanPhone } = require('./phone');

const CODE_TTL_MS     = 10 * 60 * 1000; // code valid for 10 minutes
const RESEND_WAIT_MS  = 60 * 1000;      // at most one new code per minute
const MAX_ATTEMPTS    = 5;
const TWILIO_PREFIX   = 'twilio:';      // codeHash of a code Twilio Verify checks

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

/** The user's code row of [type], or null. */
function findCode(userId, type) {
  return prisma.verificationCode.findUnique({
    where: { userId_type: { userId, type } },
  });
}

// SMS codes in Twilio mode: Twilio holds the code, the row holds its SID.
const isTwilioRow = (row) => Boolean(row?.codeHash?.startsWith(TWILIO_PREFIX));
const twilioSid = (row) => row.codeHash.slice(TWILIO_PREFIX.length);

/**
 * 'sms' for a Twilio row or one sent to a normalized Jordan number, otherwise
 * 'email' (so an address like "+tag@example.com" is still email).
 */
function channelOf(row) {
  if (isTwilioRow(row)) return 'sms';
  return row?.sentTo != null && normalizeJordanPhone(row.sentTo) === row.sentTo ? 'sms' : 'email';
}

/**
 * Read-only: seconds the user must wait before a new code of [type] can be
 * sent (0 = can send now). Same check issueCode() does, without writing.
 */
async function resendWaitSeconds(userId, type) {
  return waitSecondsFor(await findCode(userId, type));
}

/**
 * Create (or replace) the user's code of [type]. [sentTo]: where it goes
 * (null for email verification).
 * Returns { code } or { waitSeconds } if a code was sent less than a minute ago.
 */
async function issueCode(userId, type, { ignoreWait = false, sentTo = null } = {}) {
  if (!ignoreWait) {
    const waitSeconds = waitSecondsFor(await findCode(userId, type));
    if (waitSeconds > 0) return { waitSeconds };
  }

  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  await saveRow(userId, type, hashCode(userId, code), sentTo);
  return { code };
}

/** Save a code that Twilio Verify holds ([sid] = its Verification SID). */
function saveExternalCode(userId, type, sentTo, sid) {
  return saveRow(userId, type, `${TWILIO_PREFIX}${sid}`, sentTo);
}

function saveRow(userId, type, codeHash, sentTo) {
  const data = {
    codeHash,
    sentTo,
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
    attempts: 0,
    lastSentAt: new Date(),
  };
  return prisma.verificationCode.upsert({
    where: { userId_type: { userId, type } },
    create: { userId, type, ...data },
    update: data,
  });
}

/**
 * Why [row] can't be checked right now, or null if it can.
 * Same messages for email and SMS codes.
 */
function activeCodeProblem(row) {
  if (!row) return 'No active code. Tap "Resend code" to get a new one.';
  if (row.expiresAt < new Date()) return 'This code has expired. Tap "Resend code" for a new one.';
  if (row.attempts >= MAX_ATTEMPTS) return 'Too many wrong attempts. Tap "Resend code" for a new one.';
  return null;
}

/** Count a wrong code on [row]. Returns the message for the user. */
async function recordWrongAttempt(row) {
  await prisma.verificationCode.update({
    where: { id: row.id },
    data: { attempts: { increment: 1 } },
  });
  const left = MAX_ATTEMPTS - row.attempts - 1;
  return left > 0
    ? `Incorrect code. ${left} attempt${left === 1 ? '' : 's'} left.`
    : 'Too many wrong attempts. Tap "Resend code" for a new one.';
}

/**
 * End the user's code of [type] without deleting it (an SMS row keeps its
 * Twilio SID, so the next send can cancel it). [clearWait]: allow a new code
 * at once. No-op when there is no row.
 */
function expireCode(userId, type, { clearWait = false } = {}) {
  return prisma.verificationCode.updateMany({
    where: { userId, type },
    data: { expiresAt: new Date(Date.now() - 1000), ...(clearWait && { lastSentAt: new Date(0) }) },
  });
}

/** Delete the user's code of [type] (after approval). Never throws if it's gone. */
function deleteCode(userId, type) {
  return prisma.verificationCode.deleteMany({ where: { userId, type } });
}

/**
 * Check [code] against the hashed code of [type]. Returns null on success
 * (and deletes the code), or an error message explaining why it failed.
 */
async function checkCode(userId, type, code) {
  const row = await findCode(userId, type);
  const problem = activeCodeProblem(row);
  if (problem) return problem;

  if (hashCode(userId, String(code).trim()) !== row.codeHash) return recordWrongAttempt(row);

  await deleteCode(userId, type);
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

module.exports = {
  CODE_TTL_MS, RESEND_WAIT_MS, MAX_ATTEMPTS,
  issueCode, saveExternalCode, resendWaitSeconds, waitSecondsFor, findCode,
  isTwilioRow, twilioSid, channelOf, activeCodeProblem, recordWrongAttempt,
  expireCode, deleteCode, checkCode, sendEmailCode,
};
