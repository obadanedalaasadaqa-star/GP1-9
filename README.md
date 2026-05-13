# Nexus — Smart Expense Tracking

Graduation Project GP1-9 · Jordan University of Science and Technology

A Flutter mobile app that lets users scan and store receipts, track spending by category, and earn loyalty points — backed by a Node.js/Express API and a Supabase PostgreSQL database.

---

## Project Structure

```
nexus_project_v1/
├── flutter_app/   # Mobile app (Flutter/Dart)
├── backend/       # REST API (Node.js, Express, Prisma)
└── frontend/      # Admin/web dashboard (React, Vite)
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Flutter SDK | 3.x or later |
| Node.js | 18.x or later |
| npm | 9.x or later |
| Android Studio / Xcode | For running the Flutter app |

---

## 1 — Backend Setup

```bash
cd backend

# Install dependencies
npm install

# Copy the environment file — credentials are already included
cp .env.example .env

# Generate the Prisma client
npx prisma generate

# Start the development server (runs on port 3001 by default)
npm run dev
```

The API will be available at `http://localhost:3001`.

---

## 2 — Flutter App Setup

### Step 1 — Set your machine's local IP address

The Flutter app connects to the backend over your local network. Open this file:

```
flutter_app/lib/core/constants.dart
```

Change the IP address to match your machine:

```dart
static const String baseUrl = 'http://YOUR_LOCAL_IP:3001/api';
```

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

## 3 — Frontend (Web Dashboard) Setup

```bash
cd frontend

# Install dependencies
npm install

# Start the dev server (runs on port 5173)
npm run dev
```

Open `http://localhost:5173` in your browser.

---

## Running Everything Together

Start each part in a separate terminal in this order:

```
Terminal 1 → cd backend  && npm run dev
Terminal 2 → cd frontend && npm run dev
Terminal 3 → cd flutter_app && flutter run
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

- **Mobile:** Flutter, Dart, Provider, shared_preferences
- **Backend:** Node.js, Express, Prisma ORM, bcryptjs, jsonwebtoken
- **Database:** Supabase (PostgreSQL)
- **Web:** React, Vite, Axios
