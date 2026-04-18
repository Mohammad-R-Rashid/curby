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
    static func polygon(from coords: [CLLocationCoordinate2D]) -> Polygon {
        return Polygon([coords])
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
            return UIColor(red: 0.30, green: 0.78, blue: 0.40, alpha: 1.0)
        case .busy:
            return UIColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 1.0)
        case .veryBusy:
            return UIColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1.0)
        }
    }

    /// SwiftUI Color for a busy level.
    static func color(for level: BusyLevel) -> Color {
        switch level {
        case .open: return Color(red: 0.30, green: 0.78, blue: 0.40)
        case .busy: return Color(red: 1.0, green: 0.70, blue: 0.20)
        case .veryBusy: return Color(red: 1.0, green: 0.35, blue: 0.30)
        }
    }
}
