// lib/email.js and lib/names.js: the pure rules (no server, no DB).
const { normalizeEmail, emailError, MAX_EMAIL } = require('../../src/lib/email');
const { cleanName, nameError, MAX_NAME } = require('../../src/lib/names');

describe('normalizeEmail', () => {
  test('trims and lowercases', () => {
    expect(normalizeEmail('  Test_X@Nexus.Test ')).toBe('test_x@nexus.test');
  });
  test.each([[undefined], [null], [42], [{}], [['a@b.c']]])('%p gives ""', (v) => {
    expect(normalizeEmail(v)).toBe('');
  });
});

describe('emailError', () => {
  test('a normal address is fine', () => {
    expect(emailError('sara@nexus.test')).toBeNull();
  });
  test.each([
    ['empty', ''],
    ['no dot after @', 'a@b'],
    ['no @', 'nexus.test'],
    ['a space', 'sa ra@nexus.test'],
    ['two @', 'a@b@c.d'],
    ['too long', `${'a'.repeat(MAX_EMAIL - 'b.c'.length)}@b.c`],
  ])('%s gives "Enter a valid email."', (_label, v) => {
    expect(emailError(v)).toBe('Enter a valid email.');
  });
  test('exactly 254 characters is fine', () => {
    const v = `${'a'.repeat(MAX_EMAIL - '@b.c'.length)}@b.c`;
    expect(v).toHaveLength(254);
    expect(emailError(v)).toBeNull();
  });
});

describe('cleanName', () => {
  test('control characters and line separators become one space; URL text stays', () => {
    expect(cleanName(' Sa\nra\t Ali  http://x \u0007 ')).toBe('Sa ra Ali http://x');
  });
  test('C1 controls are removed too', () => {
    expect(cleanName('A\u0085B\u009fC')).toBe('A B C');
  });
  test.each([[undefined], [null], [5]])('%p gives ""', (v) => {
    expect(cleanName(v)).toBe('');
  });
});

describe('nameError', () => {
  test('both present and short: null', () => {
    expect(nameError('Sara', 'Ali')).toBeNull();
  });
  test('a missing name', () => {
    expect(nameError('', 'Ali')).toBe('First and last name are required.');
    expect(nameError('Sara', '')).toBe('First and last name are required.');
  });
  test('50 code points is fine, 51 is not (emoji count as one)', () => {
    expect(nameError('😀'.repeat(MAX_NAME), 'Ali')).toBeNull();
    expect(nameError('😀'.repeat(MAX_NAME + 1), 'Ali')).toBe('First and last name must be at most 50 characters.');
    expect(nameError('Sara', 'x'.repeat(51))).toBe('First and last name must be at most 50 characters.');
  });
});
