const { maskPhone } = require('./phone');

// Twilio Verify over plain fetch (no SDK). The only file that talks to Twilio.
// Twilio sends from its own senders, so no sender number is configured here.
// The env is read on every call, so tests can change it.
const VERIFY_BASE = 'https://verify.twilio.com/v2/Services';
const TIMEOUT_MS = 10000;

function isSmsConfigured() {
  return Boolean(process.env.TWILIO_ACCOUNT_SID
    && process.env.TWILIO_AUTH_TOKEN
    && process.env.TWILIO_VERIFY_SERVICE_SID);
}

// Twilio error codes on start that mean "this number can't get our SMS".
// Confirmed against the trial in step 18; change only these two tables.
const REASON_BY_CODE = {
  21211: 'invalidNumber',
  60200: 'invalidNumber',
  21614: 'notMobile',
  60205: 'notMobile',
  21608: 'trialOnly',
  21408: 'countryBlocked',
  21610: 'optedOut',
  60410: 'blocked',
};

// Completes "This number can't receive Nexus SMS yet: <text>." No digits,
// no number, no Twilio wording.
const CANNOT_RECEIVE_TEXT = {
  invalidNumber:  "the number isn't valid. Check it in Profile",
  notMobile:      "it isn't a mobile number",
  trialOnly:      "our demo SMS account can only text the team's numbers",
  countryBlocked: "SMS to this country isn't turned on for Nexus",
  optedOut:       'this number has opted out of Nexus SMS',
  blocked:        'SMS to this number was blocked by the carrier or by fraud protection',
};

const TOO_MANY_CODE = 60203;    // max send attempts reached
const CHECKS_USED_CODE = 60202; // max check attempts reached

// Never carries Twilio's own message: it can contain the phone number.
// kind: 'cannotReceive' (start only, with a reason), 'tooMany' or 'failed'.
class TwilioError extends Error {
  constructor({ status = 0, code = null, kind = 'failed', reason = null } = {}) {
    super(`Twilio request failed (${status}/${code})`);
    this.name = 'TwilioError';
    this.status = status;
    this.code = code;
    this.kind = kind;
    this.reason = reason;
  }
}

function logFailure(op, err, phone) {
  console.error(`[sms] ${op} failed`, {
    status: err.status, code: err.code, reason: err.reason, to: maskPhone(phone),
  });
}

// POST a form to Twilio. Returns { status, body } for any HTTP answer;
// a network error or timeout throws a TwilioError (status 0).
async function post(path, form) {
  const sid = process.env.TWILIO_ACCOUNT_SID;
  const auth = Buffer.from(`${sid}:${process.env.TWILIO_AUTH_TOKEN}`).toString('base64');
  let res;
  try {
    res = await fetch(`${VERIFY_BASE}/${process.env.TWILIO_VERIFY_SERVICE_SID}${path}`, {
      method: 'POST',
      headers: {
        authorization: `Basic ${auth}`,
        'content-type': 'application/x-www-form-urlencoded',
        accept: 'application/json',
      },
      body: new URLSearchParams(form).toString(),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch {
    throw new TwilioError({ status: 0, kind: 'failed' });
  }
  let body = null;
  try { body = await res.json(); } catch { /* non-JSON body */ }
  return { status: res.status, body };
}

/**
 * Start an SMS verification to [phone] (normalized +962…). Resolves to the
 * Verification SID ("VE…"). Throws TwilioError.
 */
async function startVerification(phone) {
  const { status, body } = await post('/Verifications', {
    To: phone, Channel: 'sms', CustomFriendlyName: 'Nexus',
  });
  if (status >= 200 && status < 300 && body?.sid) return body.sid;

  const err = startErrorFor(status, body?.code ?? null);
  logFailure('start', err, phone);
  throw err;
}

// The TwilioError for a failed start (also used by the tests' fake Twilio).
function startErrorFor(status, code) {
  if (REASON_BY_CODE[code]) {
    return new TwilioError({ status, code, kind: 'cannotReceive', reason: REASON_BY_CODE[code] });
  }
  if (status === 429 || code === TOO_MANY_CODE) return new TwilioError({ status, code, kind: 'tooMany' });
  return new TwilioError({ status, code, kind: 'failed' });
}

/** Cancel a pending verification. A 404 (already gone) counts as done. */
async function cancelVerification(sid) {
  const { status, body } = await post(`/Verifications/${encodeURIComponent(sid)}`, {
    Status: 'canceled',
  });
  if ((status >= 200 && status < 300) || status === 404) return;
  const err = new TwilioError({ status, code: body?.code ?? null, kind: 'failed' });
  logFailure('cancel', err, null);
  throw err;
}

/**
 * Check [code] for [phone]. Returns 'approved', 'wrong' (still pending) or
 * 'gone' (no pending verification left: approved elsewhere, expired, canceled
 * or checks used up). Anything else throws TwilioError.
 */
async function checkVerification(phone, code) {
  const { status, body } = await post('/VerificationCheck', { To: phone, Code: code });
  if (status === 200) {
    if (body?.status === 'approved') return 'approved';
    if (body?.status === 'pending') return 'wrong';
    return 'gone';
  }
  if (status === 404 || status === 429 || body?.code === CHECKS_USED_CODE) return 'gone';
  const err = new TwilioError({ status, code: body?.code ?? null, kind: 'failed' });
  logFailure('check', err, phone);
  throw err;
}

module.exports = {
  isSmsConfigured,
  startVerification,
  cancelVerification,
  checkVerification,
  TwilioError,
  startErrorFor,
  REASON_BY_CODE,
  CANNOT_RECEIVE_TEXT,
};
