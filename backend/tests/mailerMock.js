// Stand-in for src/lib/mailer.js. Use at the top of a test file:
//   jest.mock('../src/lib/mailer', () => require('./mailerMock'));
// Records every code so tests can read the real 6-digit code.
const sent = [];

const sendVerificationEmail = jest.fn(async (to, firstName, code) => {
  sent.push({ to, firstName, code });
});

// Last code sent to [email], or undefined.
function lastCodeFor(email) {
  for (let i = sent.length - 1; i >= 0; i--) {
    if (sent[i].to === email) return sent[i].code;
  }
  return undefined;
}

module.exports = {
  isMailConfigured: () => false,
  sendVerificationEmail,
  lastCodeFor,
};
