// Shared helpers for the AI features (insight, chat, report). Pure, no DB.
const crypto = require('crypto');

/**
 * A JD amount as text, the JS twin of the app's formatJd(): rounds to whole
 * fils first, then to 2 decimals, half away from zero. 1.205 -> "1.21".
 * Every amount sent to Claude goes through this, so the model sees exactly
 * the strings the app prints.
 */
function formatAmount(n) {
  const v = Number(n) || 0;
  const roundAway = (x) => Math.sign(x) * Math.round(Math.abs(x));
  const fils = roundAway(v * 1000);   // e.g. 1205
  const q = roundAway(fils / 10);     // x.5 is exact here
  return (q / 100).toFixed(2);
}

/**
 * Change from previous to current: "new" (from 0), "none" (both 0),
 * "+12%", "-8%" or "0%". Whole numbers, rounded like trends.dart (the
 * absolute value is rounded and the sign kept). ASCII minus, for the guard.
 */
function formatChange(current, previous) {
  if (!previous) return current ? 'new' : 'none';
  const pct = ((current - previous) / previous) * 100;
  const n = Math.round(Math.abs(pct));
  if (n === 0) return '0%';
  return pct > 0 ? `+${n}%` : `-${n}%`;
}

/**
 * A store/category/item name safe to put in a prompt: control characters
 * become spaces, whitespace collapses, cut to [max] code points.
 */
function cleanLabel(s, max = 40) {
  const flat = String(s ?? '')
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return [...flat].slice(0, max).join('').trim();
}

// ── Number guard ───────────────────────────────────────────────────────────

const ARABIC_DIGITS = /[٠-٩۰-۹]/;
const THOUSANDS = /(\d),(?=\d{3}\b)/g;
const SOURCE_NUM = /\d+(?:\.\d+)?/g;
// Dates and times inside the sources: ISO dates/months/instants
// ("2026-11-11", "2026-11", "2026-11-04T21:30:00.000Z"), clock times
// ("21:30") and written dates ("5 Nov 2026", "1 – 11 Nov 2026",
// "November 2026", "Nov 5"). Their digits are not amounts, so they are
// taken out before amounts are matched and only allowed as bare numbers.
const MONTH_NAME = '(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?';
const SOURCE_DATE = new RegExp([
  '(?<![\\d.])\\b\\d{4}-\\d{2}(?:-\\d{2}(?:T\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?(?:Z|[+-]\\d{2}:?\\d{2})?)?)?\\b',
  '(?<![\\d.])\\b\\d{1,2}:\\d{2}(?::\\d{2})?\\b',
  `(?<![\\d.])\\b\\d{1,2}(?:\\s*[–—-]\\s*\\d{1,2})?\\s+${MONTH_NAME}(?:\\s+\\d{4})?`,
  `\\b${MONTH_NAME}\\s+\\d{1,4}\\b`,
].join('|'), 'g');
// Group 1: a unit before, group 2: the number, group 3: a unit after.
// With a unit it is an amount (must match a source number), else a bare number.
const NUM_RE = /(\bJODs?\s*|\bJDs?\s*)?(\d+(?:\.\d+)?)(\s*(?:%|percent\b|per\s+cent\b|JODs?\b|JDs?\b|(?:jordanian\s+)?dinars?\b|fils\b))?/gi;

/**
 * The correctness guard: true when every number in [text] is allowed.
 * - Amounts (next to JD, JOD, dinar(s), fils, %, percent) must equal a number
 *   found in [sources] (within 0.0005). No exemptions.
 * - Bare numbers pass if they equal a source number (a date part counts
 *   here, e.g. 11 from "2026-11-11"), are whole numbers from 0 to smallMax
 *   (counts, days), or with [years] whole numbers 2000..2100.
 * - Arabic-Indic digits always fail.
 */
function numbersOk(text, sources, { smallMax = 12, years = false } = {}) {
  const body = String(text ?? '');
  if (ARABIC_DIGITS.test(body)) return false;

  const known = [];     // numbers an amount may equal
  const dateParts = []; // digits of dates/times: bare numbers only
  for (const src of sources ?? []) {
    const flat = String(src ?? '').replace(SOURCE_DATE, (d) => {
      for (const m of d.matchAll(SOURCE_NUM)) dateParts.push(Number(m[0]));
      return ' ';
    }).replace(THOUSANDS, '$1');
    for (const m of flat.matchAll(SOURCE_NUM)) known.push(Number(m[0]));
  }
  const near = (list, n) => list.some((k) => Math.abs(k - n) < 0.0005);
  const isKnown = (n) => near(known, n);

  for (const m of body.replace(THOUSANDS, '$1').matchAll(NUM_RE)) {
    const n = Number(m[2]);
    if (m[1] || m[3]) {
      if (!isKnown(n)) return false;
      continue;
    }
    if (isKnown(n) || near(dateParts, n)) continue;
    if (Number.isInteger(n) && n >= 0 && n <= smallMax) continue;
    if (years && Number.isInteger(n) && n >= 2000 && n <= 2100) continue;
    return false;
  }
  return true;
}

// ── Cache keys and token counts ────────────────────────────────────────────

// Bump a kind's number whenever its system prompt or schema changes, so saved
// texts are written again once.
const PROMPT_VERSIONS = Object.freeze({ insight: 1, chat: 1, report: 1 });

// SHA-256 of what decides the AI text: prompt version, kind, model and facts.
function factsHash(facts, model, kind, versions = PROMPT_VERSIONS) {
  return crypto.createHash('sha256')
    .update(JSON.stringify({ v: versions[kind], kind, model, facts }))
    .digest('hex');
}

/**
 * Add one SDK `usage` to a running { input, output, cacheRead } total and
 * return the total. Cache reads/writes count as input. Missing fields add 0.
 */
function addUsage(total, sdkUsage) {
  if (!sdkUsage) return total;
  const read = sdkUsage.cache_read_input_tokens ?? 0;
  const write = sdkUsage.cache_creation_input_tokens ?? 0;
  total.input += (sdkUsage.input_tokens ?? 0) + read + write;
  total.output += sdkUsage.output_tokens ?? 0;
  total.cacheRead += read;
  return total;
}

/**
 * Everything our own checks reject (refusal, max_tokens, no_text, bad_json,
 * bad_fields, invented_number, too_many_steps, deadline, bad_stop).
 * usage: the tokens already paid for, so the route can record them.
 */
class AiError extends Error {
  constructor(reason, usage = null) {
    super(reason);
    this.name = 'AiError';
    this.reason = reason;
    this.usage = usage;
  }
}

/**
 * Text blocks of a response joined, read by block type (Haiku 5.5 answers
 * can start with thinking blocks, so never content[0]).
 */
function responseText(response) {
  return (response?.content ?? [])
    .filter((b) => b && b.type === 'text')
    .map((b) => b.text)
    .join('\n')
    .trim();
}

module.exports = {
  formatAmount, formatChange, cleanLabel, numbersOk,
  PROMPT_VERSIONS, factsHash, addUsage, AiError, responseText,
};
