#!/bin/bash
# ============================================================
# Curby Backend — Deploy Script
# ============================================================
# Reads secrets from .env, creates Cloudflare resources,
# pushes secrets to all workers, and deploys everything.
#
# Usage:
#   chmod +x scripts/deploy.sh
#   ./scripts/deploy.sh
#
# Prerequisites:
#   - Node.js 18+ and pnpm installed
#   - wrangler installed: npm i -g wrangler
#   - wrangler logged in: wrangler login
#   - .env file filled in with secrets

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Curby Backend — Deployment${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── Load .env ──────────────────────────────────────────────
if [ ! -f .env ]; then
  echo -e "${RED}ERROR: .env file not found. Copy .env and fill in your secrets.${NC}"
  exit 1
fi

source .env

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_SECRET_KEY:-}" ] || [ -z "${MAPBOX_ACCESS_TOKEN:-}" ]; then
  echo -e "${RED}ERROR: Missing secrets in .env. All 3 are required:${NC}"
  echo "  SUPABASE_URL"
  echo "  SUPABASE_SECRET_KEY"
  echo "  MAPBOX_ACCESS_TOKEN"
  exit 1
fi

echo -e "${GREEN}✓ .env loaded — all secrets present${NC}"

# ── Step 1: Install dependencies ───────────────────────────
echo -e "\n${YELLOW}[1/7] Installing dependencies...${NC}"
pnpm install

# ── Step 2: Create Cloudflare resources ────────────────────
echo -e "\n${YELLOW}[2/7] Creating Cloudflare resources (idempotent)...${NC}"

# KV Namespace — create if missing, then always resolve ID from account list
# (wrangler prints JSON like \"id\": \"...\"; older regex id: \"...\" missed that.)
echo "  Creating KV namespace: curby-config..."
KV_CREATE_OUT=$(wrangler kv namespace create curby-config 2>&1 || true)
if echo "$KV_CREATE_OUT" | grep -qi "already exists"; then
  echo -e "  ${GREEN}✓ KV namespace already exists${NC}"
else
  echo -e "  ${GREEN}✓ KV namespace created${NC}"
fi

