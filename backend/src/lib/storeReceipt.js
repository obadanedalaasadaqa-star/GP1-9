// Validation for POST /api/store/receipts. Pure functions, no DB.

const PRICE_DECIMALS = 3;      // JD has 3 decimals (fils); the app shows 2
const MAX_UNIT_PRICE = 10000;  // JD
const MAX_TOTAL      = 10000;  // JD per receipt, keeps loyaltyPoints (INTEGER) safe
const MAX_ITEMS      = 100;
const MAX_QTY        = 999;
const MAX_NAME       = 80;

const SCALE = 10 ** PRICE_DECIMALS;
const MIN_UNIT_PRICE = 1 / SCALE;
const TOTAL_TOLERANCE = 0.005;

// Same format generateSerial() in routes/auth.js produces.
const SERIAL_RE = /^NXS-[0-9A-F]{5}-[0-9A-F]{5}$/;

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// Trimmed + uppercased serial, or null if it is not a valid Nexus serial.
function normalizeSerial(s) {
  if (typeof s !== 'string') return null;
  const serial = s.trim().toUpperCase();
  return SERIAL_RE.test(serial) ? serial : null;
}

// True when [price] has at most PRICE_DECIMALS decimals (with float tolerance).
function hasPriceDecimals(price) {
  const scaled = price * SCALE;
  return Math.abs(scaled - Math.round(scaled)) < 1e-9;
}

// Clean item { name, qty, unitPrice }, or null if invalid.
function parseItem(item) {
  if (!isPlainObject(item)) return null;
  const name = typeof item.name === 'string' ? item.name.trim() : '';
  if (name.length < 1 || name.length > MAX_NAME) return null;
  const { qty, unitPrice } = item;
  if (!Number.isInteger(qty) || qty < 1 || qty > MAX_QTY) return null;
  if (typeof unitPrice !== 'number' || !Number.isFinite(unitPrice)) return null;
  if (unitPrice < MIN_UNIT_PRICE || unitPrice > MAX_UNIT_PRICE) return null;
  if (!hasPriceDecimals(unitPrice)) return null;
  return { name, qty, unitPrice };
}

/**
 * Check a store receipt body. Returns { error } or
 * { serial, items, itemStrings, totalAmount, emailCopy }.
 * Rule order: body, serial, items array, each item, cap, totalAmount.
 * totalAmount is the computed total (summed in fils so float noise can't creep in).
 */
function parseStoreReceipt(body) {
  if (!isPlainObject(body)) return { error: 'Invalid request body.' };

  const serial = normalizeSerial(body.customerSerial);
  if (!serial) return { error: 'Enter a valid Nexus serial (NXS-XXXXX-XXXXX).' };

  if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > MAX_ITEMS) {
    return { error: `Add at least one item (max ${MAX_ITEMS}).` };
  }

  const items = [];
  for (let i = 0; i < body.items.length; i++) {
    const item = parseItem(body.items[i]);
    if (!item) return { error: `Item ${i + 1} is invalid.` };
    items.push(item);
  }

  const totalFils = items.reduce((sum, it) => sum + it.qty * Math.round(it.unitPrice * SCALE), 0);
  const totalAmount = totalFils / SCALE;
  if (totalAmount > MAX_TOTAL) return { error: 'Receipt total is too large.' };

  const sent = body.totalAmount;
  if (typeof sent !== 'number' || !Number.isFinite(sent)
      || Math.abs(sent - totalAmount) > TOTAL_TOLERANCE + 1e-9) {
    return { error: 'totalAmount does not match the items.' };
  }

  return {
    serial,
    items,
    itemStrings: items.map((it) => (it.qty > 1 ? `${it.name} x${it.qty}` : it.name)),
    totalAmount,
    emailCopy: body.emailCopy === true,
  };
}

module.exports = {
  PRICE_DECIMALS, MAX_UNIT_PRICE, MAX_TOTAL, MAX_ITEMS, MAX_QTY,
  normalizeSerial, parseStoreReceipt,
};
