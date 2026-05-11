// ============================================================
// API Gateway — Main Router
// ============================================================

import type { Env } from '@curby/shared';
import { handleTelemetry } from './routes/telemetry.js';
import { handleParkEvent, handleDepartEvent } from './routes/events.js';
import { handleConfig } from './routes/config.js';
import { handleWebSocketUpgrade } from './routes/websocket.js';
import { handleParkingHeatMap } from './routes/heat-map.js';

// Re-export the Durable Object class so Wrangler bundles it
export { RegionCoordinatorDO } from './durable-objects/RegionCoordinatorDO.js';

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    // CORS headers for all responses
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, X-User-Id',
    };

    // Handle preflight
    if (method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    try {
      let response: Response;

      switch (true) {
        // Health check
        case path === '/health' && method === 'GET':
          response = new Response(JSON.stringify({ status: 'ok', ts: Date.now() }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          });
          break;

        // Telemetry ingestion → Queue
        case path === '/v1/telemetry' && method === 'POST':
          response = await handleTelemetry(request, env);
          break;

        // Park event → Supabase
        case path === '/v1/events/park' && method === 'POST':
          response = await handleParkEvent(request, env);
          break;

        // Depart event → Supabase
        case path === '/v1/events/depart' && method === 'POST':
          response = await handleDepartEvent(request, env);
          break;

        // Remote config → KV
        case path === '/v1/config' && method === 'GET':
          response = await handleConfig(request, env);
          break;

        // Parking heat map → Mapbox vector tiles + Supabase
        case path === '/v1/parking-heat-map' && method === 'GET':
          response = await handleParkingHeatMap(request, env);
          break;

        // WebSocket upgrade → Durable Object
        case path === '/v1/park' && request.headers.get('Upgrade') === 'websocket':
          response = await handleWebSocketUpgrade(request, env);
          break;

        default:
          response = new Response(
            JSON.stringify({ error: 'Not Found', path }),
            { status: 404, headers: { 'Content-Type': 'application/json' } },
          );
      }

      // WebSocket upgrade responses cannot have headers mutated after creation.
      if (response.status === 101) {
        return response;
      }

      // Append CORS headers to every HTTP response
      for (const [k, v] of Object.entries(corsHeaders)) {
        response.headers.set(k, v);
      }

      return response;
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Internal Server Error';
      console.error('Router error:', message);
      return new Response(
        JSON.stringify({ error: message }),
        {
          status: 500,
          headers: { 'Content-Type': 'application/json', ...corsHeaders },
        },
      );
    }
  },
};
