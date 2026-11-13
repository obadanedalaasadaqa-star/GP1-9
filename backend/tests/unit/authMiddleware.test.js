// middleware/auth.js on fake req/res objects (no server, no DB).
const jwt = require('jsonwebtoken');
const authMiddleware = require('../../src/middleware/auth');

const SECRET = process.env.JWT_SECRET;

function run(token) {
  const req = { headers: token === undefined ? {} : { authorization: `Bearer ${token}` } };
  const res = {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
  const next = jest.fn();
  authMiddleware(req, res, next);
  return { req, res, next };
}

const expectRejected = ({ res, next }) => {
  expect(next).not.toHaveBeenCalled();
  expect(res.statusCode).toBe(401);
  expect(res.body).toEqual({ error: 'Unauthorized — invalid token' });
};

test('a session token sets req.userId and calls next', () => {
  const { req, res, next } = run(jwt.sign({ userId: 'user-1' }, SECRET, { expiresIn: '7d' }));
  expect(next).toHaveBeenCalledTimes(1);
  expect(req.userId).toBe('user-1');
  expect(res.statusCode).toBe(200);
});

test('no Authorization header gives the "no token" 401', () => {
  const { res, next } = run(undefined);
  expect(next).not.toHaveBeenCalled();
  expect(res.body).toEqual({ error: 'Unauthorized — no token' });
});

test.each([
  ['without a userId', { sub: 'user-1', purpose: 'something-else' }],
  ['with an empty userId', { userId: '' }],
  ['with a non-string userId', { userId: 42 }],
  ['with a null userId', { userId: null }],
])('a token signed with JWT_SECRET but %s gives 401', (_label, payload) => {
  expectRejected(run(jwt.sign(payload, SECRET)));
});

test('an expired session token gives 401', () => {
  expectRejected(run(jwt.sign({ userId: 'user-1', exp: Math.floor(Date.now() / 1000) - 10 }, SECRET)));
});

test('a token signed with another secret gives 401', () => {
  expectRejected(run(jwt.sign({ userId: 'user-1' }, 'another-secret')));
});
