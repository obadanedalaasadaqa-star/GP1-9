const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const prisma = require('../lib/prisma');

const router = express.Router();

const SAFE_USER_SELECT = {
  id: true,
  email: true,
  name: true,
  serialNumber: true,
  loyaltyPoints: true,
  createdAt: true,
};

function generateSerial() {
  const part = uuidv4().replace(/-/g, '').toUpperCase().slice(0, 10);
  return `NXS-${part.slice(0, 5)}-${part.slice(5)}`;
}

function signToken(userId) {
  return jwt.sign({ userId }, process.env.JWT_SECRET, { expiresIn: '7d' });
}

// POST /api/auth/register
router.post('/register', async (req, res) => {
  const { email, password, name } = req.body ?? {};

  if (!email || !password || !name) {
    return res.status(400).json({ error: 'Name, email, and password are required.' });
  }
  if (password.length < 6) {
    return res.status(400).json({ error: 'Password must be at least 6 characters.' });
  }

  try {
    const existing = await prisma.user.findUnique({ where: { email } });
    if (existing) return res.status(409).json({ error: 'Email already registered.' });

    const hashed = await bcrypt.hash(password, 12);
    const serialNumber = generateSerial();

    const user = await prisma.user.create({
      data: { email, password: hashed, name, serialNumber },
      select: SAFE_USER_SELECT,
    });

    res.status(201).json({ token: signToken(user.id), user });
  } catch (err) {
    console.error('[register]', err);
    res.status(500).json({ error: 'Registration failed. Please try again.' });
  }
});

// POST /api/auth/login
router.post('/login', async (req, res) => {
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

    const { password: _, ...safeUser } = user;
    res.json({ token: signToken(user.id), user: safeUser });
  } catch (err) {
    console.error('[login]', err);
    res.status(500).json({ error: 'Login failed. Please try again.' });
  }
});

module.exports = router;
