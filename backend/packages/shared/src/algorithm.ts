// ============================================================
// Curby Parking Load Balancer — 5-Factor Scoring Algorithm
// ============================================================
//
// S(i) = w₁·f_avail + w₂·f_turn + w₃·f_travel + w₄·f_walk + w₅·f_load
//
// NORMALIZATION GUARANTEES:
//   1. Every factor fⱼ ∈ [0, 1] — enforced by clamp()
//   2. Weights are normalized to sum = 1.0 at runtime
//      → S(i) ∈ [0, 1] is GUARANTEED regardless of config
//   3. Data confidence modulates availability + turnover
//      so no-data areas can't get artificially high scores.
//   4. Deterministic tiebreaker (areaId) prevents sort instability
//
// All weights come from remote config (Cloudflare KV).

import type { ParkingCandidate, ScoredArea } from './types.js';
import type { CurbyRemoteConfig } from './config.js';

// ─── Helpers ────────────────────────────────────────────────

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

/**
 * Normalize weights so they always sum to exactly 1.0.
 * This prevents score range drift if remote config weights
 * are misconfigured (e.g. someone adds a weight without
 * reducing others).
 */
function normalizeWeights(
  raw: CurbyRemoteConfig['algorithm']['weights'],
): CurbyRemoteConfig['algorithm']['weights'] {
  const sum =
    raw.availability +
    raw.turnover +
    raw.travelTime +
    raw.walkDistance +
    raw.loadBalance;

  // Guard against zero/negative sum
  if (sum <= 0) {
    // Fall back to equal weights
    const eq = 1 / 5;
    return {
      availability: eq,
      turnover: eq,
      travelTime: eq,
      walkDistance: eq,
      loadBalance: eq,
    };
  }

  return {
    availability: raw.availability / sum,
    turnover: raw.turnover / sum,
    travelTime: raw.travelTime / sum,
    walkDistance: raw.walkDistance / sum,
    loadBalance: raw.loadBalance / sum,
  };
}

// ─── Factor 1: Availability ─────────────────────────────────
// f_avail = (K̂ - n + λ_d · τ) / K̂
// Estimates probability of open spots when user arrives.
//
// NOTE: This factor is MODULATED by confidence (see scoring).
// Raw f_avail for a no-data area = 1.0, but after modulation
// it becomes 0.5 (neutral), preventing false confidence.

function fAvail(
  parkedCount: number,
  capacity: number,
  departureRate: number,
  arrivalRate: number,
  travelTimeMin: number,
): number {
  if (capacity <= 0) return 0.5; // Guard against bad config
  const expectedVacancy = (capacity - parkedCount) + (departureRate - arrivalRate) * travelTimeMin;
  return clamp(expectedVacancy / capacity, 0, 1);
}

// ─── Factor 2: Turnover ─────────────────────────────────────
// Duration-weighted leave probability per parked car.
// Cars parked < t_half have high P(leave). Cars parked 8h+ → P ≈ 0.
//
// Normalization: divide by max(n, 1) to get per-car average,
// then scale to [0,1]. This avoids K̂/4 arbitrary constant.
//
// f_turn = (1/n) · Σⱼ P_leave(car_j)
// When n=0 (no parked cars), turnover is irrelevant → 0.5 neutral.

function fTurnover(
  recentDepartures: number,
  windowMin: number,
  parkDurations: number[],
  durationDecayHalfLifeMin: number,
  capacity: number,
): number {
  const n = parkDurations.length;
  if (n === 0) return 0.5; // No data → neutral

  // Average leave-probability across all parked cars
  const avgLeaveProb = parkDurations.reduce((sum, dur) => {
    return sum + 1 / (1 + (dur / durationDecayHalfLifeMin) ** 2);
  }, 0) / n;

  // avgLeaveProb is already in [0, 1] since each term is in [0, 1]
  // Boost slightly by departure rate evidence
  const departureEvidence = clamp(recentDepartures / Math.max(windowMin, 1), 0, 1);

  // Blend: 70% duration-based prediction, 30% observed departures
  return clamp(0.7 * avgLeaveProb + 0.3 * departureEvidence, 0, 1);
}

// ─── Factor 3: Travel Time ──────────────────────────────────
// f_travel = e^(-τ / τ₀)
// Exponential decay — nearby areas score much higher.
// Guaranteed ∈ (0, 1] for τ ≥ 0.

function fTravel(travelMinutes: number, decayMin: number): number {
  if (decayMin <= 0) return 0.5;
  return Math.exp(-Math.max(travelMinutes, 0) / decayMin);
}



// ─── Factor 5: Walk Distance ────────────────────────────────
// f_walk = e^(-w / w₀)
// Closer to destination after parking = better.
// Guaranteed ∈ (0, 1] for w ≥ 0.

function fWalk(walkMinutes: number, decayMin: number): number {
  if (decayMin <= 0) return 0.5;
  return Math.exp(-Math.max(walkMinutes, 0) / decayMin);
}

// ─── Factor 6: Load Balance ─────────────────────────────────
// Logistic (sigmoid) penalty: f_load = 1 / (1 + e^(R - k))
// Prevents sending everyone to the same area.
// Guaranteed ∈ (0, 1) for all R, k.

function fLoad(routedUsers: number, k: number): number {
  return 1 / (1 + Math.exp(routedUsers - k));
}

// ─── Factor 7: Data Confidence ──────────────────────────────
// f_conf = u / (u + n₀)
// Areas with more contributing users get higher confidence.
// Guaranteed ∈ [0, 1) for u ≥ 0, n₀ > 0.

