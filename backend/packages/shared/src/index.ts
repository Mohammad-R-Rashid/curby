// ============================================================
// @curby/shared — Public API
// ============================================================

// Types
export type {
  LatLng,
  BBox,
  TelemetryPayload,
  ParkEventPayload,
  DepartEventPayload,
  MapboxParkingArea,
  MapboxMatrixResult,
  MapboxDirectionsResult,
  GeoJSONLineString,
  ParkingCandidate,
  ScoredArea,
  SessionEvent,
  SessionEventType,
  WSCommand,
  WSEvent,
  Env,
} from './types.js';

// Config
export type { CurbyRemoteConfig } from './config.js';
export { DEFAULT_CONFIG, getConfig } from './config.js';

// Validation
export {
  TelemetryPayloadSchema,
  ParkEventSchema,
  DepartEventSchema,
  WSCommandSchema,
} from './validation.js';

// Algorithm
export { scoreAllAreas } from './algorithm.js';

// Geohash
export { encodeGeohash, decodeGeohash, regionGeohash } from './geohash.js';

// Mapbox
export {
  searchParkingAreas,
  matrixDriving,
  matrixWalking,
  getDirections,
} from './mapbox.js';

// OSM + merged discovery
export { searchOsmParkingAreas, classifyOsmParkingCategory } from './osm.js';
export { discoverParkingAreas } from './parking-discovery.js';
export { distanceMeters, isWithinAustinArea, AUSTIN_BBOX } from './geo.js';

// Supabase
export { getSupabase } from './supabase.js';
