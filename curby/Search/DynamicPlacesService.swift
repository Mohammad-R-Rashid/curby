//
//  DynamicPlacesService.swift
//  curby
//
//  Single source of dynamic Hotspot places. Both the carousel in the bottom
//  sheet and the on-map place pins observe this service so they stay in sync.
//
//  Backed by OpenStreetMap Overpass. Mapbox SearchBox forward couldn't be
//  asked "neighborhoods near here" without a textual query and its proximity
//  bias was too weak; Overpass speaks OSM directly so we can ask for
//  area-scale tags (suburb/quarter/town) plus major destination tags
//  (university, mall, stadium, museum, attraction, airport) within a
//  geographic radius. That mix matches "Hotspot" — Westfield Valley Fair,
//  Santa Clara University, SAP Center, Hell's Kitchen — without flooding the
//  list with small community parks or specific buildings.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class DynamicPlacesService {
    private(set) var places: [PopularLocation] = []
    private(set) var isLoading: Bool = false

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastFetchedCenter: CLLocationCoordinate2D?

    /// Public Overpass instances appreciate sparse usage. Combined with the
    /// distance throttle below, this caps fetches to a few per minute.
    private let debounceMilliseconds: UInt64 = 1_200
    /// Don't refetch while panning inside this radius of the last fetch.
    private let refetchDistanceMeters: Double = 1_500
    /// Radius around the map center we ask Overpass for.
    private let searchRadiusMeters: Int = 9_000

    /// Schedule a fetch if the center has moved beyond `refetchDistanceMeters`
    /// since the last successful fetch.
    func fetchIfNeeded(near center: CLLocationCoordinate2D) {
        if let last = lastFetchedCenter,
           CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            < refetchDistanceMeters {
            return
        }
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await fetch(around: center)
        }
    }

    private func fetch(around center: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        // Combined Overpass query — area-scale neighborhoods + major
        // destinations. `way` queries are needed because malls / universities
        // / stadiums are usually polygon features, not point nodes; Overpass
        // computes their `center` for us via `out tags center`.
        // Excludes `place=neighbourhood` (too small in suburbs — was the
        // source of the unrecognizable-community-names complaint).
        let r = searchRadiusMeters
        let lat = center.latitude
        let lon = center.longitude
        let overpassQuery = """
        [out:json][timeout:18];
        (
          node["place"~"^(suburb|quarter|town)$"](around:\(r),\(lat),\(lon));
          way["amenity"~"^(university|college)$"](around:\(r),\(lat),\(lon));
          node["amenity"~"^(university|college)$"](around:\(r),\(lat),\(lon));
          way["shop"="mall"](around:\(r),\(lat),\(lon));
          node["shop"="mall"](around:\(r),\(lat),\(lon));
          way["leisure"="stadium"](around:\(r),\(lat),\(lon));
          way["tourism"~"^(attraction|theme_park|zoo|museum|aquarium)$"](around:\(r),\(lat),\(lon));
          node["tourism"~"^(attraction|theme_park|zoo|museum|aquarium)$"](around:\(r),\(lat),\(lon));
          way["aeroway"="aerodrome"](around:\(r),\(lat),\(lon));
        );
        out tags center 40;
        """

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(CurbyConstants.nominatimUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 22
        let escaped = overpassQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        request.httpBody = "data=\(escaped)".data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else { return }

            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
            guard !Task.isCancelled else { return }

            let mapCenter = CLLocation(latitude: lat, longitude: lon)

            let candidates: [PopularLocation] = decoded.elements.compactMap { element in
                // Nodes carry lat/lon directly; ways/relations carry it as
                // `center` thanks to the `out tags center` modifier.
                let elementLat = element.lat ?? element.center?.lat
                let elementLon = element.lon ?? element.center?.lon
                guard let elementLat,
                      let elementLon,
                      let name = element.tags.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      name.count >= 3
                else { return nil }
                return PopularLocation(
                    id: UUID(),
                    name: name,
                    sfSymbol: Self.sfSymbol(for: element.tags),
                    coordinate: CLLocationCoordinate2D(latitude: elementLat, longitude: elementLon),
                    // Neutral until real busyness data lands (#5).
                    busyLevel: .open,
                    subtitle: Self.subtitle(for: element.tags)
                )
            }

            // Dedupe by lowercased name (OSM occasionally carries the same
            // place as both `place` and a landmark tag).
            var seen = Set<String>()
            let deduped = candidates.filter { seen.insert($0.name.lowercased()).inserted }

            let sorted = deduped.sorted {
                let a = CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                let b = CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)
                return a.distance(from: mapCenter) < b.distance(from: mapCenter)
            }

            let finalPlaces = Array(sorted.prefix(10))
            if !finalPlaces.isEmpty {
                self.places = finalPlaces
            }
            self.lastFetchedCenter = center
        } catch {
            // Overpass occasionally returns 429 / timeouts under load — keep
            // showing the previous list and try again on the next pan.
        }
    }

    // MARK: - Display helpers

    /// Maps OSM tags to an SF Symbol name. Apple iconography throughout —
    /// Phosphor was previously used here but inconsistent with the rest of
    /// the app's iOS 26 styling.
    private static func sfSymbol(for tags: OverpassResponse.Element.Tags) -> String {
        if tags.amenity == "university" || tags.amenity == "college" { return "graduationcap.fill" }
        if tags.shop == "mall" { return "bag.fill" }
        if tags.leisure == "stadium" { return "sportscourt.fill" }
        if tags.tourism == "museum" { return "building.columns.fill" }
        if tags.tourism == "zoo" { return "tortoise.fill" }
        if tags.tourism == "aquarium" { return "fish.fill" }
        if tags.tourism == "theme_park" { return "ferris.wheel" }
        if tags.tourism == "attraction" { return "star.fill" }
        if tags.aeroway == "aerodrome" { return "airplane" }
        switch (tags.place ?? "").lowercased() {
        case "town":              return "building.2.fill"
        case "suburb", "quarter": return "mappin.and.ellipse"
        default:                  return "mappin"
        }
    }

    private static func subtitle(for tags: OverpassResponse.Element.Tags) -> String {
        if tags.amenity == "university" { return "University" }
        if tags.amenity == "college" { return "College" }
        if tags.shop == "mall" { return "Mall" }
        if tags.leisure == "stadium" { return "Stadium" }
        if tags.tourism == "museum" { return "Museum" }
        if tags.tourism == "zoo" { return "Zoo" }
        if tags.tourism == "aquarium" { return "Aquarium" }
        if tags.tourism == "theme_park" { return "Theme Park" }
        if tags.tourism == "attraction" { return "Attraction" }
        if tags.aeroway == "aerodrome" { return "Airport" }
        switch (tags.place ?? "").lowercased() {
        case "town":         return "Town"
        case "suburb":       return "District"
        case "quarter":      return "Quarter"
        default:             return "Hotspot"
        }
    }
}

// MARK: - Overpass decoder (private to this file)

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: Tags

        struct Center: Decodable {
            let lat: Double
            let lon: Double
        }

        struct Tags: Decodable {
            let name: String?
            let place: String?
            let amenity: String?
            let shop: String?
            let leisure: String?
            let tourism: String?
            let aeroway: String?
        }
    }
}
