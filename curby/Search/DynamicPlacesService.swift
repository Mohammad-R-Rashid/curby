//
//  DynamicPlacesService.swift
//  curby
//
//  Single source of dynamic landmark/area places. Both the Hotspots
//  carousel in the bottom sheet and the on-map place pins observe this
//  service so they stay in sync.
//
//  Backed by Mapbox SearchBox forward search (not Apple's MKLocalSearch).
//  Apple's POI categories don't include "neighborhood" / "district" — every
//  query for "downtown" came back as POIs (specific malls or buildings)
//  instead of areas. Mapbox forward exposes feature types
//  `neighborhood,locality,district,place` that return real administrative
//  areas alongside well-known POIs.
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

    /// Keep debounces generous and parallelism low — Mapbox SearchBox has a
    /// per-second rate limit on the paid plan.
    private let debounceMilliseconds: UInt64 = 1_200
    /// Don't refetch while panning inside this radius of the last fetch.
    private let refetchDistanceMeters: Double = 1_500

    /// Generic urban-area queries we run in parallel. The first three execute
    /// per fetch. Each result is filtered to area-scale feature types below.
    private static let landmarkQueries: [(query: String, icon: Ph)] = [
        ("downtown",     .buildings),
        ("district",     .mapPinArea),
        ("park",         .tree),
        ("midtown",      .buildings),
        ("uptown",       .buildings),
        ("village",      .storefront),
        ("plaza",        .storefront),
    ]

    /// Mapbox feature types we surface as Hotspots — area-scale destinations
    /// drivers recognize. POIs slip in for famous landmarks (zoos, stadiums,
    /// airports) and are filtered by name length below as a backstop.
    /// `nonisolated` so per-query TaskGroup closures can read it.
    private nonisolated static let allowedFeatureTypes: Set<String> = [
        "neighborhood",
        "locality",
        "district",
        "place",
        "poi",
    ]

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
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              !token.isEmpty
        else { return }

        isLoading = true
        defer { isLoading = false }

        let proximity = "\(center.longitude),\(center.latitude)"

        var collected: [PopularLocation] = []
        var seenIDs = Set<String>()

        await withTaskGroup(of: [PopularLocation].self) { group in
            for entry in Self.landmarkQueries.prefix(3) {
                group.addTask {
                    await Self.fetchOne(
                        query: entry.query,
                        icon: entry.icon,
                        proximity: proximity,
                        token: token
                    )
                }
            }

            for await results in group {
                for place in results {
                    if seenIDs.insert(place.id.uuidString).inserted {
                        collected.append(place)
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Sort by distance to the proximity center and keep the top 8.
        let mapCenter = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let sorted = collected.sorted {
            let a = CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            let b = CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)
            return a.distance(from: mapCenter) < b.distance(from: mapCenter)
        }

        let finalPlaces = Array(sorted.prefix(8))
        // Only replace if non-empty so users keep seeing the previous list
        // while the next fetch is in flight.
        if !finalPlaces.isEmpty {
            self.places = finalPlaces
        }
        self.lastFetchedCenter = center
    }

    /// Run a single Mapbox forward query. Off-MainActor (the TaskGroup
    /// closures execute concurrently); does no actor-isolated work.
    private nonisolated static func fetchOne(
        query: String,
        icon: Ph,
        proximity: String,
        token: String
    ) async -> [PopularLocation] {
        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/forward")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "types", value: "neighborhood,locality,district,place,poi"),
            URLQueryItem(name: "proximity", value: proximity),
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(MapboxForwardFeatures.self, from: data)
            return decoded.features.compactMap { feature -> PopularLocation? in
                guard let coords = feature.geometry?.coordinates, coords.count >= 2 else { return nil }
                let featureType = feature.properties.featureType ?? ""
                guard allowedFeatureTypes.contains(featureType) else { return nil }
                let name = (feature.properties.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count >= 3 else { return nil }
                return PopularLocation(
                    id: UUID(),
                    name: name,
                    icon: icon,
                    coordinate: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0]),
                    // Neutral until real busyness data lands (#5). The chip
                    // rendering stays in the UI; level will eventually be
                    // backed by real data.
                    busyLevel: .open,
                    subtitle: feature.properties.placeFormatted ?? "Nearby"
                )
            }
        } catch {
            return []
        }
    }
}

// MARK: - Mapbox forward decoder (private to this file)

private struct MapboxForwardFeatures: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let geometry: Geometry?
        let properties: Properties

        struct Geometry: Decodable {
            let coordinates: [Double]
        }

        struct Properties: Decodable {
            let name: String?
            let placeFormatted: String?
            let featureType: String?
            let mapboxID: String?

            private enum CodingKeys: String, CodingKey {
                case name
                case placeFormatted = "place_formatted"
                case featureType = "feature_type"
                case mapboxID = "mapbox_id"
            }
        }
    }
}