function fConfidence(recentUniqueUsers: number, minUsers: number): number {
  if (minUsers <= 0) return 0.5;
  return recentUniqueUsers / (recentUniqueUsers + minUsers);
}

// ─── Confidence Modulation ──────────────────────────────────
// Factors that depend on crowdsourced data (availability, turnover)
// are modulated by confidence. When confidence is low, these
// factors are pulled toward 0.5 (neutral/uncertain).
//
// modulated = conf · raw + (1 - conf) · 0.5
//
// This prevents the algorithm from making bold claims about
// areas it knows nothing about.

function modulateByConfidence(rawScore: number, confidence: number): number {
  return confidence * rawScore + (1 - confidence) * 0.5;
}

// ─── Reasoning Builder ──────────────────────────────────────

function buildReasoning(
  avail: number,
  turn: number,
  travel: number,
  walk: number,
  load: number,
  conf: number,
  candidate: ParkingCandidate,
): string {
  const parts: string[] = [];

  // Availability
  if (avail >= 0.7) parts.push(`high availability (est ${Math.round(avail * 100)}% free)`);
  else if (avail >= 0.4) parts.push(`moderate availability (est ${Math.round(avail * 100)}% free)`);
  else parts.push(`low availability (est ${Math.round(avail * 100)}% free)`);

  // Travel time
  const tMin = candidate.traffic.travelTimeMin;
  parts.push(`${tMin.toFixed(0)} min drive`);

  // Walk
  const wMin = candidate.traffic.walkTimeMin;
  parts.push(`${wMin.toFixed(0)} min walk to destination`);

  // Turnover
  if (turn >= 0.5) parts.push('high turnover');

  // Load balance warning
  if (load < 0.3) parts.push('⚠ many users headed here');

  // Confidence note
  if (conf < 0.3) parts.push('limited data for this area');

  return parts.join(', ');
}

// ─── Main Scoring Function ──────────────────────────────────

/**
 * Score all parking area candidates and return them ranked best-first.
 *
 * DETERMINISM GUARANTEES:
 * - Same inputs → same output (pure function, no randomness)
 * - Weights are normalized to sum = 1.0 → S(i) ∈ [0, 1]
 * - Ties are broken by areaId (lexicographic) → stable sort order
 * - Data-dependent factors (avail, turnover) are modulated by
 *   confidence, so no-data areas get neutral scores, not high ones
 *
 * @param candidates - Parking areas enriched with Mapbox + Supabase data
 * @param activeRouting - Map of areaId → number of users currently being routed there
 * @param config - Algorithm section of remote config
 * @returns Scored and ranked areas
 */
export function scoreAllAreas(
  candidates: ParkingCandidate[],
  activeRouting: Map<string, number>,
  config: CurbyRemoteConfig['algorithm'],
): ScoredArea[] {
  // NORMALIZE weights to sum = 1.0 (prevents config drift)
  const weights = normalizeWeights(config.weights);
  const durationDecayMin = config.durationDecayHalfLifeHours * 60;

  return candidates
    .map((c) => {
      // ── Compute raw factors ──

      const rawAvail = fAvail(
        c.occupancy.parkedCount,
        config.estimatedCapacityPerArea,
        c.occupancy.departureRate,
        c.occupancy.arrivalRate, // Added arrivalRate
        c.traffic.travelTimeMin,
      );

      const rawTurn = fTurnover(
        c.occupancy.recentDepartures,
        config.recentDepartureWindowMin,
        c.occupancy.parkDurations,
        durationDecayMin,
        config.estimatedCapacityPerArea,
      );

      // Factors from Mapbox (not dependent on crowdsourced data quality)
      const travel = fTravel(c.traffic.travelTimeMin, config.travelTimeDecayMin);

      const walk = fWalk(c.traffic.walkTimeMin, config.walkTimeDecayMin);
      const load = fLoad(activeRouting.get(c.area.id) ?? 0, config.loadPenaltyK);
      const conf = fConfidence(c.occupancy.recentUniqueUsers, config.confidenceMinUsers);

      // ── Modulate data-dependent factors by confidence ──
      // When confidence is low, availability and turnover are
      // pulled toward 0.5 (uncertain) instead of being taken at face value.
      const avail = modulateByConfidence(rawAvail, conf);
      const turn = modulateByConfidence(rawTurn, conf);

      // ── Weighted composite score ──
      // Guaranteed ∈ [0, 1] because:
      //   - Each factor ∈ [0, 1]
      //   - Weights sum to 1.0 (normalized above)
      const score =
        weights.availability * avail +
        weights.turnover * turn +
        weights.travelTime * travel +
        weights.walkDistance * walk +
        weights.loadBalance * load;

      return {
        areaId: c.area.id,
        score,
        breakdown: {
          availability: avail,
          turnover: turn,
          travelTime: travel,
          walkDistance: walk,
          loadBalance: load,
          confidence: conf,
        },
        reasoning: buildReasoning(avail, turn, travel, walk, load, conf, c),
      };
    })
    // DETERMINISTIC SORT: by score descending, then by areaId ascending (tiebreaker)
    .sort((a, b) => {
      const scoreDiff = b.score - a.score;
      if (Math.abs(scoreDiff) > 1e-10) return scoreDiff;
      // Deterministic tiebreaker: lexicographic areaId
      return a.areaId < b.areaId ? -1 : a.areaId > b.areaId ? 1 : 0;
    });
}