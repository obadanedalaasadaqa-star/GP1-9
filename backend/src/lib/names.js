// First and last name rules for register and PATCH /api/user/me. Names end up
// in emails, so control characters and line breaks never get stored.
const MAX_NAME = 50;

// Every C0/C1 control character plus U+2028/U+2029 (line/paragraph separator).
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;

// Control characters become spaces, runs of whitespace one space, then trim.
// '' for anything that is not a string.
function cleanName(v) {
  if (typeof v !== 'string') return '';
  return v.replace(CONTROL, ' ').replace(/\s+/g, ' ').trim();
}

// Message for cleaned names that may not be saved, otherwise null. Length is
// counted in code points, like the app (runes).
function nameError(first, last) {
  if (!first || !last) return 'First and last name are required.';
  if ([...first].length > MAX_NAME || [...last].length > MAX_NAME) {
    return `First and last name must be at most ${MAX_NAME} characters.`;
  }
  return null;
}

module.exports = { MAX_NAME, cleanName, nameError };
