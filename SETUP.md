# Curby — Full Project Setup Guide

> **Curby** is a real-time, crowdsourced parking recommendation engine. It predicts where open parking spots are most likely to be by combining live traffic data, historical patterns, and a 7-factor scoring algorithm — then renders the results as interactive heatmaps on a native iOS map.

This guide walks through everything you need to clone this repo onto a fresh Mac and get every component running.

---

## Table of Contents

1. [Project Overview & Architecture](#1-project-overview--architecture)
2. [Repository Structure](#2-repository-structure)
3. [Prerequisites](#3-prerequisites)
4. [iOS Application Setup](#4-ios-application-setup)
5. [Backend Setup (Cloudflare Workers)](#5-backend-setup-cloudflare-workers)
6. [Database Setup (Supabase)](#6-database-setup-supabase)
7. [Environment Variables Reference](#7-environment-variables-reference)
8. [Python Utility Scripts](#8-python-utility-scripts)
9. [Running the Full Stack Locally](#9-running-the-full-stack-locally)
10. [Deployment](#10-deployment)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Project Overview & Architecture

Curby is a multi-platform project with three main components:

### iOS App (SwiftUI + Mapbox)
The native mobile client renders an interactive map with real-time parking heatmaps. Users see color-coded zones (green → open, red → full) overlaid on streets, with a bottom-sheet detail view showing per-zone scores. The app communicates with the backend via REST APIs and WebSockets.

**Key features:**
- Street-aligned heatmap overlays that adapt to zoom level (polygon → polyline transitions)
- Live Activity support (Dynamic Island) for active parking sessions
- Geofenced zone detection using Mapbox camera lifecycle
- Popular location pins with zoom-aware visibility

### Backend (Cloudflare Workers + Durable Objects)
A distributed microservices architecture designed to handle high-throughput GPS telemetry from thousands of concurrent users:

| Service | Role |
|:--------|:-----|
| **`api-gateway`** | Main REST API + WebSocket endpoint. Hosts the `RegionCoordinatorDO` Durable Object for per-region state management and load balancing. |
| **`telemetry-consumer`** | Queue consumer that ingests GPS pings (every 5s per user) and archives them to R2 for analytics. |
| **`session-consumer`** | Queue consumer that persists parking session events (park/depart) to Supabase PostgreSQL. |

The API gateway also runs the **7-factor scoring algorithm** (`packages/shared/src/algorithm.ts`), which computes a normalized score ∈ [0, 1] for each parking zone:

```
S(i) = w₁·availability + w₂·turnover + w₃·travelTime + w₄·congestion
     + w₅·walkDistance + w₆·loadBalance + w₇·confidence
```

All weights are remotely configurable via Cloudflare KV — no redeployment needed to tune the algorithm.

### Database (Supabase PostgreSQL)
Source of truth for parking events, active sessions, and routing history. Three migration files define the schema (`active_parks`, `parking_events`, `routing_sessions`), RPC permissions, and service-role write policies.

---

## 2. Repository Structure

```
curby/
├── curby/                          # iOS app source (SwiftUI)
│   ├── curbyApp.swift              # App entry point
│   ├── ContentView.swift           # Root view
│   ├── MainNavigationView.swift    # Primary map + navigation controller
│   ├── UI/                         # Shared UI components (glass effects, haptics, overlays)
│   ├── Map/                        # Mapbox map integration
│   ├── HeatZone/                   # Heatmap rendering & zone detail views
│   ├── Parking/                    # Parking session management
│   ├── Search/                     # Location search
│   ├── Location/                   # CoreLocation services
│   ├── Camera/                     # Map camera state management
│   ├── Motion/                     # Device motion detection
│   ├── Core/                       # Shared models & utilities
│   ├── Onboarding/                 # First-launch onboarding flow
│   └── LiveActivity/               # Live Activity data models
├── CurbyLiveActivity/              # Widget extension for Dynamic Island
├── curby.xcodeproj/                # Xcode project file
├── Info.plist                      # App configuration (Mapbox token, API URL, permissions)
│
├── backend/                        # Backend monorepo (pnpm workspaces)
│   ├── package.json                # Root package — scripts: dev, deploy:all, typecheck, build
│   ├── pnpm-workspace.yaml         # Workspace: packages/* + workers/*
│   ├── tsconfig.base.json          # Shared TypeScript config
│   ├── .env                        # Secrets (git-ignored)
│   ├── workers/
│   │   ├── api-gateway/            # Main API worker + RegionCoordinatorDO
│   │   ├── session-consumer/       # Supabase write consumer
│   │   └── telemetry-consumer/     # R2 archive consumer
│   ├── packages/
│   │   └── shared/                 # Shared library (algorithm, types, config)
│   │       └── src/algorithm.ts    # 7-factor scoring algorithm
│   ├── supabase/
│   │   └── migrations/             # SQL migration files (run in order)
│   │       ├── 001_initial_schema.sql
│   │       ├── 002_rpc_permissions.sql
│   │       └── 003_service_role_parking_writes.sql
│   ├── scripts/
│   │   ├── deploy.sh               # One-command full deployment
│   │   ├── seed-config.js          # Seeds default remote config into KV
│   │   └── test-*.ts               # Algorithm & API test scripts
│   └── deploy.md                   # Detailed deployment guide
│
├── scripts/                        # Root-level utility scripts
│   ├── test_parking_apis.py        # Python API test harness
│   └── GenerateAppIcon.swift       # App icon generator
├── update_parking_ui.py            # Parking UI automation script
├── update_ui.py                    # General UI automation script
├── requirements.txt                # Python dependencies
├── README.md                       # Project overview & pitch
└── SETUP.md                        # ← You are here
```

---

## 3. Prerequisites

Install these before anything else:

| Tool | Version | Install Command | What It's For |
|:-----|:--------|:----------------|:--------------|
| **macOS** | Ventura 14+ | — | Required for Xcode & iOS development |
| **Xcode** | 15.0+ | Mac App Store | Builds & runs the iOS app, resolves Swift Packages |
| **Node.js** | 18.0+ | `brew install node` | Backend runtime |
| **pnpm** | 8.0+ | `npm install -g pnpm` | Backend package manager (workspace-aware) |
| **Wrangler CLI** | 3.0+ | `npm install -g wrangler` | Cloudflare Workers deploy & secret management |
| **Python** | 3.9+ | `brew install python` | Utility scripts (optional — not needed for core app) |
| **Git** | Latest | Pre-installed on macOS | Version control |

### Accounts Required

| Service | Why | Sign Up |
|:--------|:----|:--------|
| **Apple Developer** | Run on physical devices & TestFlight | [developer.apple.com](https://developer.apple.com) |
| **Mapbox** | Map rendering, traffic data, geocoding | [mapbox.com](https://www.mapbox.com) |
| **Cloudflare** | Worker hosting, KV, Queues, R2, Durable Objects | [dash.cloudflare.com](https://dash.cloudflare.com) |
| **Supabase** | PostgreSQL database hosting | [supabase.com](https://supabase.com) |

> [!IMPORTANT]
> Cloudflare **Workers Paid plan** ($5/mo) is required for Queues, R2, and Durable Objects. The free tier won't work.

---

## 4. iOS Application Setup

### Step 1: Clone the repo

```bash
git clone https://github.com/Mohammad-R-Rashid/curby.git
cd curby
```

### Step 2: Configure Mapbox credentials

Mapbox requires a **secret token** (starts with `sk.`) for downloading the SDK, and a **public token** (starts with `pk.`) for runtime map access.

**a) Set up `~/.netrc` for SDK download authentication:**

```bash
# Create or append to ~/.netrc
cat >> ~/.netrc << 'EOF'
machine api.mapbox.com
  login mapbox
  password sk.YOUR_SECRET_MAPBOX_TOKEN_HERE
EOF
chmod 600 ~/.netrc
```

> [!CAUTION]
> The secret token (`sk.…`) is only used at build time to download the Mapbox SDK binary. **Never** commit it to git.

**b) Verify the public token in `Info.plist`:**

The runtime public token is already set in `Info.plist` under the key `MBXAccessToken`. If you're using a different Mapbox account, update this value:

```xml
<key>MBXAccessToken</key>
<string>pk.YOUR_PUBLIC_TOKEN_HERE</string>
```

### Step 3: Open in Xcode

```bash
open curby.xcodeproj
```

1. **Wait for Swift Package Manager** to resolve dependencies (first time takes 2-5 minutes):
   - **Mapbox Maps SDK** (`mapbox-maps-ios`, v11.0.0+) — Map rendering, annotations, camera control
   - **Phosphor Icons** (`phosphor-icons/swift`, v2.1.0+) — Icon library
2. Select a **simulator** or **physical device** as the run target.
3. **Build & Run** (`⌘R`).

### Step 4: Verify the API base URL

The app connects to the backend at the URL defined in `Info.plist`:

```xml
<key>CurbyAPIBaseURL</key>
<string>https://curby-api.shihabbilal.workers.dev</string>
```

If you deploy your own backend, update this URL to point to your Cloudflare Worker.

### iOS Permissions

The app requests these permissions (already configured in `Info.plist`):

| Permission | Why |
|:-----------|:----|
| **Location When In Use** | Show user position on map, find nearby parking |
| **Location Always** | Background detection of parking availability while driving |
| **Supports Live Activities** | Dynamic Island updates during active parking sessions |

---

## 5. Backend Setup (Cloudflare Workers)

The backend is a **pnpm monorepo** with three Cloudflare Workers and a shared package.

### Step 1: Install dependencies

```bash
cd backend
pnpm install
```

This installs dependencies for all workspace packages (`packages/*` and `workers/*`) in a single command.

### Step 2: Create the `.env` file

```bash
# backend/.env
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_SECRET_KEY=sb_secret_your_key_here
MAPBOX_ACCESS_TOKEN=pk.your_public_mapbox_token_here
```

> [!CAUTION]
> **Never commit `.env` to git.** It's already in `backend/.gitignore`.

### Step 3: Authenticate with Cloudflare

```bash
wrangler login
```

This opens a browser for OAuth. Authorize Wrangler to access your Cloudflare account.

### Step 4: Deploy

The deploy script handles everything — resource creation, secret injection, config seeding, and worker deployment:

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

**What the script does (in order):**

1. Runs `pnpm install`
2. Creates Cloudflare resources: KV namespace (`curby-config`), 2 Queues (`curby-telemetry`, `curby-sessions`), R2 bucket (`curby-telemetry-lake`)
3. Pushes secrets from `.env` to `api-gateway` and `session-consumer` via `wrangler secret bulk`
4. Seeds default algorithm weights and detection thresholds into KV
5. Deploys all 3 workers
6. Runs a health check against the deployed API

**No Cloudflare dashboard visits required** after the Supabase migration.

### Step 5: Verify deployment

```bash
curl https://curby-api.<your-subdomain>.workers.dev/health
# → {"status":"ok","ts":1713480000000}

curl https://curby-api.<your-subdomain>.workers.dev/v1/config
# → { "version": 1, "detection": {...}, "algorithm": {...}, ... }
```

### Local development

```bash
cd backend
pnpm run dev    # Starts all workers in parallel with wrangler dev
```

---

## 6. Database Setup (Supabase)

### Step 1: Create a Supabase project

Go to [supabase.com/dashboard](https://supabase.com/dashboard) and create a new project.

### Step 2: Run migrations

In the Supabase **SQL Editor**, run the following files **in order**:

1. `backend/supabase/migrations/001_initial_schema.sql` — Creates core tables: `active_parks`, `parking_events`, `routing_sessions`
2. `backend/supabase/migrations/002_rpc_permissions.sql` — Sets up RPC function permissions
3. `backend/supabase/migrations/003_service_role_parking_writes.sql` — Grants service-role write access for the backend workers

### Step 3: Grab your credentials

1. Go to **Settings → API** in the Supabase dashboard
2. Copy your **Project URL** → this is your `SUPABASE_URL`
3. Copy the **`service_role` key** (starts with `sb_secret_`) → this is your `SUPABASE_SECRET_KEY`

> [!WARNING]
> Use the **service_role** key, not the `anon` key. The backend needs elevated permissions to write parking events.

---

## 7. Environment Variables Reference

### Backend (`backend/.env`)

| Variable | Format | Where It's Used |
|:---------|:-------|:----------------|
| `SUPABASE_URL` | `https://<project-id>.supabase.co` | API gateway + session consumer — database reads/writes |
| `SUPABASE_SECRET_KEY` | `sb_secret_…` | Authenticates as service role for Supabase writes |
| `MAPBOX_ACCESS_TOKEN` | `pk.…` | API gateway — traffic data, geocoding, directions |

### iOS (`Info.plist`)

| Key | Format | Purpose |
|:----|:-------|:--------|
| `MBXAccessToken` | `pk.…` | Mapbox SDK runtime authentication |
| `CurbyAPIBaseURL` | `https://…workers.dev` | Backend API endpoint |

### Build-time (`~/.netrc`)

| Machine | Login | Password |
|:--------|:------|:---------|
| `api.mapbox.com` | `mapbox` | `sk.…` (Mapbox secret token for SDK download) |

---

## 8. Python Utility Scripts

These are **optional** — they're used for API testing and UI automation, not required to run the app.

### Install dependencies

```bash
pip install -r requirements.txt
```

**Included packages:**
- `requests` (≥2.31.0) — HTTP client for API testing
- `urllib3` (≥2.0.0) — Low-level HTTP utilities

### Available scripts

| Script | Purpose | Usage |
|:-------|:--------|:------|
| `scripts/test_parking_apis.py` | Tests the deployed parking API endpoints | `python scripts/test_parking_apis.py` |
| `update_parking_ui.py` | Automates parking UI updates | `python update_parking_ui.py` |
| `update_ui.py` | General UI automation | `python update_ui.py` |

### Backend test scripts (TypeScript)

```bash
cd backend/scripts

# Test the scoring algorithm against live traffic data
npx tsx test-austin-traffic-algorithm.ts

# Test OSM parking discovery
npx tsx test-osm-parking.ts

# Test ArcGIS data integration
npx tsx test-arcgis-algorithm.ts
```

---

## 9. Running the Full Stack Locally

Here's the order to get everything running on your machine:

```bash
# 1. Start the backend (all workers in parallel)
cd backend
pnpm run dev

# 2. Open the iOS app in Xcode (separate terminal)
cd ..
open curby.xcodeproj
# → Select simulator → ⌘R to build & run
```

The iOS app will connect to the `CurbyAPIBaseURL` defined in `Info.plist`. For local development, update it to your local Wrangler dev URL (usually `http://localhost:8787`).

---

## 10. Deployment

### Backend redeployment (after code changes)

```bash
cd backend
pnpm run deploy:all
```

This runs `wrangler deploy` in all 3 worker directories. Secrets and KV config are **not** affected.

### Updating remote config (no redeploy)

Algorithm weights, detection thresholds, and feature flags can be updated via KV without redeploying:

```bash
cd backend
CONFIG_TMP=$(mktemp)
node scripts/seed-config.js >"$CONFIG_TMP"
wrangler kv key put app_config --path="$CONFIG_TMP" --namespace-id=<YOUR_KV_ID> --remote
rm -f "$CONFIG_TMP"
```

Changes propagate globally in < 60 seconds.

### Rotating secrets

```bash
# Single secret
echo "new-value" | wrangler secret put MAPBOX_ACCESS_TOKEN \
  --config workers/api-gateway/wrangler.jsonc

# Or update .env and re-push all secrets
source .env && cd workers/api-gateway
echo "{\"SUPABASE_URL\":\"$SUPABASE_URL\",\"SUPABASE_SECRET_KEY\":\"$SUPABASE_SECRET_KEY\",\"MAPBOX_ACCESS_TOKEN\":\"$MAPBOX_ACCESS_TOKEN\"}" \
  | wrangler secret bulk
```

### iOS deployment

Build and distribute via Xcode → **Product → Archive** → upload to TestFlight / App Store Connect.

---

## 11. Troubleshooting

| Problem | Solution |
|:--------|:---------|
| **Mapbox SDK fails to download** | Verify `~/.netrc` has the correct secret token (`sk.…`) and is `chmod 600` |
| **Swift Packages won't resolve** | Xcode → File → Packages → Reset Package Caches |
| **`wrangler: command not found`** | `npm install -g wrangler` |
| **`pnpm: command not found`** | `npm install -g pnpm` |
| **Queue/R2 creation fails** | Your Cloudflare plan needs Workers Paid ($5/mo) |
| **Secrets not taking effect** | Redeploy the affected worker: `cd workers/api-gateway && wrangler deploy` |
| **Supabase connection errors** | Verify `SUPABASE_URL` has no trailing slash |
| **Map shows but no heatmaps** | Check that the API is reachable and returning data — verify `CurbyAPIBaseURL` in `Info.plist` |
| **Location not working in Simulator** | Simulator → Features → Location → set a custom location |
| **Build errors after pulling** | Clean build folder (`⌘⇧K`) and re-resolve packages |

---

> [!TIP]
> **Moving to a new Mac?** Don't forget to copy these files that are git-ignored:
> - `~/.netrc` (Mapbox SDK download auth)
> - `backend/.env` (Supabase + Mapbox secrets)
> - Any local Wrangler auth state (`~/.wrangler/`)
