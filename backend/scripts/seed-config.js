#!/usr/bin/env node
// ============================================================
// Seed Remote Config into Cloudflare KV
// ============================================================
// Usage: npx wrangler kv:key put --namespace-id=<ID> "app_config" --path=./config.json
//
// Or run this script which outputs the default config JSON
// that you can then paste into the KV dashboard.

const DEFAULT_CONFIG = {
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
      availability: 0.30,
      turnover: 0.10,
      travelTime: 0.20,
      congestion: 0.10,
      walkDistance: 0.15,
      loadBalance: 0.10,
      confidence: 0.05,
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

// Output for piping to wrangler or pasting into dashboard
console.log(JSON.stringify(DEFAULT_CONFIG, null, 2));
