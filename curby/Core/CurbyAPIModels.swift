//
//  CurbyAPIModels.swift
//  curby
//
//  Shared frontend models for the deployed Curby backend.
//

import CoreLocation
import Foundation

struct CurbyLatLng: Codable, Hashable {
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

struct CurbyGeoJSONLineString: Codable, Hashable {
    let type: String
    let coordinates: [[Double]]

    var mapCoordinates: [CLLocationCoordinate2D] {
        coordinates.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }
}

struct CurbyTelemetryPayload: Codable, Hashable {
    let userId: String
    let lat: Double
    let lng: Double
    let speed: Double
    let heading: Double
    let accuracy: Double
    let timestamp: String
}

struct CurbyParkEventPayload: Codable, Hashable {
    let userId: String
    let lat: Double
    let lng: Double
    let timestamp: String
}

struct CurbyDepartEventPayload: Codable, Hashable {
    let userId: String
    let timestamp: String
}

struct CurbyRemoteConfig: Codable, Hashable {
    struct Detection: Codable, Hashable {
        let parkDetectionDurationSec: Int
        let parkDetectionDriftMeters: Double
        let departDetectionDurationSec: Int
        let speedStationaryMs: Double
        let speedWalkingMs: Double
    }

    struct AlgorithmWeights: Codable, Hashable {
        let availability: Double
        let turnover: Double
        let travelTime: Double
        let walkDistance: Double
        let loadBalance: Double
        let congestion: Double?
        let confidence: Double?
    }

    struct Algorithm: Codable, Hashable {
        let weights: AlgorithmWeights
        let estimatedCapacityPerArea: Int
        let recentDepartureWindowMin: Int
        let durationDecayHalfLifeHours: Double
        let reEvaluationIntervalSec: Int
        let scoreUpdateThreshold: Double
        let travelTimeDecayMin: Double
        let walkTimeDecayMin: Double
        let loadPenaltyK: Double
        let confidenceMinUsers: Int
    }

    struct Search: Codable, Hashable {
        let defaultRadiusMeters: Double
        let maxRadiusMeters: Double
        let maxCandidates: Int
        let occupancyRadiusMeters: Double
        /// When true (default from server), backend merges OSM Overpass parking with Mapbox POIs.
        let osmCompanionSearch: Bool?
        let overpassInterpreterUrl: String?
        /// Milliseconds to wait for Overpass before continuing with Mapbox-only candidates.
        let osmFetchTimeoutMs: Double?
    }

    struct Telemetry: Codable, Hashable {
        let uploadIntervalSec: Int
        let minDistanceMeters: Double
    }

    let version: Int
    let detection: Detection
    let algorithm: Algorithm
    let search: Search
    let telemetry: Telemetry

    static let `default` = CurbyRemoteConfig(
        version: 4,
        detection: Detection(
            parkDetectionDurationSec: 120,
            parkDetectionDriftMeters: 20,
            departDetectionDurationSec: 30,
            speedStationaryMs: 0.5,
            speedWalkingMs: 2.5
        ),
        algorithm: Algorithm(
            weights: AlgorithmWeights(
                availability: 0.28,
                turnover: 0.10,
                travelTime: 0.24,
                walkDistance: 0.10,
                loadBalance: 0.05,
                congestion: 0.18,
                confidence: 0.05
            ),
            estimatedCapacityPerArea: 50,
            recentDepartureWindowMin: 15,
            durationDecayHalfLifeHours: 4,
            reEvaluationIntervalSec: 120,
            scoreUpdateThreshold: 15,
            travelTimeDecayMin: 10,
            walkTimeDecayMin: 8,
            loadPenaltyK: 3,
            confidenceMinUsers: 10
        ),
        search: Search(
            defaultRadiusMeters: 1000,
            maxRadiusMeters: 5000,
            maxCandidates: 9,
            occupancyRadiusMeters: 200,
            osmCompanionSearch: true,
            overpassInterpreterUrl: "https://overpass-api.de/api/interpreter",
            osmFetchTimeoutMs: 1500
        ),
        telemetry: Telemetry(
            uploadIntervalSec: 5,
            minDistanceMeters: 10
        )
    )
}

struct CurbyParkingArea: Codable, Hashable {
    let id: String
    let name: String
    let center: CurbyLatLng
    let category: String
    let dataSource: String?

