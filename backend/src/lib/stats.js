// Validation and shaping for GET /api/user/stats. Pure functions, no DB.

const MAX_BOUNDS = 13; // 12 periods (a year of months)

const ERR_REQUIRED = 'bounds is required.';
const ERR_COUNT    = `bounds must have 2 to ${MAX_BOUNDS} dates.`;
const ERR_ISO      = 'bounds must be ISO dates with a time zone (e.g. 2026-11-01T00:00:00.000Z).';
const ERR_ORDER    = 'bounds must be in increasing order.';

// ISO 8601 instant with a required zone (Z or ±hh:mm). Seconds and ms optional.
const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/;

const round3 = (n) => Math.round(n * 1000) / 1000;

// Date for one bound, or null if it is not a real ISO instant with a zone.
function parseInstant(part) {
  const m = ISO_RE.exec(part);
  if (!m) return null;
  const date = new Date(part);
  if (isNaN(date)) return null;

  // V8 rolls impossible dates over (30 Feb -> 2 Mar) instead of giving NaN,
  // so check the written fields round-trip. The zone is applied only above.
  const [y, mo, d, h, mi] = m.slice(1, 6).map(Number);
  const s = m[6] ? Number(m[6]) : 0;
  const t = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d
      || t.getUTCHours() !== h || t.getUTCMinutes() !== mi || t.getUTCSeconds() !== s) {
    return null;
  }
  return date;
}

/**
 * Parse the comma-separated `bounds` query value.
 * @returns {{ bounds: Date[] } | { error: string }}
 */
function parseBounds(raw) {
  // Express gives an array for ?bounds=a&bounds=b; that is rejected too.
  if (typeof raw !== 'string' || raw.trim() === '') return { error: ERR_REQUIRED };

  const parts = raw.split(',').map((p) => p.trim());
  if (parts.length < 2 || parts.length > MAX_BOUNDS) return { error: ERR_COUNT };

  const bounds = [];
  for (const part of parts) {
    const date = parseInstant(part);
    if (!date) return { error: ERR_ISO };
    if (bounds.length > 0 && date <= bounds[bounds.length - 1]) return { error: ERR_ORDER };
    bounds.push(date);
  }
  return { bounds };
}

const byTotalThenName = (key) => (a, b) =>
  b.total - a.total || (a[key] < b[key] ? -1 : a[key] > b[key] ? 1 : 0);

/**
 * Turn the GROUPING SETS rows of the stats query into
 * { periods: [{ from, to, total, count, average, byCategory, topStore }] }.
 * rows: { idx (1-based), noCategory, noStore, category, storeName, total, count }.
 * Empty periods are filled with zeros, oldest first like `bounds`.
 */
function shapeStats(rows, bounds) {
  const periods = [];
  const stores = [];
  for (let i = 0; i < bounds.length - 1; i++) {
    periods.push({
      from: bounds[i].toISOString(),
      to: bounds[i + 1].toISOString(),
      total: 0,
      count: 0,
      average: 0,
      byCategory: [],
      topStore: null,
    });
    stores.push([]);
  }

  for (const row of rows) {
    const i = Number(row.idx) - 1;
    const period = periods[i];
    if (!period) continue;
    const total = round3(Number(row.total));
    const count = Number(row.count);
    if (Number(row.noCategory) === 0) {
      period.byCategory.push({ category: row.category, total, count });
    } else if (Number(row.noStore) === 0) {
      stores[i].push({ storeName: row.storeName, total, count });
    } else {
      period.total = total;
      period.count = count;
    }
  }

  periods.forEach((period, i) => {
    period.average = period.count > 0 ? round3(period.total / period.count) : 0;
    period.byCategory.sort(byTotalThenName('category'));
    // Most money spent; ties go to more visits, then the name.
    stores[i].sort((a, b) =>
      b.total - a.total || b.count - a.count
      || (a.storeName < b.storeName ? -1 : a.storeName > b.storeName ? 1 : 0));
    period.topStore = stores[i][0] ?? null;
  });

  return { periods };
}

module.exports = { MAX_BOUNDS, parseBounds, shapeStats, round3 };
