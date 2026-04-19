// ============================================================
// RegionCoordinatorDO — The Brain
// ============================================================
// One instance per geographic region (~20km²).
// Handles WebSocket connections, runs the 7-factor scoring
// algorithm, and load-balances parking recommendations.
//
// Uses the Hibernation API for efficient WebSocket management.

import { DurableObject } from 'cloudflare:workers';
import type { Env, WSCommand, WSEvent, ParkingCandidate, SessionEvent, LatLng } from '@curby/shared';
import {
  getConfig,
  WSCommandSchema,
  scoreAllAreas,
  searchParkingAreas,
  matrixDriving,
  matrixWalking,
  getDirections,
  getSupabase,
} from '@curby/shared';
import type { DOSession } from './types.js';

export class RegionCoordinatorDO extends DurableObject<Env> {
  /** How many users are currently being routed to each parking area */
  private activeRouting: Map<string, number> = new Map();

  /** Connected WebSocket sessions (keyed by userId) */
  private sessions: Map<string, DOSession> = new Map();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // When DO wakes from hibernation, in-memory Maps are dead.
    // Restore state from WebSocket attachments!
    this.restoreState();
  }

  private restoreState() {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        const attachment = ws.deserializeAttachment() as Omit<DOSession, 'ws'>;
        if (attachment) {
          this.sessions.set(attachment.userId, { ...attachment, ws });
          if (attachment.recommendedArea) {
            const count = this.activeRouting.get(attachment.recommendedArea) ?? 0;
            this.activeRouting.set(attachment.recommendedArea, count + 1);
          }
        }
      } catch {
        // Ignored
      }
    }
  }

  private updateSession(ws: WebSocket, updates: Partial<Omit<DOSession, 'ws'>>) {
    const session = this.findSession(ws);
    if (!session) return;
    Object.assign(session, updates);
    // Persist to Hibernation attachment
    const { ws: _ws, ...attachment } = session;
    ws.serializeAttachment(attachment);
  }

  // ─── WebSocket Lifecycle (Hibernation API) ────────────────

  async fetch(request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    const url = new URL(request.url);
    const userId = url.searchParams.get('userId') || crypto.randomUUID();
    const lat = Number(url.searchParams.get('lat'));
    const lng = Number(url.searchParams.get('lng'));

    // Accept with hibernation
    this.ctx.acceptWebSocket(server, [userId]);

    // Prepare session data
    const sessionData: Omit<DOSession, 'ws'> = {
      userId,
      userLocation: { lat, lng },
      destination: { lat, lng }, // Will be updated when find_parking is called
      status: 'searching',
    };

    // Store in Hibernation state
    server.serializeAttachment(sessionData);

    // Store in-memory session 
    this.sessions.set(userId, {
      ws: server,
      ...sessionData,
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const raw = typeof message === 'string' ? message : new TextDecoder().decode(message);

    let parsed: WSCommand;
    try {
      const json = JSON.parse(raw);
      const result = WSCommandSchema.safeParse(json);
      if (!result.success) {
        this.send(ws, { type: 'error', code: 'INVALID_COMMAND', message: result.error.message });
        return;
      }
      parsed = result.data;
    } catch {
      this.send(ws, { type: 'error', code: 'PARSE_ERROR', message: 'Invalid JSON' });
      return;
    }

    switch (parsed.type) {
      case 'find_parking':
        await this.handleFindParking(ws, parsed.destLat, parsed.destLng, parsed.radius);
        break;

      case 'arrived':
        await this.handleArrived(ws, parsed.sessionId);
        break;

      case 'cancel':
        await this.handleCancel(ws, parsed.sessionId);
        break;

      case 'accept_update':
        // Client accepted a route update — no action needed, state already updated
        break;

      case 'reject_update':
        // Client rejected — keep current route, no state change
        break;

      case 'heartbeat':
        this.send(ws, { type: 'heartbeat_ack' });
        break;
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    // Find the session for this WebSocket
    for (const [userId, session] of this.sessions) {
      if (session.ws === ws) {
        // Decrement routing count
        if (session.recommendedArea) {
          const count = this.activeRouting.get(session.recommendedArea) ?? 0;
          if (count <= 1) {
            this.activeRouting.delete(session.recommendedArea);
          } else {
            this.activeRouting.set(session.recommendedArea, count - 1);
          }
        }
        this.sessions.delete(userId);
        break;
      }
    }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    console.error('WebSocket error:', error);
    await this.webSocketClose(ws, 1011, 'WebSocket error');
  }

  // ─── Core: Find Parking ───────────────────────────────────
  // This is the main algorithm pipeline:
  // Phase 1: Broad screening (4 API calls)
  // Phase 2: Detailed routing (3 API calls for top 3)

  private async handleFindParking(
    ws: WebSocket,
    destLat: number,
    destLng: number,
    radius?: number,
  ): Promise<void> {
    const config = await getConfig(this.env.CURBY_CONFIG);
    const searchRadius = radius ?? config.search.defaultRadiusMeters;
    const destination: LatLng = { lat: destLat, lng: destLng };

    // Find the session
    const session = this.findSession(ws);
    if (!session) {
      this.send(ws, { type: 'error', code: 'NO_SESSION', message: 'Session not found' });
      return;
    }
    this.updateSession(ws, { 
      destination, 
      status: 'searching' 
    });

    try {
      // ── PHASE 1: Broad Screening ────────────────────────

      // 1. Find parking areas near destination
      const areas = await searchParkingAreas(
        destination,
        searchRadius,
        config.search.maxCandidates,
        this.env.MAPBOX_ACCESS_TOKEN,
      );

      if (areas.length === 0) {
        this.send(ws, { type: 'no_data', message: 'No parking areas found near your destination' });
        return;
      }

      // 2. Parallel data gathering
      const areaCenters = areas.map((a) => a.center);

      // User's current location for driving matrix (from WebSocket URL params)
      const userLocation = session.userLocation;

      const [drivingData, walkingTimes, occupancyData, departureData, durationData, confidenceData] =
        await Promise.all([
          // Mapbox Matrix: user's location → all parking areas (driving-traffic)
          matrixDriving(
            userLocation,
            areaCenters,
            this.env.MAPBOX_ACCESS_TOKEN,
          ),
          // Mapbox Matrix: all parking areas → destination (walking)
          matrixWalking(areaCenters, destination, this.env.MAPBOX_ACCESS_TOKEN),
          // Supabase: batch occupancy counts
          this.batchOccupancy(areaCenters, config.search.occupancyRadiusMeters),
          // Supabase: batch departure counts
          this.batchDepartures(areaCenters, config.search.occupancyRadiusMeters, config.algorithm.recentDepartureWindowMin),
          // Supabase: batch park durations
          this.batchDurations(areaCenters, config.search.occupancyRadiusMeters),
          // Supabase: batch confidence (unique users)
          this.batchConfidence(areaCenters, config.search.occupancyRadiusMeters),
        ]);

      // 3. Build ParkingCandidate[] with all data
      const candidates: ParkingCandidate[] = areas.map((area, idx) => ({
        area,
        traffic: {
          travelTimeMin: (drivingData.durations[idx] ?? 600) / 60, // sec → min
          distanceMeters: drivingData.distances[idx] ?? 0,
          walkTimeMin: (walkingTimes[idx] ?? 600) / 60,
          trafficAwareSec: drivingData.durations[idx] ?? 600,
          // freeFlowSec estimated as 70% of traffic-aware time (rough heuristic)
          freeFlowSec: (drivingData.durations[idx] ?? 600) * 0.7,
        },
        occupancy: {
          parkedCount: occupancyData[idx] ?? 0,
          recentDepartures: departureData[idx] ?? 0,
          departureRate: (departureData[idx] ?? 0) / config.algorithm.recentDepartureWindowMin,
          parkDurations: durationData[idx] ?? [],
          recentUniqueUsers: confidenceData[idx] ?? 0,
        },
      }));

      // 4. Run 7-factor scoring algorithm
      const scored = scoreAllAreas(candidates, this.activeRouting, config.algorithm);

      if (scored.length === 0) {
        this.send(ws, { type: 'no_data', message: 'Could not score any parking areas' });
        return;
      }

      // ── PHASE 2: Detailed Routing (top 3) ───────────────

      // Get full Directions for top 3 candidates (congestion annotations)
      const top3 = scored.slice(0, 3);
      const top3Candidates = top3.map((s) => candidates.find((c) => c.area.id === s.areaId)!);

      const directionsResults = await Promise.all(
        top3Candidates.map((c) =>
          getDirections(
            session.userLocation, // User's current location
            c.area.center,
            this.env.MAPBOX_ACCESS_TOKEN,
          ),
        ),
      );

      // Enrich top 3 candidates with precise congestion data and re-score
      for (let i = 0; i < top3Candidates.length; i++) {
        const dir = directionsResults[i];
        if (dir) {
          top3Candidates[i].traffic.congestionNumeric = dir.congestionNumeric;
          top3Candidates[i].traffic.segmentDistances = dir.segmentDistances;
          top3Candidates[i].traffic.routeGeometry = dir.geometry;
          top3Candidates[i].traffic.travelTimeMin = dir.travelTimeSec / 60;
        }
      }

      // Re-score top 3 with precise data
      const reScored = scoreAllAreas(top3Candidates, this.activeRouting, config.algorithm);
      const best = reScored[0];
      const bestCandidate = top3Candidates.find((c) => c.area.id === best.areaId)!;

      // 5. Update state
      const sessionId = crypto.randomUUID();
      const prevArea = session.recommendedArea;
      if (prevArea) {
        const count = this.activeRouting.get(prevArea) ?? 0;
        if (count <= 1) this.activeRouting.delete(prevArea);
        else this.activeRouting.set(prevArea, count - 1);
      }
      this.activeRouting.set(
        best.areaId,
        (this.activeRouting.get(best.areaId) ?? 0) + 1,
      );
      this.updateSession(ws, {
        recommendedArea: best.areaId,
        sessionId,
        status: 'routing',
      });

      // 6. Send recommendation via WebSocket
      const recommendation: WSEvent = {
        type: 'recommendation',
        sessionId,
        area: bestCandidate.area,
        route: {
          geometry: bestCandidate.traffic.routeGeometry ?? { type: 'LineString', coordinates: [] },
          travelTimeSec: bestCandidate.traffic.travelTimeMin * 60,
          distanceMeters: bestCandidate.traffic.distanceMeters,
          walkTimeSec: bestCandidate.traffic.walkTimeMin * 60,
        },
        score: best,
        reasoning: best.reasoning,
      };
      this.send(ws, recommendation);

      // 7. Enqueue session event for persistence
      const sessionEvent: SessionEvent = {
        type: 'created',
        sessionId,
        userId: session.userId,
        destination,
        searchRadiusM: searchRadius,
        recommendedArea: bestCandidate.area,
        alternatives: reScored.slice(1),
        routeGeometry: bestCandidate.traffic.routeGeometry,
        etaSeconds: Math.round(bestCandidate.traffic.travelTimeMin * 60),
        score: best.score,
        timestamp: new Date().toISOString(),
      };
      await this.env.SESSION_QUEUE.send(sessionEvent);

      // 8. Set alarm for re-evaluation
      await this.ctx.storage.setAlarm(
        Date.now() + config.algorithm.reEvaluationIntervalSec * 1000,
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      console.error('findParking error:', message);
      this.send(ws, { type: 'error', code: 'INTERNAL_ERROR', message });
    }
  }

  // ─── Handle Arrived ───────────────────────────────────────

  private async handleArrived(ws: WebSocket, sessionId: string): Promise<void> {
    const session = this.findSession(ws);
    if (!session || session.sessionId !== sessionId) return;

    // Decrement routing count
    if (session.recommendedArea) {
      const count = this.activeRouting.get(session.recommendedArea) ?? 0;
      if (count <= 1) {
        this.activeRouting.delete(session.recommendedArea);
      } else {
        this.activeRouting.set(session.recommendedArea, count - 1);
      }
    }

    this.updateSession(ws, { status: 'arrived' });
    this.send(ws, { type: 'confirmed', sessionId });

    // Log to session queue
    await this.env.SESSION_QUEUE.send({
      type: 'arrived',
      sessionId,
      userId: session.userId,
      destination: session.destination,
      searchRadiusM: 0,
      timestamp: new Date().toISOString(),
    });
  }

  // ─── Handle Cancel ────────────────────────────────────────

  private async handleCancel(ws: WebSocket, sessionId: string): Promise<void> {
    const session = this.findSession(ws);
    if (!session || session.sessionId !== sessionId) return;

    // Decrement routing count
    if (session.recommendedArea) {
      const count = this.activeRouting.get(session.recommendedArea) ?? 0;
      if (count <= 1) {
        this.activeRouting.delete(session.recommendedArea);
      } else {
        this.activeRouting.set(session.recommendedArea, count - 1);
      }
    }

    this.updateSession(ws, {
      status: 'searching',
      recommendedArea: undefined,
    });

    await this.env.SESSION_QUEUE.send({
      type: 'cancelled',
      sessionId,
      userId: session.userId,
      destination: session.destination,
      searchRadiusM: 0,
      timestamp: new Date().toISOString(),
    });
  }

  // ─── Alarm: Re-evaluation ─────────────────────────────────

  async alarm(): Promise<void> {
    const config = await getConfig(this.env.CURBY_CONFIG);

    // Re-evaluate for all actively routing sessions
    for (const [_, session] of this.sessions) {
      if (session.status !== 'routing' || !session.recommendedArea) continue;

      // Re-run the full pipeline
      // In a production system, we'd be smarter about caching, but
      // for v1, just re-run handleFindParking
      await this.handleFindParking(
        session.ws,
        session.destination.lat,
        session.destination.lng,
      );
    }

    // If there are still active routing sessions, set next alarm
    const hasActiveRouting = Array.from(this.sessions.values()).some(
      (s) => s.status === 'routing',
    );
    if (hasActiveRouting) {
      await this.ctx.storage.setAlarm(
        Date.now() + config.algorithm.reEvaluationIntervalSec * 1000,
      );
    }
  }

  // ─── Supabase Helpers ─────────────────────────────────────

  private async batchOccupancy(points: LatLng[], radiusM: number): Promise<number[]> {
    const supabase = getSupabase(this.env.SUPABASE_URL, this.env.SUPABASE_SECRET_KEY);
    const pointsJson = points.map((p) => ({ lat: p.lat, lng: p.lng }));

    const { data, error } = await supabase.rpc('batch_occupancy', {
      points: pointsJson,
      radius_m: radiusM,
    });

    if (error) {
      console.error('batch_occupancy error:', error);
      return points.map(() => 0);
    }

    const result = new Array(points.length).fill(0);
    for (const row of data ?? []) {
      result[row.idx] = Number(row.parked_count);
    }
    return result;
  }

  private async batchDepartures(points: LatLng[], radiusM: number, windowMin: number): Promise<number[]> {
    const supabase = getSupabase(this.env.SUPABASE_URL, this.env.SUPABASE_SECRET_KEY);
    const pointsJson = points.map((p) => ({ lat: p.lat, lng: p.lng }));

    const { data, error } = await supabase.rpc('batch_departures', {
      points: pointsJson,
      radius_m: radiusM,
      window_min: windowMin,
    });

    if (error) {
      console.error('batch_departures error:', error);
      return points.map(() => 0);
    }

    const result = new Array(points.length).fill(0);
    for (const row of data ?? []) {
      result[row.idx] = Number(row.departure_count);
    }
    return result;
  }

  private async batchDurations(points: LatLng[], radiusM: number): Promise<number[][]> {
    const supabase = getSupabase(this.env.SUPABASE_URL, this.env.SUPABASE_SECRET_KEY);
    const pointsJson = points.map((p) => ({ lat: p.lat, lng: p.lng }));

    const { data, error } = await supabase.rpc('batch_durations', {
      points: pointsJson,
      radius_m: radiusM,
    });

    if (error) {
      console.error('batch_durations error:', error);
      return points.map(() => []);
    }

    const result: number[][] = points.map(() => []);
    for (const row of data ?? []) {
      result[row.idx] = (row.durations_min as number[]) ?? [];
    }
    return result;
  }

  private async batchConfidence(points: LatLng[], radiusM: number): Promise<number[]> {
    const supabase = getSupabase(this.env.SUPABASE_URL, this.env.SUPABASE_SECRET_KEY);
    const pointsJson = points.map((p) => ({ lat: p.lat, lng: p.lng }));

    const { data, error } = await supabase.rpc('batch_confidence', {
      points: pointsJson,
      radius_m: radiusM,
    });

    if (error) {
      console.error('batch_confidence error:', error);
      return points.map(() => 0);
    }

    const result = new Array(points.length).fill(0);
    for (const row of data ?? []) {
      result[row.idx] = Number(row.unique_users);
    }
    return result;
  }

  // ─── Utilities ────────────────────────────────────────────

  private findSession(ws: WebSocket): DOSession | undefined {
    for (const session of this.sessions.values()) {
      if (session.ws === ws) return session;
    }
    return undefined;
  }

  private send(ws: WebSocket, event: WSEvent): void {
    try {
      ws.send(JSON.stringify(event));
    } catch (err) {
      console.error('Failed to send WebSocket message:', err);
    }
  }
}
