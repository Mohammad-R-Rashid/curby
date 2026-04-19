//
//  HeatZoneGeometry.swift
//  curby
//
//  Geometry helpers for rendering heat zones on the Mapbox map.
//

import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// Provides geometry and color utilities for heat zone map rendering.
enum HeatZoneGeometry {

    // MARK: - Block Shape Templates

    /// Normalised polygon templates in unit coordinates (-1...1).
    /// Each represents a different block/neighbourhood shape.
    private static let blockTemplates: [[(Double, Double)]] = [
        // Template 0: Wide rectangle (3×2 blocks)
        [
            (-1.0, -0.65), (-0.15, -0.70), (0.20, -0.68),
            (1.0, -0.65), (1.05, -0.10), (0.98, 0.30),
            (1.0, 0.65), (0.15, 0.70), (-0.25, 0.68),
            (-1.0, 0.65), (-1.02, 0.10), (-0.97, -0.25)
        ],
        // Template 1: L-shape (wraps around a corner)
        [
            (-1.0, -1.0), (0.35, -1.0), (0.35, -0.25),
            (1.0, -0.25), (1.0, 1.0), (-0.30, 1.0),
            (-0.30, 0.25), (-1.0, 0.25)
        ],
        // Template 2: Wide with street notch
        [
            (-1.0, -0.55), (-0.15, -0.50), (-0.15, -0.80),
            (0.20, -0.80), (0.20, -0.55), (1.0, -0.50),
            (1.0, 0.55), (0.10, 0.50), (-1.0, 0.55)
        ],
        // Template 3: Tall rectangle (2×4 blocks)
        [
            (-0.55, -1.0), (0.55, -1.0), (0.58, -0.30),
            (0.52, 0.35), (0.55, 1.0), (-0.55, 1.0),
            (-0.52, 0.30), (-0.58, -0.35)
        ],
        // Template 4: Irregular pentagon (triangular block)
        [
            (-0.85, -0.50), (0.10, -1.0), (0.90, -0.45),
            (0.70, 0.60), (-0.10, 0.95), (-0.80, 0.40)
        ],
        // Template 5: U-shape (open on one side)
        [
            (-1.0, -0.8), (-0.3, -0.8), (-0.3, -0.15),
            (0.3, -0.15), (0.3, -0.8), (1.0, -0.8),
            (1.0, 0.8), (-1.0, 0.8)
        ],
    ]

    // MARK: - Block Boundary Generation

    /// Generate a block-shaped polygon boundary for a heat zone.
    ///
    /// - Parameters:
    ///   - center: Centre coordinate of the zone.
    ///   - sizeMeters: Approximate size (width) of the zone in metres.
    ///   - templateIndex: Index into the shape template array.
    ///   - rotation: Rotation in degrees to align with local street grid.
    /// - Returns: Closed ring of coordinates suitable for a Polygon.
    static func blockBoundary(
        center: CLLocationCoordinate2D,
        sizeMeters: Double,
        templateIndex: Int,
        rotation: Double = 0
    ) -> [CLLocationCoordinate2D] {
        let template = blockTemplates[templateIndex % blockTemplates.count]

        let latScale = sizeMeters / 111_320.0
        let lngScale = sizeMeters / (111_320.0 * cos(center.latitude * .pi / 180.0))

        let rad = rotation * .pi / 180.0
        let cosR = cos(rad)
        let sinR = sin(rad)

        var coords = template.map { (x, y) -> CLLocationCoordinate2D in
            let rx = x * cosR - y * sinR
            let ry = x * sinR + y * cosR
            return CLLocationCoordinate2D(
                latitude: center.latitude + ry * latScale,
                longitude: center.longitude + rx * lngScale
            )
        }

        // Close the ring
        if let first = coords.first {
            coords.append(first)
        }

        return coords
    }

    /// Create a Mapbox Polygon from boundary coordinates.
    nonisolated static func polygon(from coords: [CLLocationCoordinate2D]) -> Polygon {
        return Polygon([coords])
    }

    /// Creates a rotated rectangular footprint.
    ///
    /// This is used for street-level curb segments and structure-level garage/lot footprints.
    static func rectangleBoundary(
        center: CLLocationCoordinate2D,
        lengthMeters: Double,
        widthMeters: Double,
        rotation: Double = 0
    ) -> [CLLocationCoordinate2D] {
        let halfLength = lengthMeters / 2.0
        let halfWidth = widthMeters / 2.0

        let corners: [(Double, Double)] = [
            (-halfLength, -halfWidth),
            (halfLength, -halfWidth),
            (halfLength, halfWidth),
            (-halfLength, halfWidth)
        ]

        let radians = rotation * .pi / 180.0
        let cosR = cos(radians)
        let sinR = sin(radians)

        var coords = corners.map { east, north in
            let rotatedEast = east * cosR - north * sinR
            let rotatedNorth = east * sinR + north * cosR
            return offsetCoordinate(
                from: center,
                northMeters: rotatedNorth,
                eastMeters: rotatedEast
            )
        }

        if let first = coords.first {
            coords.append(first)
        }

        return coords
    }



