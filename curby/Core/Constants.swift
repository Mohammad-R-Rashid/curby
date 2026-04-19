//
//  Constants.swift
//  curby
//
//  Core constants for the Curby map experience.
//

import CoreLocation
import Foundation

/// Centralised constants for camera, motion, and UI behaviour.
enum CurbyConstants {

    // MARK: - Default Location (Fallback when permissions denied)

    /// Geographic center of the US — used when location is unavailable.
    static let defaultCoordinate = CLLocationCoordinate2D(
        latitude: 39.8283,
        longitude: -98.5795
    )
    static let defaultFallbackZoom: Double = 4.0
    static let austinSouthwest = CLLocationCoordinate2D(latitude: 30.05, longitude: -98.10)
    static let austinNortheast = CLLocationCoordinate2D(latitude: 30.55, longitude: -97.40)

    // MARK: - Zoom Levels

    static let zoomMin: Double = 3.0
    static let zoomDefault: Double = 15.0
    static let zoomMax: Double = 20.0

    /// Zoom levels mapped to speed ranges (m/s).
    static let zoomStationary: Double = 17.0
    static let zoomWalking: Double = 16.0
    static let zoomCityDriving: Double = 15.0
    static let zoomHighway: Double = 13.5
    static let zoomHighSpeed: Double = 12.0

    // MARK: - Pitch

    static let pitchFlat: Double = 0.0
    static let pitchTilted: Double = 45.0

    // MARK: - Speed Thresholds (m/s)

    /// Below this speed, user is considered stationary.
    static let speedStationary: Double = 0.5
    /// Below this speed (but above stationary), user is walking.
    static let speedWalking: Double = 2.5
    /// City driving upper bound.
    static let speedCityDriving: Double = 15.0
    /// Highway driving upper bound.
    static let speedHighway: Double = 30.0

    // MARK: - Motion State Hysteresis

    /// Minimum duration (seconds) a speed must sustain before state transitions.
    static let motionHysteresisInterval: TimeInterval = 2.0

    // MARK: - Animation Durations

    static let cameraTransitionDuration: TimeInterval = 1.5
    static let recenterAnimationDuration: TimeInterval = 0.35
    static let uiFadeAnimationDuration: TimeInterval = 0.25

    // MARK: - UI

    static let overlayButtonSize: CGFloat = 48.0
    static let overlayCornerRadius: CGFloat = 14.0
    static let overlayPadding: CGFloat = 16.0

    // MARK: - Onboarding

    /// Default walking circumference in miles.
    static let walkingCircumferenceDefault: Double = 0.25
    static let walkingCircumferenceMin: Double = 0.1
    static let walkingCircumferenceMax: Double = 1.0
    static let walkingCircumferenceStep: Double = 0.05

    // MARK: - Heat Zones

    /// Busy activity thresholds (0–100 scale). Tuned so light traffic does not read as “all red”.
    static let busyScoreOpen: Int = 48
    static let busyScoreBusy: Int = 78
    /// Scores at or above `busyScoreBusy` are “Very Busy”.

    /// Heat zone circle radius on map (metres).
    static let heatZoneRadiusDefault: Double = 200.0

    /// Sheet action: widen destination parking search by this many miles when no POIs are found.
    static let parkingSearchRadiusExpandStepMiles: Double = 0.25

    // MARK: - Search

    static let maxRecentDestinations: Int = 10
    /// Slightly relaxed for OSM Nominatim (public instance etiquette).
    static let searchDebounceInterval: TimeInterval = 0.45

    /// Nominatim `viewbox`: southwest lon, southwest lat, northeast lon, northeast lat.
    static var nominatimViewboxParameter: String {
        "\(austinSouthwest.longitude),\(austinSouthwest.latitude),\(austinNortheast.longitude),\(austinNortheast.latitude)"
    }

    /// Required by Nominatim — identifies the app (see https://operations.osmfoundation.org/policies/nominatim/).
    static var nominatimUserAgent: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.hackmsa.curby"
        return "Curby-iOS/1.0 (\(bundle); parking-search)"
    }
    static let apiBaseURL = "https://curby-api.mohammad-rashid7337.workers.dev"
    static let metersPerMile: Double = 1_609.344
    static let parkingGeofenceToleranceMeters: Double = 25.0

    static var austinBoundingBoxParameter: String {
        "\(austinSouthwest.longitude),\(austinSouthwest.latitude),\(austinNortheast.longitude),\(austinNortheast.latitude)"
    }

    static func isWithinAustinArea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= austinSouthwest.latitude &&
            coordinate.latitude <= austinNortheast.latitude &&
            coordinate.longitude >= austinSouthwest.longitude &&
            coordinate.longitude <= austinNortheast.longitude
    }

    // MARK: - Parking Geometry Detail

    /// At and above this zoom, parking zones start resolving into street-level geometry.
    static let parkingStreetDetailZoom: Double = 15.0

    /// At and above this zoom, parking zones start resolving into structure/building geometry.
    static let parkingStructureDetailZoom: Double = 16.4

    /// Heat zone badges stay visible below this zoom, then yield to finer geometry.
    static let parkingBadgeCutoffZoom: Double = 15.2

    /// Maximum distance allowed when snapping a mock street parking segment to a mapped road.
    static let parkingRoadSnapDistanceMeters: Double = 65.0

    /// Visual corridor width for curbside parking rendered from a street centerline.
    static let parkingStreetCorridorWidthMeters: Double = 6.5

    /// Visual corridor width for metered parking rendered from a street centerline.
    static let parkingMeteredCorridorWidthMeters: Double = 5.0

    /// Maximum distance allowed when snapping a garage or lot to a mapped building footprint.
    static let parkingStructureSnapDistanceMeters: Double = 90.0
}
