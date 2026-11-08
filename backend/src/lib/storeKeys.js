const crypto = require('crypto');

// Store keys: "nxs_sk_" + 48 hex chars (192 random bits). Only the SHA-256
// hash is stored. A fast hash is fine here because the key is random, not a
// human password, and it lets us look the store up by hash (unique index).
function generateStoreKey() {
  return `nxs_sk_${crypto.randomBytes(24).toString('hex')}`;
}

function hashStoreKey(key) {
  return crypto.createHash('sha256').update(String(key)).digest('hex');
}

module.exports = { generateStoreKey, hashStoreKey };
