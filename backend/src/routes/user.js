const express = require('express');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const { normalizeJordanPhone } = require('../lib/phone');

const router = express.Router();

router.use(authMiddleware);

const SAFE_SELECT = {
  id: true,
  email: true,
  name: true,
  firstName: true,
  lastName: true,
  phone: true,
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

// PATCH /api/user/me  — update first name, last name, and phone
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
    const user = await prisma.user.update({
      where: { id: req.userId },
      data,
      select: SAFE_SELECT,
    });
    res.json(user);
  } catch (err) {
    if (err.code === 'P2002') {
      return res.status(409).json({ error: 'Phone number already registered.' });
    }
    console.error('[user/patch]', err);
    res.status(500).json({ error: 'Failed to update profile.' });
  }
});

// GET /api/user/receipts — placeholder for Phase 2
router.get('/receipts', async (req, res) => {
  try {
    const receipts = await prisma.receipt.findMany({
      where: { userId: req.userId },
      orderBy: { createdAt: 'desc' },
      take: 50,
    });
    res.json(receipts);
  } catch (err) {
    res.status(500).json({ error: 'Failed to load receipts.' });
  }
});

module.exports = router;
