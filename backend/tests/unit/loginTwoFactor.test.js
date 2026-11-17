// lib/loginTwoFactor.js with the DB-backed helpers mocked (no server, no DB).
jest.mock('../../src/lib/verification', () => ({
  issueCode: jest.fn(async () => ({ code: '123456' })),
  checkCode: jest.fn(async () => null),
}));
jest.mock('../../src/lib/mailer', () => ({ sendLoginCodeEmail: jest.fn(async () => {}) }));
jest.mock('../../src/lib/prisma', () => ({ user: { findUnique: jest.fn() } }));

const verification = require('../../src/lib/verification');
const mailer = require('../../src/lib/mailer');
const prisma = require('../../src/lib/prisma');
const { signChallenge, signSession, passwordTag } = require('../../src/lib/token');
const {
  isLoginTwoFactorAllowed, loginChallenge, loadChallengeUser, sendLoginCode, checkLoginCode,
} = require('../../src/lib/loginTwoFactor');

const USER = { id: 'user-1', email: 'a@example.com', firstName: 'Sara', password: 'hash-1' };
const EXPIRED = { error: 'Your sign-in expired. Please log in again.' };

function fakeRes() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

const savedFlag = process.env.LOGIN_2FA;
afterEach(() => {
  if (savedFlag === undefined) delete process.env.LOGIN_2FA;
  else process.env.LOGIN_2FA = savedFlag;
  jest.clearAllMocks();
});

describe('isLoginTwoFactorAllowed', () => {
  test.each([[undefined, true], ['on', true], ['off', false]])('LOGIN_2FA=%s gives %s', (value, expected) => {
    if (value === undefined) delete process.env.LOGIN_2FA;
    else process.env.LOGIN_2FA = value;
    expect(isLoginTwoFactorAllowed()).toBe(expected);
  });
});

describe('loginChallenge', () => {
  test('no req.body answers 401 without throwing', () => {
    const res = fakeRes();
    const next = jest.fn();
    loginChallenge({}, res, next);
    expect(next).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(401);
    expect(res.body).toEqual(EXPIRED);
  });

  test('a session token as the challenge gives 401', () => {
    const res = fakeRes();
    const next = jest.fn();
    loginChallenge({ body: { challengeToken: signSession('user-1', 0) } }, res, next);
    expect(next).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(401);
  });

  test('a valid challenge sets req.userId and req.challengePwd and calls next', () => {
    const req = { body: { challengeToken: signChallenge(USER) } };
    const next = jest.fn();
    loginChallenge(req, fakeRes(), next);
    expect(next).toHaveBeenCalledTimes(1);
    expect(req.userId).toBe('user-1');
    expect(req.challengePwd).toBe(passwordTag('hash-1'));
  });
});

describe('loadChallengeUser', () => {
  test('a changed password answers 401 and returns null', async () => {
    prisma.user.findUnique.mockResolvedValueOnce({ ...USER, password: 'hash-2' });
    const res = fakeRes();
    const user = await loadChallengeUser({ userId: 'user-1', challengePwd: passwordTag('hash-1') }, res);
    expect(user).toBeNull();
    expect(res.statusCode).toBe(401);
    expect(res.body).toEqual(EXPIRED);
  });

  test('a missing user answers 404', async () => {
    prisma.user.findUnique.mockResolvedValueOnce(null);
    const res = fakeRes();
    expect(await loadChallengeUser({ userId: 'gone', challengePwd: 'x' }, res)).toBeNull();
    expect(res.statusCode).toBe(404);
  });
});

describe('sendLoginCode', () => {
  test('issues a login code and emails it', async () => {
    const result = await sendLoginCode(USER);
    expect(result).toEqual({ code: '123456' });
    expect(verification.issueCode).toHaveBeenCalledWith('user-1', 'login', { ignoreWait: undefined });
    expect(mailer.sendLoginCodeEmail).toHaveBeenCalledWith('a@example.com', 'Sara', '123456');
  });

  test('returns { error } when the mailer throws', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    mailer.sendLoginCodeEmail.mockRejectedValueOnce(new Error('Brevo 500'));
    expect(await sendLoginCode(USER)).toEqual({ error: 'Could not send the sign-in email. Please try again.' });
    console.error.mockRestore();
  });

  test('passes { waitSeconds } through without emailing', async () => {
    verification.issueCode.mockResolvedValueOnce({ waitSeconds: 42 });
    expect(await sendLoginCode(USER)).toEqual({ waitSeconds: 42 });
    expect(mailer.sendLoginCodeEmail).not.toHaveBeenCalled();
  });
});

test('checkLoginCode checks the login code type', async () => {
  await checkLoginCode('user-1', '123456');
  expect(verification.checkCode).toHaveBeenCalledWith('user-1', 'login', '123456');
});
