//
//  HeatZone.swift
//  curby
//
//  Models for parking heat zones and parking spots.
//

import CoreLocation
import Foundation
import PhosphorSwift

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

    /// Initialise from a 0–100 how-busy reading.
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

// MARK: - Parking Surface Geometry

/// Describes how a parking zone resolves visually as the user zooms in.
///
/// These geometries are intentionally backend-ready: later we can replace the mock coordinates
/// with exact GeoJSON polygons for curb segments, garages, lots, and building footprints.
enum ParkingSurfaceKind: String, CaseIterable, Codable {
    case overviewArea
    case curbSegment
    case garageFootprint
    case lotFootprint

    var minimumZoom: Double {
        switch self {
        case .overviewArea:
            return 0
        case .curbSegment:
            return CurbyConstants.parkingStreetDetailZoom
        case .garageFootprint, .lotFootprint:
            return CurbyConstants.parkingStructureDetailZoom
        }
    }

    var isStructureLevel: Bool {
        switch self {
        case .garageFootprint, .lotFootprint:
            return true
        case .overviewArea, .curbSegment:
            return false
        }
    }
}

/// A single backend-ready polygon that can be rendered on the map.
struct ParkingSurface: Identifiable, Hashable {
    let id: UUID
    let zoneID: UUID
    let name: String
    let kind: ParkingSurfaceKind
    let busyLevel: BusyLevel
    let polygonCoords: [CLLocationCoordinate2D]
    let minimumZoom: Double
    let sourceReference: String?

    init(
        id: UUID = UUID(),
        zoneID: UUID,
        name: String,
        kind: ParkingSurfaceKind,
        busyLevel: BusyLevel,
        polygonCoords: [CLLocationCoordinate2D],
        minimumZoom: Double? = nil,
        sourceReference: String? = nil
    ) {
        self.id = id
        self.zoneID = zoneID
        self.name = name
        self.kind = kind
        self.busyLevel = busyLevel
        self.polygonCoords = polygonCoords
        self.minimumZoom = minimumZoom ?? kind.minimumZoom
        self.sourceReference = sourceReference
    }

    func isVisible(at zoom: Double) -> Bool {
        zoom >= minimumZoom
    }

    // Hash by stable identity so backend-fed geometry arrays do not need
    // CLLocationCoordinate2D to conform to Hashable.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ParkingSurface, rhs: ParkingSurface) -> Bool {
        lhs.id == rhs.id
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
    let parkingSurfaces: [ParkingSurface]

    /// Pre-computed polygon boundary for the overview stage.
    /// Kept as a convenience alias for legacy consumers.
    var boundaryCoords: [CLLocationCoordinate2D] {
        overviewSurface?.polygonCoords ?? []
    }

    var busyLevel: BusyLevel {
        BusyLevel(score: busyScore)
    }

    var overviewSurface: ParkingSurface? {
        parkingSurfaces.first(where: { $0.kind == .overviewArea })
    }

    var streetLevelSurfaces: [ParkingSurface] {
        parkingSurfaces.filter { $0.kind == .curbSegment }
    }

    var structureLevelSurfaces: [ParkingSurface] {
        parkingSurfaces.filter(\.kind.isStructureLevel)
    }

    func visibleSurfaces(at zoom: Double) -> [ParkingSurface] {
        parkingSurfaces.filter { $0.isVisible(at: zoom) }
    }

    init(
        id: UUID,
        name: String,
        coordinate: CLLocationCoordinate2D,
        radius: Double,
        busyScore: Int,
        parkingSpots: [ParkingSpot],
        boundaryCoords: [CLLocationCoordinate2D],
        parkingSurfaces: [ParkingSurface] = []
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.radius = radius
        self.busyScore = busyScore
        self.parkingSpots = parkingSpots

        if parkingSurfaces.isEmpty {
            let overview = ParkingSurface(
                zoneID: id,
                name: name,
                kind: .overviewArea,
                busyLevel: BusyLevel(score: busyScore),
                polygonCoords: boundaryCoords
            )
            self.parkingSurfaces = boundaryCoords.isEmpty ? [] : [overview]
        } else {
            self.parkingSurfaces = parkingSurfaces
        }
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

    var icon: Ph {
        switch self {
        case .streetCurbside: return .roadHorizon
        case .garage: return .garage
        case .lot: return .car
        case .metered: return .park
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
    var roadName: String?
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

    /// Busy level inferred from the remaining capacity.
    var capacityBusyLevel: BusyLevel {
        guard
            let available = spotsAvailable,
            let total = totalSpots,
            total > 0
        else {
            return .busy
        }

        let occupancy = 1.0 - (Double(available) / Double(total))
        return BusyLevel(score: Int(occupancy * 100))
    }

    /// A unified 0–100 openness index for UI display.
    var computedScore: Int? {
        if type == .streetCurbside || type == .metered {
            guard let prob = opennessProbability else { return nil }
            return Int(prob * 100)
        } else {
            // Simplified logic: availability percentage
            // Later this will be populated directly from the backend parking model
            guard let available = spotsAvailable, let total = totalSpots, total > 0 else { return nil }
            return Int((Double(available) / Double(total)) * 100)
        }
    }

    /// Unified busy level based on the computed openness index.
    var computedBusyLevel: BusyLevel {
        guard let score = computedScore else { return .open }
        // Higher openness index means more likely to find a spot.
        if score >= 60 { return .open }
        if score >= 30 { return .busy }
        return .veryBusy
    }
}
