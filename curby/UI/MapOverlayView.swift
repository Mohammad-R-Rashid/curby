//
//  MapOverlayView.swift
//  curby
//
//  Non-intrusive overlay UI above the map.
//

import CoreLocation
import SwiftUI

/// Overlay controls rendered above the map surface.
///
/// Positioned to avoid blocking map content:
/// - Top-right: compass indicator
/// - Bottom-right: recenter button (only in free-explore mode)
struct MapOverlayView: View {

    let cameraController: CameraController
    let locationService: LocationService
    let motionStateManager: MotionStateManager

    var body: some View {
        VStack {
            // MARK: - Top Bar
            topBar

            Spacer()

            // MARK: - Bottom Bar
            bottomBar
        }
        .padding(CurbyConstants.overlayPadding)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Spacer()
            compassIndicator
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            Spacer()

            if cameraController.showRecenterButton {
                RecenterButton {
                    cameraController.recenter()
                }
            }
        }
    }

    // MARK: - Compass Indicator

    private var compassIndicator: some View {
        let heading = locationService.currentHeading?.magneticHeading ?? 0

        return ZStack {
            VStack(spacing: 0) {
                // North indicator triangle
                Triangle()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 6, height: 8)

                Triangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 6, height: 8)
                    .rotationEffect(.degrees(180))
            }
            .rotationEffect(.degrees(-heading))
        }
        .frame(width: 36, height: 36)
        .glassEffect(.regular, in: .circle)
        .overlay {
            Circle()
                .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
        }
        .opacity(headingNearNorth(heading) ? 0.3 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: headingNearNorth(heading))
        .accessibilityLabel("Compass, heading \(Int(heading)) degrees")
        .accessibilityIdentifier("compass_indicator")
    }

    private func headingNearNorth(_ heading: Double) -> Bool {
        heading < 15 || heading > 345
    }
}

// MARK: - Triangle Shape

/// A simple triangle shape for the compass needle.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
