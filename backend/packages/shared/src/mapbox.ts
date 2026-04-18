// ============================================================
// Mapbox API Client
// ============================================================
// Wraps Search Box, Matrix, and Directions APIs.

import type { MapboxParkingArea, MapboxDirectionsResult, LatLng, GeoJSONLineString } from './types.js';

const MAPBOX_BASE = 'https://api.mapbox.com';

/**
 * Search for parking areas near a location using Mapbox Search Box API.
 */
export async function searchParkingAreas(
  destination: LatLng,
  radiusMeters: number,
  limit: number,
  accessToken: string,
): Promise<MapboxParkingArea[]> {
  // NOTE: Search Box category API does not have a 'radius' parameter.
  // It uses 'proximity' to bias results near a location.
  // We cap limit at 9 because Matrix API (driving-traffic) only supports
  // 10 total coordinates (1 origin + 9 destinations).
  const effectiveLimit = Math.min(limit, 9);

  const url = new URL(`${MAPBOX_BASE}/search/searchbox/v1/category/parking`);
  url.searchParams.set('proximity', `${destination.lng},${destination.lat}`);
  url.searchParams.set('limit', String(effectiveLimit));
  url.searchParams.set('access_token', accessToken);
  url.searchParams.set('language', 'en');

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Mapbox Search failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json() as {
    features: Array<{
      properties: { mapbox_id: string; name: string; feature_type: string };
      geometry: { coordinates: [number, number] };
    }>;
  };

  return data.features.map((f) => ({
    id: f.properties.mapbox_id,
    name: f.properties.name || 'Parking',
    center: { lat: f.geometry.coordinates[1], lng: f.geometry.coordinates[0] },
    category: f.properties.feature_type || 'parking',
  }));
}

/**
 * Get driving travel times from one origin to multiple destinations using Matrix API.
 * Uses `driving-traffic` profile for traffic-aware times.
 * Returns durations in seconds and distances in meters.
 */
export async function matrixDriving(
  origin: LatLng,
  destinations: LatLng[],
  accessToken: string,
): Promise<{ durations: number[]; distances: number[] }> {
  // IMPORTANT: driving-traffic profile is limited to 10 coordinates total.
  // 1 origin + max 9 destinations = 10 coords.
  if (destinations.length > 9) {
    throw new Error(`Matrix API (driving-traffic) limited to 9 destinations, got ${destinations.length}`);
  }

  const coords = [
    `${origin.lng},${origin.lat}`,
    ...destinations.map((d) => `${d.lng},${d.lat}`),
  ].join(';');

  const url = new URL(
    `${MAPBOX_BASE}/directions-matrix/v1/mapbox/driving-traffic/${coords}`,
  );
  url.searchParams.set('sources', '0');
  url.searchParams.set('annotations', 'duration,distance');
  url.searchParams.set('access_token', accessToken);

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Mapbox Matrix (driving) failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json() as {
    durations: number[][];
    distances: number[][];
  };

  // First row contains origin → each destination
  return {
    durations: data.durations[0].slice(1), // skip origin→origin
    distances: data.distances[0].slice(1),
  };
}

/**
 * Get walking times from multiple origins to a single destination using Matrix API.
 * Uses `walking` profile.
 * Returns durations in seconds.
 */
export async function matrixWalking(
  origins: LatLng[],
  destination: LatLng,
  accessToken: string,
): Promise<number[]> {
  // Walking profile supports up to 25 coordinates
  const coords = [
    ...origins.map((o) => `${o.lng},${o.lat}`),
    `${destination.lng},${destination.lat}`,
  ].join(';');

  const destIdx = origins.length; // last coordinate is destination
  // Sources = all parking areas (indices 0 to N-1)
  const sourceIndices = origins.map((_, idx) => idx).join(';');

  const url = new URL(
    `${MAPBOX_BASE}/directions-matrix/v1/mapbox/walking/${coords}`,
  );
  url.searchParams.set('sources', sourceIndices);
  url.searchParams.set('destinations', String(destIdx));
  url.searchParams.set('annotations', 'duration');
  url.searchParams.set('access_token', accessToken);

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Mapbox Matrix (walking) failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json() as {
    durations: number[][];
  };

  // Each row is one parking area → destination (column 0)
  return data.durations.map((row) => row[0]);
}

/**
 * Get full route with congestion data from Mapbox Directions API.
 * Uses `driving-traffic` profile with `congestion_numeric` annotation.
 */
export async function getDirections(
  origin: LatLng,
  destination: LatLng,
  accessToken: string,
): Promise<MapboxDirectionsResult> {
  const coords = `${origin.lng},${origin.lat};${destination.lng},${destination.lat}`;

  const url = new URL(
    `${MAPBOX_BASE}/directions/v5/mapbox/driving-traffic/${coords}`,
  );
  url.searchParams.set('annotations', 'congestion_numeric,distance');
  url.searchParams.set('overview', 'full');
  url.searchParams.set('geometries', 'geojson');
  url.searchParams.set('access_token', accessToken);

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Mapbox Directions failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json() as {
    routes: Array<{
      duration: number;
      distance: number;
      geometry: GeoJSONLineString;
      legs: Array<{
        annotation: {
          congestion_numeric: number[];
          distance: number[];
        };
      }>;
    }>;
  };

  const route = data.routes[0];
  if (!route) {
    throw new Error('Mapbox Directions returned no routes');
  }

  const leg = route.legs[0];

  return {
    travelTimeSec: route.duration,
    distanceMeters: route.distance,
    geometry: route.geometry,
    congestionNumeric: leg?.annotation?.congestion_numeric ?? [],
    segmentDistances: leg?.annotation?.distance ?? [],
  };
}
