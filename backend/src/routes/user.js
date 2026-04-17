const express = require('express');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');

const router = express.Router();

router.use(authMiddleware);

const SAFE_SELECT = {
  id: true,
  email: true,
  name: true,
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

// PATCH /api/user/me  — update name only for now
router.patch('/me', async (req, res) => {
  const { name } = req.body ?? {};
  if (!name?.trim()) return res.status(400).json({ error: 'Name is required.' });

  try {
    const user = await prisma.user.update({
      where: { id: req.userId },
      data: { name: name.trim() },
      select: SAFE_SELECT,
    });
    res.json(user);
  } catch (err) {
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
