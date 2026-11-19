const { randomUUID } = require('crypto');

// A new member serial, NXS-XXXXX-XXXXX (register and Google sign-up).
function generateSerial() {
  const part = randomUUID().replace(/-/g, '').toUpperCase().slice(0, 10);
  return `NXS-${part.slice(0, 5)}-${part.slice(5)}`;
}

module.exports = { generateSerial };
