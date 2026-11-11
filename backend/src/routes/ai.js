const express = require('express');
const prisma = require('../lib/prisma');
const authMiddleware = require('../middleware/auth');
const mailer = require('../lib/mailer');
const spendingQueries = require('../lib/spendingQueries');
const { parseBounds, shapeStats } = require('../lib/stats');
const { factsHash } = require('../lib/aiFormat');
const { AI_MODEL, aiErrorResponse, generateInsight } = require('../lib/ai');
const { MIN_RECEIPTS, buildFacts } = require('../lib/insight');
const { answerQuestion } = require('../lib/aiChat');
const { KINDS, takeQuota, recordTokens } = require('../lib/aiUsage');
const { parseTz } = require('../lib/aiDates');
const {
  resolvePeriod, buildReportNumbers, buildReportFacts, generateReportText,
  MIN_RECEIPTS: REPORT_MIN_RECEIPTS,
} = require('../lib/report');

const DAY_MS = 24 * 3600 * 1000;
const DEFAULT_AI_CAPS = Object.freeze({ chatPerDay: 30, reportPerDay: 10, emailPerDay: 5 });

const MAX_QUESTION = 500;
const MAX_HISTORY = 10;
const MAX_USER_TEXT = 500;
const MAX_ASSISTANT_TEXT = 1500;
const NO_RECEIPTS_ANSWER = "You don't have any receipts in Nexus yet. Scan your QR code at a store or add a receipt, then ask me again.";
const REPORT_CAP_TEXT = "You've reached today's limit of AI report summaries. The numbers are still up to date.";

// Every chat length limit counts Unicode code points, like the app (runes).
const len = (s) => [...s].length;
const ageMs = (date) => Date.now() - new Date(date).getTime();
const isFresh = (row, hash) => !!row && row.inputHash === hash && ageMs(row.createdAt) < DAY_MS;
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// Chat history: missing, or at most 10 { role, text } items that alternate,
// starting with user and ending with assistant. Returns the list or null.
function parseHistory(raw) {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_HISTORY) return null;
  const out = [];
  for (let i = 0; i < raw.length; i++) {
    const item = raw[i];
    if (!isPlainObject(item)) return null;
    const keys = Object.keys(item);
    if (keys.length !== 2 || !keys.includes('role') || !keys.includes('text')) return null;
    const role = i % 2 === 0 ? 'user' : 'assistant';
    if (item.role !== role || typeof item.text !== 'string') return null;
    const text = item.text.trim();
    const max = role === 'user' ? MAX_USER_TEXT : MAX_ASSISTANT_TEXT;
    if (len(text) < 1 || len(text) > max) return null;
    out.push({ role, text });
  }
  if (out.length > 0 && out[out.length - 1].role !== 'assistant') return null;
  return out;
}

