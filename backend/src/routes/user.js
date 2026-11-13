const express = require('express');
const bcrypt = require('bcryptjs');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const { normalizeJordanPhone } = require('../lib/phone');
const { passwordError } = require('../lib/password');
const { checkCode, sendEmailCode, resendWaitSeconds, expireCode } = require('../lib/verification');
const { sendPhoneCode, checkPhoneCode } = require('../lib/smsCodes');
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
  phone: true,
  emailVerified: true,
  phoneVerified: true,
  serialNumber: true,
  loyaltyPoints: true,
  createdAt: true,
  budgetAlertEmails: true,
  weeklySummaryEmails: true,
};

const NOTIFICATION_KEYS = ['budgetAlertEmails', 'weeklySummaryEmails', 'tzOffsetMinutes'];

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

  // PATCH /api/user/me  — update first name, last name, phone, and email
  // Changing the email requires the current password. A new phone number
  // (compared normalized) must be verified again; its pending SMS codes end.
  router.patch('/me', async (req, res) => {
    const firstName = req.body?.firstName?.trim();
    const lastName  = req.body?.lastName?.trim();
    if (!firstName || !lastName) {
      return res.status(400).json({ error: 'First and last name are required.' });
    }
    const data = { firstName, lastName, name: `${firstName} ${lastName}` };

    if (req.body?.phone) {
      const phone = normalizeJordanPhone(req.body.phone);
      if (!phone) {
        return res.status(400).json({ error: 'Enter a valid Jordanian mobile number (07X XXX XXXX).' });
      }
      data.phone = phone;
    }

    try {
      const email = req.body?.email?.trim();
      let phoneChanged = false;
      if (email || data.phone) {
        const current = await prisma.user.findUnique({ where: { id: req.userId } });
        if (!current) return res.status(404).json({ error: 'User not found.' });

        if (data.phone && data.phone !== current.phone) {
          data.phoneVerified = false;
          phoneChanged = true;
        }

        if (email && email !== current.email) {
          if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
            return res.status(400).json({ error: 'Enter a valid email.' });
          }
          const { currentPassword } = req.body;
          if (!currentPassword) {
            return res.status(400).json({ error: 'Current password is required to change your email.' });
          }
          if (!(await bcrypt.compare(currentPassword, current.password))) {
            return res.status(401).json({ error: 'Current password is incorrect.' });
          }
          data.email = email;
          data.emailVerified = false; // the new address must be verified again
        }
      }

      const user = await prisma.user.update({
        where: { id: req.userId },
        data,
        select: SAFE_SELECT,
      });
      if (data.email) await sendEmailCode(user, { ignoreWait: true });
      if (phoneChanged) {
        // Codes sent to the old number stop working; a new one may be sent at
        // once. Never breaks the update (the sentTo check still rejects them).
        try {
          await expireCode(req.userId, 'phone', { clearWait: true });
          await expireCode(req.userId, 'login');
        } catch (err) {
          console.error('[user/patch] expire phone code', err);
        }
      }
      res.json(user);
    } catch (err) {
      if (err.code === 'P2002') {
        const field = err.meta?.target?.includes('email') ? 'Email' : 'Phone number';
        return res.status(409).json({ error: `${field} already registered.` });
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
      if (waitSeconds > 0) {
        return res.status(429).json({
          error: `Please wait ${waitSeconds}s before requesting a new code.`,
          waitSeconds,
        });
      }
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
    if (!code || !/^\d{6}$/.test(String(code).trim())) {
      return res.status(400).json({ error: 'Enter the 6-digit code.' });
    }

    try {
      const problem = await checkCode(req.userId, 'email', code);
      if (problem) return res.status(400).json({ error: problem });

      const user = await prisma.user.update({
        where: { id: req.userId },
        data: { emailVerified: true },
        select: SAFE_SELECT,
      });
      res.json(user);
    } catch (err) {
      console.error('[user/email/verify]', err);
      res.status(500).json({ error: 'Failed to verify email.' });
    }
  });

  // Runs before the phoneSendCode limiter (same idea as sendCodePrecheck):
  // no number, already verified and the 60 s wait don't use up the hourly cap.
  async function phonePrecheck(req, res, next) {
    try {
      const user = await prisma.user.findUnique({ where: { id: req.userId }, select: SAFE_SELECT });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      if (!normalizeJordanPhone(user.phone)) {
        return res.status(400).json({ error: 'Add a valid mobile number in Profile first.' });
      }
      if (user.phoneVerified) return res.status(400).json({ error: 'Phone number is already verified.' });

      const waitSeconds = await resendWaitSeconds(req.userId, 'phone');
      if (waitSeconds > 0) {
        return res.status(429).json({
          error: `Please wait ${waitSeconds}s before requesting a new code.`,
          waitSeconds,
        });
      }
      res.locals.user = user;
      next();
    } catch (err) {
      console.error('[user/phone/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  }

  // POST /api/user/phone/send-code — text a code to the profile's number
  router.post('/phone/send-code', phonePrecheck, limiters.phoneSendCode, async (req, res) => {
    try {
      const result = await sendPhoneCode(res.locals.user);
      if (result.waitSeconds) {
        return res.status(429).json({
          error: `Please wait ${result.waitSeconds}s before requesting a new code.`,
          waitSeconds: result.waitSeconds,
        });
      }
      if (result.error) {
        return res.status(result.status).json({
          error: result.error, ...(result.reason && { reason: result.reason }),
        });
      }
      res.json({ message: `Code sent to ${result.to}.` });
    } catch (err) {
      console.error('[user/phone/send-code]', err);
      res.status(500).json({ error: 'Failed to send code.' });
    }
  });

  // POST /api/user/phone/verify — confirm the number with the 6-digit SMS code
  router.post('/phone/verify', limiters.phoneVerifyCode, async (req, res) => {
    const code = req.body?.code;
    if (!code || !/^\d{6}$/.test(String(code).trim())) {
      return res.status(400).json({ error: 'Enter the 6-digit code.' });
    }

    try {
      const current = await prisma.user.findUnique({ where: { id: req.userId }, select: SAFE_SELECT });
      if (!current) return res.status(404).json({ error: 'User not found.' });
      if (current.phoneVerified) return res.status(400).json({ error: 'Phone number is already verified.' });

      const problem = await checkPhoneCode(current, String(code).trim());
      if (problem) return res.status(problem.status).json({ error: problem.error });

      const user = await prisma.user.update({
        where: { id: req.userId },
        data: { phoneVerified: true },
        select: SAFE_SELECT,
      });
      res.json(user);
    } catch (err) {
      console.error('[user/phone/verify]', err);
      res.status(500).json({ error: 'Failed to verify phone number.' });
    }
  });

  // PATCH /api/user/password — change password (requires the current one)
  router.patch('/password', async (req, res) => {
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
      if (!(await bcrypt.compare(currentPassword, user.password))) {
        return res.status(401).json({ error: 'Current password is incorrect.' });
      }

      await prisma.user.update({
        where: { id: req.userId },
        data: { password: await bcrypt.hash(newPassword, 12) },
      });
      res.json({ message: 'Password updated.' });
    } catch (err) {
      console.error('[user/password]', err);
      res.status(500).json({ error: 'Failed to update password.' });
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
  // Without a range, returns the latest 50 receipts.
  router.get('/receipts', async (req, res) => {
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
        take: hasRange ? 1000 : 50,
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
