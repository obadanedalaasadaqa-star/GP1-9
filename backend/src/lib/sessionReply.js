const { signSession, signChallenge, CHALLENGE_TTL_SECONDS } = require('./token');
const { isLoginTwoFactorAllowed } = require('./loginTwoFactor');

// The user fields every auth route returns (never the hash or internal columns).
const SAFE_USER_SELECT = {
  id: true,
  email: true,
  name: true,
  firstName: true,
  lastName: true,
  emailVerified: true,
  serialNumber: true,
  loyaltyPoints: true,
  createdAt: true,
  budgetAlertEmails: true,
  weeklySummaryEmails: true,
  loginTwoFactor: true,
  passwordSet: true,
};

// Only the SAFE_USER_SELECT fields of a full user row.
const safeUserOf = (user) => Object.fromEntries(Object.keys(SAFE_USER_SELECT).map((k) => [k, user[k]]));

/**
 * The one sign-in answer for /login, /reset-password and /google, so the
 * two-step rule can't drift between them. [user] is the full row as read
 * (it needs password, tokenVersion and loginTwoFactor). A 2FA user gets a
 * 10-minute challenge signed with the row's current hash; everyone else a
 * session token and the safe user.
 */
function sessionOrChallenge(user) {
  if (user.loginTwoFactor && isLoginTwoFactorAllowed()) {
    return {
      twoFactorRequired: true,
      challengeToken: signChallenge(user),
      method: 'email',
      expiresInSeconds: CHALLENGE_TTL_SECONDS,
    };
  }
  return { token: signSession(user.id, user.tokenVersion), user: safeUserOf(user) };
}

module.exports = { SAFE_USER_SELECT, safeUserOf, sessionOrChallenge };
