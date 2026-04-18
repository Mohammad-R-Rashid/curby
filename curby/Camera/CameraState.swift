//
//  CameraState.swift
//  curby
//
//  Camera state model and dynamic configuration.
//

import Foundation

// MARK: - Camera Mode

/// The two top-level camera modes.
enum CameraMode: Equatable, CustomStringConvertible {
    /// Camera tracks the user's location with heading-based rotation.
    case follow
    /// User has manually panned/zoomed — camera is user-controlled.
    case freeExplore

    var description: String {
        switch self {
        case .follow: return "Follow"
        case .freeExplore: return "Free Explore"
        }
    }
}

// MARK: - Camera Configuration

/// Computes dynamic camera parameters from the current speed.
struct CameraConfig {

    /// Smoothly interpolated zoom level based on speed (m/s).
    static func zoom(forSpeed speed: Double) -> Double {
        let clampedSpeed = max(0, speed)

        switch clampedSpeed {
        case 0 ..< CurbyConstants.speedStationary:
            return CurbyConstants.zoomStationary

        case CurbyConstants.speedStationary ..< CurbyConstants.speedWalking:
            // Interpolate between stationary and walking zoom
            let t = (clampedSpeed - CurbyConstants.speedStationary)
                / (CurbyConstants.speedWalking - CurbyConstants.speedStationary)
            return lerp(from: CurbyConstants.zoomStationary,
                        to: CurbyConstants.zoomWalking,
                        t: t)

        case CurbyConstants.speedWalking ..< CurbyConstants.speedCityDriving:
            let t = (clampedSpeed - CurbyConstants.speedWalking)
                / (CurbyConstants.speedCityDriving - CurbyConstants.speedWalking)
            return lerp(from: CurbyConstants.zoomWalking,
                        to: CurbyConstants.zoomCityDriving,
                        t: t)

        case CurbyConstants.speedCityDriving ..< CurbyConstants.speedHighway:
            let t = (clampedSpeed - CurbyConstants.speedCityDriving)
                / (CurbyConstants.speedHighway - CurbyConstants.speedCityDriving)
            return lerp(from: CurbyConstants.zoomCityDriving,
                        to: CurbyConstants.zoomHighway,
                        t: t)

        default:
            // Above highway speed — clamp at high-speed zoom
            let t = min(1.0, (clampedSpeed - CurbyConstants.speedHighway) / 20.0)
            return lerp(from: CurbyConstants.zoomHighway,
                        to: CurbyConstants.zoomHighSpeed,
                        t: t)
        }
    }

    /// Dynamic pitch: tilts forward when moving, flat when stationary.
    static func pitch(forSpeed speed: Double) -> Double {
        if speed < CurbyConstants.speedStationary {
            return CurbyConstants.pitchFlat
        }
        // Ease into tilted pitch as speed increases
        let t = min(1.0, speed / CurbyConstants.speedWalking)
        return lerp(from: CurbyConstants.pitchFlat,
                    to: CurbyConstants.pitchTilted,
                    t: t)
    }

    // MARK: - Private

    /// Simple linear interpolation.
    private static func lerp(from a: Double, to b: Double, t: Double) -> Double {
        return a + (b - a) * clamp(t, min: 0, max: 1)
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.min(Swift.max(value, min), max)
    }
}
