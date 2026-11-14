const prisma = require('./prisma');
const { issueCode, checkCode } = require('./verification');
const { verifyChallenge, passwordTag } = require('./token');

// Two-step sign-in (opt-in per user, email codes only). Sign-in codes are rows
// in nexus_verification_codes with type 'login', so they never touch a pending
// email-verification code or its 60 s wait.

const EXPIRED = 'Your sign-in expired. Please log in again.';

// Global kill switch, read on every call: LOGIN_2FA=off makes /login ignore
// every user's loginTwoFactor setting (e.g. during a mail outage).
function isLoginTwoFactorAllowed() {
  return process.env.LOGIN_2FA !== 'off';
}

// Route middleware for /login/send-code and /login/verify. Sets req.userId
// (so the byUser limiters key on it) and req.challengePwd.
function loginChallenge(req, res, next) {
  const c = verifyChallenge(req.body?.challengeToken);
  if (!c) return res.status(401).json({ error: EXPIRED });
  req.userId = c.userId;
  req.challengePwd = c.pwd;
  next();
}

// Loads the full user of the challenge. Returns the user, or null after it has
// already answered (404 user gone, 401 password changed since the challenge).
async function loadChallengeUser(req, res) {
  const user = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!user) {
    res.status(404).json({ error: 'User not found.' });
    return null;
  }
  if (passwordTag(user.password) !== req.challengePwd) {
    res.status(401).json({ error: EXPIRED });
    return null;
  }
  return user;
}

/**
 * Issue a fresh sign-in code for [user] and email it. Never throws.
 * Returns the issueCode() result ({ code } or { waitSeconds }) or { error }.
 */
async function sendLoginCode(user, { ignoreWait } = {}) {
  const { sendLoginCodeEmail } = require('./mailer');
  try {
    const result = await issueCode(user.id, 'login', { ignoreWait });
    if (result.code) await sendLoginCodeEmail(user.email, user.firstName, result.code);
    return result;
  } catch (err) {
    console.error('[login/send-code]', err);
    return { error: 'Could not send the sign-in email. Please try again.' };
  }
}

// null on success (the code is deleted), otherwise the checkCode() error text.
function checkLoginCode(userId, code) {
  return checkCode(userId, 'login', code);
}

module.exports = {
  isLoginTwoFactorAllowed, loginChallenge, loadChallengeUser, sendLoginCode, checkLoginCode,
  EXPIRED_CHALLENGE_ERROR: EXPIRED,
};
