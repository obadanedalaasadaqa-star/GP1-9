const { generateStoreKey, hashStoreKey } = require('../../src/lib/storeKeys');

describe('store keys', () => {
  test('a key is nxs_sk_ + 48 hex chars, and two keys differ', () => {
    const a = generateStoreKey();
    const b = generateStoreKey();
    expect(a).toMatch(/^nxs_sk_[0-9a-f]{48}$/);
    expect(b).toMatch(/^nxs_sk_[0-9a-f]{48}$/);
    expect(a).not.toBe(b);
  });

  test('the hash is 64 hex chars and deterministic', () => {
    const key = generateStoreKey();
    expect(hashStoreKey(key)).toMatch(/^[0-9a-f]{64}$/);
    expect(hashStoreKey(key)).toBe(hashStoreKey(key));
  });

  test('different keys give different hashes', () => {
    expect(hashStoreKey(generateStoreKey())).not.toBe(hashStoreKey(generateStoreKey()));
  });
});
