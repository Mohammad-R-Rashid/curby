import { scoreAllAreas } from '../packages/shared/src/algorithm.ts';
import { DEFAULT_CONFIG } from '../packages/shared/src/config.ts';
import type { ParkingCandidate } from '../packages/shared/src/types.ts';

const MAPBOX_TOKEN = process.env.MAPBOX_TOKEN;

if (!MAPBOX_TOKEN) {
  console.error('❌ Missing MAPBOX_TOKEN environment variable.');
  console.log('Usage: MAPBOX_TOKEN=pk... npx tsx test-arcgis-algorithm.ts');
  process.exit(1);
}

// NOTE: The ArcGIS API endpoint provided actually contains data for Montgomery, Alabama,
// not Austin, TX. I've updated the destination/user coords so that Mapbox Matrix 
// doesn't crash when calculating the drive from Alabama to Texas!
const USER_LAT = 32.3750;
const USER_LNG = -86.3100;

const DEST_LAT = 32.3798;
const DEST_LNG = -86.3128;

async function fetchArcGISMeters() {
  console.log(`\n🔍 Fetching parking meter capacities from ArcGIS...`);

  // Force ArcGIS to output in standard Coordinate System (4326/WGS84 Lat/Lon) instead of Web Mercator
  const url = `https://services7.arcgis.com/xNUwUjOJqYE54USz/arcgis/rest/services/Parking_Meters/FeatureServer/0/query?where=1=1&outFields=*&f=json&outSR=4326&resultRecordCount=9`;

  const res = await fetch(url);
  const data = await res.json();

  if (!data.features) {
    throw new Error('Failed to fetch from ArcGIS');
  }

  // Parse the ArcGIS feature attributes
  return data.features.map((f: any) => ({
    id: f.attributes.KIOSK_ID || `meter-${f.attributes.OBJECTID}`,
    name: f.attributes.BLOCK || `Meter ${f.attributes.KIOSK_ID}`,
    lng: f.geometry.x,
    lat: f.geometry.y,
    capacity: f.attributes.SPACES || 10, // Actual physical spot count!
    notes: f.attributes.NOTES
  }));
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
    const meters = await fetchArcGISMeters();
    console.log(`Found ${meters.length} ArcGIS Parking Zones.`);

    const matrix = await fetchMatrix(USER_LNG, USER_LAT, meters);
    
    // Assemble Parking Candidates
    const candidates: ParkingCandidate[] = meters.map((m: any, idx: number) => {
      // Mocking walk times
      const walkTimeMin = Math.random() * 5 + 1; 

      // Since ArcGIS provides the exact physical SPACES capacity, we can use it!
      // Here we mock the `parkedCount` by randomly filling the capacity up.
      const parkedCars = Math.floor(Math.random() * m.capacity);
      
      return {
        area: {
          id: m.id,
          name: m.name,
          center: { lat: m.lat, lng: m.lng },
          category: 'parking_meter'
        },
        traffic: {
          travelTimeMin: matrix[idx].durSec / 60,
          distanceMeters: matrix[idx].distM,
          walkTimeMin: walkTimeMin,
        },
        occupancy: {
          parkedCount: parkedCars, 
          recentDepartures: Math.floor(Math.random() * 3),
          departureRate: Math.random() * 0.2,
          arrivalRate: Math.random() * 0.2,
          parkDurations: [60, 30],
          recentUniqueUsers: 50, 
        }
      };
    });

    console.log(`\n🧠 Running 5-Factor Score Using ArcGIS Capacities...`);
    
    const activeRoutingMap = new Map<string, number>(); 
    
    // Temporarily clone config to use ArcGIS capacities
    const dynamicConfig = JSON.parse(JSON.stringify(DEFAULT_CONFIG.algorithm));

    const ranked = scoreAllAreas(candidates, activeRoutingMap, dynamicConfig);
    
    console.log(`\n🏆 Best Parking Options (Fetched at: ${new Date().toLocaleString()}):\n`);
    ranked.forEach((r, idx) => {
      const garage = candidates.find(c => c.area.id === r.areaId)!;
      // Find the raw ArcGIS object to display its capacity
      const meter = meters.find(m => m.id === r.areaId);
      
      console.log(`${idx + 1}. ${garage.area.name} (Score: ${(r.score * 100).toFixed(1)}/100)`);
      console.log(`   └─ Capacity: ${meter.capacity} spots total [REAL - ArcGIS Data]`);
      console.log(`   └─ Travel Time: ${garage.traffic.travelTimeMin.toFixed(1)} min [REAL - Mapbox Live Traffic]`);
      console.log(`   └─ Current Occupancy: Est ${Math.round(r.breakdown.availability * 100)}% free [MOCKED for testing]`);
      console.log(`   └─ Why: ${r.reasoning}\n`);
    });

  } catch (err: any) {
    console.error('Test Failed:', err.message);
  }
}

run();
