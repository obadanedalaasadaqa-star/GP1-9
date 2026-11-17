const prisma = require('./prisma');

// Email rules for register, login and PATCH /api/user/me. New addresses are
// stored trimmed and lowercased. Older rows keep the case they were typed
// with, so lookups try the exact form first and then a case-insensitive match.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_EMAIL = 254;

// Trimmed lowercase string, or '' for anything that is not a string.
const normalizeEmail = (v) => (typeof v === 'string' ? v.trim().toLowerCase() : '');

// Message for a normalized email that may not be saved, otherwise null.
function emailError(normalized) {
  if (!normalized || normalized.length > MAX_EMAIL || !EMAIL_RE.test(normalized)) {
    return 'Enter a valid email.';
  }
  return null;
}

/**
 * The user for a typed email, or null. The exact (trimmed) form first, which
 * is today's lookup, then a case-insensitive match that must be unique: two
 * rows that differ only in case are ambiguous, so neither matches.
 * Raw SQL with lower() (not Prisma's insensitive mode) so _ and % are never
 * LIKE wildcards. Login never applies the format check.
 */
async function findUserByEmail(raw) {
  const trimmed = typeof raw === 'string' ? raw.trim() : '';
  if (!trimmed) return null;
  const exact = await prisma.user.findUnique({ where: { email: trimmed } });
  if (exact) return exact;
  const rows = await prisma.$queryRaw`
    SELECT id FROM nexus_users WHERE lower(email) = ${trimmed.toLowerCase()} LIMIT 2`;
  if (rows.length !== 1) return null;
  return prisma.user.findUnique({ where: { id: rows[0].id } });
}

// True if another account already uses [normalized] in any letter case.
async function emailTaken(normalized, exceptUserId) {
  const rows = await prisma.$queryRaw`
    SELECT 1 FROM nexus_users
     WHERE lower(email) = ${normalized} AND id <> ${exceptUserId ?? ''} LIMIT 1`;
  return rows.length > 0;
}

module.exports = { EMAIL_RE, MAX_EMAIL, normalizeEmail, emailError, findUserByEmail, emailTaken };
