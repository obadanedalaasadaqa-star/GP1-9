const { normalizeSerial, parseStoreReceipt } = require('../../src/lib/storeReceipt');

const SERIAL = 'NXS-C26B9-285D7';
const item = (over = {}) => ({ name: 'Milk', qty: 1, unitPrice: 1.25, ...over });
// A valid body; totalAmount defaults to the exact sum of the items.
function body(over = {}) {
  const items = over.items ?? [item({ qty: 2 }), item({ name: 'Bread', unitPrice: 0.5 })];
  const total = items.reduce((s, it) => s + it.qty * it.unitPrice, 0);
  return { customerSerial: SERIAL, items, totalAmount: total, ...over };
}
const errorOf = (b) => parseStoreReceipt(b).error;
const ITEM_1 = 'Item 1 is invalid.';

describe('normalizeSerial', () => {
  test('accepts lowercase and surrounding spaces', () => {
    expect(normalizeSerial('  nxs-c26b9-285d7 ')).toBe(SERIAL);
  });
  test.each(['hello', 'NXS-C26B9-285D', 'NXS-G26B9-285D7', 'NXSC26B9285D7', '', null, 42])(
    'rejects %p', (s) => {
      expect(normalizeSerial(s)).toBeNull();
    });
});

describe('parseStoreReceipt', () => {
  test('a valid body gives the clean values', () => {
    const r = parseStoreReceipt(body());
    expect(r.error).toBeUndefined();
    expect(r.serial).toBe(SERIAL);
    expect(r.totalAmount).toBe(3);
    expect(r.itemStrings).toEqual(['Milk x2', 'Bread']);
    expect(r.emailCopy).toBe(false);
  });

  test.each([null, [], 'x', 5])('body %p is rejected', (b) => {
    expect(errorOf(b)).toBe('Invalid request body.');
  });

  test('a bad serial is rejected, a lowercase one is accepted', () => {
    expect(errorOf(body({ customerSerial: 'hello' }))).toBe('Enter a valid Nexus serial (NXS-XXXXX-XXXXX).');
    expect(errorOf(body({ customerSerial: undefined }))).toBe('Enter a valid Nexus serial (NXS-XXXXX-XXXXX).');
    expect(parseStoreReceipt(body({ customerSerial: ' nxs-c26b9-285d7' })).serial).toBe(SERIAL);
  });

  test('empty items and 101 items are rejected', () => {
    expect(errorOf(body({ items: [], totalAmount: 0 }))).toBe('Add at least one item (max 100).');
    const many = Array.from({ length: 101 }, () => item());
    expect(errorOf(body({ items: many }))).toBe('Add at least one item (max 100).');
    expect(errorOf({ customerSerial: SERIAL, totalAmount: 1 })).toBe('Add at least one item (max 100).');
  });

  test('item names: blank and 81 chars are rejected', () => {
    expect(errorOf(body({ items: [item({ name: '   ' })] }))).toBe(ITEM_1);
    expect(errorOf(body({ items: [item({ name: 'a'.repeat(81) })] }))).toBe(ITEM_1);
    expect(errorOf(body({ items: [item({ name: 'a'.repeat(80) })] }))).toBeUndefined();
  });

  test('the item number in the error starts at 1', () => {
    expect(errorOf(body({ items: [item(), item({ qty: 0 })], totalAmount: 1.25 }))).toBe('Item 2 is invalid.');
  });

  test.each([0, 1.5, 1000, '2'])('qty %p is rejected', (qty) => {
    expect(errorOf(body({ items: [item({ qty })], totalAmount: 1.25 }))).toBe(ITEM_1);
  });

  test.each([0, -1, NaN, Infinity, '1', 0.0001, 1.2345, 10000.001])('unitPrice %p is rejected', (unitPrice) => {
    expect(errorOf(body({ items: [item({ unitPrice })], totalAmount: 1 }))).toBe(ITEM_1);
  });

  test.each([0.001, 1.255, 1.005])('unitPrice %p is accepted', (unitPrice) => {
    const r = parseStoreReceipt(body({ items: [item({ unitPrice })], totalAmount: unitPrice }));
    expect(r.error).toBeUndefined();
    expect(r.totalAmount).toBe(unitPrice);
  });

  test('a total over 10000 JD is rejected, exactly 10000 is accepted', () => {
    const big = [item({ name: 'Gold', qty: 2, unitPrice: 9999.999 })];
    expect(errorOf(body({ items: big, totalAmount: 19999.998 }))).toBe('Receipt total is too large.');
    const exact = [item({ name: 'Gold', qty: 4, unitPrice: 2500 })];
    expect(parseStoreReceipt(body({ items: exact, totalAmount: 10000 })).totalAmount).toBe(10000);
  });

  test('the cap is checked before totalAmount', () => {
    const big = [item({ name: 'Gold', qty: 2, unitPrice: 9999.999 })];
    expect(errorOf(body({ items: big, totalAmount: 1 }))).toBe('Receipt total is too large.');
  });

  test('totalAmount: off by 0.01 is rejected, off by 0.004 is accepted', () => {
    expect(errorOf(body({ totalAmount: 3.01 }))).toBe('totalAmount does not match the items.');
    expect(errorOf(body({ totalAmount: 3.004 }))).toBeUndefined();
    expect(errorOf(body({ totalAmount: '3' }))).toBe('totalAmount does not match the items.');
    expect(errorOf(body({ totalAmount: undefined }))).toBe('totalAmount does not match the items.');
  });

  test('the float sum 0.1*3 matches 0.3', () => {
    const r = parseStoreReceipt(body({ items: [item({ unitPrice: 0.1, qty: 3 })], totalAmount: 0.3 }));
    expect(r.error).toBeUndefined();
    expect(r.totalAmount).toBe(0.3);
  });

  test('the computed total is exact to 3 decimals', () => {
    const items = [item({ unitPrice: 1.005, qty: 3 }), item({ name: 'Gum', unitPrice: 0.333, qty: 7 })];
    const r = parseStoreReceipt(body({ items, totalAmount: 5.346 }));
    expect(r.totalAmount).toBe(5.346);
  });

  test('item names are trimmed in the saved strings', () => {
    const r = parseStoreReceipt(body({ items: [item({ name: '  Eggs ', qty: 12, unitPrice: 0.1 })], totalAmount: 1.2 }));
    expect(r.itemStrings).toEqual(['Eggs x12']);
  });

  test.each([[true, true], [false, false], ['true', false], [1, false], [undefined, false]])(
    'emailCopy %p gives %p', (emailCopy, expected) => {
      expect(parseStoreReceipt(body({ emailCopy })).emailCopy).toBe(expected);
    });
});
