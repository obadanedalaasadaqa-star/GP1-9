const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const prisma = require('../lib/prisma');
const { passwordError } = require('../lib/password');
const { sendEmailCode } = require('../lib/verification');

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
};

function generateSerial() {
  const part = uuidv4().replace(/-/g, '').toUpperCase().slice(0, 10);
  return `NXS-${part.slice(0, 5)}-${part.slice(5)}`;
}

function signToken(userId) {
  return jwt.sign({ userId }, process.env.JWT_SECRET, { expiresIn: '7d' });
}

// Router factory: every createApp() gets its own router and limiters.
module.exports = function authRoutes(limiters) {
  const router = express.Router();

  // POST /api/auth/register
  router.post('/register', limiters.register, async (req, res) => {
    const { email, password } = req.body ?? {};
    const firstName = req.body?.firstName?.trim();
    const lastName  = req.body?.lastName?.trim();

    if (!email || !password || !firstName || !lastName) {
      return res.status(400).json({
        error: 'First name, last name, email, and password are required.',
      });
    }
    const pwError = passwordError(password);
    if (pwError) return res.status(400).json({ error: pwError });

    try {
      const existing = await prisma.user.findUnique({ where: { email } });
      if (existing) return res.status(409).json({ error: 'Email already registered.' });

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
      res.status(201).json({ token: signToken(user.id), user });
    } catch (err) {
      console.error('[register]', err);
      res.status(500).json({ error: 'Registration failed. Please try again.' });
    }
  });

  // POST /api/auth/login
  router.post('/login', limiters.login, async (req, res) => {
    const { email, password } = req.body ?? {};

    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required.' });
    }

    // Dummy hash — ensures bcrypt always runs to prevent email enumeration via timing
    const DUMMY = '$2a$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    try {
      const user = await prisma.user.findUnique({ where: { email } });
      const valid = await bcrypt.compare(password, user?.password ?? DUMMY);
      if (!user || !valid) return res.status(401).json({ error: 'Invalid email or password.' });

      // Only the SAFE_USER_SELECT fields (never the hash or internal columns).
      const safeUser = Object.fromEntries(Object.keys(SAFE_USER_SELECT).map((k) => [k, user[k]]));
      res.json({ token: signToken(user.id), user: safeUser });
    } catch (err) {
      console.error('[login]', err);
      res.status(500).json({ error: 'Login failed. Please try again.' });
    }
  });

  return router;
};
