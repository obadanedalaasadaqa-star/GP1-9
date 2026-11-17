const express = require('express');
const bcrypt = require('bcryptjs');
const { randomUUID } = require('crypto');
const prisma = require('../lib/prisma');
const { passwordError } = require('../lib/password');
const { sendEmailCode, resendWaitSeconds } = require('../lib/verification');
const { normalizeEmail, emailError, findUserByEmail, emailTaken } = require('../lib/email');
const { cleanName, nameError } = require('../lib/names');
const { signSession, signChallenge, CHALLENGE_TTL_SECONDS } = require('../lib/token');
const {
  isLoginTwoFactorAllowed, loginChallenge, loadChallengeUser, sendLoginCode, checkLoginCode,
} = require('../lib/loginTwoFactor');

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

// Router factory: every createApp() gets its own router and limiters.
module.exports = function authRoutes(limiters) {
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

  return router;
};
