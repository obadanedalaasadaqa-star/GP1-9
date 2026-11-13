// Pure helpers of lib/verification.js (no DB). The integration tests for
// email codes are in tests/verification.test.js.
const { channelOf, isTwilioRow, twilioSid, activeCodeProblem, MAX_ATTEMPTS } =
  require('../../src/lib/verification');

const future = () => new Date(Date.now() + 60_000);

describe('isTwilioRow / twilioSid', () => {
  test('a twilio:<sid> row', () => {
    const row = { codeHash: 'twilio:VEabc' };
    expect(isTwilioRow(row)).toBe(true);
    expect(twilioSid(row)).toBe('VEabc');
  });

  test('a hashed row and no row', () => {
    expect(isTwilioRow({ codeHash: 'a'.repeat(64) })).toBe(false);
    expect(isTwilioRow(null)).toBe(false);
  });
});

describe('channelOf', () => {
  test('a Twilio row is sms', () => {
    expect(channelOf({ codeHash: 'twilio:VEabc', sentTo: '+962791234567' })).toBe('sms');
  });

  test('a hashed row sent to a normalized Jordan number is sms', () => {
    expect(channelOf({ codeHash: 'x', sentTo: '+962791234567' })).toBe('sms');
  });

  test('an email that starts with + is email', () => {
    expect(channelOf({ codeHash: 'x', sentTo: '+tag@example.com' })).toBe('email');
  });

  test('a normal email, a non-normalized number and no sentTo are email', () => {
    expect(channelOf({ codeHash: 'x', sentTo: 'a@nexus.test' })).toBe('email');
    expect(channelOf({ codeHash: 'x', sentTo: '0791234567' })).toBe('email');
    expect(channelOf({ codeHash: 'x', sentTo: null })).toBe('email');
  });
});

describe('activeCodeProblem', () => {
  test('null for a live row', () => {
    expect(activeCodeProblem({ expiresAt: future(), attempts: 0 })).toBeNull();
  });

  test('the same messages as email codes', () => {
    expect(activeCodeProblem(null)).toBe('No active code. Tap "Resend code" to get a new one.');
    expect(activeCodeProblem({ expiresAt: new Date(Date.now() - 1), attempts: 0 }))
      .toBe('This code has expired. Tap "Resend code" for a new one.');
    expect(activeCodeProblem({ expiresAt: future(), attempts: MAX_ATTEMPTS }))
      .toBe('Too many wrong attempts. Tap "Resend code" for a new one.');
  });
});
