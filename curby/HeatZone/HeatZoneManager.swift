//
//  HeatZoneManager.swift
//  curby
//
//  Provides heat zone data — mock for now, real API later.
//

import CoreLocation
import Foundation
import Observation

/// Manages heat zone data for a given destination.
///
/// Currently generates realistic mock data with block-shaped zones.
/// The interface is designed so a real API can be swapped in without changing consumers.
@Observable
final class HeatZoneManager {

    // MARK: - State

    /// Heat zones around the current destination.
    private(set) var heatZones: [HeatZone] = []

    /// Whether we're loading zone data.
    private(set) var isLoading: Bool = false

    /// The currently selected heat zone (for detail view).
    var selectedZone: HeatZone?

    /// Street surfaces that have already been rebuilt from real road geometry.
    private var alignedStreetSurfaceReferences: Set<String> = []

    /// Structure surfaces that have already been rebuilt from real building geometry.
    private var alignedStructureSurfaceReferences: Set<String> = []

    // MARK: - Public

    /// Load heat zones around a destination coordinate.
    func loadZones(
        around coordinate: CLLocationCoordinate2D,
        destinationName: String,
        radiusMeters: Double = 400
    ) {
        isLoading = true
        alignedStreetSurfaceReferences = []
        alignedStructureSurfaceReferences = []

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            heatZones = Self.generateMockZones(
                around: coordinate,
                name: destinationName,
                radiusMeters: radiusMeters
            )
            isLoading = false
        }
    }

    /// Clear all zones (when destination changes).
    func clearZones() {
        heatZones = []
        selectedZone = nil
        alignedStreetSurfaceReferences = []
        alignedStructureSurfaceReferences = []
    }

    /// Whether any visible street-level surfaces still need to be road-aligned.
    var needsStreetSurfaceAlignment: Bool {
        let streetReferences = heatZones
            .flatMap(\.streetLevelSurfaces)
            .compactMap(\.sourceReference)

        guard !streetReferences.isEmpty else {
            return false
        }

        return streetReferences.contains(where: { !alignedStreetSurfaceReferences.contains($0) })
    }

    /// Whether any visible structure-level surfaces still need to be snapped to mapped buildings.
    var needsStructureSurfaceAlignment: Bool {
        let structureReferences = heatZones
            .flatMap(\.structureLevelSurfaces)
            .compactMap(\.sourceReference)

        guard !structureReferences.isEmpty else {
            return false
        }

        return structureReferences.contains(where: { !alignedStructureSurfaceReferences.contains($0) })
    }

    /// Rebuild street-level polygons from queried road centerlines while leaving
    /// overview zones and structure-level geometry untouched.
    @discardableResult
    func alignStreetSurfaces(to roads: [ParkingRoadFeature]) -> Int {
        guard !roads.isEmpty, needsStreetSurfaceAlignment else {
            return 0
        }

        var updatedZones = heatZones
        var newlyAlignedReferences: Set<String> = []
        var attemptedReferences: Set<String> = []

        for zoneIndex in updatedZones.indices {
            let zone = updatedZones[zoneIndex]
            let spotsByReference = Dictionary(
                uniqueKeysWithValues: zone.parkingSpots.map { ($0.id.uuidString, $0) }
            )

            var updatedSurfaces = zone.parkingSurfaces
            var updatedSpots = zone.parkingSpots
            var zoneChanged = false

            for surfaceIndex in updatedSurfaces.indices {
                let surface = updatedSurfaces[surfaceIndex]

                guard
                    surface.kind == .curbSegment,
                    let reference = surface.sourceReference,
                    !alignedStreetSurfaceReferences.contains(reference)
                else {
                    continue
                }

                attemptedReferences.insert(reference)

                guard
                    let spot = spotsByReference[reference],
                    let alignmentData = ParkingRoadAlignment.alignedBoundaryAndName(
                        for: spot,
                        using: roads
                    )
                else {
                    continue
                }

                newlyAlignedReferences.insert(reference)

                updatedSurfaces[surfaceIndex] = ParkingSurface(
                    id: surface.id,
                    zoneID: surface.zoneID,
                    name: alignmentData.name ?? surface.name,
                    kind: surface.kind,
                    busyLevel: surface.busyLevel,
                    polygonCoords: alignmentData.coordinates,
                    sourceReference: surface.sourceReference
                )

                if let name = alignmentData.name, !name.isEmpty,
                   let sIndex = updatedSpots.firstIndex(where: { $0.id == spot.id }) {
                    updatedSpots[sIndex].roadName = name
                }

                zoneChanged = true
            }

            if zoneChanged {
                updatedZones[zoneIndex] = HeatZone(
                    id: zone.id,
                    name: zone.name,
                    coordinate: zone.coordinate,
                    radius: zone.radius,
                    busyScore: zone.busyScore,
                    parkingSpots: updatedSpots,
                    boundaryCoords: zone.boundaryCoords,
                    parkingSurfaces: updatedSurfaces
                )
            }
        }

        // Only mark successfully aligned surfaces so we can retry the failed ones
        // when more detailed vector tiles stream in during zooming.
        alignedStreetSurfaceReferences.formUnion(newlyAlignedReferences)

        guard !newlyAlignedReferences.isEmpty else {
            return 0
        }

        heatZones = updatedZones

        if let selectedZone {
            self.selectedZone = updatedZones.first(where: { $0.id == selectedZone.id })
        }

        return newlyAlignedReferences.count
    }

    /// Rebuild structure-level polygons from queried building footprints so garage and lot markers
    /// can stay attached to the actual building mass instead of the original mock rectangle.
    @discardableResult
    func alignStructureSurfaces(to buildings: [ParkingBuildingFeature]) -> Int {
        guard !buildings.isEmpty, needsStructureSurfaceAlignment else {
            return 0
        }

        var updatedZones = heatZones
        var newlyAlignedReferences: Set<String> = []
        var attemptedReferences: Set<String> = []

        for zoneIndex in updatedZones.indices {
            let zone = updatedZones[zoneIndex]
            let spotsByReference = Dictionary(
                uniqueKeysWithValues: zone.parkingSpots.map { ($0.id.uuidString, $0) }
            )

            var updatedSurfaces = zone.parkingSurfaces
            var zoneChanged = false

            for surfaceIndex in updatedSurfaces.indices {
                let surface = updatedSurfaces[surfaceIndex]

                guard
                    surface.kind.isStructureLevel,
                    let reference = surface.sourceReference,
                    !alignedStructureSurfaceReferences.contains(reference)
                else {
                    continue
                }

                attemptedReferences.insert(reference)

                guard
                    let spot = spotsByReference[reference],
                    let alignedBoundary = ParkingStructureAlignment.alignedBoundary(
                        for: spot,
                        using: buildings
                    )
                else {
                    continue
                }

                updatedSurfaces[surfaceIndex] = ParkingSurface(
                    id: surface.id,
                    zoneID: surface.zoneID,
                    name: surface.name,
                    kind: surface.kind,
                    busyLevel: surface.busyLevel,
                    polygonCoords: alignedBoundary,
                    minimumZoom: surface.minimumZoom,
                    sourceReference: surface.sourceReference
                )

                newlyAlignedReferences.insert(reference)
                zoneChanged = true
            }

            if zoneChanged {
                updatedZones[zoneIndex] = HeatZone(
                    id: zone.id,
                    name: zone.name,
                    coordinate: zone.coordinate,
                    radius: zone.radius,
                    busyScore: zone.busyScore,
                    parkingSpots: zone.parkingSpots,
                    boundaryCoords: zone.boundaryCoords,
                    parkingSurfaces: updatedSurfaces
                )
            }
        }

        alignedStructureSurfaceReferences.formUnion(newlyAlignedReferences)

        guard !newlyAlignedReferences.isEmpty else {
            return 0
        }

        heatZones = updatedZones

        if let selectedZone {
            self.selectedZone = updatedZones.first(where: { $0.id == selectedZone.id })
        }

        return newlyAlignedReferences.count
    }

    // MARK: - Mock Data Generation

    /// Generates color-coded heat zones covering the full walking radius using a hex-grid layout.
    ///
    /// One center zone + six surrounding zones tile the entire radius area without gaps.
    /// Only overview-level surfaces are produced — street-segment and garage/lot layers
    /// are omitted until real backend geometry is available.
    private static func generateMockZones(
        around center: CLLocationCoordinate2D,
        name: String,
        radiusMeters: Double
    ) -> [HeatZone] {
        // Zone size chosen so adjacent zones overlap; spacing places surrounding centers
        // at ~56% of the radius so the hex grid fully covers the circle edge.
        let spacing = radiusMeters * 0.56
        let zoneSize = radiusMeters * 0.98

        // (northMeters, eastMeters, busyScore 0–100, blockTemplate, rotationDeg, label)
        // Hex angles clockwise from north: N=0°, NE=60°, SE=120°, S=180°, SW=240°, NW=300°
        let s = spacing
        // Scores aligned with `CurbyConstants.busyScoreOpen` / `busyScoreBusy`: center stays calmer
        // (typical “destination” hex) so low-traffic periods are not a solid red field.
        let defs: [(Double, Double, Int, Int, Double, String)] = [
            (0,          0,           34, 0,   8, "\(name)"),
            (s,          0,           52, 1,  -5, "North"),
            (s * 0.5,    s * 0.866,   28, 2,  12, "Northeast"),
            (-s * 0.5,   s * 0.866,   56, 3, -10, "Southeast"),
            (-s,         0,           42, 4,   2, "South"),
            (-s * 0.5,  -s * 0.866,   26, 5,  15, "Southwest"),
            (s * 0.5,   -s * 0.866,   80, 0,  -7, "Northwest"),
        ]

        return defs.map { northM, eastM, score, template, rot, label in
            let zoneID = UUID()
            let zoneCenter = HeatZoneGeometry.offsetCoordinate(
                from: center,
                northMeters: northM,
                eastMeters: eastM
            )
            let boundary = HeatZoneGeometry.blockBoundary(
                center: zoneCenter,
                sizeMeters: zoneSize,
                templateIndex: template,
                rotation: rot
            )
            let spots = generateMockParkingSpots(
                around: zoneCenter,
                busyScore: score,
                zoneSizeMeters: zoneSize
            )
            let surface = ParkingSurface(
                zoneID: zoneID,
                name: label,
                kind: .overviewArea,
                busyLevel: BusyLevel(score: score),
                polygonCoords: boundary
            )
            return HeatZone(
                id: zoneID,
                name: label,
                coordinate: zoneCenter,
                radius: zoneSize / 2,
                busyScore: score,
                parkingSpots: spots,
                boundaryCoords: boundary,
                parkingSurfaces: [surface]
            )
        }
    }

    /// Generates mock parking spots positioned within a zone's block area.
    private static func generateMockParkingSpots(
        around center: CLLocationCoordinate2D,
        busyScore: Int,
        zoneSizeMeters: Double
    ) -> [ParkingSpot] {
        let baseOpenness = max(0.05, 1.0 - Double(busyScore) / 100.0)
        let spread = zoneSizeMeters / 111_320.0 * 0.6 // Stay within zone

        let streetNames = [
            "Guadalupe St", "Lavaca St", "Congress Ave",
            "Rio Grande St", "San Antonio St", "Nueces St",
            "Red River St", "Brazos St"
        ]
        let garageNames = [
            "Capitol Parking Garage", "City Hall Garage",
            "Convention Center Lot", "Brazos Street Garage",
            "University Garage", "Market District Lot"
        ]

        var spots: [ParkingSpot] = []

        // Street parking spots (3-4 per zone)
        for i in 0..<Int.random(in: 3...4) {
            let jitter = Double.random(in: -0.15...0.15)
            let openness = min(1.0, max(0.05, baseOpenness + jitter))
            let latOff = Double.random(in: -spread...spread)
            let lngOff = Double.random(in: -spread...spread)

            spots.append(ParkingSpot(
                id: UUID(),
                coordinate: CLLocationCoordinate2D(
                    latitude: center.latitude + latOff,
                    longitude: center.longitude + lngOff
                ),
                type: .streetCurbside,
                walkingDistance: Double.random(in: 0.05...0.4),
                roadName: streetNames[i % streetNames.count],
                opennessProbability: openness,
                segmentLength: Double.random(in: 100...400),
                lotName: nil,
                spotsAvailable: nil,
                totalSpots: nil
            ))
        }

        // Metered spot
        spots.append(ParkingSpot(
            id: UUID(),
            coordinate: CLLocationCoordinate2D(
                latitude: center.latitude + Double.random(in: -spread...spread),
                longitude: center.longitude + Double.random(in: -spread...spread)
            ),
            type: .metered,
            walkingDistance: Double.random(in: 0.1...0.3),
            roadName: streetNames[Int.random(in: 3...5)],
            opennessProbability: min(1.0, max(0.05, baseOpenness + Double.random(in: -0.1...0.1))),
            segmentLength: Double.random(in: 50...200),
            lotName: nil,
            spotsAvailable: nil,
            totalSpots: nil
        ))

        // Garages / lots (1-2 per zone)
        for i in 0..<Int.random(in: 1...2) {
            let totalCapacity = Int.random(in: 80...400)
            let occupancyRate = Double(busyScore) / 100.0
            let available = max(0, Int(Double(totalCapacity) * (1.0 - occupancyRate + Double.random(in: -0.1...0.1))))

            spots.append(ParkingSpot(
                id: UUID(),
                coordinate: CLLocationCoordinate2D(
                    latitude: center.latitude + Double.random(in: -spread...spread),
                    longitude: center.longitude + Double.random(in: -spread...spread)
                ),
                type: i == 0 ? .garage : .lot,
                walkingDistance: Double.random(in: 0.1...0.5),
                roadName: nil,
                opennessProbability: nil,
                segmentLength: nil,
                lotName: garageNames[i % garageNames.count],
                spotsAvailable: available,
                totalSpots: totalCapacity
            ))
        }

        return spots
    }

}
