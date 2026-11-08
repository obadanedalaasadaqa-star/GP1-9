jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const request = require('supertest');
const mailer = require('./mailerMock');
const {
  makeApp, registerUser, verifyUser, createTestStore, cleanup,
} = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

const app = makeApp();
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const storeKey = (key) => ({ 'X-Store-Key': key });

// Two items: 2 x 1.25 + 0.5 = 3.000 JD
const ITEMS = [
  { name: 'Milk', qty: 2, unitPrice: 1.25 },
  { name: 'Bread', qty: 1, unitPrice: 0.5 },
];
const sendReceipt = (key, body) =>
  request(app).post('/api/store/receipts').set(storeKey(key)).send(body);

let shop, customer;
beforeAll(async () => {
  shop = await createTestStore('Supermarket');
  customer = await registerUser(app);
});
afterAll(cleanup);

// Silence the "[store/receipts] 201 ..." timing lines during tests.
beforeEach(() => jest.spyOn(console, 'log').mockImplementation(() => {}));
afterEach(() => jest.restoreAllMocks());

describe('GET /api/store/me', () => {
  test('200 with the store for a valid key', async () => {
    const res = await request(app).get('/api/store/me').set(storeKey(shop.key));
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ id: shop.store.id, name: shop.store.name, category: 'Supermarket' });
  });

  test('401 without a key', async () => {
    const res = await request(app).get('/api/store/me');
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('Store key required.');
  });

  test('401 with a wrong key', async () => {
    const res = await request(app).get('/api/store/me').set(storeKey('nxs_sk_wrong'));
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('Invalid store key.');
  });
});

describe('POST /api/store/receipts', () => {
  test('201 returns only the first name, total and points; the customer gets the points and the receipt', async () => {
    const before = await request(app).get('/api/user/me').set(auth(customer.token));

    const res = await sendReceipt(shop.key, {
      customerSerial: customer.user.serialNumber.toLowerCase(),
      items: [{ name: 'Rice 2kg', qty: 1, unitPrice: 7.995 }, ...ITEMS],
      totalAmount: 10.995,
      // Ignored: the name/category always come from nexus_stores.
      storeName: 'Fake Store',
      category: 'Electronics',
    });
    expect(res.status).toBe(201);
    expect(res.body.customerFirstName).toBe('Test');
    expect(res.body.totalAmount).toBe(10.995);
    expect(res.body.pointsEarned).toBe(10);
    expect(res.body.receiptId).toEqual(expect.any(String));
    expect(res.body.createdAt).toEqual(expect.any(String));
    expect(Object.keys(res.body).sort())
      .toEqual(['createdAt', 'customerFirstName', 'pointsEarned', 'receiptId', 'totalAmount']);

    const me = await request(app).get('/api/user/me').set(auth(customer.token));
    expect(me.body.loyaltyPoints).toBe(before.body.loyaltyPoints + 10);

    const list = await request(app).get('/api/user/receipts').set(auth(customer.token));
    const first = list.body[0];
    expect(first.id).toBe(res.body.receiptId);
    expect(first.storeName).toBe(shop.store.name);
    expect(first.category).toBe('Supermarket');
    expect(first.storeId).toBe(shop.store.id);
    expect(first.items).toEqual(['Rice 2kg', 'Milk x2', 'Bread']);
    expect(first.pointsEarned).toBe(10);
    // Full lines for the receipt screen, in the order the cashier sent them.
    expect(first.lineItems).toEqual([
      { name: 'Rice 2kg', qty: 1, unitPrice: 7.995 },
      { name: 'Milk', qty: 2, unitPrice: 1.25 },
      { name: 'Bread', qty: 1, unitPrice: 0.5 },
    ]);
  }, SLOW);

  test.each([
    ['a bad serial', { customerSerial: 'hello', items: ITEMS, totalAmount: 3 },
      'Enter a valid Nexus serial (NXS-XXXXX-XXXXX).'],
    ['a mismatched total', { items: ITEMS, totalAmount: 4 }, 'totalAmount does not match the items.'],
    ['a bad item', { items: [{ name: 'Milk', qty: 1, unitPrice: 1.2345 }], totalAmount: 1.2345 }, 'Item 1 is invalid.'],
    ['an over-cap total', { items: [{ name: 'Gold', qty: 2, unitPrice: 9999.999 }], totalAmount: 19999.998 },
      'Receipt total is too large.'],
  ])('400 for %s', async (_label, body, error) => {
    const res = await sendReceipt(shop.key, { customerSerial: customer.user.serialNumber, ...body });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe(error);
  });

  test('400 Invalid JSON body for broken JSON', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = await request(app).post('/api/store/receipts')
      .set(storeKey(shop.key))
      .set('Content-Type', 'application/json')
      .send('{"customerSerial":');
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'Invalid JSON body.' });
  });

  test('404 for an unknown serial in a valid format', async () => {
    const res = await sendReceipt(shop.key, { customerSerial: 'NXS-00000-00000', items: ITEMS, totalAmount: 3 });
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('No Nexus customer with this serial.');
  });

  test('401 without a key', async () => {
    const res = await request(app).post('/api/store/receipts')
      .send({ customerSerial: customer.user.serialNumber, items: ITEMS, totalAmount: 3 });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('Store key required.');
  });
});

describe('email copy', () => {
  // The copy is sent after the 201, so give it a moment to be called.
  const settle = () => new Promise((r) => setTimeout(r, 50));
  beforeEach(() => mailer.sendReceiptEmail.mockClear());

  test('emailCopy + verified user: sendReceiptEmail is called once', async () => {
    const verified = await registerUser(app);
    await verifyUser(verified.user.id);

    const res = await sendReceipt(shop.key, {
      customerSerial: verified.user.serialNumber, items: ITEMS, totalAmount: 3, emailCopy: true,
    });
    expect(res.status).toBe(201);
    await settle();
    expect(mailer.sendReceiptEmail).toHaveBeenCalledTimes(1);
    const [to, firstName, receipt] = mailer.sendReceiptEmail.mock.calls[0];
    expect(to).toBe(verified.email);
    expect(firstName).toBe('Test');
    expect(receipt).toMatchObject({
      storeName: shop.store.name, items: ['Milk x2', 'Bread'], totalAmount: 3, pointsEarned: 3,
    });
  }, SLOW);

  test('emailCopy + unverified user: not called', async () => {
    const res = await sendReceipt(shop.key, {
      customerSerial: customer.user.serialNumber, items: ITEMS, totalAmount: 3, emailCopy: true,
    });
    expect(res.status).toBe(201);
    await settle();
    expect(mailer.sendReceiptEmail).not.toHaveBeenCalled();
  });

  test('emailCopy absent: not called', async () => {
    const verified = await registerUser(app);
    await verifyUser(verified.user.id);
    const res = await sendReceipt(shop.key, {
      customerSerial: verified.user.serialNumber, items: ITEMS, totalAmount: 3,
    });
    expect(res.status).toBe(201);
    await settle();
    expect(mailer.sendReceiptEmail).not.toHaveBeenCalled();
  }, SLOW);

  test('a failing email copy never changes the 201', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {});
    const verified = await registerUser(app);
    await verifyUser(verified.user.id);
    mailer.sendReceiptEmail.mockImplementationOnce(() => { throw new Error('boom'); });

    const res = await sendReceipt(shop.key, {
      customerSerial: verified.user.serialNumber, items: ITEMS, totalAmount: 3, emailCopy: true,
    });
    expect(res.status).toBe(201);
    await settle();
    expect(console.error).toHaveBeenCalledWith('[store/receipts] email copy failed', 'boom');
  }, SLOW);
});
