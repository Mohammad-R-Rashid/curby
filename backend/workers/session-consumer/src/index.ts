// ============================================================
// Session Consumer — Queue → Supabase routing_sessions
// ============================================================
// Persists parking recommendation events to the routing_sessions
// table for analytics and algorithm evaluation.

import type { SessionEvent } from '@curby/shared';
import { getSupabase } from '@curby/shared';

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY: string;
}

export default {
  async queue(
    batch: MessageBatch<SessionEvent>,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<void> {
    if (batch.messages.length === 0) return;

    const supabase = getSupabase(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY);

    for (const msg of batch.messages) {
      const event = msg.body;

      try {
        switch (event.type) {
          case 'created': {
            // Use RPC to handle PostGIS geometry insert
            const { error } = await supabase.rpc('insert_routing_session', {
              p_id: event.sessionId,
              p_user_id: event.userId,
              p_dest_lat: event.destination.lat,
              p_dest_lng: event.destination.lng,
              p_search_radius_m: event.searchRadiusM,
              p_recommended_area: event.recommendedArea ?? {},
              p_alternatives: event.alternatives ?? null,
              p_route_geometry: event.routeGeometry ?? null,
              p_eta_seconds: event.etaSeconds ?? null,
              p_score: event.score ?? null,
            });

            if (error) {
              console.error('Insert routing_session error:', error);
              msg.retry();
              continue;
            }
            break;
          }

          case 'arrived':
          case 'cancelled':
          case 'expired': {
            const status = event.type === 'arrived' ? 'arrived'
              : event.type === 'cancelled' ? 'cancelled'
              : 'expired';

            const { error } = await supabase
              .from('routing_sessions')
              .update({
                status,
                resolved_at: new Date().toISOString(),
              })
              .eq('id', event.sessionId);

            if (error) {
              console.error(`Update routing_session (${status}) error:`, error);
              msg.retry();
              continue;
            }
            break;
          }
        }

        msg.ack();
      } catch (err) {
        console.error('Session consumer error:', err);
        msg.retry();
      }
    }
  },
};
