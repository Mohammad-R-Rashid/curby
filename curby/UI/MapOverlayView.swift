//
//  MapOverlayView.swift
//  curby
//
//  Non-intrusive overlay UI above the map.
//

import SwiftUI
import CoreLocation

/// Overlay controls rendered above the map surface.
///
/// Positioned to avoid blocking map content:
/// - Top-right: compass indicator
/// - Bottom-right: recenter button (only in free-explore mode)
/// - Bottom-left: GPS accuracy / status indicator
struct MapOverlayView: View {

    let cameraController: CameraController
    let locationService: LocationService
    let motionStateManager: MotionStateManager

    @Environment(\.colorScheme) private var colorScheme

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
            statusIndicator
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
            Circle()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

            Circle()
                .strokeBorder(
                    Color.white.opacity(0.15),
                    lineWidth: 0.5
                )

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
        .opacity(headingNearNorth(heading) ? 0.3 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: headingNearNorth(heading))
        .accessibilityLabel("Compass, heading \(Int(heading)) degrees")
        .accessibilityIdentifier("compass_indicator")
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            // GPS signal dot
            Circle()
                .fill(gpsStatusColor)
                .frame(width: 8, height: 8)

            Text(gpsStatusText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityIdentifier("gps_status_indicator")
    }

    // MARK: - Computed Properties

    private var gpsStatusColor: Color {
        if !locationService.hasInitialFix {
            return .orange
        }
        switch locationService.horizontalAccuracy {
        case ..<10:
            return .green
        case 10 ..< 30:
            return .yellow
        default:
            return .orange
        }
    }

    private var gpsStatusText: String {
        if !locationService.hasInitialFix {
            return "Locating…"
        }
        switch locationService.horizontalAccuracy {
        case ..<10:
            return "GPS Strong"
        case 10 ..< 30:
            return "GPS Fair"
        default:
            return "GPS Weak"
        }
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