KV_ID=$(wrangler kv namespace list 2>&1 | node -e "
  let data = '';
  process.stdin.on('data', chunk => { data += chunk; });
  process.stdin.on('end', () => {
    try {
      const start = data.indexOf('[');
      const end = data.lastIndexOf(']');
      if (start === -1 || end === -1 || end <= start) return;
      const list = JSON.parse(data.slice(start, end + 1));
      const kv = list.find(k => k.title === 'curby-config' || (k.title && String(k.title).includes('curby-config')));
      if (kv && kv.id) console.log(kv.id);
    } catch (e) {}
  });
")

if [ -z "$KV_ID" ]; then
  echo -e "${RED}ERROR: Could not resolve KV namespace id for 'curby-config'.${NC}"
  echo "  Run: wrangler kv namespace list"
  echo "  Then set workers/api-gateway/wrangler.jsonc → kv_namespaces[0].id to that id."
  exit 1
fi

echo -e "  KV ID: ${CYAN}${KV_ID}${NC}"
# Update wrangler.jsonc with the real KV ID (idempotent if unchanged)
if [ "$(uname)" = "Darwin" ]; then
  sed -i '' "s/REPLACE_WITH_YOUR_KV_NAMESPACE_ID/$KV_ID/g" workers/api-gateway/wrangler.jsonc
else
  sed -i "s/REPLACE_WITH_YOUR_KV_NAMESPACE_ID/$KV_ID/g" workers/api-gateway/wrangler.jsonc
fi
echo -e "  ${GREEN}✓ Updated wrangler.jsonc with KV ID${NC}"

# Queues
echo "  Creating queue: curby-telemetry..."
wrangler queues create curby-telemetry 2>/dev/null || echo -e "  ${GREEN}✓ Queue already exists${NC}"
echo "  Creating queue: curby-sessions..."
wrangler queues create curby-sessions 2>/dev/null || echo -e "  ${GREEN}✓ Queue already exists${NC}"

# R2 Bucket
echo "  Creating R2 bucket: curby-telemetry-lake..."
wrangler r2 bucket create curby-telemetry-lake 2>/dev/null || echo -e "  ${GREEN}✓ Bucket already exists${NC}"

echo -e "${GREEN}✓ All Cloudflare resources ready${NC}"

# ── Step 3: Push secrets to API Gateway ────────────────────
echo -e "\n${YELLOW}[3/7] Pushing secrets to api-gateway...${NC}"
cd workers/api-gateway
echo "{\"SUPABASE_URL\":\"$SUPABASE_URL\",\"SUPABASE_SECRET_KEY\":\"$SUPABASE_SECRET_KEY\",\"MAPBOX_ACCESS_TOKEN\":\"$MAPBOX_ACCESS_TOKEN\"}" | wrangler secret bulk
echo -e "${GREEN}✓ API Gateway secrets set${NC}"
cd ../..

# ── Step 4: Push secrets to Session Consumer ───────────────
echo -e "\n${YELLOW}[4/7] Pushing secrets to session-consumer...${NC}"
cd workers/session-consumer
echo "{\"SUPABASE_URL\":\"$SUPABASE_URL\",\"SUPABASE_SECRET_KEY\":\"$SUPABASE_SECRET_KEY\"}" | wrangler secret bulk
echo -e "${GREEN}✓ Session Consumer secrets set${NC}"
cd ../..

# ── Step 5: Seed remote config into KV ─────────────────────
# Wrangler 4: no --pipe; use --path (see https://developers.cloudflare.com/kv/reference/kv-commands/)
echo -e "\n${YELLOW}[5/7] Seeding remote config into KV...${NC}"
CONFIG_TMP=$(mktemp)
trap "rm -f \"$CONFIG_TMP\"" EXIT
node scripts/seed-config.js >"$CONFIG_TMP"
wrangler kv key put app_config --path="$CONFIG_TMP" --namespace-id="$KV_ID" --remote
trap - EXIT
rm -f "$CONFIG_TMP"
echo -e "${GREEN}✓ Remote config seeded${NC}"

# ── Step 6: Deploy all workers ─────────────────────────────
echo -e "\n${YELLOW}[6/7] Deploying all workers...${NC}"

echo "  Deploying api-gateway..."
API_DEPLOY_OUT=$(cd workers/api-gateway && wrangler deploy 2>&1) || {
  echo "$API_DEPLOY_OUT"
  exit 1
}
echo "$API_DEPLOY_OUT"
# workers.dev URL comes from deploy output; `wrangler deployments list` does not include it
WORKER_NAME=$(node -e "
  const fs = require('fs');
  const c = fs.readFileSync('workers/api-gateway/wrangler.jsonc', 'utf8');
  const m = c.match(/\"name\"\\s*:\\s*\"([^\"]+)\"/);
  process.stdout.write(m ? m[1] : '');
")
if [ -n "$WORKER_NAME" ]; then
  API_URL=$(echo "$API_DEPLOY_OUT" | grep -Eo "https://${WORKER_NAME}\\.[a-zA-Z0-9_-]+\\.workers\\.dev" | head -1)
fi
if [ -z "$API_URL" ]; then
  API_URL=$(echo "$API_DEPLOY_OUT" | grep -Eo 'https://[a-zA-Z0-9_.-]+\.workers\.dev' | head -1)
fi
echo -e "  ${GREEN}✓ api-gateway deployed${NC}"

echo "  Deploying telemetry-consumer..."
(cd workers/telemetry-consumer && wrangler deploy)
echo -e "  ${GREEN}✓ telemetry-consumer deployed${NC}"

echo "  Deploying session-consumer..."
(cd workers/session-consumer && wrangler deploy)
echo -e "  ${GREEN}✓ session-consumer deployed${NC}"

# ── Step 7: Verify ─────────────────────────────────────────
echo -e "\n${YELLOW}[7/7] Verifying deployment...${NC}"

if [ -n "$API_URL" ]; then
  echo -e "  API URL: ${CYAN}${API_URL}${NC}"
  echo "  Testing health endpoint..."
  HEALTH=$(curl -s "${API_URL}/health" 2>/dev/null || echo "")
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo -e "  ${GREEN}✓ Health check passed${NC}"
  else
    echo -e "  ${YELLOW}⚠ Health check returned: ${HEALTH}${NC}"
    echo "  The worker may still be propagating. Try again in 30 seconds."
  fi
else
  echo -e "  ${YELLOW}⚠ Could not detect API URL. Check Cloudflare Dashboard.${NC}"
fi

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Next steps:"
echo "  1. Run the Supabase migration SQL (see deploy.md)"
echo "  2. Test: curl <your-api-url>/health"
echo "  3. Test: curl <your-api-url>/v1/config"
echo ""
