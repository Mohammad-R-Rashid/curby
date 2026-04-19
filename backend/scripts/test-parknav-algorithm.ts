import { scoreAllAreas } from '../packages/shared/src/algorithm.js';
import { DEFAULT_CONFIG } from '../packages/shared/src/config.js';
import type { ParkingCandidate } from '../packages/shared/src/types.js';

const MAPBOX_TOKEN = process.env.MAPBOX_TOKEN;
const PARKNAV_TOKEN = process.env.PARKNAV_TOKEN;

if (!MAPBOX_TOKEN || !PARKNAV_TOKEN) {
  console.error('❌ Missing require environment variables.');
  console.log('Usage: MAPBOX_TOKEN=pk... PARKNAV_TOKEN=abc... npx tsx test-parknav-algorithm.ts');
  process.exit(1);
}

// Mock User Location (e.g. driving towards UT Austin from Downtown / Congress Ave)
const USER_LAT = 30.2672;
const USER_LNG = -97.7431;

// Mock Final Destination (Union on San Antonio near UT Austin)
// 2011 San Antonio Street, Austin, TX
const DEST_LAT = 30.2833669;
const DEST_LNG = -97.7427951;

async function fetchParknavHeatmap() {
  console.log(`\n🔍 Searching for parking data near destination via Parknav...`);

  // Parknav API call from user specs
  const url = `https://api.parknav.com/v2/core/heatmap?destination=${DEST_LAT}%2C${DEST_LNG}&radius=1000&spotType=ALL&minProb=0&maxProb=1&minLength=0&maxLength=100000&outputFormat=geojson&userId=bshihab&clientInfo=mobile%3BiOS%3B17.0`;

  const res = await fetch(url, {
    method: 'GET',
    headers: {
      'accept': 'application/json',
      'apikey': PARKNAV_TOKEN as string
    }
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to fetch from Parknav API: ${res.status} ${text}`);
  }

  const data = await res.json();

  if (!data.features || data.features.length === 0) {
    throw new Error('0 parking areas found via Parknav');
  }

  // Parse the geojson features. Parknav pushes segment geometries (LineStrings)
  let validAreas = data.features.map((f: any, index: number) => {
    let lng, lat;
    if (f.geometry.type === 'LineString' && f.geometry.coordinates.length > 0) {
      lng = f.geometry.coordinates[0][0];
      lat = f.geometry.coordinates[0][1];
    } else if (f.geometry.type === 'Polygon' && f.geometry.coordinates.length > 0) {
      lng = f.geometry.coordinates[0][0][0];
      lat = f.geometry.coordinates[0][0][1];
    } else if (f.geometry.type === 'Point') {
      lng = f.geometry.coordinates[0];
      lat = f.geometry.coordinates[1];
    } else {
      lng = DEST_LNG;
      lat = DEST_LAT;
    }

    return {
      id: f.properties?.id || `parknav_zone_${index}`,
      name: f.properties?.name || `Parknav Zone ${index + 1}`,
      lng: lng,
      lat: lat,
      probability: f.properties?.probability ?? Math.random() // Availability probability [0,1]
    };
  });

  // Limit to top 5 valid zones
  return validAreas.slice(0, 5);
}

async function fetchMatrix(userLng: number, userLat: number, garages: any[]) {
  console.log(`⏱ Fetching travel times via Mapbox Matrix API...`);
  
  const coords = [`${userLng},${userLat}`, ...garages.map(g => `${g.lng},${g.lat}`)].join(';');
  const url = `https://api.mapbox.com/directions-matrix/v1/mapbox/driving-traffic/${coords}?sources=0&destinations=all&annotations=duration,distance&access_token=${MAPBOX_TOKEN}`;
  
  const res = await fetch(url);
  const data = await res.json();
  
  if (data.code !== 'Ok') {
    console.error('Matrix error:', data);
    throw new Error('Failed to fetch from Mapbox Matrix');
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
    const garages = await fetchParknavHeatmap();
    console.log(`Found ${garages.length} parking zones via Parknav.`);

    const matrix = await fetchMatrix(USER_LNG, USER_LAT, garages);
    
    // Assemble Parking Candidates
    const candidates: ParkingCandidate[] = garages.map((g: any, idx: number) => {
      const walkTimeMin = Math.random() * 5 + 1; 

      // Parknav probability maps directly to expected vacancy!
      // Math: (capacity - parkedCount) / capacity = probability
      // So if probability is 0.8, we can mock it as 80 out of 100 spots open.
      const fakeCapacity = 100;
      const fakeParked = Math.round(fakeCapacity * (1 - g.probability));
      
      return {
        area: {
          id: g.id,
          name: g.name,
          center: { lat: g.lat, lng: g.lng },
          category: 'parking_garage'
        },
        traffic: {
          travelTimeMin: matrix[idx].durSec / 60,
          distanceMeters: matrix[idx].distM,
          walkTimeMin: walkTimeMin,
        },
        occupancy: {
          parkedCount: fakeParked, // Deriving parkedCount directly from Parknav's probability!
          recentDepartures: 0,     // We can zero these out because we trust the live prob API
          departureRate: 0,
          arrivalRate: 0,
          parkDurations: [120, 60],
          recentUniqueUsers: 500,  // Fake high users to max out confidence since data is from an API!
        }
      };
    });

    console.log(`\n🧠 Running 5-Factor Score Algorithm with Parknav Live Probabilities...`);
    
    const activeRoutingMap = new Map<string, number>(); 
    const ranked = scoreAllAreas(candidates, activeRoutingMap, DEFAULT_CONFIG.algorithm);
    
    console.log(`\n🏆 Best Parking Options:\n`);
    ranked.forEach((r, idx) => {
      const garage = candidates.find(c => c.area.id === r.areaId)!;
      console.log(`${idx + 1}. ${garage.area.name} (Score: ${(r.score * 100).toFixed(1)}/100)`);
      console.log(`   └─ Parknav Availability Prob: ${(garage.probability*100).toFixed(0)}%`);
      console.log(`   └─ Why: ${r.reasoning}\n`);
    });

  } catch (err: any) {
    console.error('Test Failed:', err.message);
  }
}

run();
