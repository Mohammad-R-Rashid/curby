//
//  MainNavigationView.swift
//  curby
//
//  Apple Maps-style root view: full-screen map + draggable bottom sheet.
//

import MapboxMaps
import MapKit
import SwiftUI

/// Root container post-onboarding.
///
/// Full-screen Mapbox map with block-shaped heat zone overlays,
/// parking markers on zone selection, and an always-visible
/// draggable bottom sheet (Apple Maps style).
struct MainNavigationView: View {

    // MARK: - Dependencies

    @State private var locationService = LocationService()
    @State private var motionStateManager: MotionStateManager
    @State private var cameraController: CameraController
    @State private var heatZoneManager = HeatZoneManager()
    @State private var searchState = SearchState()

    // MARK: - Sheet State

    @State private var sheetDetent: PresentationDetent = .fraction(0.30)
    @State private var selectedZone: HeatZone?
    @State private var hasSetInitialViewport = false

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Init

    init() {
        let location = LocationService()
        let motion = MotionStateManager(locationService: location)
        let camera = CameraController(locationService: location, motionStateManager: motion)

        _locationService = State(initialValue: location)
        _motionStateManager = State(initialValue: motion)
        _cameraController = State(initialValue: camera)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // MARK: Full-screen map with overlays
            mapView
                .ignoresSafeArea()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in cameraController.userDidInteract() }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { _ in cameraController.userDidInteract() }
                )
                .simultaneousGesture(
                    RotateGesture()
                        .onChanged { _ in cameraController.userDidInteract() }
                )

            // MARK: Map overlay controls
            overlayControls
        }
        .sheet(isPresented: .constant(true)) {
            sheetContent
                .presentationDetents(
                    [.fraction(0.25), .medium, .large],
                    selection: $sheetDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationCornerRadius(24)
                .interactiveDismissDisabled()
        }
        .onAppear {
            locationService.requestPermission()
            setupInitialViewport()
            searchState.userLocation = locationService.currentLocation?.coordinate
        }
        .onChange(of: locationService.authorizationStatus) { _, newStatus in
            handleAuthorizationChange(newStatus)
        }
        .onChange(of: locationService.currentSpeed) { _, _ in
            cameraController.updateForCurrentSpeed()
        }
        .onChange(of: locationService.currentLocation) { _, newLoc in
            searchState.userLocation = newLoc?.coordinate
        }
        .animation(
            .easeInOut(duration: CurbyConstants.uiFadeAnimationDuration),
            value: cameraController.showRecenterButton
        )
    }

    // MARK: - Map View

    @ViewBuilder
    private var mapView: some View {
        Map(viewport: $cameraController.viewport) {
            // User location puck
            Puck2D(bearing: .heading)

            // Heat zone block-shaped polygons
            if !heatZoneManager.heatZones.isEmpty {
                PolygonAnnotationGroup(heatZoneManager.heatZones) { zone in
                    PolygonAnnotation(
                        polygon: HeatZoneGeometry.polygon(from: zone.boundaryCoords)
                    )
                    .fillColor(StyleColor(
                        HeatZoneGeometry.uiColor(for: zone.busyLevel)
                    ))
                    .fillOpacity(
                        zone.id == selectedZone?.id
                            ? (colorScheme == .dark ? 0.50 : 0.35)
                            : (colorScheme == .dark ? 0.35 : 0.20)
                    )
                    .fillOutlineColor(StyleColor(
                        HeatZoneGeometry.uiColor(for: zone.busyLevel)
                    ))
                }

                // Heat zone badges (B / VB labels)
                ForEvery(heatZoneManager.heatZones) { zone in
                    MapViewAnnotation(coordinate: zone.coordinate) {
                        HeatZoneBadge(zone: zone)
                            .onTapGesture {
                                selectZone(zone)
                            }
                    }
                    .allowOverlap(true)
                }
            }

            // Parking spot markers (shown when a zone is selected)
            if let zone = selectedZone {
                ForEvery(zone.parkingSpots) { spot in
                    MapViewAnnotation(coordinate: spot.coordinate) {
                        ParkingSpotMarker(spot: spot)
                    }
                    .allowOverlap(false)
                }
            }

            // Destination pin
            if let dest = searchState.selectedDestination {
                MapViewAnnotation(coordinate: dest.coordinate) {
                    DestinationPin()
                }
                .allowOverlap(true)
            }
        }
        .mapStyle(.standard(lightPreset: colorScheme == .dark ? .dusk : .day))
    }

    // MARK: - Zone Selection

    private func selectZone(_ zone: HeatZone) {
        withAnimation(.spring(response: 0.3)) {
            selectedZone = zone
            sheetDetent = .medium
        }
        cameraController.navigateToDestination(zone.coordinate, zoom: 17.0)
    }

    // MARK: - Overlay Controls (Liquid Glass)

    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()
                compassIndicator
            }
            .padding(.horizontal, CurbyConstants.overlayPadding)
            .padding(.top, 8)

            Spacer()

            HStack(alignment: .bottom) {
                gpsStatusIndicator

                Spacer()

                if cameraController.showRecenterButton {
                    recenterButton
                }
            }
            .padding(.horizontal, CurbyConstants.overlayPadding)
            .padding(.bottom, 280)
        }
    }

    // MARK: - Compass (Liquid Glass)

    private var compassIndicator: some View {
        let heading = locationService.currentHeading?.magneticHeading ?? 0

        return VStack(spacing: 0) {
            Triangle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 6, height: 8)

            Triangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 8)
                .rotationEffect(.degrees(180))
        }
        .rotationEffect(.degrees(-heading))
        .frame(width: 36, height: 36)
        .glassEffect(.regular, in: .circle)
        .opacity(heading < 15 || heading > 345 ? 0.3 : 1.0)
    }

    // MARK: - GPS Status (Liquid Glass)

    private var gpsStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(gpsColor)
                .frame(width: 8, height: 8)

            Text(gpsText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Recenter (Liquid Glass)

    private var recenterButton: some View {
        Button {
            cameraController.recenter()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.70, blue: 1.0))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private var gpsColor: Color {
        if !locationService.hasInitialFix { return .orange }
        switch locationService.horizontalAccuracy {
        case ..<10: return .green
        case 10..<30: return .yellow
        default: return .orange
        }
    }

    private var gpsText: String {
        if !locationService.hasInitialFix { return "Locating…" }
        switch locationService.horizontalAccuracy {
        case ..<10: return "GPS Strong"
        case 10..<30: return "GPS Fair"
        default: return "GPS Weak"
        }
    }

    // MARK: - Sheet Content (Contextual)

    @ViewBuilder
    private var sheetContent: some View {
        if let zone = selectedZone {
            // ZONE DETAIL MODE
            VStack(spacing: 0) {
                // Back bar
                HStack {
                    Button {
                        withAnimation {
                            selectedZone = nil
                            if let dest = searchState.selectedDestination {
                                cameraController.navigateToDestination(dest.coordinate)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Zones")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Color(red: 0.30, green: 0.70, blue: 1.0))
                    }

                    Spacer()

                    // Navigate button in detail
                    if let dest = searchState.selectedDestination {
                        Button {
                            openInMaps(coordinate: dest.coordinate, name: dest.name)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 12))
                                Text("Navigate")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                HeatZoneDetailView(
                    zone: zone,
                    destinationName: searchState.selectedDestination?.name ?? "Destination"
                )
            }
        } else {
            // SEARCH / DESTINATION MODE
            SearchView(
                searchState: searchState,
                heatZoneManager: heatZoneManager,
                onDestinationSelected: { dest in
                    heatZoneManager.loadZones(
                        around: dest.coordinate,
                        destinationName: dest.name
                    )
                    cameraController.navigateToDestination(dest.coordinate)
                    sheetDetent = .fraction(0.25)
                },
                onZoneSelected: { zone in
                    selectZone(zone)
                },
                onClearDestination: {
                    heatZoneManager.clearZones()
                    selectedZone = nil
                    cameraController.recenter()
                    sheetDetent = .fraction(0.30)
                }
            )
        }
    }

    // MARK: - Open in Maps

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    // MARK: - Camera Setup

    private func setupInitialViewport() {
        guard !hasSetInitialViewport else { return }

        let status = locationService.authorizationStatus
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)

        if granted {
            cameraController.setInitialViewport(locationGranted: true)
            hasSetInitialViewport = true
        } else if status == .notDetermined {
            locationService.requestPermission()
        } else {
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

// MARK: - Parking Spot Marker

/// A small marker shown on the map for individual parking spots.
struct ParkingSpotMarker: View {
    let spot: ParkingSpot

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: spot.type.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(markerColor, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: markerColor.opacity(0.4), radius: 3, y: 2)

            Triangle()
                .fill(markerColor)
                .frame(width: 8, height: 5)
                .rotationEffect(.degrees(180))
        }
    }

    private var markerColor: Color {
        switch spot.type {
        case .garage: return Color(red: 0.25, green: 0.45, blue: 0.85)
        case .lot: return Color(red: 0.40, green: 0.70, blue: 0.35)
        case .streetCurbside: return Color(red: 0.50, green: 0.50, blue: 0.55)
        case .metered: return Color(red: 0.80, green: 0.60, blue: 0.20)
        }
    }
}

// MARK: - Destination Pin

/// Red flag pin marking the user's final destination.
struct DestinationPin: View {
    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 30, height: 30)
                    .shadow(color: .red.opacity(0.4), radius: 4, y: 2)

                Image(systemName: "flag.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            Triangle()
                .fill(Color.red)
                .frame(width: 8, height: 5)
                .rotationEffect(.degrees(180))
        }
    }
}

// MARK: - Preview

#Preview {
    MainNavigationView()
}
