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
    func loadZones(around coordinate: CLLocationCoordinate2D, destinationName: String) {
        isLoading = true
        alignedStreetSurfaceReferences = []
        alignedStructureSurfaceReferences = []

        // Simulate network delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            heatZones = Self.generateMockZones(around: coordinate, name: destinationName)
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

    /// Generates mock heat zones with block-shaped boundaries around a coordinate.
    private static func generateMockZones(
        around center: CLLocationCoordinate2D,
        name: String
    ) -> [HeatZone] {
        // (name, lat offset, lng offset, busy score, template index, rotation, size)
        let zoneData: [(String, Double, Double, Int, Int, Double, Double)] = [
            ("\(name) — Core",    0.0,     0.0,     82, 0, 5.0,  180),
            ("North Block",       0.004,   0.001,   65, 1, -3.0, 160),
            ("South Side",       -0.004,  -0.0005,  45, 2, 8.0,  200),
            ("East Quarter",      0.001,   0.005,   73, 3, -5.0, 150),
            ("West End",         -0.001,  -0.005,   38, 4, 12.0, 170),
            ("Riverside",        -0.006,   0.003,   55, 5, 0.0,  190),
        ]

        return zoneData.map { data in
            let zoneID = UUID()
            let zoneCenter = CLLocationCoordinate2D(
                latitude: center.latitude + data.1,
                longitude: center.longitude + data.2
            )

            let boundary = HeatZoneGeometry.blockBoundary(
                center: zoneCenter,
                sizeMeters: data.6,
                templateIndex: data.4,
                rotation: data.5
            )

            let spots = generateMockParkingSpots(
                around: zoneCenter,
                busyScore: data.3,
                zoneSizeMeters: data.6
            )

            let surfaces = generateMockParkingSurfaces(
                zoneID: zoneID,
                zoneName: data.0,
                zoneBusyScore: data.3,
                zoneRotation: data.5,
                zoneSizeMeters: data.6,
                overviewBoundary: boundary,
                parkingSpots: spots
            )

            return HeatZone(
                id: zoneID,
                name: data.0,
                coordinate: zoneCenter,
                radius: data.6,
                busyScore: data.3,
                parkingSpots: spots,
                boundaryCoords: boundary,
                parkingSurfaces: surfaces
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

    private static func generateMockParkingSurfaces(
        zoneID: UUID,
        zoneName: String,
        zoneBusyScore: Int,
        zoneRotation: Double,
        zoneSizeMeters: Double,
        overviewBoundary: [CLLocationCoordinate2D],
        parkingSpots: [ParkingSpot]
    ) -> [ParkingSurface] {
        var surfaces: [ParkingSurface] = [
            ParkingSurface(
                zoneID: zoneID,
                name: zoneName,
                kind: .overviewArea,
                busyLevel: BusyLevel(score: zoneBusyScore),
                polygonCoords: overviewBoundary
            )
        ]

        var streetSurfaceIndex = 0

        for spot in parkingSpots {
            switch spot.type {
            case .streetCurbside, .metered:
                let segmentLengthFeet = spot.segmentLength ?? 180
                let segmentLengthMeters = max(28, min(segmentLengthFeet * 0.3048, zoneSizeMeters * 0.7))
                let alignment = streetSurfaceIndex.isMultiple(of: 2) ? zoneRotation : zoneRotation + 90
                streetSurfaceIndex += 1
                let p1 = HeatZoneGeometry.offsetCoordinate(from: spot.coordinate, distanceMeters: -segmentLengthMeters/2.0, bearingDegrees: alignment)
                let p2 = HeatZoneGeometry.offsetCoordinate(from: spot.coordinate, distanceMeters: segmentLengthMeters/2.0, bearingDegrees: alignment)

                surfaces.append(
                    ParkingSurface(
                        zoneID: zoneID,
                        name: spot.displayName,
                        kind: .curbSegment,
                        busyLevel: spot.opennessBusyLevel,
                        polygonCoords: [p1, p2],
                        sourceReference: spot.id.uuidString
                    )
                )

            case .garage:
                surfaces.append(
                    ParkingSurface(
                        zoneID: zoneID,
                        name: spot.displayName,
                        kind: .garageFootprint,
                        busyLevel: spot.capacityBusyLevel,
                        polygonCoords: HeatZoneGeometry.rectangleBoundary(
                            center: spot.coordinate,
                            lengthMeters: max(30, zoneSizeMeters * 0.26),
                            widthMeters: max(22, zoneSizeMeters * 0.18),
                            rotation: zoneRotation
                        ),
                        sourceReference: spot.id.uuidString
                    )
                )

            case .lot:
                surfaces.append(
                    ParkingSurface(
                        zoneID: zoneID,
                        name: spot.displayName,
                        kind: .lotFootprint,
                        busyLevel: spot.capacityBusyLevel,
                        polygonCoords: HeatZoneGeometry.rectangleBoundary(
                            center: spot.coordinate,
                            lengthMeters: max(28, zoneSizeMeters * 0.24),
                            widthMeters: max(18, zoneSizeMeters * 0.16),
                            rotation: zoneRotation + 12
                        ),
                        sourceReference: spot.id.uuidString
                    )
                )
            }
        }

        return surfaces
    }
}
