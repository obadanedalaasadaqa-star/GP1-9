// Reset the demo account to a known state before a demo.
//   npm run demo:reset -- <email>          dry run: shows what would be deleted
//   npm run demo:reset -- <email> --yes    resets (only the account in DEMO_EMAIL)
// The email can also come from DEMO_EMAIL in backend/.env. It is never written
// in the repo. backend/.env points at the SAME database as the online server,
// so this changes the live account. Stores are never touched.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const prisma = require('../src/lib/prisma');
const { resetDemoAccount } = require('../src/lib/demoData');

// Emails are stored as typed at register, so the match is exact (only spaces
// trimmed): two addresses that differ only in letter case are two accounts.
const norm = (e) => (e ?? '').trim();

function usage(problem) {
  console.error(`${problem}\n\nUsage: npm run demo:reset -- <email> [--yes]\n` +
    'Without --yes it only prints what would be deleted. --yes only resets the\n' +
    'account in DEMO_EMAIL (backend/.env). Warning: backend/.env uses the same\n' +
    'database as the online server (Render).');
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  const yes = args.includes('--yes');
  const email = norm(args.find((a) => !a.startsWith('--')) ?? process.env.DEMO_EMAIL);
  if (!email) usage('No email given and DEMO_EMAIL is not set.');
  if (/^test_.*@nexus\.test$/i.test(email)) usage('Refusing: that is a test account.');
  if (yes && (!norm(process.env.DEMO_EMAIL) || norm(process.env.DEMO_EMAIL) !== email)) {
    usage('Refusing: --yes only resets the account in DEMO_EMAIL.');
  }

  const user = await prisma.user.findUnique({
    where: { email },
    select: { id: true, email: true },
  });
  if (!user) usage(`No user with the email ${email}.`);

  const where = { userId: user.id };
  const [receipts, budgets, alerts, insights, reports, usage_, codes] = await Promise.all([
    prisma.receipt.count({ where }),
    prisma.budget.count({ where }),
    prisma.budgetAlert.count({ where }),
    prisma.aiInsight.count({ where }),
    prisma.aiReport.count({ where }),
    prisma.aiUsage.count({ where }),
    prisma.verificationCode.count({ where }),
  ]);
  console.log(`Account: ${user.email}`);
  console.log(`Would delete: ${receipts} receipts, ${budgets} budgets, ${alerts} budget alerts, ` +
    `${insights} AI insights, ${reports} AI reports, ${usage_} AI usage rows, ${codes} codes.`);
  if (!yes) {
    console.log('Dry run. Add --yes to reset (the email must equal DEMO_EMAIL).');
    return;
  }

  const result = await resetDemoAccount(prisma, user.id);
  console.log(`Reset done: ${result.receipts} receipts, ${result.budgets} budgets, ` +
    `${result.points} points, two-step sign-in off.`);
}

main()
  .catch((err) => {
    console.error('Could not reset the demo account:', err.message);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
