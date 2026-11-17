// lib/startupChecks.js: the JWT_SECRET guard (no server, no DB).
const { jwtSecretProblem } = require('../../src/lib/startupChecks');

const MESSAGE = 'JWT_SECRET is missing or shorter than 32 characters.';
const secret = (n) => 'x'.repeat(n);

describe('NODE_ENV=production', () => {
  test.each([
    ['no secret', undefined, MESSAGE],
    ['an empty secret', '', MESSAGE],
    ['31 characters', secret(31), MESSAGE],
    ['32 characters', secret(32), null],
  ])('%s', (_label, JWT_SECRET, expected) => {
    expect(jwtSecretProblem({ NODE_ENV: 'production', JWT_SECRET })).toBe(expected);
  });
});

describe('RENDER=true (no NODE_ENV)', () => {
  test('31 characters is refused', () => {
    expect(jwtSecretProblem({ RENDER: 'true', JWT_SECRET: secret(31) })).toBe(MESSAGE);
  });
  test('32 characters is fine', () => {
    expect(jwtSecretProblem({ RENDER: 'true', JWT_SECRET: secret(32) })).toBeNull();
  });
  test('no secret is refused', () => {
    expect(jwtSecretProblem({ RENDER: 'true' })).toBe(MESSAGE);
  });
});

test('neither set (local dev and tests): never a problem, even with no secret', () => {
  expect(jwtSecretProblem({})).toBeNull();
  expect(jwtSecretProblem({ NODE_ENV: 'development', JWT_SECRET: 'short' })).toBeNull();
});

test('RENDER=false counts as not Render', () => {
  expect(jwtSecretProblem({ RENDER: 'false', JWT_SECRET: 'short' })).toBeNull();
});
