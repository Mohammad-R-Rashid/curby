// ============================================================
// Route: GET /v1/config
// ============================================================
// Returns remote config from Cloudflare KV.
// Supports ?version=N for conditional 304 responses.

import type { Env } from '@curby/shared';
import { getConfig } from '@curby/shared';

export async function handleConfig(request: Request, env: Env): Promise<Response> {
  const config = await getConfig(env.CURBY_CONFIG);

  // Support conditional request: if client already has this version, 304
  const url = new URL(request.url);
  const clientVersion = url.searchParams.get('version');

  if (clientVersion && Number(clientVersion) === config.version) {
    return new Response(null, { status: 304 });
  }

  return new Response(JSON.stringify(config), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=60',
    },
  });
}
