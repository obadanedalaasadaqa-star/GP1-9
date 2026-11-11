// The insight facts for the demo account (POST /api/receipts/seed: 7 receipts
// this month, nothing older), as in plan section 3.3. [labels] are the 6 month
// labels, oldest first (the last one is this month).
function seedFacts(labels) {
  return {
    currency: 'JD',
    months: labels.map((month, i) => (i === labels.length - 1
      ? { month, total: '287.99', receipts: 7 }
      : { month, total: '0.00', receipts: 0 })),
    thisMonth: {
      month: labels[labels.length - 1],
      monthSoFar: true,
      total: '287.99',
      receipts: 7,
      averageReceipt: '41.14',
      changeVsLastMonth: 'new',
      categories: [
        { category: 'Electronics', total: '89.99', receipts: 1, changeVsLastMonth: 'new' },
        { category: 'Supermarket', total: '76.75', receipts: 2, changeVsLastMonth: 'new' },
        { category: 'Clothing', total: '67.00', receipts: 1, changeVsLastMonth: 'new' },
        { category: 'Food', total: '31.25', receipts: 2, changeVsLastMonth: 'new' },
        { category: 'Pharmacy', total: '23.00', receipts: 1, changeVsLastMonth: 'new' },
      ],
      categoriesOnlyLastMonth: [],
      topStore: { name: 'iStore', total: '89.99', receipts: 1 },
    },
    lastMonth: { month: labels[labels.length - 2], total: '0.00', receipts: 0, averageReceipt: '0.00' },
  };
}

// The 7 demo receipts as { storeName, category, totalAmount } (routes/receipts.js).
const SEED = [
  ['Carrefour', 'Supermarket', 45.50],
  ['City Pharmacy', 'Pharmacy', 23.00],
  ['Hashem Restaurant', 'Food', 18.75],
  ['Zara', 'Clothing', 67.00],
  ['Co-op Supermarket', 'Supermarket', 31.25],
  ['Books@Cafe', 'Food', 12.50],
  ['iStore', 'Electronics', 89.99],
].map(([storeName, category, totalAmount]) => ({ storeName, category, totalAmount }));

module.exports = { seedFacts, SEED };
