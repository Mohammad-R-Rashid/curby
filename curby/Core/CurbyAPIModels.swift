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
