// ── Passwords ────────────────────────────────────────────────────────────────
// Mirrors backend/src/lib/password.js.

class PasswordRule {
  final String label;
  final bool Function(String) test;
  const PasswordRule(this.label, this.test);
}

final passwordRules = <PasswordRule>[
  PasswordRule('At least 8 characters', (p) => p.length >= 8),
  PasswordRule('An uppercase letter (A–Z)', (p) => p.contains(RegExp(r'[A-Z]'))),
  PasswordRule('A lowercase letter (a–z)', (p) => p.contains(RegExp(r'[a-z]'))),
  PasswordRule('A number (0–9)', (p) => p.contains(RegExp(r'[0-9]'))),
  PasswordRule('A special character (!@#\$…)', (p) => p.contains(RegExp(r'[^A-Za-z0-9]'))),
];

bool isValidPassword(String p) => passwordRules.every((r) => r.test(p));

enum PasswordStrength { weak, fair, good, strong }

/// weak: 0–2 rules met · fair: 3–4 · good: all 5 · strong: all 5 and 12+ chars
PasswordStrength passwordStrength(String p) {
  final met = passwordRules.where((r) => r.test(p)).length;
  if (met == passwordRules.length) {
    return p.length >= 12 ? PasswordStrength.strong : PasswordStrength.good;
  }
  return met >= 3 ? PasswordStrength.fair : PasswordStrength.weak;
}

/// Form validator for a new password.
String? validateNewPassword(String? v) {
  if (v == null || v.isEmpty) return 'Password is required';
  return isValidPassword(v) ? null : 'Password does not meet all the requirements';
}

// ── Email and names ──────────────────────────────────────────────────────────
// Mirror backend/src/lib/email.js and names.js.

final emailRegExp = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
const maxEmailLength = 254;
const maxNameLength = 50;

/// Form validator for a new email (register, or a changed email on Profile).
/// Sign-in keeps the looser check, so older accounts can always log in.
String? validateEmail(String? v) {
  final email = v?.trim() ?? '';
  if (email.isEmpty) return 'Email is required';
  if (email.length > maxEmailLength || !emailRegExp.hasMatch(email)) {
    return 'Enter a valid email';
  }
  return null;
}

/// Form validator for a first or last name: required, at most 50 characters
/// (counted like the server, in code points).
String? validateName(String? v, String label) {
  final name = v?.trim() ?? '';
  if (name.isEmpty) return 'Required';
  if (name.runes.length > maxNameLength) return '$label: at most $maxNameLength characters';
  return null;
}
