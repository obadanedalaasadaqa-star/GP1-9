// Send (or re-send) the weekly summary email to one user, for manual checks.
//   npm run weekly:send -- <email> [--force]
// Runs against the DB and mail settings in backend/.env. The user must have
// "Weekly summary email" on and a verified email; --force sends again for a
// week already sent.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const prisma = require('../src/lib/prisma');
const { runWeeklySummaries } = require('../src/lib/weeklyJob');

async function main() {
  const email = (process.argv[2] ?? '').trim();
  const force = process.argv.includes('--force');
  if (!email || email.startsWith('--')) {
    console.error('Usage: npm run weekly:send -- <email> [--force]');
    process.exit(1);
  }
  const user = await prisma.user.findUnique({
    where: { email },
    select: { id: true, weeklySummaryEmails: true, emailVerified: true },
  });
  if (!user) {
    console.error(`No user with the email ${email}.`);
    process.exit(1);
  }
  if (!user.weeklySummaryEmails || !user.emailVerified) {
    console.log('Note: the job only emails users with Weekly summary on and a verified email.');
  }
  const result = await runWeeklySummaries({ userIds: [user.id], force });
  console.log(result);
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
