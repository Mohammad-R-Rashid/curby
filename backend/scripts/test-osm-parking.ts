#!/usr/bin/env npx tsx
/**
 * Smoke-test OSM Overpass companion parking discovery.
 *
 * Usage:
 *   cd backend/scripts && npx tsx test-osm-parking.ts
 *
 * With Mapbox merge (optional):
 *   MAPBOX_TOKEN=pk... npx tsx test-osm-parking.ts
 */

import { DEFAULT_CONFIG } from '../packages/shared/src/config.js';
import { discoverParkingAreas } from '../packages/shared/src/parking-discovery.js';
import { searchOsmParkingAreas } from '../packages/shared/src/osm.js';

const MAPBOX_TOKEN = process.env.MAPBOX_TOKEN;

// UT Austin area — same ballpark as other backend scripts
const DEST = { lat: 30.2833669, lng: -97.7427951 };
const RADIUS_M = 900;

async function main() {
  console.log('\n── OSM Overpass only (no Mapbox token required) ──\n');
  const osm = await searchOsmParkingAreas(DEST, RADIUS_M);
  console.log(`Candidates: ${osm.length}`);
  for (const a of osm.slice(0, 15)) {
    console.log(`  [osm] ${a.category.padEnd(16)} ${a.name.slice(0, 56)}`);
  }
  if (osm.length > 15) console.log(`  … ${osm.length - 15} more`);

  if (MAPBOX_TOKEN) {
    console.log('\n── Merged discoverParkingAreas (Mapbox + OSM) ──\n');
    const merged = await discoverParkingAreas(DEST, RADIUS_M, 9, MAPBOX_TOKEN, DEFAULT_CONFIG.search);
    console.log(`Candidates (max 9): ${merged.length}`);
    for (const a of merged) {
      const src = a.dataSource ?? 'mapbox';
      console.log(`  [${src}] ${a.category.padEnd(16)} ${a.name.slice(0, 52)}`);
    }
  } else {
    console.log('\n(Set MAPBOX_TOKEN to print merged Mapbox+OSM discovery.)\n');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
