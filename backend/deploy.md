# Curby Backend — Deployment Guide

## Prerequisites

| Tool | Install |
|------|---------|
| **Node.js 18+** | [nodejs.org](https://nodejs.org) or `brew install node` |
| **pnpm** | `npm install -g pnpm` |
| **Wrangler CLI** | `npm install -g wrangler` |
| **Cloudflare account** | [dash.cloudflare.com](https://dash.cloudflare.com) |
| **Supabase project** | [supabase.com/dashboard](https://supabase.com/dashboard) |

---

## Step 1: Supabase Database Setup

This is the only step that requires a dashboard. Run the migration SQL in Supabase:

1. Go to **Supabase Dashboard** → your project → **SQL Editor**
2. Paste the contents of [`supabase/migrations/001_initial_schema.sql`](./supabase/migrations/001_initial_schema.sql)
3. Click **Run**
4. Verify: go to **Table Editor** — you should see `active_parks`, `parking_events`, `routing_sessions`

Then grab your credentials:

1. Go to **Settings → API**
2. Copy your **Project URL** → this is `SUPABASE_URL`
3. Copy your **`sb_secret_*` key** → this is `SUPABASE_SECRET_KEY`

---

## Step 2: Fill in `.env`

Open `backend/.env` and fill in all 3 values:

```bash
SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co
SUPABASE_SECRET_KEY=sb_secret_xxxxxxxxxxxxxxxxxxxxxxxx
MAPBOX_ACCESS_TOKEN=pk.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> [!CAUTION]
> **Never commit `.env` to git.** It's already in `.gitignore`.

---

## Step 3: Login to Cloudflare

```bash
wrangler login
```

This opens a browser. Authorize Wrangler to access your account.

---

## Step 4: Deploy Everything

One command does it all:

```bash
cd backend
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### What the script does

| Step | Action | Dashboard needed? |
|------|--------|:-:|
| 1 | `pnpm install` | No |
| 2 | Creates KV namespace, 2 Queues, R2 bucket | No |
| 3 | Pushes secrets to `api-gateway` via `wrangler secret:bulk` | No |
| 4 | Pushes secrets to `session-consumer` via `wrangler secret:bulk` | No |
| 5 | Seeds default remote config into KV | No |
| 6 | Deploys all 3 workers (`wrangler deploy`) | No |
| 7 | Health check on the deployed API | No |

**Zero dashboard visits** after the Supabase migration.

---

## Step 5: Verify

```bash
# Health check
curl https://curby-api.<your-subdomain>.workers.dev/health
# → {"status":"ok","ts":1713480000000}

# Config endpoint
curl https://curby-api.<your-subdomain>.workers.dev/v1/config
# → { "version": 1, "detection": {...}, "algorithm": {...}, ... }
```

---

## Deployed Resources

After deployment, you'll have:

| Resource | Name | Type |
|----------|------|------|
| **Worker** | `curby-api` | API Gateway + Durable Object |
| **Worker** | `curby-telemetry-consumer` | Queue consumer → R2 |
| **Worker** | `curby-session-consumer` | Queue consumer → Supabase |
| **KV Namespace** | `curby-config` | Remote config store |
| **Queue** | `curby-telemetry` | GPS telemetry pipeline |
| **Queue** | `curby-sessions` | Session event pipeline |
| **R2 Bucket** | `curby-telemetry-lake` | Raw telemetry archive |
| **Durable Object** | `RegionCoordinatorDO` | Per-region load balancer |

---

## Updating Secrets Later

If you need to rotate a secret:

```bash
cd backend

# Single secret
echo "new-value" | wrangler secret put MAPBOX_ACCESS_TOKEN --config workers/api-gateway/wrangler.jsonc

# Or update .env and re-push all secrets at once
source .env
cd workers/api-gateway
echo "{\"SUPABASE_URL\":\"$SUPABASE_URL\",\"SUPABASE_SECRET_KEY\":\"$SUPABASE_SECRET_KEY\",\"MAPBOX_ACCESS_TOKEN\":\"$MAPBOX_ACCESS_TOKEN\"}" | wrangler secret:bulk
```

---

## Updating Remote Config

Change algorithm weights, detection thresholds, etc. without redeploying:

```bash
# Edit the config
node -e "
  const c = $(node scripts/seed-config.js);
  c.version = 2;
  c.algorithm.weights.availability = 0.35;
  console.log(JSON.stringify(c));
" | wrangler kv:key put --namespace-id=<YOUR_KV_ID> "app_config" --pipe
```

Or go to **Cloudflare Dashboard → KV → curby-config → edit `app_config`** and paste updated JSON.

Changes propagate globally in < 60 seconds. No redeploy needed.

---

## Redeploying After Code Changes

```bash
cd backend
pnpm run deploy:all
```

This runs `wrangler deploy` in all 3 worker directories. Secrets and KV are not affected.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `wrangler: command not found` | `npm install -g wrangler` |
| `pnpm: command not found` | `npm install -g pnpm` |
| Queue/R2 create fails | Your Cloudflare plan may need Workers Paid ($5/mo) |
| Secrets not taking effect | Redeploy the affected worker: `cd workers/api-gateway && wrangler deploy` |
| KV ID not detected by script | Find it in Cloudflare Dashboard → KV, or run `wrangler kv:namespace list` |
| Supabase connection errors | Verify `SUPABASE_URL` doesn't have a trailing slash |
