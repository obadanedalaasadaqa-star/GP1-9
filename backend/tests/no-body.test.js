jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const { makeApp, registerUser, createTestStore, cleanup } = require('./helpers');

// Express 5 leaves req.body undefined (not {}) when a request sends no body.
// Every write route must answer that with a 4xx JSON error, never a 500.
// Left out on purpose: routes where an empty body is a valid request that
// sends mail or creates data (/user/email/send-code, /receipts/seed,
// /ai/report/email).
const SLOW = 90_000;
const app = makeApp({ aiClient: null });
const auth = (token) => ({ Authorization: `Bearer ${token}` });

let u, shop;
beforeAll(async () => {
  u = await registerUser(app);
  shop = await createTestStore();
}, SLOW);
afterAll(cleanup);

const ROUTES = [
  ['post', '/api/auth/register', false],
  ['post', '/api/auth/login', false],
  ['post', '/api/auth/login/send-code', false],
  ['post', '/api/auth/login/verify', false],
  ['patch', '/api/user/me', true],
  ['patch', '/api/user/password', true],
  ['patch', '/api/user/security', true],
  ['patch', '/api/user/notifications', true],
  ['post', '/api/user/email/verify', true],
  ['post', '/api/receipts', true],
  ['put', '/api/budgets', true],
  ['post', '/api/ai/chat', true],
];

test.each(ROUTES)('%s %s with no body gets a 4xx JSON error', async (method, path, needsUser) => {
  let req = request(app)[method](path);
  if (needsUser) req = req.set(auth(u.token));
  const res = await req;
  expect(res.status).toBeGreaterThanOrEqual(400);
  expect(res.status).toBeLessThan(500);
  expect(typeof res.body.error).toBe('string');
}, SLOW);

test('POST /api/store/receipts with no body gets 400', async () => {
  const res = await request(app).post('/api/store/receipts').set('X-Store-Key', shop.key);
  expect(res.status).toBe(400);
  expect(res.body.error).toBe('Invalid request body.');
}, SLOW);

test('a broken JSON body still gets 400 "Invalid JSON body."', async () => {
  const res = await request(app).post('/api/auth/login')
    .set('Content-Type', 'application/json').send('{"email":');
  expect(res.status).toBe(400);
  expect(res.body.error).toBe('Invalid JSON body.');
}, SLOW);

test('a JSON body over the size limit gets 413, not 500', async () => {
  const res = await request(app).post('/api/auth/login')
    .set('Content-Type', 'application/json')
    .send(JSON.stringify({ email: 'x'.repeat(200 * 1024) }));
  expect(res.status).toBe(413);
  expect(res.body.error).toBe('Request body is too large.');
}, SLOW);

test('an unsupported charset gets 415, not 500', async () => {
  const res = await request(app).post('/api/auth/login')
    .set('Content-Type', 'application/json; charset=klingon').send('{}');
  expect(res.status).toBe(415);
  expect(res.body.error).toBe('Unsupported request body.');
}, SLOW);

test('?period=toString on the report gets 400, not 500', async () => {
  const res = await request(app).get('/api/ai/report?period=toString').set(auth(u.token));
  expect(res.status).toBe(400);
}, SLOW);

test('a broken percent-encoded path still gets 400', async () => {
  const res = await request(app).delete('/api/budgets/%E0').set(auth(u.token));
  expect(res.status).toBe(400);
}, SLOW);
