# Nexus — Smart Expense Tracking

Graduation Project GP1-9 · Jordan University of Science and Technology

A Flutter mobile app that lets users scan and store receipts, track spending by category, and earn loyalty points — backed by a Node.js/Express API and a Supabase PostgreSQL database.

---

## Project Structure

```
nexus_project_v1/
├── flutter_app/   # Mobile app (Flutter/Dart)
└── backend/       # REST API (Node.js, Express, Prisma)
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Flutter SDK | 3.11 or later |
| Dart SDK | 3.11 or later |
| Node.js | 22.x – 24.x |
| npm | 9.x or later |
| Android Studio / Xcode | For running the Flutter app |

---

## 1 — Backend Setup

```bash
cd backend

# Install dependencies
npm install

# Get backend/.env from Obada through a private channel (never through git).
# Never commit it. backend/.env.example only shows which variables exist.

# Generate the Prisma client
npx prisma generate

# Start the development server (runs on port 3001 by default)
npm run dev
```

> **Never run `prisma db push` or `prisma migrate`.** The schema is created by
> `src/index.js` on startup, and this database is also the live demo database.

The API will be available at `http://localhost:3001`. The online server
(`https://nexus-backend-e0di.onrender.com`, Render) runs the same code from `main`.

### Tests

```bash
cd backend
npm test
```

The tests (Jest + Supertest + socket.io-client) use the database in
`backend/.env`. They create throwaway `test_…@nexus.test` users and
`test_store_…` stores and delete them at the end. `npm test` creates any
missing tables first (Jest `globalSetup` runs `ensureSchema()`), so a fresh
test DB works without `npm start`. If a run crashes, remove any leftovers in
the Supabase SQL editor:

```sql
DELETE FROM nexus_users  WHERE email LIKE 'test\_%@nexus.test';
DELETE FROM nexus_stores WHERE name  LIKE 'test\_store\_%';
```

### Email

`src/lib/mailer.js` picks the provider on every send:

| Set in `.env` | Provider | Where |
|---|---|---|
| `BREVO_API_KEY` + `MAIL_FROM` (+ `MAIL_FROM_NAME`) | Brevo HTTPS API | Render (Render blocks SMTP) |
| `GMAIL_USER` + `GMAIL_APP_PASSWORD` | Gmail SMTP | Local only |
| nothing | Dev mode: codes and receipt summaries are printed in the server log | Local |

The startup log says which one is active (`Mail: Brevo API from …`).

**Third-party data:** when Brevo is configured, Brevo (Sendinblue SAS, France)
receives each recipient's email address and first name, the verification
codes and, for receipt copies, the store name, items and totals. Without
Brevo, nothing leaves our server except through Gmail (local only).

### AI (insight, Ask AI, reports)

The AI page uses the Claude API (`src/lib/ai.js` is the only file that talks to it).

| Set in `.env` | Meaning |
|---|---|
| `ANTHROPIC_API_KEY` | Key from console.anthropic.com. Empty: insight and Ask AI answer 503; reports still return every number, with "AI summary is not set up on this server." |
| `AI_MODEL` (optional) | Default `claude-haiku-5-5`. `claude-sonnet-5-5` or `claude-opus-5-5` is a one-line switch. Saved AI texts are written again once (the cache key includes the model). |
| `AI_FALLBACKS` (optional) | Default off. `on` sends the server-side fallback beta, and only with an Opus/Sonnet 5.5 model (Haiku 5.5 has no server-side fallback). |

The startup log says what is active (`AI: claude-haiku-5-5 (fallbacks off)`).

- **The server computes every number** with SQL; Claude only writes words around
  them. A guard rejects any answer that states an amount or percentage the
  server did not give it (insight/report: 502 or "AI unavailable"; Ask AI: one
  repair turn, then an error).
- **Ask AI tools (7):** spending summary, category breakdown, monthly totals,
  compare periods, list receipts, line items and `get_top_products` (most bought
  items over all receipts). Answers carry a `chart` built by the server from the
  tool results (`lib/aiChart.js`), or `chart: null`.
- **Insight cache:** one per user; reused while the numbers are unchanged and it
  is under 24 h old, so a second request costs nothing. A new receipt changes
  the numbers, so the next request writes a new one.
- **Limits:** new insights 20/hour; Ask AI 10 per 10 min and 30/day; AI report
  summaries 10/day (numbers are always free); report emails 3/hour and 5/day.
  Daily counters (table `nexus_ai_usage`, with token counts) reset at 00:00 UTC.
- **Cost (Haiku 5.5, $0.10 / $0.50 per 1M tokens):** about $0.0006 per insight,
  $0.0012 per question and $0.0012 per report; 500 insights + 1,000 questions +
  100 reports is about $1.60. Opus 5.5 is about 40 times that.
