// ============================================================
// Curby Shared Types
// ============================================================

// ─── Geo Primitives ─────────────────────────────────────────

export interface LatLng {
  lat: number;
  lng: number;
}

export interface BBox {
  sw: LatLng;
  ne: LatLng;
}

// ─── Telemetry ──────────────────────────────────────────────

export interface TelemetryPayload {
  userId: string;
  lat: number;
  lng: number;
  speed: number;       // m/s
  heading: number;     // degrees
  accuracy: number;    // horizontal accuracy in metres
  timestamp: string;   // ISO 8601
}

// ─── Park/Depart Events ────────────────────────────────────

export interface ParkEventPayload {
  userId: string;
  lat: number;
  lng: number;
  timestamp: string;
}

export interface DepartEventPayload {
  userId: string;
  timestamp: string;
}

// ─── Mapbox Data ────────────────────────────────────────────

export interface MapboxParkingArea {
  id: string;
  name: string;
  center: LatLng;
  category: string;   // 'parking_lot', 'parking_garage', 'parking', etc.
  /** Discovery source — used for logging / reasoning; same scoring pipeline for all. */
  dataSource?: 'mapbox' | 'osm';
}

export interface MapboxMatrixResult {
  /** Travel time in seconds to each destination */
  durations: number[];
  /** Distance in meters to each destination */
  distances: number[];
}

export interface MapboxDirectionsResult {
  travelTimeSec: number;
  distanceMeters: number;
  geometry: GeoJSONLineString;
  congestionNumeric: number[];
  segmentDistances: number[];
}

export interface GeoJSONLineString {
  type: 'LineString';
  coordinates: [number, number][];
}

// ─── Algorithm Types ────────────────────────────────────────

export interface ParkingCandidate {
  area: MapboxParkingArea;

  traffic: {
    travelTimeMin: number;
    distanceMeters: number;
    walkTimeMin: number;
    // Available after Phase 1 (Matrix API — approximate)
    freeFlowSec?: number;
    trafficAwareSec?: number;
    // Available after Phase 2 (Directions API — precise, top 3 only)
    congestionNumeric?: number[];
    segmentDistances?: number[];
    routeGeometry?: GeoJSONLineString;
  };

  occupancy: {
    parkedCount: number;
    recentDepartures: number;
    departureRate: number;        // departures per minute
    arrivalRate: number;          // arrivals per minute
    parkDurations: number[];      // minutes each car has been parked
    recentUniqueUsers: number;    // unique contributors in 24h
  };
}

export interface ScoredArea {
  areaId: string;
  score: number;           // 0-1, higher = better
  breakdown: {
    availability: number;
    turnover: number;
    travelTime: number;
    congestion: number;
    walkDistance: number;
    loadBalance: number;
    confidence: number;
  };
  reasoning: string;
}

// ─── Session Events ─────────────────────────────────────────

export type SessionEventType = 'created' | 'arrived' | 'cancelled' | 'expired';

export interface SessionEvent {
  type: SessionEventType;
  sessionId: string;
  userId: string;
  destination: LatLng;
  searchRadiusM: number;
  recommendedArea?: MapboxParkingArea;
  alternatives?: ScoredArea[];
  routeGeometry?: GeoJSONLineString;
  etaSeconds?: number;
  score?: number;
  timestamp: string;
}

// ─── WebSocket Protocol ─────────────────────────────────────

// Client → Server
export type WSCommand =
  | { type: 'find_parking'; destLat: number; destLng: number; radius?: number }
  | { type: 'arrived'; sessionId: string }
  | { type: 'cancel'; sessionId: string }
  | { type: 'accept_update'; sessionId: string }
  | { type: 'reject_update'; sessionId: string }
  | { type: 'heartbeat' };

// Server → Client
export type WSEvent =
  | {
      type: 'recommendation';
      sessionId: string;
      area: MapboxParkingArea;
      route: {
        geometry: GeoJSONLineString;
        travelTimeSec: number;
        distanceMeters: number;
        walkTimeSec: number;
      };
      score: ScoredArea;
      reasoning: string;
    }
  | {
      type: 'route_update';
      sessionId: string;
      newArea: MapboxParkingArea;
      newRoute: {
        geometry: GeoJSONLineString;
        travelTimeSec: number;
        distanceMeters: number;
        walkTimeSec: number;
      };
      newScore: ScoredArea;
      reason: string;
    }
  | { type: 'no_data'; message: string }
  | { type: 'error'; code: string; message: string }
  | { type: 'heartbeat_ack' }
  | { type: 'confirmed'; sessionId: string };

// ─── Worker Env ─────────────────────────────────────────────

export interface Env {
  // Durable Objects
  REGION_COORDINATOR: DurableObjectNamespace;
  // Queues
  TELEMETRY_QUEUE: Queue<TelemetryPayload>;
  SESSION_QUEUE: Queue<SessionEvent>;
  // R2
  TELEMETRY_LAKE: R2Bucket;
  // KV
  CURBY_CONFIG: KVNamespace;
  // Secrets
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY: string;
  MAPBOX_ACCESS_TOKEN: string;
}
