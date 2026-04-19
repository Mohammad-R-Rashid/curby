//
//  HeatZoneOverlay.swift
//  curby
//
//  Renders heat zone circles and badges on the map.
//

import CoreLocation
import MapboxMaps
import SwiftUI

/// Overlay above the map showing heat zone indicators.
///
/// Displays the zone badges (B/VB) as tappable elements.
/// The actual map circle overlays would be rendered via Mapbox annotations —
/// this view provides the SwiftUI badge layer.
struct HeatZoneOverlay: View {

    let zones: [HeatZone]
    let onZoneTapped: (HeatZone) -> Void
    let isLoading: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if isLoading {
                loadingIndicator
            }

            // Legend in top-left
            if !zones.isEmpty {
                VStack {
                    legendView
                    Spacer()
                }
                .padding(.top, 60)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Loading

    private var loadingIndicator: some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)

                Text("Loading parking zones…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)

            Spacer()
        }
    }

    // MARK: - Legend

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: Color(red: 0.30, green: 0.78, blue: 0.40), label: "Open")
            legendRow(color: Color(red: 1.0, green: 0.70, blue: 0.20), label: "Busy")
            legendRow(color: Color(red: 1.0, green: 0.35, blue: 0.30), label: "Very Busy")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A badge shown on the map for a specific heat zone.
struct HeatZoneBadge: View {
    let zone: HeatZone

    var body: some View {
        VStack(spacing: 0) {
            Text(zone.busyLevel.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .curbyGlassSurface(tint: tint, cornerRadius: 20)
                .shadow(color: tint.opacity(0.28), radius: 8, y: 3)

            Canvas { ctx, size in
                var path = Path()
                path.move(to: CGPoint(x: size.width / 2, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: 0))
                path.closeSubpath()
                ctx.fill(path, with: .color(tint.opacity(0.45)))
            }
            .frame(width: 9, height: 6)
            .offset(y: -1)
        }
    }

    private var tint: Color {
        HeatZoneGeometry.color(for: zone.busyLevel)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()

        HeatZoneOverlay(
            zones: [
                HeatZone(id: UUID(), name: "Test Zone", coordinate: .init(latitude: 30.0, longitude: -97.0), radius: 200, busyScore: 75, parkingSpots: [], boundaryCoords: [])
            ],
            onZoneTapped: { _ in },
            isLoading: false
        )
    }
}
