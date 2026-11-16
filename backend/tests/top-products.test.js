jest.mock('../src/lib/mailer', () => require('./mailerMock'));

const prisma = require('../src/lib/prisma');
const { queryTopProducts } = require('../src/lib/spendingQueries');
const { makeApp, registerUser, cleanup } = require('./helpers');

// Many sequential DB round trips; the default 30 s is too tight on the pooler.
const SLOW = 90_000;

// Fixed ids for the tie case (same createdAt): the larger id is "newest".
const TEA_ID_1 = '00000000-0000-4000-8000-000000000001';
const TEA_ID_2 = '00000000-0000-4000-8000-000000000002';

// One real backslash: 'Shop\One' in JS would just be 'ShopOne'.
const SHOP_BACKSLASH = 'Shop\\One';

const BASE = new Date('2025-06-01T10:00:00.000Z');
const at = (minutes) => new Date(BASE.getTime() + minutes * 60_000);
const threeYearsAgo = new Date(Date.now() - 3 * 365 * 24 * 3600 * 1000);

let userId;
let otherId;
let inserted = 0;

function add(uid, { items = [], lineItems, storeName = 'Corner Shop', category = 'Supermarket', createdAt, id }) {
  if (uid === userId) inserted++;
  return prisma.receipt.create({
    data: {
      ...(id && { id }),
      userId: uid, storeName, category, totalAmount: 5, items,
      ...(lineItems !== undefined && { lineItems }),
      createdAt,
    },
  });
}

const byName = (res, name) => res.products.find((p) => p.name === name);

beforeAll(async () => {
  // A run that failed before its cleanup must not break the next create.
  await prisma.receipt.deleteMany({ where: { id: { in: [TEA_ID_1, TEA_ID_2] } } });
  const app = makeApp();
  userId = (await registerUser(app)).user.id;
  otherId = (await registerUser(app)).user.id;

  // Store receipts: lineItems with prices, plus the "Milk x2" strings in items
  // (which must not be counted a second time).
  await add(userId, { lineItems: [{ name: 'Milk', qty: 2, unitPrice: 0.75 }], items: ['Milk x2'], createdAt: at(1) });
  await add(userId, { lineItems: [{ name: 'MILK', qty: 1, unitPrice: 0.8 }], items: ['MILK'], createdAt: at(2) });
  // String-only receipts.
  await add(userId, { items: ['Milk x2', 'Bread'], createdAt: at(3) });
  await add(userId, { items: ['Milk X2'], createdAt: at(4) });
  await add(userId, { items: ['Eggs x12', 'Bread'], createdAt: at(5) });
  // Same product, different spacing; 'fresh milk' is 1 minute newer.
  await add(userId, { items: ['Fresh  Milk'], createdAt: at(6) });
  await add(userId, { items: ['fresh milk'], createdAt: at(7) });
  // Tie: same createdAt, the larger id wins.
  await add(userId, { id: TEA_ID_1, items: ['Tea'], createdAt: at(8) });
  await add(userId, { id: TEA_ID_2, items: ['TEA'], createdAt: at(8) });
  // Store names with LIKE special characters.
  await add(userId, { storeName: SHOP_BACKSLASH, items: ['Soap'], createdAt: at(9) });
  await add(userId, { storeName: 'Shop%One', items: ['Shampoo'], createdAt: at(10) });
  // Older than the 2 years any dated tool can reach.
  await add(userId, { items: ['Bread'], createdAt: threeYearsAgo });
  // Bad rows: must never raise.
  await add(userId, { items: { a: 1 }, createdAt: at(11) });
  await add(userId, { lineItems: { a: 1 }, items: ['Juice'], createdAt: at(12) });
  await add(userId, {
    lineItems: [{ name: 'Rice', qty: 'abc', unitPrice: 1 }, { name: 'Oil', qty: 1 }, 5],
    items: [], createdAt: at(13),
  });
  // More plain receipts: over the 10 receipts get_line_items can read.
  await add(userId, { items: ['Bread'], createdAt: at(14) });
  await add(userId, { items: ['Bread'], createdAt: at(15) });

  // Another user's Milk is never counted.
  await add(otherId, { items: ['Milk x5'], createdAt: at(1) });
  await add(otherId, { items: ['Milk'], createdAt: at(2) });
}, SLOW);

afterAll(async () => {
  await cleanup();
});

