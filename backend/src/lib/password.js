// Password rules for new passwords (register + change password).
// Mirrors passwordRules in flutter_app/lib/core/validators.dart.
const RULES = [
  { test: (p) => p.length >= 8,          text: 'at least 8 characters' },
  { test: (p) => /[A-Z]/.test(p),        text: 'an uppercase letter' },
  { test: (p) => /[a-z]/.test(p),        text: 'a lowercase letter' },
  { test: (p) => /[0-9]/.test(p),        text: 'a number' },
  { test: (p) => /[^A-Za-z0-9]/.test(p), text: 'a special character' },
];

// Returns an error message listing every unmet rule, or null if the password is valid.
function passwordError(password) {
  if (typeof password !== 'string') return 'Password is required.';
  const missing = RULES.filter((r) => !r.test(password)).map((r) => r.text);
  if (missing.length === 0) return null;
  const list = missing.length === 1
    ? missing[0]
    : `${missing.slice(0, -1).join(', ')} and ${missing[missing.length - 1]}`;
  return `Password must contain ${list}.`;
}

module.exports = { passwordError };
