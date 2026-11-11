// Daily AI caps and token counts per user (table nexus_ai_usage, UTC day).
// prisma is used through the shared object at call time, so tests can spy on it.
const prisma = require('./prisma');

// kind only ever comes from these constants, never from a request.
const KINDS = Object.freeze({ chat: 'chat', report: 'report', reportEmail: 'report_email' });
const VALID = new Set(Object.values(KINDS));

/**
 * Take one slot of today's cap. Returns the slots left after this one, or
 * null when the cap is already reached. One atomic statement, so two parallel
 * requests can never both take the last slot. A row created earlier by
 * recordTokens (count 0) is counted from 0.
 */
async function takeQuota(userId, kind, cap) {
  if (!VALID.has(kind)) throw new Error('bad usage kind');
  const rows = await prisma.$queryRaw`
    INSERT INTO nexus_ai_usage ("userId", day, kind, count)
    VALUES (${userId}, (NOW() AT TIME ZONE 'UTC')::date, ${kind}, 1)
    ON CONFLICT ("userId", day, kind)
    DO UPDATE SET count = nexus_ai_usage.count + 1
    WHERE nexus_ai_usage.count < ${cap}::int
    RETURNING count`;
  return rows.length ? cap - Number(rows[0].count) : null;
}

/**
 * Add the tokens of a request ({ input, output } or null) to today's row.
 * An upsert, so a request that crossed UTC midnight still records its tokens
 * without using a slot. Best effort: errors (a bad kind included) are logged,
 * never thrown.
 */
async function recordTokens(userId, kind, usage) {
  try {
    if (!VALID.has(kind)) throw new Error('bad usage kind');
    const input = Math.max(0, Math.round(usage?.input ?? 0));
    const output = Math.max(0, Math.round(usage?.output ?? 0));
    if (!usage || (input === 0 && output === 0)) return;
    await prisma.$executeRaw`
      INSERT INTO nexus_ai_usage ("userId", day, kind, count, "inputTokens", "outputTokens")
      VALUES (${userId}, (NOW() AT TIME ZONE 'UTC')::date, ${kind}, 0, ${input}::int, ${output}::int)
      ON CONFLICT ("userId", day, kind)
      DO UPDATE SET "inputTokens"  = nexus_ai_usage."inputTokens"  + EXCLUDED."inputTokens",
                    "outputTokens" = nexus_ai_usage."outputTokens" + EXCLUDED."outputTokens"`;
  } catch (err) {
    console.error('[ai/usage]', err.message);
  }
}

module.exports = { KINDS, takeQuota, recordTokens };
