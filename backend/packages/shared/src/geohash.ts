// ============================================================
// Geohash Utilities
// ============================================================
// Encodes lat/lng into a geohash string for spatial bucketing.

const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/**
 * Encode a latitude/longitude pair into a geohash string.
 * @param lat Latitude (-90 to 90)
 * @param lng Longitude (-180 to 180)
 * @param precision Number of characters (default 7 ≈ 150m)
 */
export function encodeGeohash(lat: number, lng: number, precision: number = 7): string {
  let latMin = -90, latMax = 90;
  let lngMin = -180, lngMax = 180;
  let hash = '';
  let isLng = true;
  let bit = 0;
  let ch = 0;

  while (hash.length < precision) {
    if (isLng) {
      const mid = (lngMin + lngMax) / 2;
      if (lng >= mid) {
        ch |= 1 << (4 - bit);
        lngMin = mid;
      } else {
        lngMax = mid;
      }
    } else {
      const mid = (latMin + latMax) / 2;
      if (lat >= mid) {
        ch |= 1 << (4 - bit);
        latMin = mid;
      } else {
        latMax = mid;
      }
    }

    isLng = !isLng;
    bit++;

    if (bit === 5) {
      hash += BASE32[ch];
      bit = 0;
      ch = 0;
    }
  }

  return hash;
}

/**
 * Decode a geohash into a lat/lng center point.
 */
export function decodeGeohash(hash: string): { lat: number; lng: number } {
  let latMin = -90, latMax = 90;
  let lngMin = -180, lngMax = 180;
  let isLng = true;

  for (const c of hash) {
    const idx = BASE32.indexOf(c);
    if (idx === -1) throw new Error(`Invalid geohash character: ${c}`);

    for (let bit = 4; bit >= 0; bit--) {
      const mask = 1 << bit;
      if (isLng) {
        const mid = (lngMin + lngMax) / 2;
        if (idx & mask) {
          lngMin = mid;
        } else {
          lngMax = mid;
        }
      } else {
        const mid = (latMin + latMax) / 2;
        if (idx & mask) {
          latMin = mid;
        } else {
          latMax = mid;
        }
      }
      isLng = !isLng;
    }
  }

  return {
    lat: (latMin + latMax) / 2,
    lng: (lngMin + lngMax) / 2,
  };
}

/**
 * Get a region-level geohash (precision 4 ≈ 20km) for Durable Object routing.
 */
export function regionGeohash(lat: number, lng: number): string {
  return encodeGeohash(lat, lng, 4);
}