- **Set a monthly spend limit in the Anthropic console.** The per-user caps
  limit one user, not everyone.

**Third-party data:** when `ANTHROPIC_API_KEY` is set, Anthropic (USA) receives:
monthly and per-category spending totals, receipt counts, dates, store, category
and item names from the user's receipts (names cut to 40 to 60 characters), and
the questions the user types in Ask AI. Store, category and item names can be
typed by the user on manually added receipts. No names, emails,
serials or ids are sent. **Report emails** go through the same mail provider as
verification codes (Brevo on Render, Gmail locally) and contain the report's
totals, category and store names, and the date, store, category and total of
the biggest receipts.

### Store Simulator (live receipts)

The backend serves a cashier web page at `/store/`
(`http://localhost:3001/store/` locally,
`https://nexus-backend-e0di.onrender.com/store/` online). A cashier signs in
with a **store key**, builds a cart, scans the customer's Nexus QR code with
the webcam (or types the serial) and sends the receipt. The phone gets it
live over Socket.IO and shows a "New receipt" sheet.

Create a store (runs against the DB in `backend/.env`, which Render also uses):

```bash
cd backend
npm run store:create -- "Carrefour" Supermarket
# Categories: Supermarket, Food, Pharmacy, Clothing, Electronics
```

The key is printed **once** and only its hash is stored. Keep it private:
never put store keys in git, notes or screenshots. To revoke a store, delete
its row in the Supabase SQL editor (its receipts stay in the users' archives,
with `storeId` set to NULL):

```sql
DELETE FROM nexus_stores WHERE name = 'Carrefour';
```

The server caches valid store keys in memory for 60 seconds, so a revoked
store keeps working for **up to 60 s** (or until the server restarts).

A lost key cannot be recovered: create a new store and delete the old row.

### Budgets and alerts

Users set a monthly budget per category in the app (Profile → Budgets & alerts,
or the Budgets card in Trends). "Spent" is the sum of the user's receipts in
that category for the current calendar month in the user's time zone, with the
same `[from, to)` rule as `/api/user/stats`, so the bars match Trends.

- **Alerts at 80% and 100%.** Checked after each **store** receipt
  (`POST /api/store/receipts`), after the store already got its 201. The phone
  gets a live `budget:alert` event (always on) and, when "Budget alert emails"
  is on and the email is verified, an email. Each level fires **once per
  category per month** (table `nexus_budget_alerts`); one receipt that jumps
  past 100% gives a single 100% alert. Changing or removing a budget resets that
  category's alerts for the current month (the same amount resets nothing).
  Manual and seeded receipts (tests and `demo:reset` only) count toward the
  bars but never trigger an alert.
- **Time zone:** the app sends its offset (`tzOffsetMinutes`) when it saves a
  budget or a setting; the server keeps it per user (default 180, Jordan) for
  "this month" in alerts.
- **Limits:** up to 20 budgets, 1 to 100000 JD each. Budget changes and
  notification settings: 60 per 10 min per user.

- **Weekly summary email (opt-in, Profile → Weekly summary email).** Sent from
  Sunday 09:00 in the user's time zone about the previous Sunday-Saturday week:
  total, receipts, change vs the week before, top categories, top store and
  this month's budgets (numbers only, no AI text). Skipped when that week had no
  receipts; the first one comes the Sunday after opting in. A timer in the
  server checks every 15 minutes (startup log `Weekly summary: on …`), so if
  the server slept through Sunday morning the email goes out at the next check,
  never twice. `WEEKLY_SUMMARY=off` in `.env` stops it. To send one by hand:

  ```bash
  cd backend
  npm run weekly:send -- you@example.com           # only if this week's is not sent yet
  npm run weekly:send -- you@example.com --force   # send again
  ```

**Third-party data:** budget alert and weekly summary emails go through the
same mail provider as receipt copies (Brevo on Render, Gmail locally) and
contain category and store names, budgets, amounts spent and dates.

### Two-step sign-in (opt-in, email codes)

Off for everyone by default. Each user turns it on in Profile → **Sign-in
security → Two-step sign-in**.

- **Turning it on needs a verified email** (the switch is disabled with a
  "Verify" link until then; the server answers 403). No password is needed.
- **Turning it off needs the current password** (400 without it, 401 if wrong).
- **Changing the email turns it off** (the new address is unverified). Verify the
  new address and turn it on again.
- **How it works:** for a user with it on, a correct email and password on
  `POST /api/auth/login` returns `{ twoFactorRequired: true, challengeToken,
  method: 'email', expiresInSeconds: 600 }` instead of a session. The app's code
  screen asks for a code (`/login/send-code`) and sends it back
  (`/login/verify`), which returns the normal `{ token, user }`. Codes last 10
  minutes, allow 5 tries and can be resent once a minute. The challenge only
  works on these two routes (it is signed with its own key), expires after 10
  minutes, and a password change voids it. Signing in with a code does not
  change `emailVerified`. Users with it off log in exactly as before.
