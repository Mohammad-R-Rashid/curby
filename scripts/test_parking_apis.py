#!/usr/bin/env python3
"""
Test script: Validate parking data APIs work across the US.

Tests two data sources:
  1. OpenStreetMap Overpass API — free, no key, returns parking facilities with capacity/type
  2. Mapbox Geocoding API — uses existing Mapbox token, returns POI parking results

Run: python3 scripts/test_parking_apis.py
"""

import json
import time
import urllib.request
import urllib.parse
from dataclasses import dataclass

# ── Config ──────────────────────────────────────────────────────────────────

MAPBOX_TOKEN = "pk.eyJ1IjoiY29kZW9saXZlNzMzNyIsImEiOiJjbW80bnoyYXAxZ2RtMnRvZjIzZmVweHBqIn0.o1460B_12pz6qaH1s49QNA"

# Test locations across the US
TEST_LOCATIONS = [
    {"name": "Downtown San Jose, CA",   "lat": 37.3382, "lng": -121.8863},
    {"name": "Downtown Austin, TX",     "lat": 30.2672, "lng": -97.7431},
    {"name": "Downtown San Francisco",  "lat": 37.7749, "lng": -122.4194},
    {"name": "Manhattan, NYC",          "lat": 40.7580, "lng": -73.9855},
    {"name": "Downtown Chicago",        "lat": 41.8781, "lng": -87.6298},
    {"name": "Downtown Miami",          "lat": 25.7617, "lng": -80.1918},
]

RADIUS_METERS = 1000  # 1km search radius


# ── Helpers ─────────────────────────────────────────────────────────────────

def fetch_json(url: str, data: bytes = None, headers: dict = None) -> dict:
    """Simple JSON fetch with optional POST body."""
    req = urllib.request.Request(url, data=data, headers=headers or {})
    req.add_header("User-Agent", "CurbyParkingTest/1.0")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


# ── Test 1: OpenStreetMap Overpass API ──────────────────────────────────────

def test_overpass(lat: float, lng: float, radius: int = RADIUS_METERS) -> list:
    """
    Query OSM Overpass for all parking facilities within a radius.
    Returns a list of parking dicts with name, type, capacity, coordinates.
    
    Overpass QL docs: https://wiki.openstreetmap.org/wiki/Overpass_API
    This is completely free — no API key, no signup.
    """
    query = f"""
    [out:json][timeout:10];
    (
      node["amenity"="parking"](around:{radius},{lat},{lng});
      way["amenity"="parking"](around:{radius},{lat},{lng});
      relation["amenity"="parking"](around:{radius},{lat},{lng});
    );
    out center tags;
    """

    url = "https://overpass-api.de/api/interpreter"
    data = urllib.parse.urlencode({"data": query}).encode()

    result = fetch_json(url, data=data)
    elements = result.get("elements", [])

    parkings = []
    for el in elements:
        tags = el.get("tags", {})
        # Get coordinates (nodes have lat/lon directly, ways/relations use "center")
        if "center" in el:
            coord_lat = el["center"]["lat"]
            coord_lng = el["center"]["lon"]
        elif "lat" in el:
            coord_lat = el["lat"]
            coord_lng = el["lon"]
        else:
            continue

        parkings.append({
            "name": tags.get("name", "Unnamed Parking"),
            "type": tags.get("parking", "unknown"),       # surface, underground, multi-storey
            "capacity": tags.get("capacity", "N/A"),
            "fee": tags.get("fee", "unknown"),
            "operator": tags.get("operator", "N/A"),
            "access": tags.get("access", "unknown"),
            "lat": coord_lat,
            "lng": coord_lng,
            "osm_id": el.get("id"),
        })

    return parkings


# ── Test 2: Mapbox Geocoding API ───────────────────────────────────────────

