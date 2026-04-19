// ============================================================
// Curby Remote Configuration
// ============================================================
// All tunable parameters live in Cloudflare KV.
// Workers read from KV; iOS app fetches via GET /v1/config.

export interface CurbyRemoteConfig {
  version: number;

  detection: {
    parkDetectionDurationSec: number;
    parkDetectionDriftMeters: number;
    departDetectionDurationSec: number;
    speedStationaryMs: number;
    speedWalkingMs: number;
  };

  algorithm: {
    weights: {
      availability: number;
      turnover: number;
      travelTime: number;
      walkDistance: number;
      loadBalance: number;
    };
    estimatedCapacityPerArea: number;
    recentDepartureWindowMin: number;
    durationDecayHalfLifeHours: number;
    reEvaluationIntervalSec: number;
    scoreUpdateThreshold: number;
    travelTimeDecayMin: number;
    walkTimeDecayMin: number;
    loadPenaltyK: number;
    confidenceMinUsers: number;
  };

  search: {
    defaultRadiusMeters: number;
    maxRadiusMeters: number;
    maxCandidates: number;
    occupancyRadiusMeters: number;
  };

  telemetry: {
    uploadIntervalSec: number;
    minDistanceMeters: number;
  };
}

/** Default configuration — used as fallback if KV is empty. */
export const DEFAULT_CONFIG: CurbyRemoteConfig = {
  version: 1,

  detection: {
    parkDetectionDurationSec: 120,
    parkDetectionDriftMeters: 20,
    departDetectionDurationSec: 30,
    speedStationaryMs: 0.5,
    speedWalkingMs: 2.5,
  },

  algorithm: {
    weights: {
      availability: 0.35,
      turnover: 0.15,
      travelTime: 0.25,
      walkDistance: 0.15,
      loadBalance: 0.10,
    },
    estimatedCapacityPerArea: 50,
    recentDepartureWindowMin: 15,
    durationDecayHalfLifeHours: 4,
    reEvaluationIntervalSec: 120,
    scoreUpdateThreshold: 15,
    travelTimeDecayMin: 10,
    walkTimeDecayMin: 8,
    loadPenaltyK: 3,
    confidenceMinUsers: 10,
  },

  search: {
    defaultRadiusMeters: 1000,
    maxRadiusMeters: 5000,
    maxCandidates: 9,
    occupancyRadiusMeters: 200,
  },

  telemetry: {
    uploadIntervalSec: 5,
    minDistanceMeters: 10,
  },
};

/**
 * In-memory cache. In Workers, module-level state persists
 * for the lifetime of the isolate (typically seconds to minutes).
 * In Durable Objects, it persists for the DO's lifetime.
 * This is safe and avoids unnecessary KV reads.
 */
let cachedConfig: CurbyRemoteConfig | null = null;
let cacheTimestamp = 0;
const CACHE_TTL_MS = 60_000; // 60 seconds

/**
 * Read remote config from KV with in-memory caching.
 * Falls back to DEFAULT_CONFIG if KV is empty or unavailable.
 */
export async function getConfig(kv: KVNamespace): Promise<CurbyRemoteConfig> {
  const now = Date.now();

  if (cachedConfig && now - cacheTimestamp < CACHE_TTL_MS) {
    return cachedConfig;
  }

  try {
    const raw = await kv.get('app_config', { type: 'json' });
    if (raw) {
      cachedConfig = raw as CurbyRemoteConfig;
      cacheTimestamp = now;
      return cachedConfig;
    }
  } catch {
    // KV unavailable — fall back to defaults
  }

  cachedConfig = DEFAULT_CONFIG;
  cacheTimestamp = now;
  return DEFAULT_CONFIG;
}
