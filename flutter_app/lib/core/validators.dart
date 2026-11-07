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
