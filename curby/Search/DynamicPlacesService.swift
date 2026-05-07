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
    private static let landmarkQueries: [(query: String, icon: Ph)] = [
        ("downtown",          .buildings),
        ("park",              .tree),
        ("shopping district", .bag),
        ("university",        .graduationCap),
        ("museum",            .ticket),
        ("stadium",           .speakerHifi),
        ("hospital",          .firstAid),
        ("airport",           .airplane),
        ("mall",              .storefront),
        ("beach",             .umbrella),
    ]

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

                    return response.mapItems.prefix(3).map { item in
                        PopularLocation(
                            id: UUID(),
                            name: item.name ?? entry.query.capitalized,
                            icon: entry.icon,
                            coordinate: item.placemark.coordinate,
                            // Neutral until real busyness data lands (reminder #5).
                            busyLevel: .open,
                            subtitle: item.placemark.locality ?? item.placemark.subLocality ?? "Nearby"
                        )
                    }
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
