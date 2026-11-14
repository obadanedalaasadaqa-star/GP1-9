// Demo account data for `npm run demo:reset` (scripts/demo-reset.js).
// buildDemoData is pure (no DB, deterministic for a fixed now and tz);
// resetDemoAccount replaces one user's data in a single transaction.
const { monthWindow } = require('./budgets');

const PAST_MONTHS = 5;

// One past month: five receipts at fixed points of the month.
const PAST_SLOTS = [
  { at: 0.08, storeName: 'Carrefour',         category: 'Supermarket', base: 42.5,  items: ['Milk x2', 'Bread', 'Eggs x12', 'Rice 2kg'] },
  { at: 0.27, storeName: 'Hashem Restaurant', category: 'Food',        base: 18.75, items: ['Falafel plate x2', 'Hummus', 'Fresh Juice x2'] },
  { at: 0.45, storeName: 'City Pharmacy',     category: 'Pharmacy',    base: 14.25, items: ['Vitamin C', 'Panadol x20'] },
  { at: 0.66, storeName: 'Zara',              category: 'Clothing',    base: 55,    items: ['T-Shirt', 'Jeans'] },
  { at: 0.86, storeName: 'Books@Cafe',        category: 'Food',        base: 12.5,  items: ['Cappuccino x2', 'Cheesecake slice'] },
];
// Every third month also has an electronics receipt.
const EXTRA_SLOT = { at: 0.93, storeName: 'iStore', category: 'Electronics', base: 39.99, items: ['USB-C Cable', 'Phone Case'] };

// This month so far: at fixed points of [start of month, now), so none is in
// the future and there is room even at 00:30 on the 1st.
const CURRENT_SLOTS = [
  { at: 0.10, storeName: 'Carrefour',         category: 'Supermarket', amount: 24.5,  items: ['Milk x2', 'Bread', 'Cheese 500g'] },
  { at: 0.30, storeName: 'Hashem Restaurant', category: 'Food',        amount: 18.75, items: ['Falafel plate x2', 'Hummus'] },
  { at: 0.50, storeName: 'City Pharmacy',     category: 'Pharmacy',    amount: 9.5,   items: ['Hand Sanitizer', 'Vitamin C'] },
  { at: 0.70, storeName: 'Books@Cafe',        category: 'Food',        amount: 12.5,  items: ['Cappuccino x2', 'Cheesecake slice'] },
  { at: 0.90, storeName: 'Co-op Supermarket', category: 'Supermarket', amount: 16.25, items: ['Yogurt x3', 'Tomatoes 1kg'] },
];

// The "near" budget: this month's spending is 65-79% of its limit, so one
// Store Simulator receipt in this category crosses 80% during the demo.
const NEAR_CATEGORY = 'Food';
const NEAR_RATIO = 0.70;
const OTHER_BUDGETS = [
  { category: 'Supermarket', monthlyLimit: 150 },
  { category: 'Clothing',    monthlyLimit: 100 },
];

const round2 = (x) => Math.round(x * 100) / 100;
const at = (from, to, fraction) => new Date(from.getTime() + Math.floor((to.getTime() - from.getTime()) * fraction));
const receipt = (slot, amount, createdAt) => ({
  storeName: slot.storeName,
  category: slot.category,
  totalAmount: amount,
  items: slot.items,
  pointsEarned: Math.floor(amount),
  createdAt,
});

/**
 * The demo data for [now] in the user's zone [tz] (minutes east of UTC).
 * Returns { months, receipts, budgets, points }: about 30 receipts over this
 * month and the previous 5 (at least 4 each), and 3 budgets.
 */
function buildDemoData(now, tz) {
  const current = monthWindow(now, tz);
  const months = [current];
  for (let i = 0; i < PAST_MONTHS; i++) {
    months.unshift(monthWindow(new Date(months[0].fromUtc.getTime() - 1), tz));
  }

  const receipts = [];
  months.slice(0, -1).forEach((m, i) => {
    const monthsAgo = PAST_MONTHS - i;
    // Amounts change a little from month to month so Trends has a shape.
    const factor = 1 + ((monthsAgo * 7) % 5 - 2) * 0.06;
    const slots = monthsAgo % 3 === 0 ? [...PAST_SLOTS, EXTRA_SLOT] : PAST_SLOTS;
    for (const slot of slots) {
      receipts.push(receipt(slot, round2(slot.base * factor), at(m.fromUtc, m.toUtc, slot.at)));
    }
  });
  for (const slot of CURRENT_SLOTS) {
    receipts.push(receipt(slot, slot.amount, at(current.fromUtc, now, slot.at)));
  }

  const nearSpent = CURRENT_SLOTS
    .filter((s) => s.category === NEAR_CATEGORY)
    .reduce((sum, s) => sum + s.amount, 0);
  const budgets = [
    { category: NEAR_CATEGORY, monthlyLimit: Math.ceil(nearSpent / NEAR_RATIO) },
    ...OTHER_BUDGETS,
  ];
  const points = receipts.reduce((sum, r) => sum + r.pointsEarned, 0);
  return { months, receipts, budgets, points };
}

/**
 * Replace [userId]'s receipts, AI data, budgets, alerts and codes with the demo
 * data, set the points to match, and turn two-step sign-in off, in one
 * transaction. Never touches email, password, name, serial, emailVerified,
 * the email settings or the time zone, so the demo phone stays logged in.
 */
async function resetDemoAccount(prisma, userId, now = new Date()) {
  const user = await prisma.user.findUnique({ where: { id: userId }, select: { tzOffsetMinutes: true } });
  if (!user) throw new Error('User not found.');
  const data = buildDemoData(now, user.tzOffsetMinutes ?? 180);
  const where = { userId };

  await prisma.$transaction([
    prisma.receipt.deleteMany({ where }),
    prisma.aiInsight.deleteMany({ where }),
    prisma.aiReport.deleteMany({ where }),
    prisma.aiUsage.deleteMany({ where }),
    prisma.budget.deleteMany({ where }),
    prisma.budgetAlert.deleteMany({ where }),
    prisma.verificationCode.deleteMany({ where }),
    prisma.receipt.createMany({ data: data.receipts.map((r) => ({ userId, ...r })) }),
    prisma.budget.createMany({ data: data.budgets.map((b) => ({ userId, ...b })) }),
    prisma.user.update({ where: { id: userId }, data: { loyaltyPoints: data.points, loginTwoFactor: false } }),
  ]);
  return { receipts: data.receipts.length, budgets: data.budgets.length, points: data.points };
}

module.exports = { buildDemoData, resetDemoAccount };
