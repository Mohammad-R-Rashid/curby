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
    @State private var currentMapZoom = CurbyConstants.zoomDefault
    @State private var selectedBuilding: StandardBuildingsFeature?
    @State private var hasLoadedMap = false
    @State private var isParkingRoadQueryInFlight = false

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
                    [.fraction(0.25), .fraction(0.30), .medium, .large],
                    selection: $sheetDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationCornerRadius(24)
                .interactiveDismissDisabled()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .ignoresSafeArea(edges: .bottom)
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
        MapReader { proxy in
            Map(viewport: $cameraController.viewport) {
                // User location puck
                Puck2D(bearing: .heading)

                if !heatZoneManager.heatZones.isEmpty {
                    ParkingZoneMapStyleContent(
                        zones: heatZoneManager.heatZones,
                        selectedZoneID: selectedZone?.id,
                        zoom: currentMapZoom
                    )

                    if currentMapZoom < CurbyConstants.parkingBadgeCutoffZoom {
                        // Zone badges remain at overview zooms, then yield to street/building geometry.
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
                }

                if currentMapZoom >= CurbyConstants.parkingStructureDetailZoom,
                   let selectedBuilding
                {
                    FeatureState(selectedBuilding, .init(select: true))
                }

                if currentMapZoom >= CurbyConstants.parkingStructureDetailZoom {
                    TapInteraction(.standardBuildings) { building, _ in
                        selectedBuilding = building
                        return true
                    }
                }

                TapInteraction(.layer(ParkingZoneLayerIDs.overviewHitLayer), radius: 8) { feature, _ in
                    selectZoneForSurfaceFeature(feature)
                    return true
                }

                TapInteraction(.layer(ParkingZoneLayerIDs.streetHitLayer), radius: 8) { feature, _ in
                    selectZoneForSurfaceFeature(feature)
                    return true
                }

                TapInteraction(.layer(ParkingZoneLayerIDs.garageHitLayer), radius: 8) { feature, _ in
                    selectZoneForSurfaceFeature(feature)
                    return false
                }

                TapInteraction(.layer(ParkingZoneLayerIDs.lotHitLayer), radius: 8) { feature, _ in
                    selectZoneForSurfaceFeature(feature)
                    return false
                }

                TapInteraction { _ in
                    if currentMapZoom >= CurbyConstants.parkingStructureDetailZoom {
                        selectedBuilding = nil
                    }
                    return false
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
            // Hide SDK compass — we use the custom compass in `overlayControls`.
            .ornamentOptions(OrnamentOptions(compass: CompassViewOptions(visibility: .hidden)))
            .onStyleLoaded { _ in
                try? proxy.map?.setStyleImportConfigProperty(
                    for: "basemap",
                    config: "showIndoor",
                    value: true
                )
            }
            .onMapLoaded { _ in
                hasLoadedMap = true
                requestStreetSurfaceAlignmentIfNeeded(using: proxy)
            }
            .onCameraChanged { event in
                currentMapZoom = event.cameraState.zoom

                if event.cameraState.zoom < CurbyConstants.parkingStructureDetailZoom {
                    selectedBuilding = nil
                }

                requestStreetSurfaceAlignmentIfNeeded(using: proxy)
            }
            .onChange(of: heatZoneManager.heatZones.map(\.id)) { _, _ in
                scheduleStreetSurfaceAlignmentIfNeeded(
                    using: proxy,
                    delayMilliseconds: 250
                )
            }
        }
    }

    // MARK: - Zone Selection

    private func selectZone(_ zone: HeatZone) {
        withAnimation(.spring(response: 0.3)) {
            selectedZone = zone
            sheetDetent = .medium
        }
        selectedBuilding = nil
        cameraController.navigateToDestination(zone.coordinate, zoom: 17.0)
    }

    private func selectZoneForSurfaceFeature(_ feature: FeaturesetFeature) {
        guard
            let zoneIDString = feature.properties["zone_id"]??.string,
            let zoneID = UUID(uuidString: zoneIDString),
            let zone = heatZoneManager.heatZones.first(where: { $0.id == zoneID })
        else {
            return
        }

        selectZone(zone)
    }

    private func scheduleStreetSurfaceAlignmentIfNeeded(
        using proxy: MapboxMaps.MapProxy,
        delayMilliseconds: UInt64
    ) {
        Task { @MainActor in
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }

            requestStreetSurfaceAlignmentIfNeeded(using: proxy)
        }
    }

    private func requestStreetSurfaceAlignmentIfNeeded(using proxy: MapboxMaps.MapProxy) {
        guard
            hasLoadedMap,
            !isParkingRoadQueryInFlight,
            currentMapZoom >= CurbyConstants.parkingStreetDetailZoom,
            heatZoneManager.needsStreetSurfaceAlignment,
            let map = proxy.map,
            map.allSourceIdentifiers.contains(where: { $0.id == ParkingRoadNetworkIDs.source })
        else {
            return
        }

        isParkingRoadQueryInFlight = true

        let options = SourceQueryOptions(
            sourceLayerIds: [ParkingRoadNetworkIDs.sourceLayer],
            filter: ["all"]
        )

        map.querySourceFeatures(for: ParkingRoadNetworkIDs.source, options: options) { result in
            Task { @MainActor in
                isParkingRoadQueryInFlight = false

                guard case let .success(features) = result else {
                    return
                }

                let roads = ParkingRoadAlignment.roadFeatures(from: features)
                heatZoneManager.alignStreetSurfaces(to: roads)
            }
        }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .overlay {
            Circle()
                .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
        }
        .opacity(heading < 15 || heading > 345 ? 0.3 : 1.0)
    }

    // MARK: - Recenter (sheet — moves with bottom panel)

    private var sheetRecenterButton: some View {
        sheetBarIconButton(
            symbol: "location.fill",
            tint: CurbyGlass.primaryTint,
            accessibilityLabel: "Recenter map on your location"
        ) {
            cameraController.recenter()
        }
    }

    // MARK: - Sheet Content (Contextual)

    @ViewBuilder
    private var sheetContent: some View {
        if let zone = selectedZone {
            // ZONE DETAIL MODE
            VStack(spacing: 0) {
                // Back bar
                GlassEffectContainer(spacing: CurbyGlass.chromeSpacing) {
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
                            .foregroundStyle(CurbyGlass.primaryTint)
                        }

                        Spacer()

                        if cameraController.showRecenterButton {
                            sheetRecenterButton
                        }

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
                                .frame(minWidth: 96)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(CurbyGlass.primaryTint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .curbyGlassSurface(cornerRadius: CurbyGlass.barCornerRadius)
                }
                .padding(.horizontal, 20)
                // Breathing room under the sheet grabber (system drag indicator).
                .padding(.top, 20)
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
                showRecenterButton: cameraController.showRecenterButton,
                onRecenter: { cameraController.recenter() },
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

    private func sheetBarIconButton(
        symbol: String,
        tint: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
