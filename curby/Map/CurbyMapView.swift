//
//  CurbyMapView.swift
//  curby
//
//  Main Mapbox map wrapper — the core of the app.
//

import MapboxMaps
import SwiftUI

/// The primary map view wrapping Mapbox's `Map` with the Curby camera system.
///
/// Responsibilities:
/// - Renders the Mapbox map with dark/light mode support
/// - Displays the user's location puck with heading
/// - Detects user gestures to trigger follow → freeExplore transitions
/// - Overlays the control UI (recenter, compass, status)
struct CurbyMapView: View {

    @Bindable var cameraController: CameraController
    let locationService: LocationService
    let motionStateManager: MotionStateManager

    @Environment(\.colorScheme) private var colorScheme

    /// Tracks whether we've done the initial setup.
    @State private var hasSetInitialViewport = false

    var body: some View {
        ZStack {
            // MARK: - Map

            mapLayer
                .ignoresSafeArea()

                // Detect user drag (pan) gestures to exit follow mode.
                // Uses .simultaneousGesture so it doesn't steal from the map's
                // internal UIPanGestureRecognizer — both fire in parallel.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            cameraController.userDidInteract()
                        }
                )

                // Detect pinch-to-zoom gestures
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { _ in
                            cameraController.userDidInteract()
                        }
                )

                // Detect rotation gestures
                .simultaneousGesture(
                    RotateGesture()
                        .onChanged { _ in
                            cameraController.userDidInteract()
                        }
                )

            // MARK: - Overlay UI

            MapOverlayView(
                cameraController: cameraController,
                locationService: locationService,
                motionStateManager: motionStateManager
            )
        }
        .animation(
            .easeInOut(duration: CurbyConstants.uiFadeAnimationDuration),
            value: cameraController.showRecenterButton
        )
        .onAppear {
            setupInitialViewport()
        }
        .onChange(of: locationService.currentSpeed) { _, _ in
            cameraController.updateForCurrentSpeed()
        }
        .onChange(of: locationService.authorizationStatus) { _, newStatus in
            handleAuthorizationChange(newStatus)
        }
    }

    // MARK: - Map Layer

    @ViewBuilder
    private var mapLayer: some View {
        Map(viewport: $cameraController.viewport) {
            // Location puck with heading arrow when moving
            Puck2D(bearing: .heading)
        }
        .mapStyle(colorScheme == .dark ? .dark : .standard)
    }

    // MARK: - Setup

    private func setupInitialViewport() {
        guard !hasSetInitialViewport else { return }

        let status = locationService.authorizationStatus
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)

        if granted {
            cameraController.setInitialViewport(locationGranted: true)
            hasSetInitialViewport = true
        } else if status == .notDetermined {
            // Request permission — will handle in onChange
            locationService.requestPermission()
        } else {
            // Denied or restricted — use fallback
            cameraController.setInitialViewport(locationGranted: false)
            hasSetInitialViewport = true
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        guard !hasSetInitialViewport else { return }

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            cameraController.setInitialViewport(locationGranted: true)
            hasSetInitialViewport = true
        case .denied, .restricted:
            cameraController.setInitialViewport(locationGranted: false)
            hasSetInitialViewport = true
        default:
            break
        }
    }
}
