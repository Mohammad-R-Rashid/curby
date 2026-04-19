import { scoreAllAreas } from '../packages/shared/src/algorithm.ts';
import { DEFAULT_CONFIG } from '../packages/shared/src/config.ts';
import type { ParkingCandidate } from '../packages/shared/src/types.ts';

const MAPBOX_TOKEN = process.env.MAPBOX_TOKEN;

if (!MAPBOX_TOKEN) {
  console.error('❌ Missing MAPBOX_TOKEN environment variable.');
  console.log('Usage: MAPBOX_TOKEN=pk... npx tsx test-austin-algorithm.ts');
  process.exit(1);
}

// User driving from downtown Austin towards UT Austin
const USER_LAT = 30.2672;
const USER_LNG = -97.7431;

// Destination: Union on San Antonio, UT Austin
const DEST_LAT = 30.2833669; // 30.2833669
const DEST_LNG = -97.7427951; // -97.7427951

// Haversine formula to filter coordinates strictly to our neighborhood
function getDistance(lat1: number, lon1: number, lat2: number, lon2: number) {
  const R = 6371e3; // metres
  const φ1 = lat1 * Math.PI/180;
  const φ2 = lat2 * Math.PI/180;
  const Δφ = (lat2-lat1) * Math.PI/180;
  const Δλ = (lon2-lon1) * Math.PI/180;

  const a = Math.sin(Δφ/2) * Math.sin(Δφ/2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ/2) * Math.sin(Δλ/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));

  return R * c; 
}

async function fetchAustinEntrances() {
  console.log(`\n🔍 Fetching official Austin Parking Lot Entrances...`);

  // Direct Socrata query to Austin's Open Data portal 
  const url = `https://data.austintexas.gov/resource/ij6a-fwpi.json?$limit=5000`;

  const res = await fetch(url);
  const data = await res.json();

  if (data.error) {
    throw new Error(`Socrata Error: ${data.message}`);
  }

  // Filter parking entrances geometrically to only what's within 1000 meters of the Destination
  const nearbyEntrances = [];
  
  // A lot ID deduplication map
  const uniqueLots = new Set();

  for (const entry of data) {
    const lat = parseFloat(entry.latitude);
    const lng = parseFloat(entry.longitude);
    if (!lat || !lng) continue;

    const distMeters = getDistance(DEST_LAT, DEST_LNG, lat, lng);
    
    // Within 1km radius and ensure we only route to one entrance per parking lot ID
    if (distMeters <= 1000 && !uniqueLots.has(entry.parking_lo)) {
      uniqueLots.add(entry.parking_lo);
      nearbyEntrances.push({
        id: entry.parking_lo || entry.objectid_1,
        name: `Lot ${entry.parking_lo}`,
        lat: lat,
        lng: lng,
        walkMeters: distMeters // using direct distance as an approximation for walk time
      });
    }
  }

  if (nearbyEntrances.length === 0) {
    console.error('No Austin Open Data parking entrances found within 1km. Falling back to expanded 3km radius...');
    // Fallback if none found strictly close
    for (const entry of data) {
      const lat = parseFloat(entry.latitude);
      const lng = parseFloat(entry.longitude);
      if (!lat || !lng) continue;
      const distMeters = getDistance(DEST_LAT, DEST_LNG, lat, lng);
      if (distMeters <= 3000 && !uniqueLots.has(entry.parking_lo)) {
        uniqueLots.add(entry.parking_lo);
        nearbyEntrances.push({
          id: entry.parking_lo || entry.objectid_1,
          name: `Lot ${entry.parking_lo}`,
          lat: lat,
          lng: lng,
          walkMeters: distMeters
        });
      }
    }
  }

  return nearbyEntrances.slice(0, 9); // Mapbox Matrix has 10 limit (1 user + 9 destinations)
}

async function fetchMatrix(userLng: number, userLat: number, garages: any[]) {
  console.log(`⏱ Calculating driving routes to exact Entrance/Exit points via Mapbox Matrix API...`);
  
  const coords = [`${userLng},${userLat}`, ...garages.map(g => `${g.lng},${g.lat}`)].join(';');
  const url = `https://api.mapbox.com/directions-matrix/v1/mapbox/driving-traffic/${coords}?sources=0&destinations=all&annotations=duration,distance&access_token=${MAPBOX_TOKEN}`;
  
  const res = await fetch(url);
  const data = await res.json();
  
  if (data.code !== 'Ok') {
    throw new Error(`Mapbox Error: ${data.message}`);
  }

  const durations = data.durations[0];
  const distances = data.distances[0];

  return durations.map((dur: number, idx: number) => ({
    durSec: dur,
    distM: distances[idx],
  })).slice(1);
}

async function run() {
  try {
    const entrances = await fetchAustinEntrances();
    console.log(`Found ${entrances.length} official Lot Entrances within routing range.`);

    if (entrances.length === 0) {
      console.log('No entrances found, terminating test.');
      return;
    }

    const matrix = await fetchMatrix(USER_LNG, USER_LAT, entrances);
    
    // Assemble Parking Candidates
    const candidates: ParkingCandidate[] = entrances.map((e: any, idx: number) => {
      // Mock Walk time strictly based on precise Haversine distance (approx 1 min per 80 meters)
      const walkTimeMin = e.walkMeters / 80;

      return {
        area: {
          id: e.id,
          name: e.name,
          center: { lat: e.lat, lng: e.lng },
          category: 'parking_entrance'
        },
        traffic: {
          travelTimeMin: matrix[idx].durSec / 60,
          distanceMeters: matrix[idx].distM,
          walkTimeMin: walkTimeMin,
        },
        occupancy: {
          // Since we are ignoring live occupancy for this test, set standard constant defaults
          parkedCount: 50, 
          recentDepartures: 5,
          departureRate: 0.1,
          arrivalRate: 0.1,
          parkDurations: [60],
          recentUniqueUsers: 50, // Keep confidence stable
        }
      };
    });

    console.log(`\n🧠 Running 5-Factor Score on Austin Garage Entrances...`);
    
    // Temporarily clone config to assume each lot supports around 100 spots 
    // (since entrance data doesn't state physical capacity)
    const dynamicConfig = JSON.parse(JSON.stringify(DEFAULT_CONFIG.algorithm));
    dynamicConfig.estimatedCapacityPerArea = 100;

    const activeRoutingMap = new Map<string, number>(); 
    const ranked = scoreAllAreas(candidates, activeRoutingMap, dynamicConfig);
    
    console.log(`\n🏆 Best Physical Routes to Entrances:\n`);
    ranked.forEach((r, idx) => {
      const garage = candidates.find(c => c.area.id === r.areaId)!;
      
      console.log(`${idx + 1}. Austin ${garage.area.name} (Score: ${(r.score * 100).toFixed(1)}/100)`);
      console.log(`   └─ Drive to Entrance: ${garage.traffic.travelTimeMin.toFixed(1)} mins`);
      console.log(`   └─ Walk from Entrance to Union: ${garage.traffic.walkTimeMin.toFixed(1)} mins`);
      console.log(`   └─ Why: ${r.reasoning}\n`);
    });

  } catch (err: any) {
    console.error('\nTest Failed:', err.message);
  }
}

run();
