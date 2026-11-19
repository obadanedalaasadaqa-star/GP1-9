const express = require('express');
const bcrypt = require('bcryptjs');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const { passwordError } = require('../lib/password');
const { checkEmailCode, sendEmailCode, resendWaitSeconds } = require('../lib/verification');
const { normalizeEmail, emailError, emailTaken } = require('../lib/email');
const { cleanName, nameError } = require('../lib/names');
const { signSession } = require('../lib/token');
const { disconnectUser } = require('../lib/realtime');
const { parseBounds, shapeStats } = require('../lib/stats');
const { queryStats } = require('../lib/spendingQueries');
const { parseTz } = require('../lib/aiDates');
const { latestWeek } = require('../lib/weeklySummary');

const SAFE_SELECT = {
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
  passwordSet: true,
};

const NOTIFICATION_KEYS = ['budgetAlertEmails', 'weeklySummaryEmails', 'tzOffsetMinutes'];

// The receipt fields the app reads (Receipt.fromJson); never userId or storeId.
const RECEIPT_SELECT = {
  id: true, storeName: true, category: true, totalAmount: true,
  items: true, lineItems: true, pointsEarned: true, createdAt: true,
};

const waitError = (waitSeconds) => ({
  error: `Please wait ${waitSeconds}s before requesting a new code.`,
  waitSeconds,
});

// A password change, 2FA on, an email change and "sign out everywhere" end
// every older session: the row's tokenVersion goes up in the same write, the
// user's open sockets are dropped before the answer, and the calling device
// gets a fresh token (except for sign out everywhere).
const endOtherSessions = (userId) => disconnectUser(userId);