describe('queryTopProducts', () => {
  test('counts every receipt, merges names, sums quantity and priced spend', async () => {
    expect(inserted).toBeGreaterThanOrEqual(15);
    const res = await queryTopProducts(userId, { limit: 20 });
    expect(res.receiptsChecked).toBe(inserted);
    expect(res.receiptsWithPrices).toBe(3);
    expect(res.firstAt.getTime()).toBe(threeYearsAgo.getTime());

    // Bread: 5 receipts, one of them 3 years old (done-when 3).
    expect(byName(res, 'Bread')).toMatchObject({ timesBought: 5, quantity: 5, spent: null });
    // Milk: case-insensitive, X2 counts as 2, items strings of store receipts
    // are not counted again, the other user is not counted.
    expect(byName(res, 'Milk')).toMatchObject({ timesBought: 4, quantity: 7, pricedLines: 2 });
    expect(byName(res, 'Milk').spent).toBeCloseTo(2.3, 6);
    expect(res.products.filter((p) => p.name.toLowerCase() === 'milk')).toHaveLength(1);
    // The xN regex reached Postgres with its backslashes.
    expect(byName(res, 'Eggs')).toMatchObject({ timesBought: 1, quantity: 12 });
    // The whitespace regex too: two spaces merge, the newer spelling wins.
    expect(byName(res, 'fresh milk')).toMatchObject({ timesBought: 2, quantity: 2 });
    expect(byName(res, 'Fresh  Milk')).toBeUndefined();
    // Same createdAt: the larger receipt id wins.
    expect(byName(res, 'TEA')).toMatchObject({ timesBought: 2 });
    expect(byName(res, 'Tea')).toBeUndefined();
    // Bad rows don't throw and count where they can.
    expect(byName(res, 'Juice')).toMatchObject({ timesBought: 1, quantity: 1 });
    expect(byName(res, 'Rice')).toMatchObject({ timesBought: 1, quantity: 1, spent: null });
    expect(byName(res, 'Oil')).toMatchObject({ timesBought: 1, quantity: 1, spent: null });
    // No ids or userId leave the query.
    for (const p of res.products) {
      expect(Object.keys(p).sort()).toEqual(['name', 'pricedLines', 'quantity', 'spent', 'timesBought']);
    }
  }, SLOW);

  test('the tie case gives the same name on every run', async () => {
    for (let i = 0; i < 2; i++) {
      const res = await queryTopProducts(userId, { limit: 20 });
      expect(byName(res, 'TEA')).toBeDefined();
    }
  }, SLOW);

  test('sorts: times, quantity, spend', async () => {
    const times = await queryTopProducts(userId, { sort: 'times', limit: 20 });
    expect(times.products.slice(0, 2).map((p) => p.name)).toEqual(['Bread', 'Milk']);
    const qty = await queryTopProducts(userId, { sort: 'quantity', limit: 20 });
    expect(qty.products.slice(0, 3).map((p) => p.name)).toEqual(['Eggs', 'Milk', 'Bread']);
    const spend = await queryTopProducts(userId, { sort: 'spend', limit: 20 });
    expect(spend.products[0].name).toBe('Milk');
    expect(spend.products.slice(1).every((p) => p.spent === null)).toBe(true);
    // Nulls last, then by times bought.
    expect(spend.products[1].name).toBe('Bread');
    await expect(queryTopProducts(userId, { sort: 'cheapest' })).rejects.toThrow();
  }, SLOW);

  test('limit returns limit + 1 rows, so the caller can tell it was cut', async () => {
    const res = await queryTopProducts(userId, { limit: 2 });
    expect(res.products).toHaveLength(3);
  }, SLOW);

  test('a date range leaves the old receipt out', async () => {
    const res = await queryTopProducts(userId, { fromUtc: at(0), toUtc: at(60), limit: 20 });
    expect(res.receiptsChecked).toBe(inserted - 1);
    expect(byName(res, 'Bread')).toMatchObject({ timesBought: 4 });
  }, SLOW);

  test('store filters match backslash and % literally', async () => {
    const row = await prisma.receipt.findFirst({ where: { userId, storeName: SHOP_BACKSLASH } });
    expect(row.storeName.includes('\\')).toBe(true);
    expect(row.storeName).toHaveLength(8);

    const backslash = await queryTopProducts(userId, { store: SHOP_BACKSLASH, limit: 20 });
    expect(backslash.receiptsChecked).toBe(1);
    expect(backslash.products.map((p) => p.name)).toEqual(['Soap']);

    const percent = await queryTopProducts(userId, { store: 'Shop%', limit: 20 });
    expect(percent.receiptsChecked).toBe(1);
    expect(percent.products.map((p) => p.name)).toEqual(['Shampoo']);

    const category = await queryTopProducts(userId, { category: 'supermarket', limit: 20 });
    expect(category.receiptsChecked).toBe(inserted);
  }, SLOW);

  test('a user with no receipts gets an empty answer', async () => {
    const res = await queryTopProducts('00000000-0000-4000-8000-00000000ffff', {});
    expect(res).toEqual({ products: [], receiptsChecked: 0, receiptsWithPrices: 0, firstAt: null, lastAt: null });
  }, SLOW);
});
