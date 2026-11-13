const { normalizeJordanPhone } = require('../../src/lib/phone');

describe('normalizeJordanPhone', () => {
  test.each([
    '0791234567',
    '791234567',
    '+962791234567',
    '00962791234567',
    '962791234567',
    '00962 79 123 4567',
    '079-123-4567',
    '(079) 123 4567',
  ])('accepts %s', (input) => {
    expect(normalizeJordanPhone(input)).toBe('+962791234567');
  });

  test('accepts 077 and 078', () => {
    expect(normalizeJordanPhone('0771234567')).toBe('+962771234567');
    expect(normalizeJordanPhone('0781234567')).toBe('+962781234567');
  });

  test.each([
    ['076 prefix', '0761234567'],
    ['too short',  '079123456'],
    ['too long',   '07912345678'],
    ['letters',    '079123456a'],
    ['empty',      ''],
  ])('rejects %s', (_label, input) => {
    expect(normalizeJordanPhone(input)).toBeNull();
  });

  test('rejects non-strings', () => {
    expect(normalizeJordanPhone(791234567)).toBeNull();
    expect(normalizeJordanPhone(null)).toBeNull();
  });
});
