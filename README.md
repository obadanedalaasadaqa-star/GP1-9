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
| PATCH | `/api/user/me` | Update display name |
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

`/api/user/stats` takes `bounds`: 2 to 13 comma-separated ISO instants with a
time zone (e.g. `2026-10-31T21:00:00.000Z`), oldest first. Each neighbour pair
is one period, from inclusive and to exclusive (the same rule as `?from&to`).

`/api/user/*`, `/api/receipts*` and `/api/ai/*` require an `Authorization: Bearer <token>`
header. `/api/store/*` requires an `X-Store-Key: nxs_sk_…` header instead.

Live updates: the app opens a Socket.IO connection to the server root with
`auth: { token }` and receives `receipt:new` events in its own room.

---

## Tech Stack

- **Mobile:** Flutter 3.11, Dart, Provider, http, shared_preferences, qr_flutter, google_fonts, socket_io_client
- **Backend:** Node.js, Express, Prisma ORM, bcryptjs, jsonwebtoken, uuid, Socket.IO, Brevo (email), jsQR (Store Simulator), Claude API (`@anthropic-ai/sdk`)
- **Database:** Supabase (PostgreSQL)
