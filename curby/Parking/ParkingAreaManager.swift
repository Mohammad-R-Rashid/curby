//
//  ParkingAreaManager.swift
//  curby
//
//  Loads real parking POIs from Mapbox and keeps them bounded to Austin.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class ParkingAreaManager {
    private(set) var areas: [LiveParkingArea] = []
    private(set) var isLoading: Bool = false
    private(set) var lastErrorMessage: String?
    /// Mapbox returned successfully but zero POIs inside the walking radius (distinct from network errors).
    private(set) var noParkingInGeofence: Bool = false
    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var walkingGeofenceRadiusMeters: Double = OnboardingState.storedWalkingDistanceMeters

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastUserLocation: CLLocationCoordinate2D?

    func loadAreas(
        around coordinate: CLLocationCoordinate2D,
        userLocation: CLLocationCoordinate2D?,
        walkingRadiusMeters: Double = OnboardingState.storedWalkingDistanceMeters,
        limit: Int = 25
    ) {
        loadTask?.cancel()
        destinationCoordinate = coordinate
        lastUserLocation = userLocation
        walkingGeofenceRadiusMeters = walkingRadiusMeters

        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String else {
            areas = []
            noParkingInGeofence = false
            lastErrorMessage = "Missing Mapbox token."
            isLoading = false
            return
        }

        isLoading = true
        lastErrorMessage = nil
        noParkingInGeofence = false

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let loadedAreas = try await Self.fetchAreas(
                    around: coordinate,
                    userLocation: userLocation,
                    walkingRadiusMeters: walkingRadiusMeters,
                    limit: limit,
                    token: token
                )
                guard !Task.isCancelled else { return }
                self.areas = loadedAreas
                self.isLoading = false
                self.noParkingInGeofence = loadedAreas.isEmpty
                self.lastErrorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.areas = []
                self.isLoading = false
                self.noParkingInGeofence = false
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    func refresh(userLocation: CLLocationCoordinate2D?) {
        guard let destinationCoordinate else { return }
        loadAreas(
            around: destinationCoordinate,
            userLocation: userLocation ?? lastUserLocation,
            walkingRadiusMeters: walkingGeofenceRadiusMeters
        )
    }

    func clear() {
        loadTask?.cancel()
        areas = []
        isLoading = false
        lastErrorMessage = nil
        noParkingInGeofence = false
        destinationCoordinate = nil
        lastUserLocation = nil
    }

    var streetAreas: [LiveParkingArea] {
        areas.filter { $0.kind == .street }
    }

    var structureAreas: [LiveParkingArea] {
        areas.filter { $0.kind != .street }
    }

    var geofenceDistanceText: String {
        let miles = walkingGeofenceRadiusMeters / CurbyConstants.metersPerMile
        return String(format: "%.2f mi", miles)
    }

    private static func fetchAreas(
        around coordinate: CLLocationCoordinate2D,
        userLocation: CLLocationCoordinate2D?,
        walkingRadiusMeters: Double,
        limit: Int,
        token: String
    ) async throws -> [LiveParkingArea] {
        // Mapbox SearchBox returns the same data for `parking` and `parking_lot`,
        // and a `proximity`-only call tends to return up to 25 entries for the
        // single most popular garage in dense areas (different mapbox_ids,
        // identical coordinates). Pair a bbox-restricted call (diverse urban
        // results) with a proximity-only call (covers sparse suburban areas
        // where the bbox can be empty). Coordinate dedup below collapses any
        // remaining coincident entries.
        let pageLimit = String(min(max(limit, 1), 25))
        let proximity = "\(coordinate.longitude),\(coordinate.latitude)"
        // Query a bbox 1.75× the walking radius so dense neighborhoods
        // don't blow Mapbox's 25-result cap before we see all the
        // garages near a small hotspot. The post-filter below still
        // prunes everything outside the actual walking-radius circle
        // by `estimatedWalkingMeters`, so coverage goes up without
        // showing pins beyond the geofence.
        let bboxPaddingMeters = walkingRadiusMeters * 1.75 + CurbyConstants.parkingGeofenceToleranceMeters
        let metersPerLatDegree = 111_000.0
        let metersPerLonDegree = 111_000.0 * max(cos(coordinate.latitude * .pi / 180), 0.1)
        let dLat = bboxPaddingMeters / metersPerLatDegree
        let dLon = bboxPaddingMeters / metersPerLonDegree
        let bbox = "\(coordinate.longitude - dLon),\(coordinate.latitude - dLat),\(coordinate.longitude + dLon),\(coordinate.latitude + dLat)"

        let queries: [[URLQueryItem]] = [
            [
                URLQueryItem(name: "access_token", value: token),
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "limit", value: pageLimit),
                URLQueryItem(name: "proximity", value: proximity),
                URLQueryItem(name: "bbox", value: bbox),
            ],
            [
                URLQueryItem(name: "access_token", value: token),
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "limit", value: pageLimit),
                URLQueryItem(name: "proximity", value: proximity),
                URLQueryItem(name: "country", value: "US"),
            ],
        ]

        let allFeatures: [MapboxParkingCategoryFeature] = await withTaskGroup(
            of: [MapboxParkingCategoryFeature].self
        ) { group in
            for queryItems in queries {
                group.addTask {
                    do {
                        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/category/parking_lot")
                        components?.queryItems = queryItems

                        guard let url = components?.url else { return [] }

                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                            return []
                        }

                        let decoded = try JSONDecoder().decode(MapboxParkingCategoryResponse.self, from: data)
                        return decoded.features
                    } catch {
                        return []
                    }
                }
            }

            var collected: [MapboxParkingCategoryFeature] = []
            for await features in group {
                collected.append(contentsOf: features)
            }
            return collected
        }

        // Mapbox tags BikeLink and similar bike/scooter lockers under the
        // `parking_lot` category (verified against San Jose City Hall — the
        // first result is literally "BikeLink : City Hall Wedges"). Match
        // them anywhere in the name, not just at the start, so renames like
        // "City Hall - BikeLink" can't slip through.
        let blockedSubstrings = ["bikelink", "bike link", "bike rack", "bicycle rack", "scooter"]

        let results = allFeatures.compactMap { feature -> LiveParkingArea? in
            let name = feature.properties.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            // Filter out non-parking POIs
            let nameLower = name.lowercased()
            for substring in blockedSubstrings {
                if nameLower.contains(substring) { return nil }
            }

            let baseCoordinate = CLLocationCoordinate2D(
                latitude: feature.geometry.coordinates[1],
                longitude: feature.geometry.coordinates[0]
            )

            let navigationCoordinate = feature.properties.coordinates?.routablePoints?.first.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            } ?? baseCoordinate
            let destinationDistanceMeters = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ).distance(from: CLLocation(
                latitude: navigationCoordinate.latitude,
                longitude: navigationCoordinate.longitude
            ))

            // Compare estimated walking-route distance (not great-circle) to
            // the user's walking radius — see walkingRouteDetourFactor.
            let estimatedWalkingMeters = destinationDistanceMeters * CurbyConstants.walkingRouteDetourFactor
            guard estimatedWalkingMeters <= walkingRadiusMeters + CurbyConstants.parkingGeofenceToleranceMeters else {
                return nil
            }

            return LiveParkingArea(
                id: feature.properties.mapboxID,
                name: name,
                coordinate: baseCoordinate,
                navigationCoordinate: navigationCoordinate,
                address: feature.properties.address ?? "",
                fullAddress: feature.properties.fullAddress ?? "",
                placeFormatted: feature.properties.placeFormatted ?? "",
                phone: feature.properties.metadata?.phone,
                website: feature.properties.metadata?.website,
                openHoursText: feature.properties.metadata?.openHours?.weekdayText ?? [],
                categoryIDs: feature.properties.poiCategoryIDs ?? [],
                distanceMeters: feature.properties.distance,
                destinationDistanceMeters: destinationDistanceMeters,
                kind: LiveParkingArea.kind(
                    forName: name,
                    categoryIDs: feature.properties.poiCategoryIDs ?? []
                )
            )
        }

        // Deduplicate by Mapbox ID, then coalesce near-coincident entries
        // (Mapbox often surfaces the same physical garage as several POIs with
        // distinct ids and slight name variations like "P5610" vs "P5610 Javits
        // Center Parking"). Prefer the more descriptive name when collapsing.
        var dedupedByID: [LiveParkingArea] = []
        var seenIDs = Set<String>()
        for area in results {
            if seenIDs.insert(area.id).inserted {
                dedupedByID.append(area)
            }
        }

        let coalesceMeters: Double = 12.0
        var uniqueResults: [LiveParkingArea] = []
        for area in dedupedByID {
            let candidate = CLLocation(
                latitude: area.coordinate.latitude,
                longitude: area.coordinate.longitude
            )
            if let existingIndex = uniqueResults.firstIndex(where: { existing in
                CLLocation(
                    latitude: existing.coordinate.latitude,
                    longitude: existing.coordinate.longitude
                ).distance(from: candidate) < coalesceMeters
            }) {
                if Self.descriptivenessScore(of: area.name)
                    > Self.descriptivenessScore(of: uniqueResults[existingIndex].name) {
                    uniqueResults[existingIndex] = area
                }
                continue
            }
            uniqueResults.append(area)
        }

        if let userLocation {
            let origin = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            return uniqueResults.sorted {
                let lhsDestinationDistance = $0.destinationDistanceMeters ?? .greatestFiniteMagnitude
                let rhsDestinationDistance = $1.destinationDistanceMeters ?? .greatestFiniteMagnitude
                if abs(lhsDestinationDistance - rhsDestinationDistance) > 15 {
                    return lhsDestinationDistance < rhsDestinationDistance
                }

                let lhsDistance = origin.distance(from: CLLocation(
                    latitude: $0.navigationCoordinate.latitude,
                    longitude: $0.navigationCoordinate.longitude
                ))
                let rhsDistance = origin.distance(from: CLLocation(
                    latitude: $1.navigationCoordinate.latitude,
                    longitude: $1.navigationCoordinate.longitude
                ))
                return lhsDistance < rhsDistance
            }
        }

        return uniqueResults.sorted {
            ($0.destinationDistanceMeters ?? .greatestFiniteMagnitude) <
                ($1.destinationDistanceMeters ?? .greatestFiniteMagnitude)
        }
    }

    private static func descriptivenessScore(of name: String) -> Int {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        let hasSpace = trimmed.contains(" ")
        return letterCount * 10 + (hasSpace ? 1_000 : 0) + trimmed.count
    }
}

