const express = require('express');
const bcrypt = require('bcryptjs');
const { randomUUID } = require('crypto');
const prisma = require('../lib/prisma');
const { passwordError } = require('../lib/password');
const {
  sendEmailCode, resendWaitSeconds, issueCode, checkResetCode, CODE_TTL_SECONDS,
} = require('../lib/verification');
const { normalizeEmail, emailError, findUserByEmail, emailTaken } = require('../lib/email');
const { cleanName, nameError } = require('../lib/names');
const { signSession, signChallenge, CHALLENGE_TTL_SECONDS } = require('../lib/token');
const {
  isLoginTwoFactorAllowed, loginChallenge, loadChallengeUser, sendLoginCode, checkLoginCode,
} = require('../lib/loginTwoFactor');
const { disconnectUser } = require('../lib/realtime');
const { sendPasswordResetEmail, sendPasswordChangedEmail } = require('../lib/mailer');
const {
  RESET_TYPE, DEFAULT_FLOOR_MS, FORGOT_SENT, RESET_FAILED,
  looseEmailError, codeError, isResetEligible, padTo, errTag,
} = require('../lib/passwordReset');

const SAFE_USER_SELECT = {
  id: true,
  email: true,
  name: true,
  firstName: true,
  lastName: true,
  emailVerified: true,
  serialNumber: true,
  loyaltyPoints: true,
  createdAt: true,
  budgetAlertEmails: true,
  weeklySummaryEmails: true,
  loginTwoFactor: true,
};

function generateSerial() {
  const part = randomUUID().replace(/-/g, '').toUpperCase().slice(0, 10);
  return `NXS-${part.slice(0, 5)}-${part.slice(5)}`;
}

// Only the SAFE_USER_SELECT fields (never the hash or internal columns).
const safeUserOf = (user) => Object.fromEntries(Object.keys(SAFE_USER_SELECT).map((k) => [k, user[k]]));

const waitError = (waitSeconds) => ({
  error: `Please wait ${waitSeconds}s before requesting a new code.`,
  waitSeconds,
});

// The one forgot-password answer: the same bytes whether or not the email
// has an account, a code was just sent, or the send failed.
const FORGOT_BODY = { message: FORGOT_SENT, expiresInSeconds: CODE_TTL_SECONDS };

