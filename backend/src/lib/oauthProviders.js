// Outside sign-in providers. Only Google is used now. Apple is described so it
// becomes a config change + one route later (plan 3.6), but nothing mounts it.
//
// Audiences (our OAuth client IDs) come from the environment on every call,
// so a value loaded by dotenv or changed in a test is never missed. They are
// public identifiers, but they stay out of git: GOOGLE_CLIENT_IDS lives only in
// backend/.env and Render's environment.

const PROVIDERS = {
  google: {
    enabled: true,
    issuers: ['https://accounts.google.com', 'accounts.google.com'],
    jwksUrl: 'https://www.googleapis.com/oauth2/v3/certs',
    algorithms: ['RS256'],
    audienceEnv: 'GOOGLE_CLIENT_IDS',
  },
  // Not built: needs the paid Apple Developer Program. No route uses it.
  apple: {
    enabled: false,
    issuers: ['https://appleid.apple.com'],
    jwksUrl: 'https://appleid.apple.com/auth/keys',
    algorithms: ['RS256'],
    audienceEnv: 'APPLE_CLIENT_IDS',
  },
};

// The provider's config, or null for an unknown name.
function provider(name) {
  return Object.hasOwn(PROVIDERS, name) ? PROVIDERS[name] : null;
}

// The accepted client IDs: comma-separated, trimmed, empties dropped.
// Unset or empty → [] (the route then answers 503).
function audiences(name) {
  const p = provider(name);
  if (!p) return [];
  const raw = process.env[p.audienceEnv];
  if (typeof raw !== 'string') return [];
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

module.exports = { PROVIDERS, provider, audiences };