// Router factory: every createApp() gets its own router, limiters and
// in-flight maps. getAiClient() returns the Claude client or null (no key).
module.exports = function aiRoutes(limiters, { getAiClient, caps: capOverrides } = {}) {
  const router = express.Router();
  router.use(authMiddleware);
  const caps = { ...DEFAULT_AI_CAPS, ...(capOverrides ?? {}) };

  // ── GET /api/ai/insight?bounds=… ───────────────────────────────────────
  const insightInFlight = new Map();
  const insightReply = (row, cached) => ({
    status: 'ready', summary: row.summary, tip: row.tip, createdAt: row.createdAt, cached,
  });

  // Answers everything that needs no Claude call (bad bounds, not enough
  // data, a fresh saved insight) before the limiter, so those never count.
  async function insightPrecheck(req, res, next) {
    try {
      const parsed = parseBounds(req.query.bounds);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      const { bounds } = parsed;

      const rows = await spendingQueries.queryStats(req.userId, bounds);
      const { periods } = shapeStats(rows, bounds);
      const receiptCount = periods.reduce((sum, p) => sum + p.count, 0);
      if (receiptCount < MIN_RECEIPTS) {
        return res.json({ status: 'not_enough_data', receiptCount, minReceipts: MIN_RECEIPTS });
      }

      const facts = buildFacts(periods, new Date());
      // From the requested model, never from response.model.
      const hash = factsHash(facts, AI_MODEL(), 'insight');
      const saved = await prisma.aiInsight.findUnique({ where: { userId: req.userId } });
      if (isFresh(saved, hash)) return res.json(insightReply(saved, true));

      res.locals.insight = { facts, hash };
      next();
    } catch (err) {
      console.error('[ai/insight]', err);
      res.status(500).json({ error: 'Failed to load insight.' });
    }
  }

  async function insightHandler(req, res) {
    try {
      const client = getAiClient();
      if (!client) return res.status(503).json({ error: 'AI insights are not set up on this server.' });
      const { facts, hash } = res.locals.insight;
      const userId = req.userId;
      const key = `${userId}:${hash}`;

      // One shared promise per user and numbers. The entry is deleted in the
      // function's own finally, so the only promise is the one awaited below
      // (never a detached "finally" chain on p: that would be an unhandled rejection).
      let p = insightInFlight.get(key);
      if (!p) {
        p = (async () => {
          try {
            // Read again: another request may have saved it after our precheck.
            const saved = await prisma.aiInsight.findUnique({ where: { userId } });
            if (isFresh(saved, hash)) return { row: saved, cached: true };

            const started = Date.now();
            const out = await generateInsight(client, facts);
            console.log(`[ai/insight] generated user=${userId} model=${out.model} ` +
              `in=${out.usage.input} out=${out.usage.output} ${Date.now() - started}ms`);
            const data = {
              inputHash: hash, summary: out.summary, tip: out.tip, model: out.model,
              inputTokens: out.usage.input, outputTokens: out.usage.output, createdAt: new Date(),
            };
            const row = await prisma.aiInsight.upsert({
              where: { userId }, create: { userId, ...data }, update: data,
            });
            return { row, cached: false };
          } finally {
            insightInFlight.delete(key);
          }
        })();
        insightInFlight.set(key, p);
      }
      const { row, cached } = await p;
      res.json(insightReply(row, cached));
    } catch (err) {
      const mapped = aiErrorResponse(err, 'insight');
      if (!mapped) {
        console.error('[ai/insight]', err);
        return res.status(500).json({ error: 'Failed to load insight.' });
      }
      console.log(`[ai/insight] failed user=${req.userId} reason=${mapped.reason}`);
      res.status(mapped.status).json({ error: mapped.error });
    }
  }

  router.get('/insight', insightPrecheck, limiters.aiInsight, insightHandler);

  // ── POST /api/ai/chat ─────────────────────────────────────────────────
  async function chatPrecheck(req, res, next) {
    try {
      const body = isPlainObject(req.body) ? req.body : {};
      const question = typeof body.question === 'string'
        ? body.question.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim()
        : '';
      if (len(question) < 1 || len(question) > MAX_QUESTION) {
        return res.status(400).json({ error: 'Type a question (up to 500 characters).' });
      }
      const history = parseHistory(body.history);
      if (!history) return res.status(400).json({ error: 'Invalid chat history.' });
      const tz = parseTz(body.tzOffsetMinutes);
      if (tz.error) return res.status(400).json({ error: tz.error });

      if (!getAiClient()) return res.status(503).json({ error: 'Ask AI is not set up on this server.' });

      if (await spendingQueries.countReceipts(req.userId) === 0) {
        return res.json({ answer: NO_RECEIPTS_ANSWER, toolsUsed: [], remainingToday: null });
      }
      res.locals.chat = { question, history, tz };
      next();
    } catch (err) {
      console.error('[ai/chat]', err);
      res.status(500).json({ error: 'Failed to answer.' });
    }
  }

  async function chatHandler(req, res) {
    try {
      const client = getAiClient();
      if (!client) return res.status(503).json({ error: 'Ask AI is not set up on this server.' });
      const { question, history, tz } = res.locals.chat;

      const remaining = await takeQuota(req.userId, KINDS.chat, caps.chatPerDay);
      if (remaining === null) {
        return res.status(429).json({ error: `You've reached today's limit of ${caps.chatPerDay} questions. Try again tomorrow.` });
      }

      const started = Date.now();
      let result = null;
      let failure = null;
      try {
        result = await answerQuestion(client, { userId: req.userId, tz, history, question, now: new Date() });
      } catch (err) {
        failure = err;
      }
      // Before replying, success or failure: paid calls always count.
      const info = result ?? failure ?? {};
      await recordTokens(req.userId, KINDS.chat, info.usage);

      const mapped = failure ? aiErrorResponse(failure, 'chat') : null;
      const u = info.usage ?? { input: 0, output: 0, cacheRead: 0 };
      console.log(`[ai/chat] user=${req.userId} calls=${info.calls ?? 0} ` +
        `tools=${(result?.toolsUsed ?? []).join(',') || '-'} in=${u.input} out=${u.output} ` +
        `cacheRead=${u.cacheRead ?? 0} ${Date.now() - started}ms` +
        (failure ? ` reason=${mapped?.reason ?? 'error'}` : result.refused ? ' reason=refusal' : ''));

      if (failure) {
        if (!mapped) {
          console.error('[ai/chat]', failure);
          return res.status(500).json({ error: 'Failed to answer.' });
        }
        return res.status(mapped.status).json({ error: mapped.error });
      }
      res.json({ answer: result.answer, toolsUsed: result.toolsUsed, remainingToday: remaining });
    } catch (err) {
      console.error('[ai/chat]', err);
      res.status(500).json({ error: 'Failed to answer.' });
    }
  }

  router.post('/chat', chatPrecheck, limiters.aiChat, chatHandler);

  // ── Reports (shared by GET /report and POST /report/email) ─────────────
  const reportInFlight = new Map();
  const reportReady = (row, cached) => ({
    status: 'ready', headline: row.headline, narrative: row.narrative,
    tips: row.tips, createdAt: row.createdAt, cached,
  });

  function reportAiError(err) {
    const mapped = aiErrorResponse(err, 'report');
    if (!mapped) {
      console.error('[ai/report]', err);
      return { status: 'unavailable', error: 'Could not write the AI summary this time.' };
    }
    console.log(`[ai/report] failed reason=${mapped.reason}`);
    return { status: 'unavailable', error: mapped.error };
  }

  async function saveReport(userId, rangeKey, hash, out) {
    const data = {
      inputHash: hash, headline: out.headline, narrative: out.narrative, tips: out.tips,
      model: out.model, inputTokens: out.usage.input, outputTokens: out.usage.output, createdAt: new Date(),
    };
    const row = await prisma.aiReport.upsert({
      where: { userId_rangeKey: { userId, rangeKey } },
      create: { userId, rangeKey, ...data },
      update: data,
    });
    try {
      await prisma.$executeRaw`
        DELETE FROM nexus_ai_reports
         WHERE "userId" = ${userId} AND "createdAt" < NOW() - interval '2 days'`;
    } catch (err) {
      console.error('[ai/report] prune', err.message);
    }
    return row;
  }

  // The AI part of a report, shared by parallel identical requests. Only the
  // request that starts it takes a daily slot. Never a detached "finally" chain on p.
  function reportAi(client, userId, r, facts, hash) {
    const key = `${userId}:${r.rangeKey}:${hash}`;
    let p = reportInFlight.get(key);
    if (p) return p;
    p = (async () => {
      try {
        // Read again: another request may have saved it after our first read.
        const saved = await prisma.aiReport.findUnique({ where: { userId_rangeKey: { userId, rangeKey: r.rangeKey } } });
        if (isFresh(saved, hash)) return reportReady(saved, true);
        const left = await takeQuota(userId, KINDS.report, caps.reportPerDay);
        if (left === null) return { status: 'unavailable', error: REPORT_CAP_TEXT };
        let usage = null;
        try {
          const started = Date.now();
          const out = await generateReportText(client, facts);
          usage = out.usage;
          console.log(`[ai/report] generated user=${userId} period=${r.period} model=${out.model} ` +
            `in=${out.usage.input} out=${out.usage.output} ${Date.now() - started}ms`);
          const row = await saveReport(userId, r.rangeKey, hash, out);
          return reportReady(row, false);
        } catch (err) {
          usage = usage ?? err?.usage ?? null;
          return reportAiError(err);
        } finally {
          await recordTokens(userId, KINDS.report, usage); // never throws
        }
      } finally {
        reportInFlight.delete(key);
      }
    })();
    reportInFlight.set(key, p);
    return p;
  }

  // Every number (always) plus the AI part (when possible). With
  // newAi false only a fresh saved AI text is used and Claude is never
  // called (the email path: fast, and no second paid call).
  async function buildReport(userId, r, tz, { newAi = true } = {}) {
    const numbers = await buildReportNumbers(userId, r, tz);
    const facts = buildReportFacts(numbers, { soFar: r.soFar, tz });
    const hash = factsHash(facts, AI_MODEL(), 'report');
    let ai;
    if (numbers.totals.receipts < REPORT_MIN_RECEIPTS) {
      ai = { status: 'not_enough_data', receiptCount: numbers.totals.receipts, minReceipts: REPORT_MIN_RECEIPTS };
    } else {
      const saved = await prisma.aiReport.findUnique({ where: { userId_rangeKey: { userId, rangeKey: r.rangeKey } } });
      const client = getAiClient();
      if (isFresh(saved, hash)) ai = reportReady(saved, true);
      else if (!client) ai = { status: 'unavailable', error: 'AI summary is not set up on this server.' };
      else if (!newAi) ai = { status: 'unavailable', error: 'AI summary is not available right now.' };
      else ai = await reportAi(client, userId, r, facts, hash);
    }
    return { ...numbers, ai };
  }

  // { r, tz } or { error } for report params (query or body).
  function reportParams(src) {
    const params = isPlainObject(src) ? src : {};
    const tz = parseTz(params.tzOffsetMinutes);
    if (tz.error) return { error: tz.error };
    const r = resolvePeriod(params, new Date(), tz);
    if (r.error) return { error: r.error };
    return { r, tz };
  }

  // ── GET /api/ai/report?period=… ───────────────────────────────────────
  async function reportHandler(req, res) {
    try {
      const parsed = reportParams(req.query);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      res.json(await buildReport(req.userId, parsed.r, parsed.tz));
    } catch (err) {
      console.error('[ai/report]', err);
      res.status(500).json({ error: 'Failed to build report.' });
    }
  }

  router.get('/report', limiters.aiReport, reportHandler);

  // ── POST /api/ai/report/email ─────────────────────────────────────────
  // Validation and the verified check before the limiter; no quota here.
  async function emailPrecheck(req, res, next) {
    try {
      const parsed = reportParams(req.body);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      const user = await prisma.user.findUnique({
        where: { id: req.userId },
        select: { firstName: true, email: true, emailVerified: true },
      });
      if (!user) return res.status(404).json({ error: 'User not found.' });
      if (!user.emailVerified) {
        return res.status(403).json({ error: 'Verify your email first to get reports by email.' });
      }
      res.locals.email = { user, ...parsed };
      next();
    } catch (err) {
      console.error('[ai/report-email]', err);
      res.status(500).json({ error: 'Failed to send the report.' });
    }
  }

  async function emailHandler(req, res) {
    try {
      // First step: a request the burst limiter rejected never gets here.
      const left = await takeQuota(req.userId, KINDS.reportEmail, caps.emailPerDay);
      if (left === null) {
        return res.status(429).json({ error: `You've reached today's limit of ${caps.emailPerDay} report emails. Try again tomorrow.` });
      }
      const { user, r, tz } = res.locals.email;
      // Reuses the AI text the user saw in the app; never a new Claude call.
      const report = await buildReport(req.userId, r, tz, { newAi: false });
      try {
        await mailer.sendReportEmail(user.email, user.firstName, report, tz);
      } catch (err) {
        console.error('[mail] report email failed:', err.message);
        return res.status(502).json({ error: 'Could not send the email. Try again later.' });
      }
      console.log(`[ai/report-email] sent user=${req.userId} period=${r.period}`);
      res.json({ message: `Report sent to ${user.email}.` });
    } catch (err) {
      console.error('[ai/report-email]', err);
      res.status(500).json({ error: 'Failed to send the report.' });
    }
  }

  router.post('/report/email', emailPrecheck, limiters.aiReportEmail, emailHandler);

  return router;
};

module.exports.DEFAULT_AI_CAPS = DEFAULT_AI_CAPS;
