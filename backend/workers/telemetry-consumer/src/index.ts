// ============================================================
// Telemetry Consumer — Queue → R2
// ============================================================
// Receives batches of GPS telemetry from the queue,
// serializes as NDJSON, and stores in R2 for long-term archive.
// No Supabase write — keeps costs minimal.

import type { TelemetryPayload } from '@curby/shared';

interface Env {
  TELEMETRY_LAKE: R2Bucket;
}

export default {
  async queue(
    batch: MessageBatch<TelemetryPayload>,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<void> {
    if (batch.messages.length === 0) return;

    // Serialize batch as NDJSON
    const ndjson = batch.messages
      .map((msg) => JSON.stringify(msg.body))
      .join('\n') + '\n';

    // Generate R2 key: raw/{YYYY}/{MM}/{DD}/{HH}:{mm}:{ss}-{uuid}.ndjson
    const now = new Date();
    const yyyy = now.getUTCFullYear();
    const mm = String(now.getUTCMonth() + 1).padStart(2, '0');
    const dd = String(now.getUTCDate()).padStart(2, '0');
    const hh = String(now.getUTCHours()).padStart(2, '0');
    const min = String(now.getUTCMinutes()).padStart(2, '0');
    const ss = String(now.getUTCSeconds()).padStart(2, '0');
    const uuid = crypto.randomUUID();

    const key = `raw/${yyyy}/${mm}/${dd}/${hh}:${min}:${ss}-${uuid}.ndjson`;

    // Write to R2
    await env.TELEMETRY_LAKE.put(key, ndjson, {
      httpMetadata: { contentType: 'application/x-ndjson' },
      customMetadata: {
        messageCount: String(batch.messages.length),
        batchTimestamp: now.toISOString(),
      },
    });

    // Acknowledge all messages
    batch.ackAll();
  },
};
