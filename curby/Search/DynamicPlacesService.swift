//
//  DynamicPlacesService.swift
//  curby
//
//  Single source of dynamic Hotspot places. Both the carousel in the bottom
//  sheet and the on-map place pins observe this service so they stay in sync.
//
//  Backed by OpenStreetMap Overpass. Mapbox SearchBox forward worked but had
//  weak proximity bias and required a textual query — there's no
//  "neighborhoods near here" call. Overpass lets us query OSM directly for
//  features tagged place=neighbourhood / suburb / quarter within a radius,
//  which matches the user's mental model of a Hotspot exactly (Hell's
//  Kitchen, Mission District, South Congress — not parks, not specific
//  POIs). Public Overpass instance is free, no API key required; we keep
//  request volume polite via the existing debounce + distance throttle.
//

import CoreLocation
import Foundation
import Observation
import PhosphorSwift

@MainActor
@Observable
final class DynamicPlacesService {
    private(set) var places: [PopularLocation] = []
    private(set) var isLoading: Bool = false

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastFetchedCenter: CLLocationCoordinate2D?

    /// Public Overpass instances appreciate sparse usage. Combined with the
    /// distance throttle below, this caps fetches to a few per minute even
    /// during heavy panning.
    private let debounceMilliseconds: UInt64 = 1_200
    /// Don't refetch while panning inside this radius of the last fetch.
    private let refetchDistanceMeters: Double = 1_500
    /// How far around the map center we ask Overpass for neighborhoods.
    private let searchRadiusMeters: Int = 8_000

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

        // `out tags center` keeps the lat/lon (the bare `out tags` returns
        // tag-only elements with no geometry, which the decoder then drops).
        let overpassQuery = """
        [out:json][timeout:15];
        (
          node["place"~"neighbourhood|suburb|quarter"](around:\(searchRadiusMeters),\(center.latitude),\(center.longitude));
        );
        out tags center 30;
        """

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(CurbyConstants.nominatimUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 18
        let escaped = overpassQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        request.httpBody = "data=\(escaped)".data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else { return }

            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
            guard !Task.isCancelled else { return }

            let mapCenter = CLLocation(latitude: center.latitude, longitude: center.longitude)

            let candidates: [PopularLocation] = decoded.elements.compactMap { element in
                guard let lat = element.lat, let lon = element.lon,
                      let name = element.tags.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      name.count >= 3
                else { return nil }
                return PopularLocation(
                    id: UUID(),
                    name: name,
                    icon: Self.icon(for: element.tags.place),
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    // Neutral until real busyness data lands (#5). The chip
                    // rendering stays in the UI; level will be backed by real
                    // data once we have it.
                    busyLevel: .open,
                    subtitle: Self.subtitle(for: element.tags.place)
                )
            }

            // Dedupe by lowercased name (OSM sometimes carries the same
            // neighborhood as both `quarter` and `neighbourhood`).
            var seen = Set<String>()
            let deduped = candidates.filter { seen.insert($0.name.lowercased()).inserted }

            let sorted = deduped.sorted {
                let a = CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                let b = CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)
                return a.distance(from: mapCenter) < b.distance(from: mapCenter)
            }

            let finalPlaces = Array(sorted.prefix(8))
            if !finalPlaces.isEmpty {
                self.places = finalPlaces
            }
            self.lastFetchedCenter = center
        } catch {
            // Public Overpass occasionally returns 429 / timeouts under load —
            // keep showing the previous list and try again on the next pan.
        }
    }

    // MARK: - Display helpers

    private static func icon(for place: String?) -> Ph {
        switch (place ?? "").lowercased() {
        case "neighbourhood", "neighborhood": return .mapPinArea
        case "suburb":                        return .houseLine
        case "quarter":                       return .buildings
        default:                              return .mapPinArea
        }
    }

    private static func subtitle(for place: String?) -> String {
        switch (place ?? "").lowercased() {
        case "neighbourhood", "neighborhood": return "Neighborhood"
        case "suburb":                        return "Suburb"
        case "quarter":                       return "District"
        default:                              return "Hotspot"
        }
    }
}

// MARK: - Overpass decoder (private to this file)

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let lat: Double?
        let lon: Double?
        let tags: Tags

        struct Tags: Decodable {
            let name: String?
            let place: String?
        }
    }
}
