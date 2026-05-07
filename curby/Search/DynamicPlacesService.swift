//
//  DynamicPlacesService.swift
//  curby
//
//  Single source of dynamic landmark/area places. Both the Places carousel
//  in the bottom sheet and the on-map place pins observe this service so
//  they stay in sync. Replaces the per-city hardcoded PopularLocation arrays.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import PhosphorSwift

@MainActor
@Observable
final class DynamicPlacesService {
    private(set) var places: [PopularLocation] = []
    private(set) var isLoading: Bool = false

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastFetchedCenter: CLLocationCoordinate2D?

    /// Apple throttles MKLocalSearch at 50 requests / 60 seconds. Debounce
    /// generously and keep parallelism low so a fast pan can't burn the budget.
    private let debounceMilliseconds: UInt64 = 1_200
    /// Don't refetch while panning inside this radius of the last fetch.
    private let refetchDistanceMeters: Double = 1_500
    /// Broad landmark query buckets. The first three run per fetch.
    /// Wording is biased toward area-scale POIs (downtowns, districts, large
    /// parks, major attractions) — we want the hotspots a driver would
    /// recognize, not individual restaurants or community parks.
    private static let landmarkQueries: [(query: String, icon: Ph)] = [
        ("downtown",          .buildings),
        ("regional park",     .tree),
        ("shopping district", .bag),
        ("university",        .graduationCap),
        ("museum",            .ticket),
        ("stadium",           .speakerHifi),
        ("airport",           .airplane),
        ("mall",              .storefront),
        ("beach",             .umbrella),
        ("national park",     .tree),
    ]

    /// POI categories that count as a "hotspot" — area-scale destinations
    /// drivers recognize. Anything outside this set (restaurants, cafes,
    /// banks, gas stations, schools, gyms, etc.) is dropped.
    private static let allowedCategories: Set<MKPointOfInterestCategory> = [
        .airport,
        .amusementPark,
        .aquarium,
        .beach,
        .museum,
        .nationalPark,
        .stadium,
        .theater,
        .university,
        .zoo,
        .publicTransport,
        .park,            // Park results filtered further by signals (see shouldKeep).
        .marina,
    ]

    /// True when an MKMapItem is "hotspot worthy" — an area-scale landmark
    /// rather than a specific business or community-scale park.
    ///
    /// `query` is the landmark query that produced the item; we use it as a
    /// signal for `.park` results (a "regional park" query inherently asks
    /// for larger parks; an incidental park result from a "downtown" query
    /// is held to a stricter bar).
    private static func shouldKeep(_ item: MKMapItem, query: String) -> Bool {
        // Reject if Apple categorized it but the category isn't on our list
        // (this drops restaurants, cafes, banks, schools, gas stations, etc.).
        if let category = item.pointOfInterestCategory {
            guard allowedCategories.contains(category) else { return false }

            // Apple lumps community parks and famous parks into `.park`.
            // Keep only ones with a real popularity signal — no hardcoded
            // names. Two dynamic signals are accepted:
            //  - The originating query was already targeting larger parks
            //    ("regional park", "state park", "national park").
            //  - The place has an official website URL. Community parks
            //    almost never do; well-known city parks reliably do.
            if category == .park {
                let queryLower = query.lowercased()
                let queryAimsLargePark = ["regional park", "state park", "national park"]
                    .contains(where: queryLower.contains)
                let hasOfficialURL = item.url != nil
                if !queryAimsLargePark && !hasOfficialURL { return false }
            }
        }
        // No category means we can't reason about it — be conservative and
        // require the name to be reasonably substantial (drops single-word
        // generic entries that often slip through).
        if (item.name ?? "").count < 4 { return false }
        return true
    }

    /// Schedule a fetch if the center has moved beyond `refetchDistanceMeters`
    /// since the last successful fetch. Cancel + reschedule any in-flight task.
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

        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 8_000,
            longitudinalMeters: 8_000
        )

        var collected: [PopularLocation] = []
        var seenNames: Set<String> = []

        await withTaskGroup(of: [PopularLocation].self) { group in
            for entry in Self.landmarkQueries.prefix(3) {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = entry.query
                    request.region = region
                    request.resultTypes = .pointOfInterest

                    guard let response = try? await MKLocalSearch(request: request).start() else {
                        return []
                    }

                    return response.mapItems
                        .compactMap { item -> PopularLocation? in
                            guard Self.shouldKeep(item, query: entry.query) else { return nil }
                            return PopularLocation(
                                id: UUID(),
                                name: item.name ?? entry.query.capitalized,
                                icon: entry.icon,
                                coordinate: item.placemark.coordinate,
                                // Neutral until real busyness data lands (#5).
                                // Color-coded chip stays in the UI; the level
                                // here will eventually be backed by real data.
                                busyLevel: .open,
                                subtitle: item.placemark.locality ?? item.placemark.subLocality ?? "Nearby"
                            )
                        }
                        .prefix(3)
                        .map { $0 }
                }
            }

            for await results in group {
                for place in results {
                    let key = place.name.lowercased()
                    if seenNames.insert(key).inserted {
                        collected.append(place)
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }

        let mapCenter = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let sorted = collected.sorted {
            let a = CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            let b = CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)
            return a.distance(from: mapCenter) < b.distance(from: mapCenter)
        }

        let finalPlaces = Array(sorted.prefix(8))
        // Only replace if non-empty so users keep seeing the previous list while
        // the next fetch is in flight (prevents a flash of an empty carousel).
        if !finalPlaces.isEmpty {
            self.places = finalPlaces
        }
        self.lastFetchedCenter = center
    }
}
