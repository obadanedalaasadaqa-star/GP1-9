// middleware/auth.js on fake req/res objects (no server; Prisma is mocked).
jest.mock('../../src/lib/prisma', () => ({ user: { findUnique: jest.fn() } }));

const jwt = require('jsonwebtoken');
const prisma = require('../../src/lib/prisma');
const authMiddleware = require('../../src/middleware/auth');
const { signSession } = require('../../src/lib/token');
const { SESSION_SELECT } = require('../../src/lib/session');

const SECRET = process.env.JWT_SECRET;

async function run(token) {
  const req = { headers: token === undefined ? {} : { authorization: `Bearer ${token}` } };
  const res = {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const next = jest.fn();
  await authMiddleware(req, res, next);
  return { req, res, next };
}

const expectRejected = ({ res, next }) => {
  expect(next).not.toHaveBeenCalled();
  expect(res.statusCode).toBe(401);
  expect(res.body).toEqual({ error: 'Unauthorized — invalid token' });
};

beforeEach(() => {
  prisma.user.findUnique.mockReset();
  prisma.user.findUnique.mockResolvedValue({ tokenVersion: 0, emailVerified: false });
});

test('a session token with the current version sets req.userId and req.emailVerified', async () => {
  prisma.user.findUnique.mockResolvedValue({ tokenVersion: 3, emailVerified: true });
  const { req, res, next } = await run(signSession('user-1', 3));
  expect(next).toHaveBeenCalledTimes(1);
  expect(req.userId).toBe('user-1');
  expect(req.emailVerified).toBe(true);
  expect(res.statusCode).toBe(200);
  // One primary-key lookup with the shared select.
  expect(prisma.user.findUnique).toHaveBeenCalledWith({ where: { id: 'user-1' }, select: SESSION_SELECT });
});

test('a token from before session versions (no tv) counts as version 0', async () => {
  const { req, next } = await run(jwt.sign({ userId: 'user-1' }, SECRET, { expiresIn: '7d' }));
  expect(next).toHaveBeenCalledTimes(1);
  expect(req.userId).toBe('user-1');
});

test('an older version gives 401', async () => {
  prisma.user.findUnique.mockResolvedValue({ tokenVersion: 1, emailVerified: true });
  expectRejected(await run(signSession('user-1', 0)));
});

test('a deleted user gives 401', async () => {
  prisma.user.findUnique.mockResolvedValue(null);
  expectRejected(await run(signSession('user-1', 0)));
});

test('a DB error gives 503, never 401 (the app logs out on 401)', async () => {
  prisma.user.findUnique.mockRejectedValue(new Error('db down'));
  jest.spyOn(console, 'error').mockImplementation(() => {});
  const { res, next } = await run(signSession('user-1', 0));
  expect(next).not.toHaveBeenCalled();
  expect(res.statusCode).toBe(503);
  expect(res.body).toEqual({ error: 'Could not check your session. Try again.' });
  console.error.mockRestore();
});

test('no Authorization header gives the "no token" 401', async () => {
  const { res, next } = await run(undefined);
  expect(next).not.toHaveBeenCalled();
  expect(res.body).toEqual({ error: 'Unauthorized — no token' });
  expect(prisma.user.findUnique).not.toHaveBeenCalled();
});

test.each([
  ['without a userId', { sub: 'user-1', purpose: 'something-else' }],
  ['with an empty userId', { userId: '' }],
  ['with a non-string userId', { userId: 42 }],
  ['with a null userId', { userId: null }],
  ['with a negative tv', { userId: 'user-1', tv: -1 }],
  ['with a string tv', { userId: 'user-1', tv: '0' }],
])('a token signed with JWT_SECRET but %s gives 401 without a DB lookup', async (_label, payload) => {
  expectRejected(await run(jwt.sign(payload, SECRET)));
  expect(prisma.user.findUnique).not.toHaveBeenCalled();
});

test('an expired session token gives 401', async () => {
  expectRejected(await run(jwt.sign({ userId: 'user-1', exp: Math.floor(Date.now() / 1000) - 10 }, SECRET)));
});

test('a token signed with another secret gives 401', async () => {
  expectRejected(await run(jwt.sign({ userId: 'user-1' }, 'another-secret')));
});

test('a sign-in challenge token gives 401', async () => {
  const { signChallenge } = require('../../src/lib/token');
  expectRejected(await run(signChallenge({ id: 'user-1', password: 'hash' })));
});
