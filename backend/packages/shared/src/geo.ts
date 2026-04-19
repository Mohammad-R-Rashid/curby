// ============================================================
// Shared geo helpers (Austin service area + haversine distance)
// ============================================================

import type { LatLng } from './types.js';

const EARTH_RADIUS_METERS = 6_371_000;

/** Mapbox Search `bbox` parameter for Austin metro bias. */
export const AUSTIN_BBOX = '-98.10,30.05,-97.40,30.55';

export function isWithinAustinArea(point: LatLng): boolean {
  return (
    point.lat >= 30.05 &&
    point.lat <= 30.55 &&
    point.lng >= -98.10 &&
    point.lng <= -97.40
  );
}

export function distanceMeters(a: LatLng, b: LatLng): number {
  const toRadians = (value: number): number => (value * Math.PI) / 180;
  const dLat = toRadians(b.lat - a.lat);
  const dLng = toRadians(b.lng - a.lng);
  const lat1 = toRadians(a.lat);
  const lat2 = toRadians(b.lat);

  const haversine =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;

  return 2 * EARTH_RADIUS_METERS * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
}