- **Dev mode:** without mail settings the code is printed in the server log:
  `[mail:dev] Sign-in code for <email>: 123456`.
- **Emergency switch:** `LOGIN_2FA=off` in `.env` (or on Render) turns it off for
  everyone at once (e.g. during a mail outage); the startup log says
  `Login 2FA: OFF for everyone`. Each user's setting is kept, so the Profile
  switch still shows "on" and its text still says a code is emailed, but no code
  is asked until the variable is removed, then codes resume.
- **Rate limits:** the `login` limiter only counts failed attempts. A correct
  password for a 2FA user returns a 200 challenge, which is not limited per IP;
  this is safe because `/login` sends no email and issues no session. Code sends
  are capped per user by `loginSendCode` (5 an hour, plus the 60 s wait) and
  checks by `loginVerifyCode` (10 per 15 min). `PATCH /api/user/security` has
  its own `security` limiter (10 per 15 min per user).
- **Locked out** (2FA on, no access to the inbox): turn it off in Profile while
  still logged in, set `LOGIN_2FA=off`, or set that user's `"loginTwoFactor"` to
  false in the DB.

**Third-party data:** sign-in codes go through the same mail provider as the
verification email (address, first name and the code).

### Demo reset

Puts the demo account back into a known state before a demo:

```bash
cd backend
npm run demo:reset -- <demo email>          # dry run: prints what would be deleted
npm run demo:reset -- <demo email> --yes    # reset
```

- **`--yes` only works for the account in `DEMO_EMAIL`** (set it in your own
  `backend/.env`, never in the repo). Test accounts (`test_…@nexus.test`) are
  always refused.
- **Warning:** `backend/.env` points at the same database as the online server,
  so this changes the live account.
- One transaction deletes the account's receipts, AI insight/reports/usage,
  budgets, budget alerts and codes, then adds about 30 receipts over this month
  and the previous 5 (in the user's time zone), 3 budgets (Food is about 70%
  used, so one Store Simulator Food receipt of 5 JD or more crosses the 80%
  alert), sets the points to match and turns two-step sign-in off.
- Email, password, name, serial, email verification, email settings and time
  zone are kept, so the demo phone stays logged in. Stores are never touched
  (`npm run store:create` stays separate).

---

## 2 — Flutter App Setup

### Step 1 — Choose the server

The app uses the online server by default
(`https://nexus-backend-e0di.onrender.com/api`), so a plain `flutter run`
works on Wi-Fi or mobile data. On the free plan the server sleeps after about
15 minutes idle; the first launch after that can show "Waking up the server..."
for up to a minute. To use a backend running on your own machine
instead, pass its address when you run the app:

```bash
flutter run --dart-define=API_BASE_URL=http://<your-LAN-IP>:3001/api
```

The address is never written into the code, so don't commit a LAN IP.

**How to find your IP:**
- **Windows:** open Command Prompt → `ipconfig` → look for IPv4 Address
- **macOS/Linux:** open Terminal → `ifconfig` → look for `inet` under `en0`
- **Android Emulator:** use `http://10.0.2.2:3001/api` instead of your IP
- **iOS Simulator:** use `http://127.0.0.1:3001/api` instead of your IP

### Step 2 — Install and run

```bash
cd flutter_app

# Install Flutter dependencies
flutter pub get

# Run the app (make sure a device or emulator is connected)
flutter run
```

---

## Running Everything Together

Start each part in a separate terminal in this order:

```
Terminal 1 → cd backend    && npm run dev
Terminal 2 → cd flutter_app && flutter run --dart-define=API_BASE_URL=http://<your-LAN-IP>:3001/api
```

---

## API Overview

