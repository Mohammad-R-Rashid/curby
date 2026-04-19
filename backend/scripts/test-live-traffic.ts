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

async function testLiveTraffic() {
  console.log(`\n🚦 Testing Mapbox Live Traffic vs Historical Profile`);
  console.log(`Route: Downtown Austin -> UT Austin (Union on San Antonio)\n`);

  // We request the 'driving-traffic' profile, which gives us both:
  // 1. duration (live traffic impacted)
  // 2. duration_typical (historical baseline / speed limits)
  const coords = `${USER_LNG},${USER_LAT};${DEST_LNG},${DEST_LAT}`;
  const url = `https://api.mapbox.com/directions/v5/mapbox/driving-traffic/${coords}?annotations=duration,distance,congestion_numeric&overview=full&access_token=${MAPBOX_TOKEN}`;

  try {
    const res = await fetch(url);
    const data = await res.json();

    if (data.code !== 'Ok') {
      throw new Error(`Mapbox Error: ${data.message}`);
    }

    const route = data.routes[0];
    const liveDurationMin = route.duration / 60;
    const historicalDurationMin = route.duration_typical / 60;
    
    // Some basic math on the delay
    const delayMin = liveDurationMin - historicalDurationMin;
    
    console.log(`⏱️  Historical/Speed-Limit Driving Time: ${historicalDurationMin.toFixed(1)} minutes`);
    console.log(`🚗  Live Traffic Driving Time:         ${liveDurationMin.toFixed(1)} minutes`);
    
    if (delayMin > 1) {
      console.log(`\n⚠️  WARNING: Route is experiencing a +${delayMin.toFixed(1)} minute traffic delay right now!`);
    } else if (delayMin < -1) {
      console.log(`\n🚀 Route is completely clear! Travelling ${Math.abs(delayMin).toFixed(1)} mins faster than typical.`);
    } else {
      console.log(`\n🟢 Traffic is flowing normally along this route at the moment.`);
    }

    // You can also access exact segment-by-segment congestion points:
    console.log(`\n🛣️ Sample of Congestion Numeric Array (0 = blocked, 100 = free-flow):`);
    // Showing just the first 10 segment blocks
    console.log(route.legs[0].annotation.congestion_numeric.slice(0, 10));
    
  } catch (err: any) {
    console.error('Test Failed:', err.message);
  }
}

testLiveTraffic();
