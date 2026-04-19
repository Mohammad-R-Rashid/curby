Nueces mosque is one of the most packed masjids for its size in the world. Over 1,000 people show up for Ramadan free iftars, and hundreds for three Jummahs in a packed tiny house. 

With exactly 4 parking spots on premise, many commuters have the most frustrating times of their life trying to park. And when they do park, someone blocks them in, or they can choose the 20 minute away parking and miss a lot of the Khutba. 

We built Curby. Curby solves the disconnect between classic navigation and parking. Curby predicts based on a deterministic formula with multiple weights from live data where the most likley parking spots will be. One top of that, it makes geofenced zones with most likley more open areas versus occupied areas from a zoomed out perspective, so you can quicky figure out which way to search while driving.

One you do eventually park, Curby tracks that and logs it in an occupancy database which it adds to it's load balancing algorithm. So when more Curby users come to the same place looking for parking, Curby directs them elsewhere. This will be specifically useful in tight spaces like Nueces masjid. 

We built Curby natively in SwiftUI, with Mapbox SDK the map instead of Apple maps or Google Maps because Mapbox has the most advanced data rendering and geofencing tools of a mobile map provider. Our deterministic formula assigns weights to different data ingestion pipelines such as Mapbox traffic data, historical data, and the number of parking spots the OSM API found. Then it normalizes each zone of parking spots to a Z score which it then uses to render heat maps, and display recommended parking spot.

Our back end architecture is built with a few micro services form Cloudflare & Supabase:
1) Cloudflare workers for high ingest data points from all of our live users every 5 seconds
2) Cloudflare Durable Objects for state management for quick in memory reterivals of live user locations
3) Cloudflare Websockets based on Durable Objects that helps talk to our Supabase PostgreSQL source of truth.
4) Cloudflare Queues for updates to the allocations table in Supabase in the background.

This design may seem to have many micro services, and that is to ensure we can easily scale to thousands if not millions of users without hitting technical limits and ensuring Cruby can keep serving users.

The hardest problem turned out to be knowing which data points to feed into our scoring and which API sources would give us the highest-quality signal. Live counts update every few minutes, which on a hackathon timeline means designing for stale, missing, and occasionally wrong inputs from day one. We built a confidence-weighted decay so the algorithm falls back gracefully to historical priors and labels its own uncertainty instead of pretending it knows more than it does. Map rendering was the second-hardest challenge transitioning between polygon and line overlays as users zoom, without flicker or camera jank, required going deeper into Mapbox's layer lifecycle than the documentation particularly encourages.
A few lessons stuck with us. We went in thinking we might need a machine learning model and came out with a linear weighted formula that fits on a whiteboard and outperforms anything more complex we could have tuned in the time available. And modern tooling makes city-scale apps genuinely tractable: Mapbox and open data portals let a small team ship something that feels real, fast. Curby is a small fix for a surprisingly common problem. Parking don't have to be guesswork when Curby is on your side.
