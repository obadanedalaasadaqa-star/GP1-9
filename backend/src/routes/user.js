const express = require('express');
const bcrypt = require('bcryptjs');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const { normalizeJordanPhone } = require('../lib/phone');
const { passwordError } = require('../lib/password');
const { checkCode, sendEmailCode } = require('../lib/verification');

const router = express.Router();

router.use(authMiddleware);

const SAFE_SELECT = {
  id: true,
  email: true,
  name: true,
  firstName: true,
  lastName: true,
  phone: true,
  emailVerified: true,
  serialNumber: true,
  loyaltyPoints: true,
  createdAt: true,
};

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
// Changing the email requires the current password.
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
    if (email) {
      const current = await prisma.user.findUnique({ where: { id: req.userId } });
      if (!current) return res.status(404).json({ error: 'User not found.' });

      if (email !== current.email) {
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

// POST /api/user/email/send-code — (re)send the email verification code
router.post('/email/send-code', async (req, res) => {
  try {
    const user = await prisma.user.findUnique({ where: { id: req.userId }, select: SAFE_SELECT });
    if (!user) return res.status(404).json({ error: 'User not found.' });
    if (user.emailVerified) return res.status(400).json({ error: 'Email is already verified.' });

    const result = await sendEmailCode(user);
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
router.post('/email/verify', async (req, res) => {
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

module.exports = router;
