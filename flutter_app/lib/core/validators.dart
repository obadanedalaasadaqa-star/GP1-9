// Jordanian mobile numbers: 077 / 078 / 079 + 7 digits.
// Mirrors normalizeJordanPhone() in backend/src/lib/phone.js.
bool isValidJordanPhone(String input) {
  var digits = input.replaceAll(RegExp(r'[\s\-()]'), '');
  if (digits.startsWith('+962')) {
    digits = digits.substring(4);
  } else if (digits.startsWith('00962')) {
    digits = digits.substring(5);
  } else if (digits.startsWith('962')) {
    digits = digits.substring(3);
  }
  if (digits.startsWith('0')) digits = digits.substring(1);
  return RegExp(r'^7[789]\d{7}$').hasMatch(digits);
}

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
