const {
  looseEmailError, codeError, isResetEligible, padTo, errTag, EMAIL_INVALID, CODE_INVALID,
} = require('../../src/lib/passwordReset');

describe('looseEmailError', () => {
  test.each(['a@b', 'sara@nexus.test', '  Sara@Nexus.Test  ', `${'a'.repeat(250)}@b.c`])(
    '%s is accepted', (email) => expect(looseEmailError(email)).toBeNull());

  test.each([
    ['empty', ''], ['spaces', '   '], ['no @', 'sara.nexus.test'], ['a number', 123],
    ['an array', ['a@b']], ['null', null], ['undefined', undefined], ['255 characters', `${'a'.repeat(251)}@b.c`],
  ])('%s is refused', (_name, email) => expect(looseEmailError(email)).toBe(EMAIL_INVALID));
});

describe('codeError', () => {
  test.each(['123456', ' 123456 ', 123456, '000000'])('%p is accepted', (code) => expect(codeError(code)).toBeNull());
  test.each(['12345', '1234567', 'abcdef', ['123456'], 1234567, null, undefined, {}])(
    '%p is refused', (code) => expect(codeError(code)).toBe(CODE_INVALID));
});

test('isResetEligible is true for every account (Q2)', () => {
  expect(isResetEligible({ emailVerified: false })).toBe(true);
  expect(isResetEligible({ emailVerified: true, loginTwoFactor: true })).toBe(true);
});

describe('padTo', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  test('waits for the rest of the floor', async () => {
    const started = Date.now();
    let done = false;
    padTo(started, 700).then(() => { done = true; });
    await jest.advanceTimersByTimeAsync(699);
    expect(done).toBe(false);
    await jest.advanceTimersByTimeAsync(1);
    expect(done).toBe(true);
  });

  test('resolves at once when the floor has already passed', async () => {
    let done = false;
    padTo(Date.now() - 1000, 700).then(() => { done = true; });
    await Promise.resolve();
    expect(done).toBe(true);
  });
});

test('errTag never returns the message', () => {
  const err = Object.assign(new Error('x@nexus.test rejected'), { code: 'MAIL_FAIL' });
  expect(errTag(err)).toBe('MAIL_FAIL');
  expect(errTag(new TypeError('a@b'))).toBe('TypeError');
  expect(errTag({ status: 502 })).toBe(502);
  expect(errTag(undefined)).toBe('Error');
});
