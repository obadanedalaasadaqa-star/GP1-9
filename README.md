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

The tests (Jest + Supertest) use the database in `backend/.env`. They create
throwaway `test_…@nexus.test` users and delete them at the end. If a run
crashes, remove any leftovers in the Supabase SQL editor:

```sql
DELETE FROM nexus_users WHERE email LIKE 'test\_%@nexus.test';
```

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
| POST | `/api/receipts` | Create a new receipt |
| POST | `/api/receipts/seed` | Seed demo receipts (idempotent) |

All routes except `/auth/*` require an `Authorization: Bearer <token>` header.

---

## Tech Stack

- **Mobile:** Flutter 3.11, Dart, Provider, http, shared_preferences, qr_flutter, google_fonts
- **Backend:** Node.js, Express, Prisma ORM, bcryptjs, jsonwebtoken, uuid
- **Database:** Supabase (PostgreSQL)