def test_mapbox(lat: float, lng: float, radius: int = RADIUS_METERS) -> list:
    """
    Query Mapbox Search Box API for parking POIs near a coordinate.
    Uses the existing Mapbox access token from Info.plist.
    Free tier: 100k requests/month.
    """
    url = (
        f"https://api.mapbox.com/search/searchbox/v1/category/parking"
        f"?proximity={lng},{lat}"
        f"&limit=10"
        f"&access_token={MAPBOX_TOKEN}"
    )

    result = fetch_json(url)
    features = result.get("features", [])

    parkings = []
    for feat in features:
        props = feat.get("properties", {})
        coords = feat.get("geometry", {}).get("coordinates", [0, 0])
        context = props.get("context", {})

        parkings.append({
            "name": props.get("name", "Unknown"),
            "full_address": props.get("full_address", "N/A"),
            "category": props.get("poi_category", "N/A"),
            "lat": coords[1],
            "lng": coords[0],
            "locality": context.get("locality", {}).get("name", "N/A"),
            "mapbox_id": props.get("mapbox_id", "N/A"),
        })

    return parkings


# ── Run Tests ──────────────────────────────────────────────────────────────

def print_divider(char="─", width=70):
    print(char * width)


def run_tests():
    print("\n🅿️  CURBY PARKING DATA API TEST SUITE")
    print_divider("═")
    print(f"Testing {len(TEST_LOCATIONS)} locations across the US\n")

    overpass_totals = 0
    mapbox_totals = 0

    for loc in TEST_LOCATIONS:
        name = loc["name"]
        lat, lng = loc["lat"], loc["lng"]

        print(f"\n📍 {name} ({lat}, {lng})")
        print_divider()

        # ── Overpass ──
        print("  🗺️  OpenStreetMap Overpass API:")
        try:
            t0 = time.time()
            overpass_results = test_overpass(lat, lng)
            elapsed = time.time() - t0
            overpass_totals += len(overpass_results)

            if overpass_results:
                print(f"     ✅ Found {len(overpass_results)} parking facilities ({elapsed:.1f}s)")
                # Show top 3
                for p in overpass_results[:3]:
                    capacity_str = f" | capacity: {p['capacity']}" if p["capacity"] != "N/A" else ""
                    fee_str = f" | fee: {p['fee']}" if p["fee"] != "unknown" else ""
                    print(f"        • {p['name']} [{p['type']}]{capacity_str}{fee_str}")
                if len(overpass_results) > 3:
                    print(f"        ... and {len(overpass_results) - 3} more")
            else:
                print(f"     ⚠️  No results ({elapsed:.1f}s)")
        except Exception as e:
            print(f"     ❌ Error: {e}")

        # Brief pause to be respectful to Overpass rate limits
        time.sleep(1.0)

        # ── Mapbox ──
        print("  🏷️  Mapbox Geocoding API:")
        try:
            t0 = time.time()
            mapbox_results = test_mapbox(lat, lng)
            elapsed = time.time() - t0
            mapbox_totals += len(mapbox_results)

            if mapbox_results:
                print(f"     ✅ Found {len(mapbox_results)} parking POIs ({elapsed:.1f}s)")
                for p in mapbox_results[:3]:
                    print(f"        • {p['name']} — {p['full_address']}")
                if len(mapbox_results) > 3:
                    print(f"        ... and {len(mapbox_results) - 3} more")
            else:
                print(f"     ⚠️  No results ({elapsed:.1f}s)")
        except Exception as e:
            print(f"     ❌ Error: {e}")

    # ── Summary ──
    print("\n")
    print_divider("═")
    print("📊 SUMMARY")
    print_divider()
    print(f"  Overpass:  {overpass_totals} total parking facilities across {len(TEST_LOCATIONS)} cities")
    print(f"  Mapbox:    {mapbox_totals} total parking POIs across {len(TEST_LOCATIONS)} cities")
    print()

    if overpass_totals > 0 and mapbox_totals > 0:
        print("  ✅ BOTH APIs are working! Ready to integrate hybrid data source.")
    elif overpass_totals > 0:
        print("  ⚠️  Overpass works, but Mapbox returned no results. Check token.")
    elif mapbox_totals > 0:
        print("  ⚠️  Mapbox works, but Overpass returned no results. May be rate-limited.")
    else:
        print("  ❌ Neither API returned data. Check network connectivity.")

    print()


if __name__ == "__main__":
    run_tests()
