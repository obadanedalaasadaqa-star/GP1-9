const { normalizeJordanPhone, maskPhone } = require('./phone');
const {
  findCode, waitSecondsFor, isTwilioRow, twilioSid, activeCodeProblem, recordWrongAttempt,
  issueCode, saveExternalCode, expireCode, deleteCode, checkCode,
} = require('./verification');
const {
  isSmsConfigured, startVerification, cancelVerification, checkVerification, CANNOT_RECEIVE_TEXT,
} = require('./twilioVerify');

// SMS codes of any [type] ('phone' now; 'login' for sign-in codes later).
// Twilio mode: Twilio Verify makes and checks the code; the row keeps
// 'twilio:<sid>' and where it went. Dev mode (no TWILIO_* vars): the code is
// hashed in the row like an email code and printed to the server log
// (outside production; in production a missing Twilio config is a 502).
// Rule: a row is deleted only when its code is approved. Every other ending
// expires it, so a Twilio SID is never lost while it may still be pending.

const NO_LONGER_VALID = 'This code is no longer valid. Tap "Resend code" for a new one.';
const LOG_LABEL = { phone: 'Phone', login: 'Sign-in' };

// The route answer for a failed Twilio start.
function startErrorResult(err) {
  if (err?.kind === 'cannotReceive' && CANNOT_RECEIVE_TEXT[err.reason]) {
    return {
      status: 400,
      error: `This number can't receive Nexus SMS yet: ${CANNOT_RECEIVE_TEXT[err.reason]}.`,
      reason: err.reason,
    };
  }
  if (err?.kind === 'tooMany') {
    return { status: 429, error: 'Too many SMS to this number. Try again later.' };
  }
  // TwilioErrors are already logged (masked); anything else is a bug.
  if (err?.name !== 'TwilioError') console.error('[sms] start failed', err);
  return { status: 502, error: 'Could not send the SMS. Please try again.' };
}

/**
 * Send a new SMS code of [type] to [user].phone.
 * Returns { sent: true, to } (to = masked number), { waitSeconds }, or
 * { status, error, reason? } for the route to answer.
 */
async function sendSmsCode(user, type, { ignoreWait = false } = {}) {
  const phone = normalizeJordanPhone(user.phone);
  if (!phone) return { status: 400, error: 'Add a valid mobile number in Profile first.' };

  const existing = await findCode(user.id, type);
  if (!ignoreWait) {
    const waitSeconds = waitSecondsFor(existing);
    if (waitSeconds > 0) return { waitSeconds };
  }

  if (isSmsConfigured()) {
    // Twilio keeps one pending verification per number: cancel the old one so
    // the new code starts with fresh checks. Failures are logged by twilioVerify.
    if (isTwilioRow(existing)) {
      try { await cancelVerification(twilioSid(existing)); } catch { /* send anyway */ }
    }
    let sid;
    try {
      sid = await startVerification(phone);
    } catch (err) {
      return startErrorResult(err);
    }
    await saveExternalCode(user.id, type, phone, sid); // only after Twilio accepted
    return { sent: true, to: maskPhone(phone) };
  }

  // Production without Twilio: nobody reads the log, so say it failed.
  if (process.env.NODE_ENV === 'production') {
    console.error('[sms] not configured: set the TWILIO_* vars');
    return { status: 502, error: 'Could not send the SMS. Please try again.' };
  }
  const { code } = await issueCode(user.id, type, { ignoreWait: true, sentTo: phone });
  console.log(`[sms:dev] ${LOG_LABEL[type] ?? 'SMS'} code for ${maskPhone(phone)}: ${code}`);
  return { sent: true, to: maskPhone(phone) };
}

/**
 * Check [code] against [row] (the user's code of [type], loaded by the caller).
 * Returns null when approved (the row is deleted), or { status, error }.
 */
async function checkSmsCode(user, type, row, code) {
  const phone = normalizeJordanPhone(user.phone);
  if (row && row.sentTo !== phone) {
    await expireCode(user.id, type);
    return { status: 400, error: 'Your number changed after the code was sent. Tap "Resend code".' };
  }
  const problem = activeCodeProblem(row);
  if (problem) return { status: 400, error: problem };

  if (isTwilioRow(row)) {
    // Twilio was configured when this code was sent but isn't now.
    if (!isSmsConfigured()) {
      await expireCode(user.id, type);
      return { status: 400, error: NO_LONGER_VALID };
    }
    let result;
    try {
      result = await checkVerification(phone, String(code).trim());
    } catch {
      return { status: 502, error: 'Could not check the code. Please try again.' };
    }
    if (result === 'approved') {
      await deleteCode(user.id, type);
      return null;
    }
    if (result === 'wrong') return { status: 400, error: await recordWrongAttempt(row) };
    await expireCode(user.id, type); // 'gone': keep the SID so a resend can cancel it
    return { status: 400, error: NO_LONGER_VALID };
  }

  const message = await checkCode(user.id, type, code);
  return message ? { status: 400, error: message } : null;
}

const sendPhoneCode = (user, opts) => sendSmsCode(user, 'phone', opts);
const checkPhoneCode = async (user, code) =>
  checkSmsCode(user, 'phone', await findCode(user.id, 'phone'), code);

module.exports = { sendSmsCode, checkSmsCode, sendPhoneCode, checkPhoneCode };
