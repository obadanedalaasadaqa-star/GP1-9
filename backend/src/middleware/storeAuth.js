const prisma = require('../lib/prisma');
const { hashStoreKey } = require('../lib/storeKeys');

// Valid keys are cached in memory for 60 s, so a receipt needs no extra DB
// round trip for the key. Trade-off: revoking a store (deleting its row)
// takes up to 60 s to apply. Wrong keys are never cached.
const CACHE_TTL_MS = 60 * 1000;
const cache = new Map(); // apiKeyHash -> { store, at }

// Store routes send the store key in X-Store-Key (kept apart from the user
// JWT in Authorization). Sets req.store = { id, name, category }.
module.exports = async (req, res, next) => {
  const key = req.get('x-store-key');
  if (!key) return res.status(401).json({ error: 'Store key required.' });

  const apiKeyHash = hashStoreKey(key);
  const hit = cache.get(apiKeyHash);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) {
    req.store = hit.store;
    return next();
  }
  cache.delete(apiKeyHash);

  try {
    const store = await prisma.store.findUnique({
      where: { apiKeyHash },
      select: { id: true, name: true, category: true },
    });
    if (!store) return res.status(401).json({ error: 'Invalid store key.' });
    cache.set(apiKeyHash, { store, at: Date.now() });
    req.store = store;
  } catch (err) {
    console.error('[storeAuth]', err);
    return res.status(500).json({ error: 'Could not check the store key.' });
  }
  next();
};
