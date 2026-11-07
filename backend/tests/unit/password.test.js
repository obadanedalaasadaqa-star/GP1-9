const { passwordError } = require('../../src/lib/password');

describe('passwordError', () => {
  test('accepts a password that meets every rule', () => {
    expect(passwordError('Nexus@2026')).toBeNull();
  });

  test.each([
    ['Ne@1abc',     'at least 8 characters'],
    ['nexus@2026',  'an uppercase letter'],
    ['NEXUS@2026',  'a lowercase letter'],
    ['Nexus@abcd',  'a number'],
    ['Nexus2026',   'a special character'],
  ])('rejects %s (missing %s)', (pw, rule) => {
    expect(passwordError(pw)).toBe(`Password must contain ${rule}.`);
  });

  test('lists several missing rules', () => {
    expect(passwordError('abc')).toBe(
      'Password must contain at least 8 characters, an uppercase letter, a number and a special character.'
    );
  });

  test('rejects non-strings', () => {
    expect(passwordError(undefined)).toBe('Password is required.');
    expect(passwordError(12345678)).toBe('Password is required.');
  });
});
