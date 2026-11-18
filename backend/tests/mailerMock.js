// Stand-in for src/lib/mailer.js. Use at the top of a test file:
//   jest.mock('../src/lib/mailer', () => require('./mailerMock'));
// Records every code so tests can read the real 6-digit code, and every
// receipt copy in sentReceipts.
const sent = [];
const sentReceipts = [];
const sentReports = [];
const sentBudgetAlerts = [];
const sentWeekly = [];
const sentLogin = [];
const sentReset = [];
const sentPasswordChanged = [];

const sendVerificationEmail = jest.fn(async (to, firstName, code) => {
  sent.push({ to, firstName, code });
});

// Two-step sign-in codes (POST /api/auth/login/send-code).
const sendLoginCodeEmail = jest.fn(async (to, firstName, code) => {
  sentLogin.push({ to, firstName, code });
});

// Password reset codes (POST /api/auth/forgot-password). The route calls
// .catch() on the promise, like the store route.
const sendPasswordResetEmail = jest.fn(async (to, firstName, code) => {
  sentReset.push({ to, firstName, code });
});

// "Your password was changed" notices (POST /api/auth/reset-password).
const sendPasswordChangedEmail = jest.fn(async (to, firstName) => {
  sentPasswordChanged.push({ to, firstName });
});

// Make the next reset-code send reject (like a Brevo error that repeats the
// address in its message). Nothing is recorded for that send.
function failResetSendOnce(message = 'send failed') {
  sendPasswordResetEmail.mockImplementationOnce(async () => {
    throw Object.assign(new Error(message), { code: 'MAIL_FAIL' });
  });
}

// Returns a promise like the real one: the store route calls .catch() on it.
const sendReceiptEmail = jest.fn(async (to, firstName, receipt) => {
  sentReceipts.push({ to, firstName, receipt });
});

// Spending report emails (POST /api/ai/report/email).
const sendReportEmail = jest.fn(async (to, firstName, report, tz) => {
  sentReports.push({ to, firstName, report, tz });
});

// Budget alerts at 80% / 100% (lib/budgetAlerts.js).
const sendBudgetAlertEmail = jest.fn(async (to, firstName, alert) => {
  sentBudgetAlerts.push({ to, firstName, alert });
});

// Weekly summary emails (lib/weeklyJob.js).
const sendWeeklySummaryEmail = jest.fn(async (to, firstName, summary) => {
  sentWeekly.push({ to, firstName, summary });
});

// Last code sent to [email], or undefined.
function lastCodeFor(email) {
  for (let i = sent.length - 1; i >= 0; i--) {
    if (sent[i].to === email) return sent[i].code;
  }
  return undefined;
}

// Last sign-in code sent to [email], or undefined.
function lastLoginCodeFor(email) {
  for (let i = sentLogin.length - 1; i >= 0; i--) {
    if (sentLogin[i].to === email) return sentLogin[i].code;
  }
  return undefined;
}

// Last password reset code sent to [email], or undefined.
function lastResetCodeFor(email) {
  for (let i = sentReset.length - 1; i >= 0; i--) {
    if (sentReset[i].to === email) return sentReset[i].code;
  }
  return undefined;
}

module.exports = {
  mailProvider: () => null,
  isMailConfigured: () => false,
  sendVerificationEmail,
  sendLoginCodeEmail,
  sentLogin,
  sendPasswordResetEmail,
  sentReset,
  failResetSendOnce,
  sendPasswordChangedEmail,
  sentPasswordChanged,
  sendReceiptEmail,
  sentReceipts,
  sendReportEmail,
  sentReports,
  sendBudgetAlertEmail,
  sentBudgetAlerts,
  sendWeeklySummaryEmail,
  sentWeekly,
  lastCodeFor,
  lastLoginCodeFor,
  lastResetCodeFor,
};
