jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const http = require('http');
const jwt = require('jsonwebtoken');
const request = require('supertest');
const { io: connectClient } = require('socket.io-client');
const { createApp } = require('../src/app');
const { initRealtime, closeRealtime } = require('../src/lib/realtime');
const { registerUser, createTestStore, cleanup } = require('./helpers');

// Many DB round trips per test; the default 30 s is too tight on the pooler.
const SLOW = 90_000;
const ITEMS = [{ name: 'Milk', qty: 2, unitPrice: 1.25 }];

let server, url, app, shop, a, b;
const sockets = [];

// Connect a client with [token]; resolves once connected (or rejects on error).
function connect(token, { waitFor = 'connect' } = {}) {
  const socket = connectClient(url, {
    auth: token === undefined ? {} : { token },
    transports: ['websocket'],
    reconnection: false,
    forceNew: true,
  });
  sockets.push(socket);
  return new Promise((resolve, reject) => {
    if (waitFor === 'connect') {
      socket.once('connect', () => resolve(socket));
      socket.once('connect_error', reject);
    } else {
      socket.once('connect', () => reject(new Error('connected unexpectedly')));
      socket.once('connect_error', (err) => resolve({ socket, err }));
    }
  });
}

const once = (socket, event, ms = 5000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`no ${event} within ${ms}ms`)), ms);
  socket.once(event, (data) => { clearTimeout(timer); resolve(data); });
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sendReceipt = (serial) => request(app).post('/api/store/receipts')
  .set('X-Store-Key', shop.key).send({ customerSerial: serial, items: ITEMS, totalAmount: 2.5 });
const auth = (token) => ({ Authorization: `Bearer ${token}` });

beforeAll(async () => {
  app = createApp({ rateLimit: false });
  server = http.createServer(app);
  initRealtime(server);
  await new Promise((r) => server.listen(0, r));
  url = `http://localhost:${server.address().port}`;
  shop = await createTestStore('Food');
  a = await registerUser(app);
  b = await registerUser(app);
}, SLOW);

afterAll(async () => {
  for (const s of sockets) s.disconnect();
  await closeRealtime();
  await new Promise((r) => server.close(r));
  await cleanup();
});

beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

test('done-when: the receipt reaches the phone fast, with the new points', async () => {
  const socket = await connect(a.token);
  const before = await request(app).get('/api/user/me').set(auth(a.token));

  let tEvent;
  const event = once(socket, 'receipt:new', 30_000).then((e) => { tEvent = Date.now(); return e; });
  const tPost = Date.now();
  const res = await sendReceipt(a.user.serialNumber);
  const tResponse = Date.now();
  expect(res.status).toBe(201);
  const e = await event;

  expect(e.receipt.id).toBe(res.body.receiptId);
  expect(e.receipt.storeName).toBe(shop.store.name);
  expect(e.receipt.items).toEqual(['Milk x2']);
  expect(e.receipt.lineItems).toEqual([{ name: 'Milk', qty: 2, unitPrice: 1.25 }]);
  expect(e.pointsEarned).toBe(2);
  expect(e.loyaltyPoints).toBe(before.body.loyaltyPoints + 2);

  // The server emits before it answers, so this is usually negative. It only
  // measures the push path, not the DB round trips.
  expect(tEvent - tResponse).toBeLessThanOrEqual(500);
  console.info(`[realtime] POST→event ${tEvent - tPost}ms`);
  if (process.env.REALTIME_MAX_MS) {
    expect(tEvent - tPost).toBeLessThanOrEqual(Number(process.env.REALTIME_MAX_MS));
  }
}, SLOW);

test("isolation: user B does not get A's receipt", async () => {
  const socketB = await connect(b.token);
  const got = jest.fn();
  socketB.on('receipt:new', got);
  expect((await sendReceipt(a.user.serialNumber)).status).toBe(201);
  await sleep(500);
  expect(got).not.toHaveBeenCalled();
}, SLOW);

test.each([
  ['a bad token', 'not-a-jwt'],
  ['a token signed with another secret', jwt.sign({ userId: 'x' }, 'other-secret')],
  ['no token', undefined],
])('%s gets connect_error unauthorized', async (_label, token) => {
  const { err } = await connect(token, { waitFor: 'error' });
  expect(err.message).toBe('unauthorized');
});

test('an expired token is disconnected by the server, and a reconnect is refused', async () => {
  const token = jwt.sign({ userId: a.user.id }, process.env.JWT_SECRET, { expiresIn: 2 });
  const socket = await connect(token);

  const reason = await once(socket, 'disconnect', 4000);
  expect(reason).toBe('io server disconnect');
  await sleep(500);
  expect(socket.connected).toBe(false); // the client does not reconnect by itself

  // The app's RealtimeService reconnects once by hand on this reason; the
  // handshake carries the expired token and is refused.
  const refused = once(socket, 'connect_error', 4000);
  socket.connect();
  expect((await refused).message).toBe('unauthorized');
}, 15_000);

test('done-when: nothing is lost while the phone is offline', async () => {
  const before = await request(app).get('/api/user/me').set(auth(a.token));
  const res = await sendReceipt(a.user.serialNumber); // A has no socket open now
  expect(res.status).toBe(201);

  await connect(a.token);
  // What the app re-fetches on reconnect/resume:
  const list = await request(app).get('/api/user/receipts').set(auth(a.token));
  const me = await request(app).get('/api/user/me').set(auth(a.token));
  expect(list.body[0].id).toBe(res.body.receiptId);
  expect(me.body.loyaltyPoints).toBe(before.body.loyaltyPoints + 2);
}, SLOW);
