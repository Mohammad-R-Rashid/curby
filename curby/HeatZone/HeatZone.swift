//
//  HeatZone.swift
//  curby
//
//  Models for parking heat zones and parking spots.
//

import CoreLocation
import Foundation

// MARK: - Busy Level

/// Classification of how busy a zone or street is.
enum BusyLevel: String, CaseIterable, Codable {
    case open
    case busy
    case veryBusy

    var label: String {
        switch self {
        case .open: return "Open"
        case .busy: return "B"
        case .veryBusy: return "VB"
        }
    }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .busy: return "Busy"
        case .veryBusy: return "Very Busy"
        }
    }

    /// Initialise from a 0–100 busy score.
    init(score: Int) {
        switch score {
        case 0..<CurbyConstants.busyScoreOpen:
            self = .open
        case CurbyConstants.busyScoreOpen..<CurbyConstants.busyScoreBusy:
            self = .busy
        default:
            self = .veryBusy
        }
    }
}

// MARK: - Heat Zone

/// A geographic zone with aggregated parking busyness data.
struct HeatZone: Identifiable, Hashable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let radius: Double // metres
    let busyScore: Int // 0–100
    let parkingSpots: [ParkingSpot]

    /// Pre-computed polygon boundary following block/road outlines.
    /// Used for rendering on the map. Empty = no polygon rendered.
    let boundaryCoords: [CLLocationCoordinate2D]

    var busyLevel: BusyLevel {
        BusyLevel(score: busyScore)
    }

    // Hashable conformance using id only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HeatZone, rhs: HeatZone) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Parking Type

/// The type of parking space.
enum ParkingType: String, CaseIterable, Codable {
    case streetCurbside
    case garage
    case lot
    case metered

    var icon: String {
        switch self {
        case .streetCurbside: return "road.lanes"
        case .garage: return "building.2"
        case .lot: return "car.fill"
        case .metered: return "parkingsign.circle"
        }
    }

    var displayName: String {
        switch self {
        case .streetCurbside: return "Street Parking"
        case .garage: return "Garage"
        case .lot: return "Parking Lot"
        case .metered: return "Metered"
        }
    }
}

// MARK: - Parking Spot

/// A single parking option — covers street, garage, lot, and metered parking.
struct ParkingSpot: Identifiable, Hashable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let type: ParkingType
    let walkingDistance: Double // miles

    // Street/curbside specific
    let roadName: String?
    /// Probability that this road segment has open spots (0.0–1.0).
    /// This is the core algorithm output — stubbed with mock data.
    let opennessProbability: Double?
    let segmentLength: Double? // feet of curb

    // Garage/lot specific
    let lotName: String?
    let spotsAvailable: Int?
    let totalSpots: Int?

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ParkingSpot, rhs: ParkingSpot) -> Bool {
        lhs.id == rhs.id
    }

    /// Convenience: display name for any parking type.
    var displayName: String {
        switch type {
        case .streetCurbside, .metered:
            return roadName ?? "Unknown Road"
        case .garage, .lot:
            return lotName ?? "Unknown Lot"
        }
    }

    /// Openness as a percentage string (street parking).
    var opennessPercentage: String? {
        guard let prob = opennessProbability else { return nil }
        return "\(Int(prob * 100))%"
    }

    /// Openness busy level (for colour coding).
    var opennessBusyLevel: BusyLevel {
        guard let prob = opennessProbability else { return .open }
        switch prob {
        case 0.6...1.0: return .open
        case 0.3..<0.6: return .busy
        default: return .veryBusy
        }
    }

    /// Capacity string for lots/garages.
    var capacityString: String? {
        guard let available = spotsAvailable, let total = totalSpots else { return nil }
        return "\(available)/\(total)"
    }
}
