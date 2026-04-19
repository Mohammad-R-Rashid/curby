//
//  ExpandedMapView.swift
//  curby
//
//  Full-screen map with all heat zones visible.
//

import MapboxMaps
import SwiftUI

/// Full-screen map showing all heat zones in the area.
///
/// Used when the user taps "Expand View" from the search screen,
/// or when navigating to a destination with heat zones.
struct ExpandedMapView: View {

    let destination: SelectedDestination?
    @Bindable var cameraController: CameraController
    let locationService: LocationService
    let motionStateManager: MotionStateManager
    let heatZoneManager: HeatZoneManager
    let onZoneSelected: (HeatZone) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // MARK: - Map
            mapLayer
                .ignoresSafeArea()

                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            cameraController.userDidInteract()
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { _ in
                            cameraController.userDidInteract()
                        }
                )

            // MARK: - Heat Zone Overlay
            HeatZoneOverlay(
                zones: heatZoneManager.heatZones,
                onZoneTapped: onZoneSelected,
                isLoading: heatZoneManager.isLoading
            )

            // MARK: - Top Controls
            VStack {
                HStack {
                    // Back button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CurbyGlass.primaryTint)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .overlay {
                                Circle()
                                    .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
                            }
                    }

                    Spacer()

                    // Compass
                    MapOverlayView(
                        cameraController: cameraController,
                        locationService: locationService,
                        motionStateManager: motionStateManager
                    )
                    .frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // MARK: - Bottom Bar
                bottomBar
            }

            // MARK: - Zone List (Tappable zones)
            if !heatZoneManager.heatZones.isEmpty {
                VStack {
                    Spacer()

                    zoneCarousel
                        .padding(.bottom, 100)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            if let dest = destination {
                heatZoneManager.loadZones(
                    around: dest.coordinate,
                    destinationName: dest.name
                )
            }
        }
    }

    // MARK: - Map Layer

    @ViewBuilder
    private var mapLayer: some View {
        Map(viewport: $cameraController.viewport) {
            Puck2D(bearing: .heading)
        }
        .mapStyle(colorScheme == .dark ? .dark : .standard)
        .ornamentOptions(OrnamentOptions(compass: CompassViewOptions(visibility: .hidden)))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        Group {
            if let dest = destination {
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 14))
                        .foregroundStyle(CurbyGlass.destinationTint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dest.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(dest.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("END")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CurbyGlass.destinationTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(CurbyGlass.destinationTint.opacity(0.15))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .curbyGlassSurface(
                    tint: CurbyGlass.destinationTint,
                    cornerRadius: CurbyGlass.compactCornerRadius
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Zone Carousel

    private var zoneCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(heatZoneManager.heatZones) { zone in
                    Button {
                        onZoneSelected(zone)
                    } label: {
                        zoneCard(zone)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func zoneCard(_ zone: HeatZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(zone.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(zone.busyLevel.label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(busyColor(zone.busyLevel))
                    )
            }

            HStack(spacing: 4) {
                Text("Score: \(zone.busyScore)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(busyColor(zone.busyLevel))

                Spacer()

                Text("\(zone.parkingSpots.count) spots")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 180)
        .padding(12)
        .curbyGlassSurface(
            tint: busyColor(zone.busyLevel),
            cornerRadius: CurbyGlass.compactCornerRadius
        )
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }

    private func busyColor(_ level: BusyLevel) -> Color {
        switch level {
        case .open: return Color(red: 0.30, green: 0.78, blue: 0.40)
        case .busy: return Color(red: 1.0, green: 0.70, blue: 0.20)
        case .veryBusy: return Color(red: 1.0, green: 0.35, blue: 0.30)
        }
    }
}