// Router factory: every createApp() gets its own router and limiters.
module.exports = function userRoutes(limiters) {
  const router = express.Router();
  router.use(authMiddleware);

  // GET /api/user/me
  router.get('/me', async (req, res) => {
    try {
      const user = await prisma.user.findUnique({
        where: { id: req.userId },
        select: SAFE_SELECT,
      });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      res.json(user);
    } catch (err) {
      console.error('[user/me]', err);
      res.status(500).json({ error: 'Failed to load profile.' });
    }
  });

  // PATCH /api/user/me  — update first name, last name, and email
  // Changing the email requires the current password. Other body fields
  // (e.g. a "phone" from an old app build) are ignored.
  // The password limiter only runs when a password is sent (an email change), so
  // a name-only edit is never blocked. Without currentPassword no password is
  // checked, so skipping the limiter there can't be used to guess one.
  const passwordCheckIfSent = (req, res, next) =>
    (req.body?.currentPassword ? limiters.passwordCheck(req, res, next) : next());

  // Names first (no DB), then whether the email really changes. An email change
  // must pass the password, "already registered" and the 60 s resend wait
  // before it may use one of the hourly sendCode slots.
  async function emailChangePrecheck(req, res, next) {
    // Names end up in emails: control characters are stripped, length capped.
    const firstName = cleanName(req.body?.firstName);
    const lastName  = cleanName(req.body?.lastName);
    const nameProblem = nameError(firstName, lastName);
    if (nameProblem) return res.status(400).json({ error: nameProblem });
    res.locals.names = { firstName, lastName };

    const email = normalizeEmail(req.body?.email);
    if (!email) return next(); // no email sent: a name-only edit

    try {
      const current = await prisma.user.findUnique({ where: { id: req.userId } });
      if (!current) return res.status(404).json({ error: 'User not found.' });
      // The app always sends the email, even unchanged. Another case or
      // surrounding spaces is not a change, and an older stored address is
      // never format-checked, so it can't block a name edit.
      if (email === normalizeEmail(current.email)) return next();
      // An account made by Google has no password to confirm the change with.
      if (current.passwordSet === false) {
        return res.status(409).json({ error: 'Set a password before changing your email.', code: 'no_password' });
      }

      const emailProblem = emailError(email);
      if (emailProblem) return res.status(400).json({ error: emailProblem });
      const { currentPassword } = req.body ?? {};
      if (typeof currentPassword !== 'string' || !currentPassword) {
        return res.status(400).json({ error: 'Current password is required to change your email.' });
      }
      if (!(await bcrypt.compare(currentPassword, current.password))) {
        return res.status(401).json({ error: 'Current password is incorrect.' });
      }
      if (await emailTaken(email, req.userId)) {
        return res.status(409).json({ error: 'Email already registered.' });
      }
      // Same wait as /email/send-code: at most one code a minute.
      const waitSeconds = await resendWaitSeconds(req.userId, 'email');
      if (waitSeconds > 0) return res.status(429).json(waitError(waitSeconds));

      res.locals.emailChange = { email };
      next();
    } catch (err) {
      console.error('[user/patch]', err);
      res.status(500).json({ error: 'Failed to update profile.' });
    }
  }

  // The same limiter instance as /email/send-code, so both share the user's
  // 5 codes an hour. A name-only edit never touches it.
  const sendCodeIfEmailChange = (req, res, next) =>
    (res.locals.emailChange ? limiters.sendCode(req, res, next) : next());

  router.patch('/me', passwordCheckIfSent, emailChangePrecheck, sendCodeIfEmailChange, async (req, res) => {
    const { firstName, lastName } = res.locals.names;
    const data = { firstName, lastName, name: `${firstName} ${lastName}` };
    const change = res.locals.emailChange;

    try {
      if (!change) {
        const user = await prisma.user.update({
          where: { id: req.userId },
          data,
          select: SAFE_SELECT,
        });
        return res.json(user);
      }

      // One transaction: the new address (unverified again; two-step sign-in
      // needs a verified email, so it goes off too and a typo can't lock the
      // user out), a new session version, and no code for the old address.
      const [updated] = await prisma.$transaction([
        prisma.user.update({
          where: { id: req.userId },
          data: {
            ...data,
            email: change.email,
            emailVerified: false,
            loginTwoFactor: false,
            tokenVersion: { increment: 1 },
          },
          select: { ...SAFE_SELECT, tokenVersion: true },
        }),
        prisma.verificationCode.deleteMany({ where: { userId: req.userId, type: 'email' } }),
      ]);
      const { tokenVersion, ...user } = updated;
      endOtherSessions(req.userId);
      await sendEmailCode(user); // the old row is gone, so there is no wait
      res.json({ ...user, token: signSession(user.id, tokenVersion) });
    } catch (err) {
      if (err.code === 'P2002') {
        return res.status(409).json({ error: 'Email already registered.' });
      }
      console.error('[user/patch]', err);
      res.status(500).json({ error: 'Failed to update profile.' });
    }
  });

  // Runs before the sendCode limiter: answers the cheap rejections (already
  // verified, 60 s resend wait) so they don't count toward the hourly cap.
  async function sendCodePrecheck(req, res, next) {
    try {
      const user = await prisma.user.findUnique({ where: { id: req.userId }, select: SAFE_SELECT });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      if (user.emailVerified) return res.status(400).json({ error: 'Email is already verified.' });

      const waitSeconds = await resendWaitSeconds(req.userId, 'email');
      if (waitSeconds > 0) return res.status(429).json(waitError(waitSeconds));
      res.locals.user = user; // reused by the route, saves a query
      next();
    } catch (err) {
      console.error('[user/email/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  }

  // POST /api/user/email/send-code — (re)send the email verification code
  router.post('/email/send-code', sendCodePrecheck, limiters.sendCode, async (req, res) => {
    try {
      const { user } = res.locals;
      const result = await sendEmailCode(user);
      // Still possible if two requests pass the precheck at the same time.
      if (result.waitSeconds) {
        return res.status(429).json({
          error: `Please wait ${result.waitSeconds}s before requesting a new code.`,
          waitSeconds: result.waitSeconds,
        });
      }
      if (result.error) return res.status(502).json({ error: result.error });
      res.json({ message: `Code sent to ${user.email}.` });
    } catch (err) {
      console.error('[user/email/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  });

  // POST /api/user/email/verify — confirm the email with the 6-digit code
  router.post('/email/verify', limiters.verifyCode, async (req, res) => {
    const code = req.body?.code;
    if ((typeof code !== 'string' && typeof code !== 'number') || !/^\d{6}$/.test(String(code).trim())) {
      return res.status(400).json({ error: 'Enter the 6-digit code.' });
    }

    try {
      const result = await checkEmailCode(req.userId, code);
      if (result.problem) return res.status(400).json({ error: result.problem });
      // A code from before codes were bound to an address.
      if (result.email === null) {
        return res.status(400).json({ error: 'This code is no longer valid. Tap "Resend code" for a new one.' });
      }
      // Only verifies the address the code was sent to.
      const { count } = await prisma.user.updateMany({
        where: { id: req.userId, email: result.email },
        data: { emailVerified: true },
      });
      if (count === 0) {
        return res.status(400).json({ error: 'This code was sent to a different address. Tap "Resend code" for a new one.' });
      }
      const user = await prisma.user.findUnique({ where: { id: req.userId }, select: SAFE_SELECT });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      res.json(user);
    } catch (err) {
      console.error('[user/email/verify]', err);
      res.status(500).json({ error: 'Failed to verify email.' });
    }
  });

  // PATCH /api/user/password — change password (requires the current one)
  router.patch('/password', limiters.passwordCheck, async (req, res) => {
    const { currentPassword, newPassword } = req.body ?? {};
    if (!currentPassword || !newPassword) {
      return res.status(400).json({ error: 'Current and new password are required.' });
    }
    const pwError = passwordError(newPassword);
    if (pwError) return res.status(400).json({ error: pwError });
    if (newPassword === currentPassword) {
      return res.status(400).json({ error: 'New password must be different from the current one.' });
    }

    try {
      const user = await prisma.user.findUnique({ where: { id: req.userId } });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      // Google-only account: there is no current password to check. It sets
      // one with Forgot password ("Set a password" in Profile).
      if (user.passwordSet === false) {
        return res.status(409).json({ error: 'You sign in with Google. Use Set a password in Profile first.', code: 'no_password' });
      }
      if (!(await bcrypt.compare(currentPassword, user.password))) {
        return res.status(401).json({ error: 'Current password is incorrect.' });
      }

      const hash = await bcrypt.hash(newPassword, 12);
      const [{ tokenVersion }] = await prisma.$transaction([
        prisma.user.update({
          where: { id: req.userId },
          data: { password: hash, tokenVersion: { increment: 1 } },
          select: { tokenVersion: true },
        }),
        // A pending forgot-password code must not outlive the change.
        prisma.verificationCode.deleteMany({ where: { userId: req.userId, type: 'reset' } }),
      ]);
      endOtherSessions(req.userId);
      res.json({ message: 'Password updated.', token: signSession(req.userId, tokenVersion) });
    } catch (err) {
      console.error('[user/password]', err);
      res.status(500).json({ error: 'Failed to update password.' });
    }
  });

  // PATCH /api/user/security { loginTwoFactor, currentPassword? }
  // Two-step sign-in (opt-in). Turning it on needs a verified email; turning it
  // off needs the current password. The security limiter counts every request,
  // so it also caps password guesses on the turn-off branch.
  router.patch('/security', limiters.security, async (req, res) => {
    const { loginTwoFactor, currentPassword } = req.body ?? {};
    if (typeof loginTwoFactor !== 'boolean') {
      return res.status(400).json({ error: 'loginTwoFactor must be true or false.' });
    }

    try {
      const user = await prisma.user.findUnique({ where: { id: req.userId } });
      if (!user) return res.status(404).json({ error: 'User not found.' });

      if (user.loginTwoFactor !== loginTwoFactor) {
        // A Google-only account could never turn it off again (that needs
        // the password), so it can't turn it on until it sets one.
        if (loginTwoFactor && user.passwordSet === false) {
          return res.status(403).json({ error: 'Set a password before turning on two-step sign-in.', code: 'no_password' });
        }
        if (loginTwoFactor && !user.emailVerified) {
          return res.status(403).json({ error: 'Verify your email before turning on two-step sign-in.' });
        }
        if (!loginTwoFactor) {
          if (typeof currentPassword !== 'string' || !currentPassword) {
            return res.status(400).json({ error: 'Current password is required to turn off two-step sign-in.' });
          }
          if (!(await bcrypt.compare(currentPassword, user.password))) {
            return res.status(401).json({ error: 'Current password is incorrect.' });
          }
        }
      }

      // Already at that value: nothing is written (only the SAFE_SELECT fields).
      if (user.loginTwoFactor === loginTwoFactor) {
        return res.json(Object.fromEntries(Object.keys(SAFE_SELECT).map((k) => [k, user[k]])));
      }
      if (loginTwoFactor) {
        // Turn on only if the email is still verified at write time: an email
        // change in between (PATCH /me) must not leave it on for an unverified
        // address.
        // Turning it on also ends every other session.
        const { count } = await prisma.user.updateMany({
          where: { id: req.userId, emailVerified: true },
          data: { loginTwoFactor: true, tokenVersion: { increment: 1 } },
        });
        if (count === 0) {
          return res.status(403).json({ error: 'Verify your email before turning on two-step sign-in.' });
        }
        const turnedOn = await prisma.user.findUnique({
          where: { id: req.userId },
          select: { ...SAFE_SELECT, tokenVersion: true },
        });
        if (!turnedOn) return res.status(404).json({ error: 'User not found.' });
        const { tokenVersion, ...user } = turnedOn;
        endOtherSessions(req.userId);
        return res.json({ ...user, token: signSession(req.userId, tokenVersion) });
      }
      const updated = await prisma.user.update({
        where: { id: req.userId },
        data: { loginTwoFactor },
        select: SAFE_SELECT,
      });
      res.json(updated);
    } catch (err) {
      if (err.code === 'P2025') return res.status(404).json({ error: 'User not found.' });
      console.error('[user/security]', err);
      res.status(500).json({ error: 'Failed to save settings.' });
    }
  });

  // POST /api/user/logout-all — end every session of this user, this one too
  // (no new token: the app logs out). No body needed; any body is ignored.
  // Shares the security limiter with PATCH /security.
  router.post('/logout-all', limiters.security, async (req, res) => {
    try {
      await prisma.user.update({
        where: { id: req.userId },
        data: { tokenVersion: { increment: 1 } },
        select: { id: true },
      });
      endOtherSessions(req.userId);
      res.json({ message: 'Signed out on all devices.' });
    } catch (err) {
      if (err.code === 'P2025') return res.status(404).json({ error: 'User not found.' });
      console.error('[user/logout-all]', err);
      res.status(500).json({ error: 'Failed to sign out.' });
    }
  });

  // PATCH /api/user/notifications { budgetAlertEmails?, weeklySummaryEmails?, tzOffsetMinutes? }
  // Email settings. Does not need a verified email: the server checks that
  // again before sending anything. Unknown keys are ignored.
  router.patch('/notifications', limiters.budgets, async (req, res) => {
    const body = req.body ?? {};
    if (typeof body !== 'object' || !NOTIFICATION_KEYS.some((k) => body[k] !== undefined)) {
      return res.status(400).json({ error: 'Nothing to update.' });
    }
    const data = {};
    for (const key of ['budgetAlertEmails', 'weeklySummaryEmails']) {
      if (body[key] === undefined) continue;
      if (typeof body[key] !== 'boolean') {
        return res.status(400).json({ error: `${key} must be true or false.` });
      }
      data[key] = body[key];
    }
    if (body.tzOffsetMinutes !== undefined) {
      const tz = parseTz(body.tzOffsetMinutes);
      if (tz.error) return res.status(400).json({ error: tz.error });
      data.tzOffsetMinutes = tz;
    }

    try {
      const current = await prisma.user.findUnique({
        where: { id: req.userId },
        select: { weeklySummaryEmails: true, tzOffsetMinutes: true },
      });
      if (!current) return res.status(404).json({ error: 'User not found.' });
      // Turning the weekly email on: mark the latest week as done, so the first
      // email is about the next full week, not an instant one about last week.
      if (data.weeklySummaryEmails === true && !current.weeklySummaryEmails) {
        data.weeklySummarySentWeek = latestWeek(new Date(), data.tzOffsetMinutes ?? current.tzOffsetMinutes).key;
      }
      const user = await prisma.user.update({
        where: { id: req.userId },
        data,
        select: SAFE_SELECT,
      });
      res.json(user);
    } catch (err) {
      if (err.code === 'P2025') return res.status(404).json({ error: 'User not found.' });
      console.error('[user/notifications]', err);
      res.status(500).json({ error: 'Failed to save settings.' });
    }
  });

  // GET /api/user/receipts
  // Optional ?from=&to= (ISO dates, from inclusive, to exclusive) filters by date.
  // Without a range, returns the latest 50 receipts; with one, the newest 500
  // (a receipt a day is 365 a year). Only the fields the app reads.
  router.get('/receipts', limiters.receiptsRead, async (req, res) => {
    const { from, to } = req.query;
    const fromDate = from ? new Date(from) : null;
    const toDate   = to   ? new Date(to)   : null;
    if ((fromDate && isNaN(fromDate)) || (toDate && isNaN(toDate))) {
      return res.status(400).json({ error: 'from and to must be valid dates.' });
    }
    const hasRange = fromDate || toDate;

    try {
      const receipts = await prisma.receipt.findMany({
        where: {
          userId: req.userId,
          ...(hasRange && {
            createdAt: {
              ...(fromDate && { gte: fromDate }),
              ...(toDate && { lt: toDate }),
            },
          }),
        },
        orderBy: { createdAt: 'desc' },
        take: hasRange ? 500 : 50,
        select: RECEIPT_SELECT,
      });
      res.json(receipts);
    } catch (err) {
      res.status(500).json({ error: 'Failed to load receipts.' });
    }
  });

  // GET /api/user/stats?bounds=<iso>,<iso>,...
  // 2 to 13 ISO instants with a zone; each neighbour pair is one period
  // [from, to) — the same rule as /receipts?from&to, so Trends matches the Archive.
  router.get('/stats', async (req, res) => {
    const parsed = parseBounds(req.query.bounds);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { bounds } = parsed;

    try {
      // One round trip: period totals, per category and per store via GROUPING SETS.
      const rows = await queryStats(req.userId, bounds);
      res.json(shapeStats(rows, bounds));
    } catch (err) {
      console.error('[user/stats]', err);
      res.status(500).json({ error: 'Failed to load stats.' });
    }
  });

  return router;
};
