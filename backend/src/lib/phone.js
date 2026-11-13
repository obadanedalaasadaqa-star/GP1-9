// Jordanian mobile numbers: 077 / 078 / 079 + 7 digits.
// Accepts "0791234567", "791234567", "+962791234567", "00962 79 123 4567".
// Returns the normalized "+962791234567", or null if the number is invalid.
function normalizeJordanPhone(input) {
  if (typeof input !== 'string') return null;
  let digits = input.replace(/[\s\-()]/g, '');
  if (digits.startsWith('+962')) digits = digits.slice(4);
  else if (digits.startsWith('00962')) digits = digits.slice(5);
  else if (digits.startsWith('962')) digits = digits.slice(3);
  if (digits.startsWith('0')) digits = digits.slice(1);
  return /^7[789]\d{7}$/.test(digits) ? `+962${digits}` : null;
}

module.exports = { normalizeJordanPhone };
