// ============================================================
// Route: POST /v1/telemetry
// ============================================================
// Validates GPS telemetry and enqueues to Cloudflare Queue.
// Returns 202 Accepted immediately — processing is async.

import type { Env } from '@curby/shared';
import { TelemetryPayloadSchema } from '@curby/shared';

export async function handleTelemetry(request: Request, env: Env): Promise<Response> {
  const body = await request.json();
  const parsed = TelemetryPayloadSchema.safeParse(body);

  if (!parsed.success) {
    return new Response(
      JSON.stringify({ error: 'Invalid payload', details: parsed.error.flatten() }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  await env.TELEMETRY_QUEUE.send(parsed.data);

  return new Response(null, { status: 202 });
}
