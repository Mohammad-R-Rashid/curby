//
//  MotionStateManager.swift
//  curby
//
//  Classifies user motion state from speed with hysteresis.
//

import Foundation
import Observation

// MARK: - Motion State

/// User's inferred motion state based on GPS speed.
enum MotionState: String, CustomStringConvertible {
    case stationary
    case walking
    case driving

    var description: String { rawValue.capitalized }
}

// MARK: - Motion State Manager

/// Observes speed from LocationService and classifies motion state.
///
/// Applies temporal hysteresis to prevent rapid flickering between states
/// (e.g., stopping at a traffic light shouldn't instantly flip to "stationary").
@Observable
final class MotionStateManager {

    // MARK: - Published State

    /// Current classified motion state.
    private(set) var motionState: MotionState = .stationary

    /// True when driving — UI should reduce animation intensity.
    var shouldReduceAnimations: Bool {
        motionState == .driving
    }

    /// True when driving — zoom should be stabilised (less responsive to micro speed changes).
    var shouldStabilizeZoom: Bool {
        motionState == .driving
    }

    // MARK: - Private

    private var candidateState: MotionState = .stationary
    private var candidateTimestamp: Date = .now
    private let locationService: LocationService

    // MARK: - Init

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    // MARK: - Update

    /// Call this on each location update to re-evaluate motion state.
    func update() {
        let speed = locationService.currentSpeed
        let rawState = Self.classify(speed: speed)

        if rawState == motionState {
            // Already in this state — reset candidate
            candidateState = rawState
            candidateTimestamp = .now
            return
        }

        if rawState == candidateState {
            // Candidate sustained — check duration
            let elapsed = Date.now.timeIntervalSince(candidateTimestamp)
            if elapsed >= CurbyConstants.motionHysteresisInterval {
                motionState = rawState
            }
        } else {
            // New candidate — start timer
            candidateState = rawState
            candidateTimestamp = .now
        }
    }

    // MARK: - Classification

    /// Instant classification without hysteresis (internal).
    private static func classify(speed: Double) -> MotionState {
        switch speed {
        case ..<CurbyConstants.speedStationary:
            return .stationary
        case CurbyConstants.speedStationary ..< CurbyConstants.speedWalking:
            return .walking
        default:
            return .driving
        }
    }
}
