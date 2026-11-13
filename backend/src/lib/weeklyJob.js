// Weekly summary job: emails each opted-in, verified user a summary of the
// last full Sunday-Saturday week, once per week, from Sunday 09:00 local.
// Runs inside the server (startWeeklyJob, called from index.js only, so tests
// never start it). If the server slept through Sunday morning, the next check
// catches up; the claim on "weeklySummarySentWeek" means never twice.
const { Prisma } = require('@prisma/client');
const prisma = require('./prisma');
const mailer = require('./mailer');
const spendingQueries = require('./spendingQueries');
const budgetQueries = require('./budgetQueries');
const { localRangeToUtc, addDays } = require('./aiDates');
const { monthWindow } = require('./budgets');
const { latestWeek, buildWeeklySummary } = require('./weeklySummary');

const FIRST_RUN_MS = 60 * 1000;
const EVERY_MS = 15 * 60 * 1000;

// Spending of one local week [from, to] (to inclusive).
function weekPeriod(userId, from, to, tz) {
  const { fromUtc, toUtc } = localRangeToUtc(from, to, tz);
  return spendingQueries.queryRange(userId, fromUtc, toUtc);
}

/**
 * Send the weekly emails that are due at [now]. userIds limits the run to
 * those users (tests and scripts/send-weekly.js always pass it); without it,
 * every opted-in user except @nexus.test test accounts. force sends
 * again for a week already sent. Users furthest behind come first, so a busy
 * batch can't starve the rest. Returns { sent, skipped, failed }.
 */
async function runWeeklySummaries({ now = new Date(), userIds, force = false, limit = 50 } = {}) {
  // The timer run never touches throwaway test accounts: npm test and the
  // servers (local and Render) share one DB, so a test user that turned the
  // email on must not get a real email or have its week claimed mid-test.
  const scope = userIds
    ? Prisma.sql`AND id = ANY(${userIds})`
    : Prisma.sql`AND email NOT LIKE ${'%@nexus.test'}`;
  const users = await prisma.$queryRaw`
    SELECT id, email, "firstName", "tzOffsetMinutes", "weeklySummarySentWeek"
      FROM nexus_users
     WHERE "weeklySummaryEmails" AND "emailVerified" ${scope}
     ORDER BY "weeklySummarySentWeek" ASC NULLS FIRST, id
     LIMIT ${limit}
  `;

  const result = { sent: 0, skipped: 0, failed: 0 };
  for (const user of users) {
    const tz = user.tzOffsetMinutes;
    const old = user.weeklySummarySentWeek;
    const week = latestWeek(now, tz);
    if (old === week.key && !force) {
      result.skipped++;
      continue;
    }

    // Claim the week; another run that already claimed it wins.
    const claimed = await prisma.$queryRaw`
      UPDATE nexus_users SET "weeklySummarySentWeek" = ${week.key}
       WHERE id = ${user.id} AND "weeklySummarySentWeek" IS NOT DISTINCT FROM ${old}
      RETURNING id
    `;
    if (!claimed.length) {
      result.skipped++;
      continue;
    }

    try {
      const [current, previous] = await Promise.all([
        weekPeriod(user.id, week.from, week.to, tz),
        weekPeriod(user.id, addDays(week.from, -7), addDays(week.to, -7), tz),
      ]);
      if (current.count === 0) {
        result.skipped++; // nothing to say; the week stays claimed
        continue;
      }
      const m = monthWindow(now, tz);
      const budgets = await budgetQueries.budgetStatuses(user.id, m.fromUtc, m.toUtc);
      const summary = buildWeeklySummary({ week, current, previous, budgets, month: m.label });
      await mailer.sendWeeklySummaryEmail(user.email, user.firstName, summary);
      result.sent++;
    } catch (err) {
      // Give the week back, so the next check retries.
      await prisma.$executeRaw`
        UPDATE nexus_users SET "weeklySummarySentWeek" = ${old}
         WHERE id = ${user.id} AND "weeklySummarySentWeek" = ${week.key}
      `.catch(() => {});
      result.failed++;
      console.error(`[weekly] user=${user.id} failed`, err.message);
    }
  }
  return result;
}

/**
 * Check for due weekly emails 60 s after boot and then every 15 minutes,
 * unless WEEKLY_SUMMARY=off. Runs never overlap; errors are only logged.
 * Returns true when the job was started.
 */
function startWeeklyJob() {
  if (process.env.WEEKLY_SUMMARY === 'off') return false;
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const r = await runWeeklySummaries();
      if (r.sent || r.failed) console.log(`[weekly] sent=${r.sent} skipped=${r.skipped} failed=${r.failed}`);
    } catch (err) {
      console.error('[weekly] run failed', err.message);
    } finally {
      running = false;
    }
  };
  setTimeout(tick, FIRST_RUN_MS).unref();
  setInterval(tick, EVERY_MS).unref();
  return true;
}

module.exports = { runWeeklySummaries, startWeeklyJob };
