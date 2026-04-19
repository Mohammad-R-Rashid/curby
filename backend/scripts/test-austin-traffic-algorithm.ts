import { scoreAllAreas } from '../packages/shared/src/algorithm.ts';
import { DEFAULT_CONFIG } from '../packages/shared/src/config.ts';
import type { ParkingCandidate } from '../packages/shared/src/types.ts';

const MAPBOX_TOKEN = process.env.MAPBOX_TOKEN;

if (!MAPBOX_TOKEN) {
  console.error('❌ Missing MAPBOX_TOKEN environment variable.');
  process.exit(1);
}

// User driving from downtown Austin towards UT Austin
const USER_LAT = 30.2672;
const USER_LNG = -97.7431;

// Destination: Union on San Antonio, UT Austin
const DEST_LAT = 30.2833669;
const DEST_LNG = -97.7427951;

function getDistance(lat1: number, lon1: number, lat2: number, lon2: number) {
  const R = 6371e3; // metres
  const φ1 = lat1 * Math.PI/180;
  const φ2 = lat2 * Math.PI/180;
  const Δφ = (lat2-lat1) * Math.PI/180;
  const Δλ = (lon2-lon1) * Math.PI/180;
  const a = Math.sin(Δφ/2) * Math.sin(Δφ/2) + Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ/2) * Math.sin(Δλ/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return R * c; 
}

async function fetchAustinEntrances() {
  console.log(`\n🔍 Fetching Austin Socrata Parking Lot Entrances...`);
  const url = `https://data.austintexas.gov/resource/ij6a-fwpi.json?$limit=5000`;
  const res = await fetch(url);
  const data = await res.json();

  if (data.error) throw new Error(`Socrata Error: ${data.message}`);

  const nearbyEntrances = [];
  const uniqueLots = new Set();

  for (const entry of data) {
    const lat = parseFloat(entry.latitude);
    const lng = parseFloat(entry.longitude);
    if (!lat || !lng) continue;

    const distMeters = getDistance(DEST_LAT, DEST_LNG, lat, lng);
    
    // We fall back to 3000m directly here since 1000m only found 1 last time!
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

  return nearbyEntrances.slice(0, 5); // Take top 5 just for clean testing output
}

async function fetchDirectionsWithLiveTraffic(destLng: number, destLat: number) {
  // Using Directions API instead of Matrix to get Deep Traffic Details
  const coords = `${USER_LNG},${USER_LAT};${destLng},${destLat}`;
  const url = `https://api.mapbox.com/directions/v5/mapbox/driving-traffic/${coords}?annotations=duration,distance,congestion_numeric&overview=full&access_token=${MAPBOX_TOKEN}`;
  
  const res = await fetch(url);
  const data = await res.json();
  
  if (data.code !== 'Ok') throw new Error(`Mapbox Error: ${data.message}`);

  const route = data.routes[0];
  
  return {
    liveDurationSec: route.duration,
    historicalDurationSec: route.duration_typical,
    distanceM: route.distance,
    delayMin: (route.duration - route.duration_typical) / 60,
    congestionAvg: calculateAverageCongestion(route.legs[0].annotation.congestion_numeric)
  };
}

function calculateAverageCongestion(numericArray: number[]) {
  // Ignore null segments
  const valid = numericArray.filter(n => n !== null);
  if (valid.length === 0) return 100;
  const sum = valid.reduce((a, b) => a + b, 0);
  return sum / valid.length;
}

async function run() {
  try {
    const entrances = await fetchAustinEntrances();
    console.log(`Found ${entrances.length} official Lot Entrances within routing range.`);

    console.log(`⏱ Pulling Deep Mapbox Live Traffic details for each route...`);

    // Fetch deep traffic directions for each candidate in parallel
    const trafficDataArray = await Promise.all(
      entrances.map(e => fetchDirectionsWithLiveTraffic(e.lng, e.lat))
    );
    
    // Assemble Parking Candidates
    const candidates: ParkingCandidate[] = entrances.map((e: any, idx: number) => {
      const traffic = trafficDataArray[idx];
      const walkTimeMin = e.walkMeters / 80;

      return {
        area: {
          id: e.id,
          name: e.name,
          center: { lat: e.lat, lng: e.lng },
          category: 'parking_entrance'
        },
        traffic: {
           // We explicitly insert LIVE traffic duration into the algorithm here!
          travelTimeMin: traffic.liveDurationSec / 60,
          distanceMeters: traffic.distanceM,
          walkTimeMin: walkTimeMin,
        },
        occupancy: {
          // Neutral Mocked Occupancy for pure routing scoring
          parkedCount: 50, 
          recentDepartures: 5,
          departureRate: 0.1,
          arrivalRate: 0.1,
          parkDurations: [60],
          recentUniqueUsers: 50, 
        }
      };
    });

    console.log(`\n🧠 Running 5-Factor Score Algorithm...`);
    
    // Override configuration to completely disable Availability and Turnover!
    // Since our algorithm mathematically normalizes weights to sum to 1.0, 
    // setting these to 0.0 will dynamically shift 100% of the scoring power
    // entirely to Travel Time, Walk Distance, and Load Balance.
    const dynamicConfig = JSON.parse(JSON.stringify(DEFAULT_CONFIG.algorithm));
    dynamicConfig.weights.availability = 0.0;
    dynamicConfig.weights.turnover = 0.0;

    const ranked = scoreAllAreas(candidates, new Map<string, number>(), dynamicConfig);
    
    console.log(`\n🏆 Best Routes Ranked by Mapbox Live Traffic + Walk Prox:\n`);
    ranked.forEach((r, idx) => {
      const garage = candidates.find(c => c.area.id === r.areaId)!;
      const tData = trafficDataArray.find((_, tIdx) => entrances[tIdx].id === garage.area.id)!;
      
      console.log(`${idx + 1}. Austin ${garage.area.name} (Alg Score: ${(r.score * 100).toFixed(1)}/100)`);
      if (tData.delayMin > 0) {
        console.log(`   └─ 🚗 Live Drive Time: ${garage.traffic.travelTimeMin.toFixed(1)} mins (⚠️ +${tData.delayMin.toFixed(1)} min traffic delay)`);
      } else {
        console.log(`   └─ 🚗 Live Drive Time: ${garage.traffic.travelTimeMin.toFixed(1)} mins (🟢 Clear traffic, -${Math.abs(tData.delayMin).toFixed(1)} min fast!)`);
      }
      console.log(`   └─ 🚶 Walk to Union:   ${garage.traffic.walkTimeMin.toFixed(1)} mins`);
      
      // Clean up the algorithmic reasoning string to strip out availability/turnover chatter
      let cleanReasoning = r.reasoning
        .replace(/.*?availability.*?,\s*/g, '')
        .replace(/,\s*high turnover/g, '');

      console.log(`   └─ Alg. Rank Focus:  ${cleanReasoning}\n`);
    });

  } catch (err: any) {
    console.error('\nTest Failed:', err.message);
  }
}

run();