// Router factory: every createApp() gets its own router and limiters.
// resetFloorMs: the minimum time of a forgot/reset answer (tests pass 0).
module.exports = function authRoutes(limiters, { resetFloorMs = DEFAULT_FLOOR_MS } = {}) {
  const router = express.Router();

  // POST /api/auth/register
  router.post('/register', limiters.register, async (req, res) => {
    const { password } = req.body ?? {};
    // Stored trimmed and lowercased. Non-strings count as missing.
    const email = normalizeEmail(req.body?.email);
    // Names end up in emails: control characters are stripped, length capped.
    const firstName = cleanName(req.body?.firstName);
    const lastName  = cleanName(req.body?.lastName);

    if (!email || !password || !firstName || !lastName) {
      return res.status(400).json({
        error: 'First name, last name, email, and password are required.',
      });
    }
    if (emailError(email)) return res.status(400).json({ error: emailError(email) });
    const nameProblem = nameError(firstName, lastName);
    if (nameProblem) return res.status(400).json({ error: nameProblem });
    const pwError = passwordError(password);
    if (pwError) return res.status(400).json({ error: pwError });

    try {
      // Any letter case: an older row may have been stored with capitals.
      if (await emailTaken(email)) return res.status(409).json({ error: 'Email already registered.' });

      const hashed = await bcrypt.hash(password, 12);
      const serialNumber = generateSerial();

      const user = await prisma.user.create({
        data: {
          email, password: hashed, serialNumber,
          firstName, lastName,
          name: `${firstName} ${lastName}`,
        },
        select: SAFE_USER_SELECT,
      });

      await sendEmailCode(user);
      res.status(201).json({ token: signSession(user.id, 0), user }); // a new row starts at version 0
    } catch (err) {
      // Two registers with the same email at the same time.
      if (err.code === 'P2002') return res.status(409).json({ error: 'Email already registered.' });
      console.error('[register]', err);
      res.status(500).json({ error: 'Registration failed. Please try again.' });
    }
  });

  // POST /api/auth/login
  router.post('/login', limiters.login, async (req, res) => {
    const { email, password } = req.body ?? {};

    // Non-strings would reach Prisma or bcrypt and give a 500.
    if (typeof email !== 'string' || typeof password !== 'string' || !email || !password) {
      return res.status(400).json({ error: 'Email and password are required.' });
    }

    // Dummy hash — ensures bcrypt always runs to prevent email enumeration via timing
    const DUMMY = '$2a$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    try {
      // Exact match first (as stored), then a unique case-insensitive one. No
      // format check here, so an older address like a@b still signs in.
      const user = await findUserByEmail(email);
      const valid = await bcrypt.compare(password, user?.password ?? DUMMY);
      if (!user || !valid) return res.status(401).json({ error: 'Invalid email or password.' });

      // Two-step sign-in is on: no session yet, only a 10-minute challenge.
      // No code is sent here; the app's code screen asks for one when it
      // opens, so every send goes through the precheck and limiter below.
      if (user.loginTwoFactor && isLoginTwoFactorAllowed()) {
        return res.json({
          twoFactorRequired: true,
          challengeToken: signChallenge(user),
          method: 'email',
          expiresInSeconds: CHALLENGE_TTL_SECONDS,
        });
      }

      res.json({ token: signSession(user.id, user.tokenVersion), user: safeUserOf(user) });
    } catch (err) {
      console.error('[login]', err);
      res.status(500).json({ error: 'Login failed. Please try again.' });
    }
  });

  // Runs before the loginSendCode limiter: answers the 60 s resend wait first,
  // so it doesn't use up the hourly cap (same as sendCodePrecheck in user.js).
  async function loginSendPrecheck(req, res, next) {
    try {
      const user = await loadChallengeUser(req, res);
      if (!user) return;
      const waitSeconds = await resendWaitSeconds(user.id, 'login');
      if (waitSeconds > 0) return res.status(429).json(waitError(waitSeconds));
      res.locals.user = user;
      next();
    } catch (err) {
      console.error('[login/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  }

  // POST /api/auth/login/send-code { challengeToken } — email a sign-in code
  router.post('/login/send-code', loginChallenge, loginSendPrecheck, limiters.loginSendCode, async (req, res) => {
    try {
      const { user } = res.locals;
      const result = await sendLoginCode(user);
      // Still possible if two requests pass the precheck at the same time.
      if (result.waitSeconds) return res.status(429).json(waitError(result.waitSeconds));
      if (result.error) return res.status(502).json({ error: result.error });
      res.json({ message: `Code sent to ${user.email}.` });
    } catch (err) {
      console.error('[login/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  });

  // POST /api/auth/login/verify { challengeToken, code } — the session token
  // after the right sign-in code. Does not change emailVerified.
  router.post('/login/verify', loginChallenge, limiters.loginVerifyCode, async (req, res) => {
    const code = req.body?.code;
    // A string or a number only: String(['123456']) would pass the pattern.
    if ((typeof code !== 'string' && typeof code !== 'number') || !/^\d{6}$/.test(String(code).trim())) {
      return res.status(400).json({ error: 'Enter the 6-digit code.' });
    }

    try {
      const user = await loadChallengeUser(req, res);
      if (!user) return;
      const problem = await checkLoginCode(user.id, code);
      if (problem) return res.status(400).json({ error: problem });
      res.json({ token: signSession(user.id, user.tokenVersion), user: safeUserOf(user) });
    } catch (err) {
      console.error('[login/verify]', err);
      res.status(500).json({ error: 'Login failed. Please try again.' });
    }
  });

  // POST /api/auth/forgot-password { email }
  // Emails a 6-digit reset code to the account's stored address. Always the
  // same 200 (never says whether the email has an account) and padded to
  // resetFloorMs; the email is sent without waiting for it.
  router.post('/forgot-password',
    limiters.forgotPasswordIp, limiters.forgotPasswordEmail, limiters.forgotPasswordEmailDay,
    async (req, res) => {
      const email = req.body?.email;
      const problem = looseEmailError(email);
      if (problem) return res.status(400).json({ error: problem });

      const started = Date.now();
      try {
        const user = await findUserByEmail(email);
        if (user && isResetEligible(user)) {
          // { waitSeconds } (a code went out less than a minute ago): do nothing.
          const r = await issueCode(user.id, RESET_TYPE, { email: user.email });
          if (r.code) {
            // The stored address, never the typed one.
            sendPasswordResetEmail(user.email, user.firstName, r.code)
              .catch((err) => console.error('[forgot-password] send failed', user.id, errTag(err)));
          }
        }
      } catch (err) {
        // A 500 only for known emails would tell them apart: same 200 instead.
        console.error('[forgot-password] failed', errTag(err));
      }
      await padTo(started, resetFloorMs);
      res.json(FORGOT_BODY);
    });

  // POST /api/auth/reset-password { email, code, newPassword }
  // Sets the new password with a reset code, ends every older session, and
  // signs in (or answers the 2FA challenge if the user turned it on).
  router.post('/reset-password', limiters.resetPasswordIp, limiters.resetPasswordEmail, async (req, res) => {
    const { email, code, newPassword } = req.body ?? {};
    // All checks before any DB read, so a bad body never uses up a code try.
    const emailProblem = looseEmailError(email);
    if (emailProblem) return res.status(400).json({ error: emailProblem });
    const codeProblem = codeError(code);
    if (codeProblem) return res.status(400).json({ error: codeProblem });
    const pwError = passwordError(newPassword);
    if (pwError) return res.status(400).json({ error: pwError });

    const started = Date.now();
    let user;
    try {
      user = await findUserByEmail(email);
      // One answer for every failure, with no "attempts left".
      if (!user || !(await checkResetCode(user.id, user.email, code))) {
        await padTo(started, resetFloorMs);
        return res.status(400).json({ error: RESET_FAILED });
      }

      const hash = await bcrypt.hash(newPassword, 12);
      const [updated] = await prisma.$transaction([
        prisma.user.update({
          where: { id: user.id },
          // Typing a code sent to this address proves the inbox (Q2).
          // loginTwoFactor is not touched: 2FA stays on.
          data: { password: hash, tokenVersion: { increment: 1 }, emailVerified: true },
          select: { ...SAFE_USER_SELECT, tokenVersion: true, password: true },
        }),
        // Pending sign-in codes go too; old challenges die with the old hash.
        prisma.verificationCode.deleteMany({ where: { userId: user.id, type: 'login' } }),
      ]);
      disconnectUser(user.id);

      // Q6: tell the inbox owner (no code, no link). Fire and forget.
      sendPasswordChangedEmail(updated.email, updated.firstName)
        .catch((err) => console.error('[reset-password] notice failed', user.id, errTag(err)));

      // Q1 (b): a 2FA user still needs the sign-in code. The challenge is
      // signed with the new hash.
      if (updated.loginTwoFactor && isLoginTwoFactorAllowed()) {
        return res.json({
          twoFactorRequired: true,
          challengeToken: signChallenge(updated),
          method: 'email',
          expiresInSeconds: CHALLENGE_TTL_SECONDS,
        });
      }
      res.json({ token: signSession(updated.id, updated.tokenVersion), user: safeUserOf(updated) });
    } catch (err) {
      console.error('[reset-password]', user?.id ?? '-', errTag(err));
      res.status(500).json({ error: 'Reset failed. Please try again.' });
    }
  });

  return router;
};
