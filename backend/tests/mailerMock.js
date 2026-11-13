// Stand-in for src/lib/mailer.js. Use at the top of a test file:
//   jest.mock('../src/lib/mailer', () => require('./mailerMock'));
// Records every code so tests can read the real 6-digit code, and every
// receipt copy in sentReceipts.
const sent = [];
const sentReceipts = [];
const sentReports = [];
const sentBudgetAlerts = [];
const sentWeekly = [];

const sendVerificationEmail = jest.fn(async (to, firstName, code) => {
  sent.push({ to, firstName, code });
});

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

module.exports = {
  mailProvider: () => null,
  isMailConfigured: () => false,
  sendVerificationEmail,
  sendReceiptEmail,
  sentReceipts,
  sendReportEmail,
  sentReports,
  sendBudgetAlertEmail,
  sentBudgetAlerts,
  sendWeeklySummaryEmail,
  sentWeekly,
  lastCodeFor,
};
