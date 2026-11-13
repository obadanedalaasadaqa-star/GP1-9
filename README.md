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

### Phone verification (SMS)

Users confirm the number on their account with a 6-digit SMS code (Profile →
Phone Status → Verify). `src/lib/twilioVerify.js` is the only file that talks
to Twilio; it is picked on every request:

| Set in `.env` | Mode | Where |
|---|---|---|
| `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` + `TWILIO_VERIFY_SERVICE_SID` | Twilio Verify sends and checks the code | Render, or local when testing real SMS |
| nothing | Dev mode: the code is printed in the server log (`[sms:dev] Phone code for 079 *** 4567: 123456`) | Local |

The startup log says which one is active (`SMS: Twilio Verify (service VA…1234)`).
In production without the Twilio vars it prints `SMS: NOT CONFIGURED` and
send-code answers 502 (codes are never printed in production).

Twilio setup (done once by the account owner):
1. Create a Twilio trial account. The owner's own number is verified automatically.
2. Add each team member's number under **Phone Numbers → Verified Caller IDs**
   (for example `<your verified number>`). A trial can only text these numbers.
3. Create a **Verify Service** with the friendly name **Nexus** and code length 6,
   so the SMS reads "Your Nexus verification code is: …". The server also sends
   `CustomFriendlyName=Nexus` with every request.
4. Under Verify → Geo permissions, enable **Jordan**.
5. Put the three values in `backend/.env` (and in the Render environment).
   Never type a real phone number into code, tests or this README.

If Twilio refuses a number, the app shows "This number can't receive Nexus SMS
yet: <reason>." (for example: the number isn't valid, it isn't a mobile number,
or the demo account can only text the team's numbers). The response also has a
`reason` field: `invalidNumber`, `notMobile`, `trialOnly`, `countryBlocked`,
`optedOut` or `blocked`. A carrier that drops an SMS after Twilio accepted it
can't be detected; the code screen tells the user to check the number.

Limits: 3 SMS per hour and 10 code checks per 15 minutes per user, one new
code per minute, codes valid for 10 minutes with 5 tries. Changing the number
in Profile resets it to "Not verified", and a code sent to the old number no
longer works. Production needs a paid Twilio account (the trial only texts
verified numbers).

**Third-party data:** when Twilio is configured, Twilio (Twilio Inc., USA)
receives the user's phone number for each code sent. Logs only show masked
numbers (`079 *** 4567`).

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
typed by the user on manually added receipts. No names, emails, phone numbers,
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
  Manual (`POST /api/receipts`) and seeded receipts count toward the bars but
  never trigger an alert.
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
| POST | `/api/auth/login` | Login and receive a JWT |
| GET | `/api/user/me` | Get current user profile |
| PATCH | `/api/user/me` | Update first/last name, phone and email (email needs `currentPassword`) |
| POST | `/api/user/phone/send-code` | Text a 6-digit code to the profile's number (Twilio Verify, or the log in dev mode) |
| POST | `/api/user/phone/verify` | `{ code }` → the user with `phoneVerified: true` |
| GET | `/api/user/receipts` | Get last 50 receipts |
| GET | `/api/user/stats?bounds=…` | Spending totals per period, category and store (Trends) |
| POST | `/api/receipts` | Create a new receipt |
| POST | `/api/receipts/seed` | Seed demo receipts (idempotent) |
| GET | `/api/store/me` | Store login: check a store key |
| POST | `/api/store/receipts` | Store sends a receipt to a customer serial |
| GET | `/api/ai/insight?bounds=…` | AI summary + tip for this month (same bounds as stats; cached 24 h) |
| POST | `/api/ai/chat` | Ask AI: `{ question, history?, tzOffsetMinutes? }` → `{ answer, toolsUsed, remainingToday }` |
| GET | `/api/ai/report?period=…` | Spending report: `1m`, `3m`, `6m`, `1y` or `custom&from=YYYY-MM-DD&to=YYYY-MM-DD` |
| POST | `/api/ai/report/email` | Email the report to the verified address |
| GET | `/api/budgets?tzOffsetMinutes=` | This month's budgets with spent/percent/level, and the categories to pick from |
| PUT | `/api/budgets` | Create or change one: `{ category, limit, tzOffsetMinutes? }` → the list |
| DELETE | `/api/budgets/:category` | Remove one (URL-encoded name) → the list |
| PATCH | `/api/user/notifications` | `{ budgetAlertEmails?, weeklySummaryEmails?, tzOffsetMinutes? }` → the user |

`/api/user/stats` takes `bounds`: 2 to 13 comma-separated ISO instants with a
time zone (e.g. `2026-10-31T21:00:00.000Z`), oldest first. Each neighbour pair
is one period, from inclusive and to exclusive (the same rule as `?from&to`).

`/api/user/*`, `/api/receipts*`, `/api/ai/*` and `/api/budgets*` require an `Authorization: Bearer <token>`
header. `/api/store/*` requires an `X-Store-Key: nxs_sk_…` header instead.

Live updates: the app opens a Socket.IO connection to the server root with
`auth: { token }` and receives `receipt:new` events in its own room, and
`budget:alert` events after a store receipt that reaches 80% or 100% of a budget:
`{ receiptId, category, level (80 | 100), percent, spent, limit, remaining, overBy, month, monthLabel }`.

---

## Tech Stack

- **Mobile:** Flutter 3.11, Dart, Provider, http, shared_preferences, qr_flutter, google_fonts, socket_io_client
- **Backend:** Node.js, Express, Prisma ORM, bcryptjs, jsonwebtoken, uuid, Socket.IO, Brevo (email), jsQR (Store Simulator), Claude API (`@anthropic-ai/sdk`)
- **Database:** Supabase (PostgreSQL)
