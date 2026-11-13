const express = require('express');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const { parseTz } = require('../lib/aiDates');
const {
  MAX_BUDGETS, CATEGORY_ERROR, cleanCategory, parseBudgetBody, monthWindow,
} = require('../lib/budgets');
const budgetQueries = require('../lib/budgetQueries');

// ?tzOffsetMinutes= when sent (a number or { error }), else undefined. parseTz
// alone would turn a missing value into 180 and hide the saved one.
const queryTz = (req) => (req.query.tzOffsetMinutes !== undefined ? parseTz(req.query.tzOffsetMinutes) : undefined);

// Router factory: every createApp() gets its own router and limiters.
// Monthly budgets per category. Every route answers the full list
// (budgetQueries.budgetList) for the current month in the user's zone.
module.exports = function budgetRoutes(limiters) {
  const router = express.Router();
  router.use(authMiddleware);

  // GET /api/budgets?tzOffsetMinutes= — read-only, never saves the tz.
  router.get('/', async (req, res) => {
    const sentTz = queryTz(req);
    if (sentTz?.error) return res.status(400).json({ error: sentTz.error });
    try {
      const saved = await budgetQueries.savedTz(req.userId);
      if (saved === null) return res.status(404).json({ error: 'User not found.' });
      res.json(await budgetQueries.budgetList(req.userId, sentTz ?? saved));
    } catch (err) {
      console.error('[budgets/get]', err);
      res.status(500).json({ error: 'Failed to load budgets.' });
    }
  });

  // PUT /api/budgets { category, limit, tzOffsetMinutes? } — create or change one.
  router.put('/', limiters.budgets, async (req, res) => {
    const parsed = parseBudgetBody(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { category, limit } = parsed;
    const now = new Date();

    try {
      const saved = await budgetQueries.savedTz(req.userId);
      if (saved === null) return res.status(404).json({ error: 'User not found.' });
      const tz = parsed.tz ?? saved;
      const { month } = monthWindow(now, tz);

      // One batch transaction (no interactive transaction: on the 6543 pooler
      // those time out under load). The UPDATE saves the tz and locks the user
      // row, so a parallel PUT waits here; the next statement then sees its
      // commit and two PUTs can't both pass the 20-budget check.
      // A new or changed budget may warn again this month (same amount: no reset).
      const [, rows] = await prisma.$transaction([
        prisma.$executeRaw`
          UPDATE nexus_users SET "tzOffsetMinutes" = ${tz}::int WHERE id = ${req.userId}
        `,
        prisma.$queryRaw`
          WITH old AS (
            SELECT "monthlyLimit" FROM nexus_budgets WHERE "userId" = ${req.userId} AND category = ${category}
          ), up AS (
            INSERT INTO nexus_budgets ("userId", category, "monthlyLimit")
            SELECT ${req.userId}, ${category}, ${limit}::float8
             WHERE EXISTS (SELECT 1 FROM old)
                OR (SELECT COUNT(*) FROM nexus_budgets WHERE "userId" = ${req.userId}) < ${MAX_BUDGETS}
            ON CONFLICT ("userId", category)
            DO UPDATE SET "monthlyLimit" = EXCLUDED."monthlyLimit", "updatedAt" = NOW()
            RETURNING 1
          ), reset AS (
            DELETE FROM nexus_budget_alerts
             WHERE "userId" = ${req.userId} AND category = ${category} AND month = ${month}
               AND EXISTS (SELECT 1 FROM up)
               AND NOT EXISTS (SELECT 1 FROM old WHERE ROUND("monthlyLimit" * 1000) = ROUND(${limit}::float8 * 1000))
            RETURNING 1
          )
          SELECT EXISTS (SELECT 1 FROM up) AS saved
        `,
      ]);
      if (!rows[0].saved) {
        return res.status(400).json({ error: `You can have up to ${MAX_BUDGETS} budgets.` });
      }
      res.json(await budgetQueries.budgetList(req.userId, tz, now));
    } catch (err) {
      console.error('[budgets/put]', err);
      res.status(500).json({ error: 'Failed to save budget.' });
    }
  });

  // DELETE /api/budgets/:category?tzOffsetMinutes= — remove one (URL-encoded name).
  router.delete('/:category', limiters.budgets, async (req, res) => {
    const category = cleanCategory(req.params.category);
    if (!category) return res.status(400).json({ error: CATEGORY_ERROR });
    const sentTz = queryTz(req);
    if (sentTz?.error) return res.status(400).json({ error: sentTz.error });
    const now = new Date();

    try {
      const saved = await budgetQueries.savedTz(req.userId);
      if (saved === null) return res.status(404).json({ error: 'User not found.' });
      const tz = sentTz ?? saved;
      const { month } = monthWindow(now, tz);
      const [deleted] = await prisma.$transaction([
        prisma.$executeRaw`
          DELETE FROM nexus_budgets WHERE "userId" = ${req.userId} AND category = ${category}
        `,
        prisma.$executeRaw`
          DELETE FROM nexus_budget_alerts
           WHERE "userId" = ${req.userId} AND category = ${category} AND month = ${month}
        `,
      ]);
      if (deleted === 0) return res.status(404).json({ error: 'No budget for this category.' });
      res.json(await budgetQueries.budgetList(req.userId, tz, now));
    } catch (err) {
      console.error('[budgets/delete]', err);
      res.status(500).json({ error: 'Failed to delete budget.' });
    }
  });

  return router;
};
