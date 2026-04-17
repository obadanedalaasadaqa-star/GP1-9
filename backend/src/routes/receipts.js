const express = require('express');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

const DEMO_RECEIPTS = [
  { storeName: 'Carrefour',         category: 'Supermarket', totalAmount: 45.50, items: ['Milk x2', 'Bread', 'Eggs x12', 'Chicken 1kg', 'Rice 2kg'],   pointsEarned: 45 },
  { storeName: 'City Pharmacy',     category: 'Pharmacy',    totalAmount: 23.00, items: ['Vitamin C', 'Panadol x20', 'Hand Sanitizer'],                  pointsEarned: 23 },
  { storeName: 'Hashem Restaurant', category: 'Food',        totalAmount: 18.75, items: ['Falafel plate x2', 'Hummus', 'Fresh Juice x2'],                pointsEarned: 18 },
  { storeName: 'Zara',              category: 'Clothing',    totalAmount: 67.00, items: ['T-Shirt', 'Jeans'],                                            pointsEarned: 67 },
  { storeName: 'Co-op Supermarket', category: 'Supermarket', totalAmount: 31.25, items: ['Yogurt x3', 'Cheese 500g', 'Tomatoes 1kg', 'Juice 1L x2'],    pointsEarned: 31 },
  { storeName: 'Books@Cafe',        category: 'Food',        totalAmount: 12.50, items: ['Cappuccino x2', 'Cheesecake slice'],                           pointsEarned: 12 },
  { storeName: 'iStore',            category: 'Electronics', totalAmount: 89.99, items: ['USB-C Cable', 'Screen Protector', 'Phone Case'],               pointsEarned: 89 },
];

// POST /api/receipts — create a single receipt (called by store scanner in production)
router.post('/', async (req, res) => {
  const { storeName, category, totalAmount, items } = req.body ?? {};

  if (!storeName?.trim() || !category?.trim() || totalAmount == null || !Array.isArray(items)) {
    return res.status(400).json({ error: 'storeName, category, totalAmount, and items are required.' });
  }

  try {
    const pointsEarned = Math.floor(totalAmount);
    const [receipt] = await Promise.all([
      prisma.receipt.create({
        data: {
          userId: req.userId,
          storeName: storeName.trim(),
          category: category.trim(),
          totalAmount: parseFloat(totalAmount),
          items,
          pointsEarned,
        },
      }),
      prisma.user.update({
        where: { id: req.userId },
        data: { loyaltyPoints: { increment: pointsEarned } },
      }),
    ]);
    res.status(201).json(receipt);
  } catch (err) {
    console.error('[receipts/post]', err);
    res.status(500).json({ error: 'Failed to create receipt.' });
  }
});

// POST /api/receipts/seed — seed demo receipts for this user (idempotent)
router.post('/seed', async (req, res) => {
  try {
    const existing = await prisma.receipt.count({ where: { userId: req.userId } });
    if (existing > 0) {
      return res.json({ seeded: false, message: 'Already has receipts.' });
    }

    const totalPoints = DEMO_RECEIPTS.reduce((sum, r) => sum + r.pointsEarned, 0);

    await prisma.$transaction([
      ...DEMO_RECEIPTS.map((r) =>
        prisma.receipt.create({
          data: { userId: req.userId, ...r },
        })
      ),
      prisma.user.update({
        where: { id: req.userId },
        data: { loyaltyPoints: { increment: totalPoints } },
      }),
    ]);

    res.json({ seeded: true, count: DEMO_RECEIPTS.length });
  } catch (err) {
    console.error('[receipts/seed]', err);
    res.status(500).json({ error: 'Failed to seed receipts.' });
  }
});

module.exports = router;
