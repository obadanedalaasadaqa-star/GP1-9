const express = require('express');
const prisma = require('../lib/prisma');
const storeAuth = require('../middleware/storeAuth');
const { parseStoreReceipt } = require('../lib/storeReceipt');
const { emitToUser } = require('../lib/realtime');
const { sendReceiptEmail } = require('../lib/mailer');

// Router factory: every createApp() gets its own router and limiters.
// Used by the Store Simulator (public/store) with a store key.
module.exports = function storeRoutes(limiters) {
  const router = express.Router();

  // GET /api/store/me — store "login": checks the key, returns the store
  router.get('/me', limiters.storeAuth, storeAuth, (req, res) => {
    res.json(req.store);
  });

  // POST /api/store/receipts — send a receipt to a customer by serial.
  // Store name/category come from nexus_stores, never from the body.
  router.post('/receipts', limiters.storeAuth, storeAuth, limiters.storeReceipts, async (req, res) => {
    const started = Date.now();
    const parsed = parseStoreReceipt(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });

    const { store } = req;
    const pointsEarned = Math.floor(parsed.totalAmount);
    let row;
    try {
      // One statement (atomic, one DB round trip): add the points to the user
      // with this serial and insert the receipt. No match = nothing written.
      const rows = await prisma.$queryRaw`
        WITH u AS (
          UPDATE nexus_users SET "loyaltyPoints" = "loyaltyPoints" + ${pointsEarned}::int, "updatedAt" = NOW()
           WHERE "serialNumber" = ${parsed.serial}
           RETURNING id, "firstName", email, "emailVerified", "loyaltyPoints"
        ), r AS (
          INSERT INTO nexus_receipts ("userId", "storeId", "storeName", category, "totalAmount", items, "lineItems", "pointsEarned")
          SELECT u.id, ${store.id}, ${store.name}, ${store.category}, ${parsed.totalAmount}::float8,
                 ${JSON.stringify(parsed.itemStrings)}::jsonb, ${JSON.stringify(parsed.items)}::jsonb, ${pointsEarned}::int
            FROM u
          RETURNING *
        )
        SELECT r.*, u."firstName" AS "customerFirstName", u.email AS "customerEmail",
               u."emailVerified" AS "customerEmailVerified", u."loyaltyPoints" AS "customerLoyaltyPoints"
          FROM u JOIN r ON r."userId" = u.id`;
      row = rows[0];
    } catch (err) {
      console.error('[store/receipts]', err);
      return res.status(500).json({ error: 'Failed to send receipt.' });
    }
    if (!row) return res.status(404).json({ error: 'No Nexus customer with this serial.' });

    // Same shape as a row from GET /api/user/receipts.
    const receipt = {
      id: row.id,
      userId: row.userId,
      storeId: row.storeId,
      storeName: row.storeName,
      category: row.category,
      totalAmount: row.totalAmount,
      items: row.items,
      lineItems: row.lineItems,
      pointsEarned: row.pointsEarned,
      createdAt: row.createdAt,
    };
    const user = {
      firstName: row.customerFirstName,
      email: row.customerEmail,
      emailVerified: row.customerEmailVerified,
    };

    // The receipt is saved: from here on nothing may turn it into an error
    // (a cashier retry would double the points). Push it to the phone live.
    try {
      emitToUser(receipt.userId, 'receipt:new', {
        receipt, pointsEarned: receipt.pointsEarned, loyaltyPoints: row.customerLoyaltyPoints,
      });
    } catch (err) {
      console.error('[store/receipts] live push failed', err.message);
    }

    // Saved: only the customer's first name goes back to the store.
    res.status(201).json({
      receiptId: receipt.id,
      customerFirstName: user.firstName,
      totalAmount: receipt.totalAmount,
      pointsEarned: receipt.pointsEarned,
      createdAt: receipt.createdAt,
    });
    console.log(`[store/receipts] 201 store=${store.id} in ${Date.now() - started}ms`);

    // Email copy after the reply, outside any try that answers 500.
    if (parsed.emailCopy && user.emailVerified) {
      Promise.resolve()
        .then(() => sendReceiptEmail(user.email, user.firstName, {
          storeName: receipt.storeName,
          items: receipt.items,
          totalAmount: receipt.totalAmount,
          pointsEarned: receipt.pointsEarned,
          createdAt: receipt.createdAt,
        }))
        .catch((err) => console.error('[store/receipts] email copy failed', err.message));
    }
  });

  return router;
};
