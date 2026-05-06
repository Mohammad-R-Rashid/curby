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

    /// Maximum number of POIs we materialize as heat zones at once. Each zone
    /// expands into ~5 polygons and gets a road-alignment pass, so dense areas
    /// (24+ POIs) used to lock up the main thread. Heat-zone scores are still
    /// mock for now; this cap is revisited when real busyness data lands.
    private static let maxHeatZones: Int = 10

    /// Load heat zones strictly around real, live parking POIs.
    func loadZones(
        from parkingAreas: [LiveParkingArea]
    ) {
        isLoading = true
        alignedStreetSurfaceReferences = []
        alignedStructureSurfaceReferences = []

        // parkingAreas arrives sorted by distance — keep the closest N.
        let limited = Array(parkingAreas.prefix(Self.maxHeatZones))

        Task { @MainActor in
            heatZones = Self.generateZones(from: limited)
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

    /// Generates heat zones with street-block curb segments + overview areas from real parking POIs.
    private static func generateZones(from areas: [LiveParkingArea]) -> [HeatZone] {
        return areas.map { area in
            let zoneID = UUID(uuidString: area.id) ?? UUID()
            let score = Int.random(in: 20...85) // Random until backend real-time density is connected
            let busyLevel = BusyLevel(score: score)

            var surfaces: [ParkingSurface] = []

            // 1. Overview area — larger polygon that's visible when zoomed out
            let overviewSize = 200.0
            let overviewBoundary = HeatZoneGeometry.blockBoundary(
                center: area.coordinate,
                sizeMeters: overviewSize,
                templateIndex: area.id.hashValue % 6,
                rotation: Double(area.id.hashValue % 45)
            )
            surfaces.append(ParkingSurface(
                zoneID: zoneID,
                name: area.displayName,
                kind: .overviewArea,
                busyLevel: busyLevel,
                polygonCoords: overviewBoundary,
                sourceReference: area.id
            ))

            // 2. Street-level curb segments — radiating from the parking area
            //    Creates 3-4 street segments at different bearings to simulate blocks
            let segmentBearings: [Double]
            switch area.kind {
            case .street:
                // Street parking: segments along the road in both directions
                let baseBearing = Double(area.id.hashValue % 180)
                segmentBearings = [baseBearing, baseBearing + 180, baseBearing + 90, baseBearing + 270]
            case .garage, .lot:
                // Structures: segments on surrounding approach streets
                let baseBearing = Double(area.id.hashValue % 90)
                segmentBearings = [baseBearing, baseBearing + 90, baseBearing + 180, baseBearing + 270]
            case .general:
                let baseBearing = Double(area.id.hashValue % 120)
                segmentBearings = [baseBearing, baseBearing + 120, baseBearing + 240]
            }

            for (i, bearing) in segmentBearings.enumerated() {
                // Offset the segment start from center so they radiate outward
                let offsetDistance = 30.0 + Double(i * 15)
                let segmentCenter = HeatZoneGeometry.offsetCoordinate(
                    from: area.coordinate,
                    distanceMeters: offsetDistance + 40,
                    bearingDegrees: bearing
                )

                // Each curb segment is a thin rectangle (like a painted street line)
                let segmentLength = 60.0 + Double(i % 3) * 25.0
                let segmentCoords = HeatZoneGeometry.rectangleBoundary(
                    center: segmentCenter,
                    lengthMeters: segmentLength,
                    widthMeters: 6.0,
                    rotation: bearing
                )

                // Vary busy level slightly per segment for visual interest
                let segmentScore = max(0, min(100, score + Int.random(in: -15...15)))
                surfaces.append(ParkingSurface(
                    zoneID: zoneID,
                    name: "\(area.displayName) — Block \(i + 1)",
                    kind: .curbSegment,
                    busyLevel: BusyLevel(score: segmentScore),
                    polygonCoords: segmentCoords,
                    sourceReference: area.id
                ))
            }

            // 3. Structure footprints for garages and lots
            if area.kind == .garage || area.kind == .lot {
                let footprintKind: ParkingSurfaceKind = area.kind == .garage ? .garageFootprint : .lotFootprint
                let footprintSize = area.kind == .garage ? 45.0 : 55.0
                let footprintWidth = area.kind == .garage ? 30.0 : 40.0
                let footprintCoords = HeatZoneGeometry.rectangleBoundary(
                    center: area.coordinate,
                    lengthMeters: footprintSize,
                    widthMeters: footprintWidth,
                    rotation: Double(area.id.hashValue % 30)
                )
                surfaces.append(ParkingSurface(
                    zoneID: zoneID,
                    name: area.displayName,
                    kind: footprintKind,
                    busyLevel: busyLevel,
                    polygonCoords: footprintCoords,
                    sourceReference: area.id
                ))
            }

            let spot = ParkingSpot(
                id: zoneID,
                coordinate: area.coordinate,
                type: area.kind == .garage ? .garage : (area.kind == .street ? .streetCurbside : .lot),
                walkingDistance: (area.effectiveDistanceMeters ?? 100) / 1609.344,
                roadName: area.streetLabel,
                opennessProbability: max(0.05, 1.0 - Double(score) / 100.0),
                segmentLength: 50,
                lotName: area.displayName,
                spotsAvailable: nil,
                totalSpots: nil
            )

            return HeatZone(
                id: zoneID,
                name: area.displayName,
                coordinate: area.coordinate,
                radius: overviewSize / 2,
                busyScore: score,
                parkingSpots: [spot],
                boundaryCoords: overviewBoundary,
                parkingSurfaces: surfaces
            )
        }
    }
    // Removed mock generators

}