| Method | Route | Description |
|---|---|---|
| POST | `/api/auth/register` | Register a new user |
| POST | `/api/auth/login` | Login: `{ token, user }`, or a sign-in challenge `{ twoFactorRequired, challengeToken, method, expiresInSeconds }` when two-step sign-in is on |
| POST | `/api/auth/login/send-code` | `{ challengeToken }`: email a sign-in code |
| POST | `/api/auth/login/verify` | `{ challengeToken, code }` → `{ token, user }` |
| GET | `/api/user/me` | Get current user profile |
| PATCH | `/api/user/me` | Update first/last name and email (a new email needs `currentPassword`) |
| PATCH | `/api/user/security` | `{ loginTwoFactor, currentPassword? }` → the user (on needs a verified email, off needs the password) |
| PATCH | `/api/user/password` | `{ currentPassword, newPassword }` → `{ message, token }` |
| POST | `/api/user/logout-all` | Sign out on every device, this one included (no body) |
| GET | `/api/user/receipts` | Last 50 receipts, or the newest 500 in `?from&to` |
| GET | `/api/user/stats?bounds=…` | Spending totals per period, category and store (Trends) |
| GET | `/api/store/me` | Store login: check a store key |
| POST | `/api/store/receipts` | Store sends a receipt to a customer serial |
| GET | `/api/ai/insight?bounds=…` | AI summary + tip for this month (same bounds as stats; cached 24 h) |
| POST | `/api/ai/chat` | Ask AI: `{ question, history?, tzOffsetMinutes? }` → `{ answer, toolsUsed, remainingToday, chart }` (`chart`: bars / columns / compare, or null) |
| GET | `/api/ai/report?period=…` | Spending report: `1m`, `3m`, `6m`, `1y` or `custom&from=YYYY-MM-DD&to=YYYY-MM-DD` |
| POST | `/api/ai/report/email` | Email the report to the verified address |
| GET | `/api/budgets?tzOffsetMinutes=` | This month's budgets with spent/percent/level, and the categories to pick from |
| PUT | `/api/budgets` | Create or change one: `{ category, limit, tzOffsetMinutes? }` → the list |
| DELETE | `/api/budgets/:category` | Remove one (URL-encoded name) → the list |
| PATCH | `/api/user/notifications` | `{ budgetAlertEmails?, weeklySummaryEmails?, tzOffsetMinutes? }` → the user |

`/api/user/stats` takes `bounds`: 2 to 13 comma-separated ISO instants with a
time zone (e.g. `2026-10-31T21:00:00.000Z`), oldest first. Each neighbour pair
is one period, from inclusive and to exclusive (the same rule as `?from&to`).

`/api/user/*`, `/api/ai/*` and `/api/budgets*` require an `Authorization: Bearer <token>`
header. `/api/store/*` requires an `X-Store-Key: nxs_sk_…` header instead.

`POST /api/receipts` and `POST /api/receipts/seed` exist **only in tests**
(`createApp({ testRoutes: true })`, used by `makeApp`). The running server has
neither (404), so nobody can add receipts or points to their own account; real
receipts come from stores (`POST /api/store/receipts`).

**Sessions.** Every session token carries the user's session version. A
password change, turning two-step sign-in on, an email change and
`POST /api/user/logout-all` raise it, so every older token gets 401 and its
live connection is dropped. The first three answer with a new `token` for the
device that made the change (the app saves it); sign out everywhere signs that
device out too. Tokens from before Phase 8 count as version 0 and keep working
until one of these happens. A normal Log out does not end the session on the
server.

**AI and email limits.** Ask AI, new insights and new report summaries need a
verified email (numbers and saved texts do not). New insights are capped at 20
per user per UTC day. An email change in `PATCH /api/user/me` waits 60 s after
the last code and shares the 5-codes-an-hour limit with `/email/send-code`; a
code only verifies the address it was sent to. Names are cut of control
characters and capped at 50 characters. New accounts' emails are stored
trimmed and lowercased; login also finds older mixed-case rows.

**Startup guard.** On Render (`RENDER=true`) or with `NODE_ENV=production`
the server refuses to start when `JWT_SECRET` is missing or shorter than 32
characters. Do not add `NODE_ENV=production` on Render just for this.

**Checking `TRUST_PROXY`** (the IP rate limiters; IPv6 is grouped by /64): the
`[rate-limit] login blocked ip=` line is only written when a request is
blocked, so force one block. Send 11 `POST /api/auth/login` with an address
that has no account (e.g. `test_proxycheck@nexus.test`), any password and the
header `X-Forwarded-For: 203.0.113.7`; the 11th gets 429. The log line must
show your real public IP: `203.0.113.7` means `TRUST_PROXY` is too high, a
private or Render-internal address means too low. Login from that IP is then
blocked for 15 minutes for every account (the demo too); a restart clears it.

Live updates: the app opens a Socket.IO connection to the server root with
`auth: { token }` and receives `receipt:new` events in its own room, and
`budget:alert` events after a store receipt that reaches 80% or 100% of a budget:
`{ receiptId, category, level (80 | 100), percent, spent, limit, remaining, overBy, month, monthLabel }`.

---

## Tech Stack

- **Mobile:** Flutter 3.11, Dart, Provider, http, shared_preferences, qr_flutter, google_fonts, socket_io_client
- **Backend:** Node.js, Express, Prisma ORM, bcryptjs, jsonwebtoken, uuid, Socket.IO, Brevo (email), jsQR (Store Simulator), Claude API (`@anthropic-ai/sdk`)
- **Database:** Supabase (PostgreSQL)