    var coordinate: CLLocationCoordinate2D {
        center.coordinate
    }

    var categoryLabel: String {
        switch normalizedCategory {
        case "parking_garage":
            return "Garage"
        case "parking_lot":
            return "Lot"
        case "parking_meter":
            return "Metered"
        case "parking_entrance":
            return "Entrance"
        default:
            return "Parking"
        }
    }

    var normalizedCategory: String {
        category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct CurbyScoreBreakdown: Codable, Hashable {
    let availability: Double
    let turnover: Double
    let travelTime: Double
    let congestion: Double?
    let walkDistance: Double
    let loadBalance: Double
    let confidence: Double?
}

struct CurbyScoredArea: Codable, Hashable {
    let areaId: String
    let score: Double
    let breakdown: CurbyScoreBreakdown
    let reasoning: String
}

struct CurbyRoute: Codable, Hashable {
    let geometry: CurbyGeoJSONLineString
    let travelTimeSec: Double
    let distanceMeters: Double
    let walkTimeSec: Double

    var coordinates: [CLLocationCoordinate2D] {
        geometry.mapCoordinates
    }

    var driveMinutesText: String {
        let minutes = max(1, Int(round(travelTimeSec / 60)))
        return "\(minutes) min drive"
    }

    var walkMinutesText: String {
        let minutes = max(1, Int(round(walkTimeSec / 60)))
        return "\(minutes) min walk"
    }

    var distanceMilesText: String {
        let miles = distanceMeters / 1_609.344
        return String(format: "%.1f mi", miles)
    }
}

struct CurbyParkingRecommendation: Hashable {
    let sessionId: String
    let area: CurbyParkingArea
    let route: CurbyRoute
    let score: CurbyScoredArea
    let reasoning: String

    /// Short label for how well this pick fits (hides abstract model output from the UI).
    var matchQualityShortLabel: String {
        let percent = Int((score.score * 100).rounded())
        switch percent {
        case 75...100:
            return "Strong match"
        case 58..<75:
            return "Good pick"
        case 42..<58:
            return "Okay option"
        default:
            return "Worth a try"
        }
    }
}

struct CurbyRecommendationEvent: Codable {
    let type: String
    let sessionId: String
    let area: CurbyParkingArea
    let route: CurbyRoute
    let score: CurbyScoredArea
    let reasoning: String
}

struct CurbyRouteUpdateEvent: Codable {
    let type: String
    let sessionId: String
    let newArea: CurbyParkingArea
    let newRoute: CurbyRoute
    let newScore: CurbyScoredArea
    let reason: String
}

struct CurbyNoDataEvent: Codable {
    let type: String
    let message: String
}

struct CurbyErrorEvent: Codable {
    let type: String
    let code: String
    let message: String
}

struct CurbyConfirmedEvent: Codable {
    let type: String
    let sessionId: String
}

struct CurbyHeartbeatAckEvent: Codable {
    let type: String
}

// MARK: - Parking Heat Map

/// Coarse difficulty bucket served as the primary visual cue on heat tiles.
/// Mirrors backend `HeatMapDifficulty` strings exactly.
enum CurbyHeatMapDifficulty: String, Codable, Hashable {
    case easy
    case medium
    case hard
}

/// One Polygon or MultiPolygon coming off the wire. We keep raw `[Double]`
/// nesting (instead of `CLLocationCoordinate2D` arrays) so the JSON shape
/// matches GeoJSON exactly; conversion happens in the render layer.
struct CurbyHeatMapGeometry: Codable, Hashable {
    let type: String
    /// `Polygon`  → [[[lng, lat], ...]]            — array of rings
    /// `MultiPolygon` → [[[[lng, lat], ...], ...]] — array of polygons
    private let rawCoordinates: AnyCodable

    var isMultiPolygon: Bool { type == "MultiPolygon" }

    /// Returns one or more rings-of-rings. For Polygon this is `[polygonRings]`;
    /// for MultiPolygon it's `[polygon1Rings, polygon2Rings, ...]`.
    var polygons: [[[CLLocationCoordinate2D]]] {
        if isMultiPolygon {
            guard let outer = rawCoordinates.value as? [[[[Double]]]] else { return [] }
            return outer.map { rings in rings.map(Self.ringToCoordinates) }
        } else {
            guard let rings = rawCoordinates.value as? [[[Double]]] else { return [] }
            return [rings.map(Self.ringToCoordinates)]
        }
    }

    private static func ringToCoordinates(_ ring: [[Double]]) -> [CLLocationCoordinate2D] {
        ring.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case rawCoordinates = "coordinates"
    }
}

struct CurbyHeatMapStats: Codable, Hashable {
    let blockCount: Int
    let avgCongestion: Double
    let activeParks: Int
    let recentDepartures: Int
    let areaSqM: Double
}

struct CurbyHeatMapTile: Codable, Hashable, Identifiable {
    let id: String
    let geometry: CurbyHeatMapGeometry
    let score: Double
    let label: CurbyHeatMapDifficulty
    /// Hex color suggested by the backend; matches the iOS palette.
    let tint: String
    let stats: CurbyHeatMapStats
}

struct CurbyHeatMapResponse: Codable, Hashable {
    let tiles: [CurbyHeatMapTile]
    let anchor: CurbyLatLng
    let radiusM: Double
    let clusterCount: Int
    let computedAt: String
    /// True when no `active_parks` rows existed in the query area; the
    /// score is congestion-only, so the UI can show a "low confidence" badge.
    let fallback: Bool
}

/// Tiny `Any` wrapper that round-trips arbitrary JSON arrays — used inside
/// `CurbyHeatMapGeometry` so Polygon and MultiPolygon coordinate nestings
/// can both live in one Codable struct without two parallel decoding paths.
private struct AnyCodable: Codable, Hashable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let nested = try? container.decode([[[[Double]]]].self) {
            self.value = nested
        } else if let nested = try? container.decode([[[Double]]].self) {
            self.value = nested
        } else if let nested = try? container.decode([[Double]].self) {
            self.value = nested
        } else {
            self.value = [] as [Any]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? [[[[Double]]]] {
            try container.encode(v)
        } else if let v = value as? [[[Double]]] {
            try container.encode(v)
        } else if let v = value as? [[Double]] {
            try container.encode(v)
        } else {
            try container.encode([[Double]]())
        }
    }

    func hash(into hasher: inout Hasher) {
        // Hash a structural digest — full coord arrays are large but stable
        // for a given response, and Identifiable.id covers the common path.
        if let v = value as? [[[[Double]]]] {
            hasher.combine("mp")
            hasher.combine(v.count)
        } else if let v = value as? [[[Double]]] {
            hasher.combine("p")
            hasher.combine(v.count)
        } else {
            hasher.combine("0")
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Structural equality is good enough for our use; full coord
        // comparisons are expensive and unnecessary.
        if let a = lhs.value as? [[[[Double]]]], let b = rhs.value as? [[[[Double]]]] {
            return a.count == b.count
        }
        if let a = lhs.value as? [[[Double]]], let b = rhs.value as? [[[Double]]] {
            return a.count == b.count
        }
        return false
    }
}

enum CurbyWebSocketEvent {
    case recommendation(CurbyParkingRecommendation)
    case routeUpdate(CurbyParkingRecommendation)
    case noData(String)
    case error(code: String, message: String)
    case confirmed(sessionId: String)
    case heartbeatAck
}

enum CurbyParkingSearchStatus: Equatable {
    case idle
    case connecting
    case searching
    case recommended
    case noData(String)
    case error(String)
    case arrived
}
