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

        guard CurbyConstants.isWithinAustinArea(coordinate) else {
            areas = []
            noParkingInGeofence = false
            lastErrorMessage = "Curby currently supports Austin-area parking only."
            isLoading = false
            return
        }

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
        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/category/parking")
        components?.queryItems = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 25))),
            URLQueryItem(name: "proximity", value: "\(coordinate.longitude),\(coordinate.latitude)"),
            URLQueryItem(name: "bbox", value: CurbyConstants.austinBoundingBoxParameter),
            URLQueryItem(name: "country", value: "US"),
        ]

        guard let url = components?.url else {
            throw CurbyAPIClientError.invalidBaseURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CurbyAPIClientError.badStatusCode(
                (response as? HTTPURLResponse)?.statusCode ?? -1,
                String(data: data, encoding: .utf8)
            )
        }

        let decoded = try JSONDecoder().decode(MapboxParkingCategoryResponse.self, from: data)
        let results = decoded.features.compactMap { feature -> LiveParkingArea? in
            let name = feature.properties.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            let baseCoordinate = CLLocationCoordinate2D(
                latitude: feature.geometry.coordinates[1],
                longitude: feature.geometry.coordinates[0]
            )
            guard CurbyConstants.isWithinAustinArea(baseCoordinate) else {
                return nil
            }

            let navigationCoordinate = feature.properties.coordinates.routablePoints.first.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            } ?? baseCoordinate
            let destinationDistanceMeters = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ).distance(from: CLLocation(
                latitude: navigationCoordinate.latitude,
                longitude: navigationCoordinate.longitude
            ))

            guard destinationDistanceMeters <= walkingRadiusMeters + CurbyConstants.parkingGeofenceToleranceMeters else {
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

        var uniqueResults: [LiveParkingArea] = []
        var seenIDs = Set<String>()
        for area in results {
            if seenIDs.insert(area.id).inserted {
                uniqueResults.append(area)
            }
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

            let routablePoints: [RoutablePoint]

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
        let coordinates: Coordinates
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