    /// Offsets a coordinate by local north/east metre values.
    static func offsetCoordinate(
        from coordinate: CLLocationCoordinate2D,
        northMeters: Double,
        eastMeters: Double
    ) -> CLLocationCoordinate2D {
        let latitudeOffset = northMeters / 111_320.0
        let longitudeOffset = eastMeters / (111_320.0 * cos(coordinate.latitude * .pi / 180.0))

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeOffset,
            longitude: coordinate.longitude + longitudeOffset
        )
    }

    /// Offsets a coordinate by a distance in metres at a bearing in degrees.
    static func offsetCoordinate(
        from coordinate: CLLocationCoordinate2D,
        distanceMeters: Double,
        bearingDegrees: Double
    ) -> CLLocationCoordinate2D {
        let radians = bearingDegrees * .pi / 180.0
        let northMeters = distanceMeters * cos(radians)
        let eastMeters = distanceMeters * sin(radians)

        return offsetCoordinate(
            from: coordinate,
            northMeters: northMeters,
            eastMeters: eastMeters
        )
    }

    /// Converts a coordinate delta into local north/east metre offsets.
    static func meterOffset(
        from origin: CLLocationCoordinate2D,
        to coordinate: CLLocationCoordinate2D
    ) -> (north: Double, east: Double) {
        let northMeters = (coordinate.latitude - origin.latitude) * 111_320.0
        let eastMeters = (coordinate.longitude - origin.longitude)
            * (111_320.0 * cos(origin.latitude * .pi / 180.0))

        return (north: northMeters, east: eastMeters)
    }

    /// Converts parking surfaces into a GeoJSON feature collection for style-layer rendering.
    nonisolated static func featureCollection(for surfaces: [ParkingSurface]) -> FeatureCollection {
        FeatureCollection(features: surfaces.map(feature(for:)))
    }

    nonisolated static func feature(for surface: ParkingSurface) -> Feature {
        let geometry: Geometry
        if surface.kind == .curbSegment {
            geometry = .lineString(LineString(surface.polygonCoords))
        } else {
            geometry = .polygon(polygon(from: surface.polygonCoords))
        }

        var feature = Feature(geometry: geometry)
        feature.identifier = .string(surface.id.uuidString)
        feature.properties = [
            "zone_id": .string(surface.zoneID.uuidString),
            "surface_id": .string(surface.id.uuidString),
            "kind": .string(surface.kind.rawValue),
            "busy_level": .string(surface.busyLevel.rawValue),
            "name": .string(surface.name)
        ]
        return feature
    }

    /// Stable anchor for a surface polygon, biased toward a point that stays inside the footprint.
    nonisolated static func surfaceAnchor(
        of polygonCoordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        let polygon = polygon(from: polygonCoordinates)
        return polygon.centerOfMass ?? polygon.centroid ?? polygon.center
    }

    /// Backward-compatible alias for older structure badge call sites.
    nonisolated static func centroid(
        of polygonCoordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        surfaceAnchor(of: polygonCoordinates)
    }

    // MARK: - Legacy Circle (kept for fallback)

    /// Creates a geographic circle polygon from a center coordinate and radius.
    static func circlePolygon(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        steps: Int = 64
    ) -> Polygon {
        var coords: [CLLocationCoordinate2D] = []

        for i in 0..<steps {
            let angle = Double(i) * (2.0 * .pi / Double(steps))
            let dx = radiusMeters * cos(angle)
            let dy = radiusMeters * sin(angle)

            let lat = center.latitude + (dy / 111_320.0)
            let lng = center.longitude + (dx / (111_320.0 * cos(center.latitude * .pi / 180.0)))

            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }

        if let first = coords.first {
            coords.append(first)
        }

        return Polygon([coords])
    }

    // MARK: - Colors

    /// UIColor for a busy level — used for Mapbox StyleColor.
    static func uiColor(for level: BusyLevel) -> UIColor {
        switch level {
        case .open:
            return UIColor(red: 0.32, green: 0.78, blue: 0.52, alpha: 1.0)
        case .busy:
            return UIColor(red: 1.0, green: 0.62, blue: 0.28, alpha: 1.0)
        case .veryBusy:
            return UIColor(red: 1.0, green: 0.48, blue: 0.42, alpha: 1.0)
        }
    }

    static func styleColor(for level: BusyLevel) -> StyleColor {
        StyleColor(uiColor(for: level))
    }

    /// SwiftUI Color for a busy level.
    static func color(for level: BusyLevel) -> Color {
        switch level {
        case .open: return Color(red: 0.32, green: 0.78, blue: 0.52)
        case .busy: return Color(red: 1.0, green: 0.62, blue: 0.28)
        case .veryBusy: return Color(red: 1.0, green: 0.48, blue: 0.42)
        }
    }

    private static func deduplicatedCoordinates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []

        for coordinate in coordinates {
            guard let last = result.last else {
                result.append(coordinate)
                continue
            }

            if coordinate.distance(to: last) > 0.5 {
                result.append(coordinate)
            }
        }

        return result
    }

    private static func offsetPath(
        _ coordinates: [CLLocationCoordinate2D],
        distanceMeters: Double,
        bearingDeltaDegrees: Double
    ) -> [CLLocationCoordinate2D] {
        coordinates.enumerated().map { index, coordinate in
            let tangentBearing = pathBearing(at: index, in: coordinates)
            return offsetCoordinate(
                from: coordinate,
                distanceMeters: distanceMeters,
                bearingDegrees: tangentBearing + bearingDeltaDegrees
            )
        }
    }

    private static func pathBearing(
        at index: Int,
        in coordinates: [CLLocationCoordinate2D]
    ) -> Double {
        if coordinates.count < 2 {
            return 0
        }

        if index == 0 {
            return coordinates[0].direction(to: coordinates[1])
        }

        if index == coordinates.count - 1 {
            return coordinates[coordinates.count - 2].direction(to: coordinates[index])
        }

        return coordinates[index - 1].direction(to: coordinates[index + 1])
    }
}
