const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const prisma = require('./prisma');
const { findUserByEmail, emailTaken } = require('./email');
const { cleanName, MAX_NAME } = require('./names');
const { generateSerial } = require('./serial');

// Which Nexus account a verified outside identity (Google) signs in to.
// claims come from lib/idToken.js: { subject, email (normalized),
// emailVerified, trustedEmail, givenName, familyName }.
//
//   L0  The provider's email must be verified, or nothing is looked up.
//   L1  A known identity (provider, subject) → its user. Looked up first and
//       only by subject; the Google email never picks the account here.
//   L2  No identity, but an account has that email (findUserByEmail, exact
//       apart from case; no Gmail dot or +tag folding):
//         - it already has another identity of this provider → other_google;
//         - its email is verified AND the Google email is trusted → link;
//         - otherwise the account's password is needed once to link.
//   L3  "Trusted" = a Gmail address or a Workspace account (hd).
//   L4  No identity, no account → a new account (verified email, no password),
//       unless rows that differ only in letter case already use the address
//       (email_taken, as /register).
//
// Returns { user, created, linked } with the full user row as read after the
// link, or { refuse: 'email_unverified' | 'other_google' | 'password_required'
// | 'wrong_password' | 'email_taken' }. password only matters in L2's password
// branch; it is compared with bcrypt and never written, validated or logged.

// First 50 code points of a cleaned name ('' if none).
const nameOrEmpty = (v) => [...cleanName(v)].slice(0, MAX_NAME).join('');

// Thrown when the account changed (a password reset) between the L2 read and
// the link: findOrLinkOrCreate runs the rules again on the fresh row.
class LinkStale extends Error {}

// One transaction that first locks the user row, but only if its password
// hash and tokenVersion are still the ones L2 read (and, on the password path,
// compared). A reset that commits first makes the count 0, so nothing is
// linked; a reset that arrives later waits for the lock, then its
// authIdentity.deleteMany removes this link (S15: the reset always wins).
async function linkIdentity(provider, claims, user, { markVerified }) {
  return prisma.$transaction(async (tx) => {
    const { count } = await tx.user.updateMany({
      where: { id: user.id, password: user.password, tokenVersion: user.tokenVersion },
      // Rewriting tokenVersion with its own value only takes the row lock.
      data: markVerified ? { emailVerified: true } : { tokenVersion: user.tokenVersion },
    });
    if (count !== 1) throw new LinkStale();
    await tx.authIdentity.create({
      data: { userId: user.id, provider, subject: claims.subject, email: claims.email },
    });
    return tx.user.findUnique({ where: { id: user.id } });
  }, { maxWait: 10_000, timeout: 15_000 });
}

async function createAccount(provider, claims) {
  const firstName = nameOrEmpty(claims.givenName) || 'Nexus';
  const lastName = nameOrEmpty(claims.familyName) || 'member';
  // A hash of random bytes nobody ever sees: no password can match it.
  const password = await bcrypt.hash(crypto.randomBytes(32).toString('hex'), 12);
  // One statement with a nested create, so the user and its identity are
  // written in one transaction.
  return prisma.user.create({
    data: {
      email: claims.email,
      password,
      passwordSet: false,
      emailVerified: true,
      firstName,
      lastName,
      name: `${firstName} ${lastName}`,
      serialNumber: generateSerial(),
      identities: { create: { provider, subject: claims.subject, email: claims.email } },
    },
  });
}

async function applyRules(provider, claims, password) {
  // L0
  if (claims.emailVerified !== true) return { refuse: 'email_unverified' };

  // L1. The user is found through the link in one statement, so Postgres
  // sees both from the same snapshot: either before a password reset (the
  // old tokenVersion, so the session dies with the reset) or after it (no
  // link, so this falls through to L2). Two reads left a gap between them.
  const known = await prisma.user.findFirst({
    where: { identities: { some: { provider, subject: claims.subject } } },
  });
  if (known) {
    // updateMany: a link a reset just deleted is a no-op, not a P2025 500.
    await prisma.authIdentity.updateMany({
      where: { provider, subject: claims.subject }, data: { lastUsedAt: new Date() },
    });
    return { user: known, created: false, linked: false };
  }

  // L2
  const existing = await findUserByEmail(claims.email);
  if (existing) {
    const other = await prisma.authIdentity.findUnique({
      where: { userId_provider: { userId: existing.id, provider } },
    });
    // The same subject: a parallel first sign-in linked or created it a
    // moment ago, so this is L1 after all.
    if (other && other.subject === claims.subject) return { user: existing, created: false, linked: false };
    if (other) return { refuse: 'other_google' };

    if (existing.emailVerified === true && claims.trustedEmail === true) {
      const user = await linkIdentity(provider, claims, existing, { markVerified: false });
      return { user, created: false, linked: true };
    }

    if (typeof password !== 'string') return { refuse: 'password_required' };
    if (!(await bcrypt.compare(password, existing.password))) return { refuse: 'wrong_password' };
    // The email is marked verified only on strong proof (a trusted address).
    const markVerified = claims.trustedEmail === true && existing.emailVerified !== true;
    const user = await linkIdentity(provider, claims, existing, { markVerified });
    return { user, created: false, linked: true };
  }

  // L4. findUserByEmail finds nothing when two older rows differ only in
  // letter case; /register refuses such an address too (emailTaken).
  if (await emailTaken(claims.email)) return { refuse: 'email_taken' };
  const user = await createAccount(provider, claims);
  return { user, created: true, linked: false };
}

async function findOrLinkOrCreate(provider, claims, { password } = {}) {
  try {
    return await applyRules(provider, claims, password);
  } catch (err) {
    // Two first sign-ins at once (same subject or same email): the second
    // finds the first one's rows on the next pass (L1 or L2). After a reset
    // during the link, the next pass compares against the new hash.
    if (err?.code !== 'P2002' && !(err instanceof LinkStale)) throw err;
    return applyRules(provider, claims, password);
  }
}

module.exports = { findOrLinkOrCreate };
