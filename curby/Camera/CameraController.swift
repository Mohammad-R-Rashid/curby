//
//  CameraController.swift
//  curby
//
//  Central camera logic — manages viewport state and mode transitions.
//

import Foundation
import MapboxMaps
import Observation
import SwiftUI

/// Manages the map camera's viewport, mode transitions, and speed-reactive parameters.
///
/// The controller owns the `Viewport` binding that drives the Mapbox `Map` view.
/// It reacts to speed changes from `MotionStateManager` and gesture-driven mode
/// switches to produce the correct viewport configuration at all times.
@Observable
final class CameraController {

    // MARK: - Published State

    /// The current viewport — bound to the Map view.
    var viewport: Viewport = .idle

    /// The current camera mode.
    private(set) var mode: CameraMode = .follow

    /// Whether the recenter button should be visible.
    var showRecenterButton: Bool {
        mode == .freeExplore
    }

    // MARK: - Dependencies

    private let locationService: LocationService
    private let motionStateManager: MotionStateManager

    /// Tracks the last zoom/pitch to avoid redundant updates.
    private var lastAppliedZoom: Double = CurbyConstants.zoomDefault
    private var lastAppliedPitch: Double = CurbyConstants.pitchFlat

    // MARK: - Init

    init(locationService: LocationService, motionStateManager: MotionStateManager) {
        self.locationService = locationService
        self.motionStateManager = motionStateManager
    }

    // MARK: - Public API

    /// Call on each location update to adjust camera for current speed.
    func updateForCurrentSpeed() {
        // Update motion state
        motionStateManager.update()

        guard mode == .follow else { return }

        let speed = locationService.currentSpeed
        let targetZoom = CameraConfig.zoom(forSpeed: speed)
        let targetPitch = CameraConfig.pitch(forSpeed: speed)

        // Skip if changes are negligible (prevents animation churn)
        let zoomDelta = abs(targetZoom - lastAppliedZoom)
        let pitchDelta = abs(targetPitch - lastAppliedPitch)

        // When driving, apply a higher threshold to stabilise the view
        let threshold: Double = motionStateManager.shouldStabilizeZoom ? 0.5 : 0.15

        guard zoomDelta > threshold || pitchDelta > 3.0 else { return }

        lastAppliedZoom = targetZoom
        lastAppliedPitch = targetPitch

        withViewportAnimation(.default(maxDuration: CurbyConstants.cameraTransitionDuration)) {
            viewport = .followPuck(
                zoom: targetZoom,
                bearing: .heading,
                pitch: targetPitch
            )
        }
    }

    /// Called when the user interacts with the map (pan, pinch, rotate).
    /// Transitions the camera from follow mode into free-explore mode.
    func userDidInteract() {
        guard mode == .follow else { return }
        mode = .freeExplore
        // Don't change the viewport — let the user's gesture control it.
        // The Mapbox Map will automatically enter an idle viewport state.
    }

    /// Called when the recenter button is tapped.
    /// Smoothly transitions back to follow mode.
    func recenter() {
        mode = .follow

        let speed = locationService.currentSpeed
        let targetZoom = CameraConfig.zoom(forSpeed: speed)
        let targetPitch = CameraConfig.pitch(forSpeed: speed)

        lastAppliedZoom = targetZoom
        lastAppliedPitch = targetPitch

        withViewportAnimation(.default(maxDuration: CurbyConstants.cameraTransitionDuration)) {
            viewport = .followPuck(
                zoom: targetZoom,
                bearing: .heading,
                pitch: targetPitch
            )
        }
    }

    /// Sets the initial viewport when the app launches.
    /// Uses follow-puck if location is available, otherwise falls back to a default view.
    func setInitialViewport(locationGranted: Bool) {
        if locationGranted {
            mode = .follow
            withViewportAnimation(.default(maxDuration: CurbyConstants.cameraTransitionDuration)) {
                viewport = .followPuck(
                    zoom: CurbyConstants.zoomDefault,
                    bearing: .heading,
                    pitch: CurbyConstants.pitchFlat
                )
            }
        } else {
            mode = .freeExplore
            viewport = .camera(
                center: CurbyConstants.defaultCoordinate,
                zoom: CurbyConstants.defaultFallbackZoom
            )
        }
    }

    /// Navigate the map to show a specific destination coordinate.
    func navigateToDestination(_ coordinate: CLLocationCoordinate2D, zoom: Double = CurbyConstants.zoomDefault) {
        mode = .freeExplore

        withViewportAnimation(.default(maxDuration: CurbyConstants.cameraTransitionDuration)) {
            viewport = .camera(
                center: coordinate,
                zoom: zoom,
                bearing: 0,
                pitch: CurbyConstants.pitchTilted
            )
        }
    }
}

