// Like real Twilio Verify: a verification whose 5 checks are used up STAYS
// PENDING. start() on that number keeps returning the same sid and code, and
// check() keeps answering 'gone'. Only an 'approved' check or cancel()
// removes it. P-14, P-15 and L-12 depend on this.
//
// Stand-in for src/lib/twilioVerify.js. Use at the top of a test file:
//   jest.mock('../src/lib/twilioVerify', () => require('./twilioMock'));
// The error classes and reason tables are the real module's.
const crypto = require('crypto');
const actual = jest.requireActual('../src/lib/twilioVerify');

const MAX_CHECKS = 5;

// Switches a test can flip. reset() puts them back.
const state = {
  configured: true,     // isSmsConfigured()
  cancelFails: false,   // cancel() throws a 'failed' TwilioError
  startError: null,     // { code, status? }: start() throws like the real module
  checkFails: false,    // check() throws a 'failed' TwilioError
};
const pending = new Map();  // phone -> { sid, code, checks }
const lastCodes = new Map(); // phone -> last code sent (kept after approval)
const starts = [];           // { phone, sid } for every accepted start
const cancelledSids = [];

const isSmsConfigured = jest.fn(() => state.configured);

const startVerification = jest.fn(async (phone) => {
  if (state.startError) {
    const { code, status = 400 } = state.startError;
    throw actual.startErrorFor(status, code);
  }
  let v = pending.get(phone);
  if (!v) {
    v = {
      sid: `VE${crypto.randomBytes(16).toString('hex')}`,
      code: String(crypto.randomInt(0, 1_000_000)).padStart(6, '0'),
      checks: 0,
    };
    pending.set(phone, v);
  }
  lastCodes.set(phone, v.code);
  starts.push({ phone, sid: v.sid });
  return v.sid;
});

const cancelVerification = jest.fn(async (sid) => {
  if (state.cancelFails) throw new actual.TwilioError({ status: 500, kind: 'failed' });
  for (const [phone, v] of pending) {
    if (v.sid === sid) pending.delete(phone);
  }
  cancelledSids.push(sid);
});

const checkVerification = jest.fn(async (phone, code) => {
  if (state.checkFails) throw new actual.TwilioError({ status: 500, kind: 'failed' });
  const v = pending.get(phone);
  if (!v || v.checks >= MAX_CHECKS) return 'gone';
  v.checks += 1;
  if (code === v.code) {
    pending.delete(phone);
    return 'approved';
  }
  return 'wrong';
});

// Last code sent to [phone] (normalized +962…), or undefined.
function lastSmsCodeFor(phone) {
  return lastCodes.get(phone);
}

// Use up all checks of the pending verification (as if Twilio counted them).
function useUpChecks(phone) {
  const v = pending.get(phone);
  if (v) v.checks = MAX_CHECKS;
}

// Switches back to defaults and call records cleared. Pending verifications
// are kept (each test user has its own number), so a describe's tests can
// share one user's code.
function resetCalls() {
  Object.assign(state, { configured: true, cancelFails: false, startError: null, checkFails: false });
  starts.length = 0;
  cancelledSids.length = 0;
  for (const fn of [isSmsConfigured, startVerification, cancelVerification, checkVerification]) {
    fn.mockClear();
  }
}

// Everything, including pending verifications.
function reset() {
  resetCalls();
  pending.clear();
  lastCodes.clear();
}

module.exports = {
  ...actual,
  isSmsConfigured,
  startVerification,
  cancelVerification,
  checkVerification,
  state,
  starts,
  cancelledSids,
  lastSmsCodeFor,
  useUpChecks,
  resetCalls,
  reset,
};
