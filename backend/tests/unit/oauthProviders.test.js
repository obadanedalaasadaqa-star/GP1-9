// lib/oauthProviders.js: provider config and the audience list (no DB, no network).
const { PROVIDERS, provider, audiences } = require('../../src/lib/oauthProviders');

let saved;
beforeEach(() => { saved = process.env.GOOGLE_CLIENT_IDS; });
afterEach(() => { process.env.GOOGLE_CLIENT_IDS = saved; });

describe('audiences (U9)', () => {
  test('read on every call, trimmed, empties dropped', () => {
    process.env.GOOGLE_CLIENT_IDS = ' 1-a.apps.googleusercontent.com , ,2-b.apps.googleusercontent.com,';
    expect(audiences('google')).toEqual(['1-a.apps.googleusercontent.com', '2-b.apps.googleusercontent.com']);
    process.env.GOOGLE_CLIENT_IDS = '3-c.apps.googleusercontent.com';
    expect(audiences('google')).toEqual(['3-c.apps.googleusercontent.com']);
  });

  test('unset or empty → []', () => {
    process.env.GOOGLE_CLIENT_IDS = '';
    expect(audiences('google')).toEqual([]);
    delete process.env.GOOGLE_CLIENT_IDS;
    expect(audiences('google')).toEqual([]);
    process.env.GOOGLE_CLIENT_IDS = ' , ';
    expect(audiences('google')).toEqual([]);
  });

  test('unknown provider names (including prototype keys) → [] and null', () => {
    expect(audiences('__proto__')).toEqual([]);
    expect(provider('constructor')).toBeNull();
    expect(provider('github')).toBeNull();
  });
});

describe('providers (U14)', () => {
  test('google: the two issuers, the constant JWKS URL, RS256 only', () => {
    expect(PROVIDERS.google.enabled).toBe(true);
    expect(PROVIDERS.google.issuers).toEqual(['https://accounts.google.com', 'accounts.google.com']);
    expect(PROVIDERS.google.jwksUrl).toBe('https://www.googleapis.com/oauth2/v3/certs');
    expect(PROVIDERS.google.algorithms).toEqual(['RS256']);
  });

  test('apple exists but is not enabled, and no Apple route is exported', () => {
    expect(PROVIDERS.apple.enabled).toBe(false);
    const authRoutes = require('../../src/routes/auth');
    expect(typeof authRoutes).toBe('function');
    expect(Object.keys(authRoutes)).not.toContain('apple');
  });
});