private struct MapboxParkingCategoryResponse: Decodable {
    let features: [MapboxParkingCategoryFeature]
}

private struct MapboxParkingCategoryFeature: Decodable {
    struct Geometry: Decodable {
        let coordinates: [Double]
    }

    struct Properties: Decodable {
        struct Coordinates: Decodable {
            struct RoutablePoint: Decodable {
                let latitude: Double
                let longitude: Double

                private enum CodingKeys: String, CodingKey {
                    case latitude
                    case longitude
                }
            }

            let routablePoints: [RoutablePoint]?

            private enum CodingKeys: String, CodingKey {
                case routablePoints = "routable_points"
            }
        }

        struct Metadata: Decodable {
            struct OpenHours: Decodable {
                let weekdayText: [String]

                private enum CodingKeys: String, CodingKey {
                    case weekdayText = "weekday_text"
                }
            }

            let phone: String?
            let website: String?
            let openHours: OpenHours?

            private enum CodingKeys: String, CodingKey {
                case phone
                case website
                case openHours = "open_hours"
            }
        }

        let name: String
        let mapboxID: String
        let address: String?
        let fullAddress: String?
        let placeFormatted: String?
        let coordinates: Coordinates?
        let poiCategoryIDs: [String]?
        let metadata: Metadata?
        let distance: Double?

        private enum CodingKeys: String, CodingKey {
            case name
            case mapboxID = "mapbox_id"
            case address
            case fullAddress = "full_address"
            case placeFormatted = "place_formatted"
            case coordinates
            case poiCategoryIDs = "poi_category_ids"
            case metadata
            case distance
        }
    }

    let geometry: Geometry
    let properties: Properties
}
