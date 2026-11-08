// Create a store that can send receipts, and print its key once.
//   npm run store:create -- "Carrefour" Supermarket
// Runs against the DB in backend/.env. The key is never stored, only its hash.
// To revoke a store, delete its row in nexus_stores (its receipts stay).
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const prisma = require('../src/lib/prisma');
const { generateStoreKey, hashStoreKey } = require('../src/lib/storeKeys');

// The categories the app already has colours for.
const CATEGORIES = ['Supermarket', 'Food', 'Pharmacy', 'Clothing', 'Electronics'];

function usage(problem) {
  console.error(`${problem}\n\nUsage: npm run store:create -- "<store name>" <category>\n` +
    `Categories: ${CATEGORIES.join(', ')}`);
  process.exit(1);
}

async function main() {
  const name = (process.argv[2] ?? '').trim();
  const category = (process.argv[3] ?? '').trim();
  if (!name || name.length > 60) usage('Store name must be 1 to 60 characters.');
  if (!CATEGORIES.includes(category)) usage(`Unknown category "${category}".`);

  const key = generateStoreKey();
  const store = await prisma.store.create({
    data: { name, category, apiKeyHash: hashStoreKey(key) },
  });

  console.log(`Store created: ${store.name} (${store.category})`);
  console.log(`Store id: ${store.id}`);
  console.log(`Store key (shown once, keep it safe): ${key}`);
}

main()
  .catch((err) => {
    console.error('Could not create the store:', err.message);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
