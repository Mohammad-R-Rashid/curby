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

    /// Busy score thresholds.
    static let busyScoreOpen: Int = 40
    static let busyScoreBusy: Int = 70
    /// Above busyScoreBusy is "Very Busy".

    /// Heat zone circle radius on map (metres).
    static let heatZoneRadiusDefault: Double = 200.0

    // MARK: - Search

    static let maxRecentDestinations: Int = 10
    static let searchDebounceInterval: TimeInterval = 0.3
}
