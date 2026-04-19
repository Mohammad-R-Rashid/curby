//
//  MainNavigationView.swift
//  curby
//
//  Apple Maps-style root view: full-screen map + draggable bottom sheet.
//

import MapboxMaps
import MapKit
import PhosphorSwift
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
    /// Snaps to tier boundaries so map style layers only re-diff when the display meaningfully changes.
    @State private var renderZoom = CurbyConstants.zoomDefault
    @State private var selectedBuilding: StandardBuildingsFeature?
    @State private var selectedStructureSurfaceID: UUID?
    @State private var hasLoadedMap = false
    @State private var isParkingRoadQueryInFlight = false
    @State private var isParkingStructureQueryInFlight = false
    @State private var showSettings = false

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
                        zoom: renderZoom
                    )

                    if renderZoom < CurbyConstants.parkingBadgeCutoffZoom {
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

                    if renderZoom >= CurbyConstants.parkingStructureDetailZoom {
                        ForEvery(structurePinItems) { item in
                            MapViewAnnotation(coordinate: item.coordinate) {
                                StructureParkingPin(
                                    item: item,
                                    isSelected: item.id == selectedStructureSurfaceID
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleStructurePinTap(item)
                                }
                            }
                            .allowZElevate(true)
                            .allowOverlap(true)
                            .priority(item.id == selectedStructureSurfaceID ? 8 : 3)
                        }
                    }
                }

                if renderZoom >= CurbyConstants.parkingStructureDetailZoom,
                   let selectedBuilding
                {
                    FeatureState(selectedBuilding, .init(select: true))
                }

                if renderZoom >= CurbyConstants.parkingStructureDetailZoom {
                    TapInteraction(.standardBuildings) { building, _ in
                        selectedBuilding = building
                        selectedStructureSurfaceID = nil
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
                    selectStructureForSurfaceFeature(feature)
                    return true
                }

                TapInteraction(.layer(ParkingZoneLayerIDs.lotHitLayer), radius: 8) { feature, _ in
                    selectStructureForSurfaceFeature(feature)
                    return true
                }

                TapInteraction { _ in
                    if currentMapZoom >= CurbyConstants.parkingStructureDetailZoom {
                        selectedBuilding = nil
                        selectedStructureSurfaceID = nil
                    }
                    return false
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
                requestParkingSurfaceAlignmentIfNeeded(using: proxy)
            }
            .onCameraChanged { event in
                let zoom = event.cameraState.zoom
                currentMapZoom = zoom

                if renderZoomTier(zoom) != renderZoomTier(renderZoom) {
                    renderZoom = zoom
                }

                if zoom < CurbyConstants.parkingStructureDetailZoom {
                    if selectedBuilding != nil { selectedBuilding = nil }
                    if selectedStructureSurfaceID != nil { selectedStructureSurfaceID = nil }
                }

                requestParkingSurfaceAlignmentIfNeeded(using: proxy)
            }
            .onChange(of: heatZoneManager.heatZones.map(\.id)) { _, _ in
                selectedStructureSurfaceID = nil
                scheduleParkingSurfaceAlignmentIfNeeded(
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
        selectedStructureSurfaceID = nil
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

    private func handleStructurePinTap(_ item: StructurePinItem) {
        if selectedStructureSurfaceID == item.id {
            selectZoneForStructurePin(item)
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            selectedStructureSurfaceID = item.id
            selectedBuilding = nil
        }
    }

    private func selectStructureForSurfaceFeature(_ feature: FeaturesetFeature) {
        guard
            let surfaceIDString = feature.properties["surface_id"]??.string,
            let surfaceID = UUID(uuidString: surfaceIDString)
        else {
            return
        }

        if
            selectedStructureSurfaceID == surfaceID,
            let item = structurePinItems.first(where: { $0.id == surfaceID })
        {
            selectZoneForStructurePin(item)
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            selectedStructureSurfaceID = surfaceID
            selectedBuilding = nil
        }
    }

    private func selectZoneForStructurePin(_ item: StructurePinItem) {
        guard let zone = heatZoneManager.heatZones.first(where: { $0.id == item.zoneID }) else {
            return
        }

        selectZone(zone)
    }

    private func renderZoomTier(_ zoom: Double) -> Int {
        if zoom >= CurbyConstants.parkingStructureDetailZoom { return 3 }
        if zoom >= CurbyConstants.parkingBadgeCutoffZoom { return 2 }
        if zoom >= CurbyConstants.parkingStreetDetailZoom { return 1 }
        return 0
    }

    private var structurePinItems: [StructurePinItem] {
        let visibleZones: [HeatZone]
        if let selectedZoneID = selectedZone?.id {
            visibleZones = heatZoneManager.heatZones.filter { $0.id == selectedZoneID }
        } else {
            visibleZones = heatZoneManager.heatZones
        }

        return visibleZones.flatMap { zone in
            let spotsByReference = Dictionary(
                uniqueKeysWithValues: zone.parkingSpots.map { ($0.id.uuidString, $0) }
            )

            return zone.visibleSurfaces(at: renderZoom)
                .filter(\.kind.isStructureLevel)
                .compactMap { (surface: ParkingSurface) -> StructurePinItem? in
                    guard let coordinate = HeatZoneGeometry.surfaceAnchor(of: surface.polygonCoords) else {
                        return nil
                    }

                    let spot = surface.sourceReference.flatMap { spotsByReference[$0] }
                    return StructurePinItem(
                        zoneID: zone.id,
                        coordinate: coordinate,
                        surface: surface,
                        spot: spot
                    )
                }
        }
    }

    private func scheduleParkingSurfaceAlignmentIfNeeded(
        using proxy: MapboxMaps.MapProxy,
        delayMilliseconds: UInt64
    ) {
        Task { @MainActor in
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }

            requestParkingSurfaceAlignmentIfNeeded(using: proxy)
        }
    }

    private func requestParkingSurfaceAlignmentIfNeeded(using proxy: MapboxMaps.MapProxy) {
        guard heatZoneManager.needsStreetSurfaceAlignment || heatZoneManager.needsStructureSurfaceAlignment else {
            return
        }
        requestStreetSurfaceAlignmentIfNeeded(using: proxy)
        requestStructureSurfaceAlignmentIfNeeded(using: proxy)
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
            sourceLayerIds: [ParkingRoadNetworkIDs.roadSourceLayer],
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

    private func requestStructureSurfaceAlignmentIfNeeded(using proxy: MapboxMaps.MapProxy) {
        guard
            hasLoadedMap,
            !isParkingStructureQueryInFlight,
            currentMapZoom >= CurbyConstants.parkingStructureDetailZoom,
            heatZoneManager.needsStructureSurfaceAlignment,
            let map = proxy.map,
            map.allSourceIdentifiers.contains(where: { $0.id == ParkingRoadNetworkIDs.source })
        else {
            return
        }

        isParkingStructureQueryInFlight = true

        let options = SourceQueryOptions(
            sourceLayerIds: [ParkingRoadNetworkIDs.buildingSourceLayer],
            filter: ["all"]
        )

        map.querySourceFeatures(for: ParkingRoadNetworkIDs.source, options: options) { result in
            Task { @MainActor in
                isParkingStructureQueryInFlight = false

                guard case let .success(features) = result else {
                    return
                }

                let buildings = ParkingStructureAlignment.buildingFeatures(from: features)
                heatZoneManager.alignStructureSurfaces(to: buildings)
            }
        }
    }

    // MARK: - Overlay Controls (Liquid Glass)

    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()
                settingsButton
            }
            .padding(.horizontal, CurbyConstants.overlayPadding)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    // MARK: - Settings Button (Liquid Glass)

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Ph.gearSix.fill
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
        }
        .glassEffect(.regular, in: .circle)
        .overlay {
            Circle()
                .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
        }
    }

    // MARK: - Recenter (sheet — moves with bottom panel)

    private var sheetRecenterButton: some View {
        sheetBarIconButton(
            icon: .crosshairSimple,
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
                                selectedStructureSurfaceID = nil
                                if let dest = searchState.selectedDestination {
                                    cameraController.navigateToDestination(dest.coordinate)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Ph.caretLeft.bold
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 13, height: 13)
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
                                HStack(spacing: 6) {
                                    Ph.navigationArrow.fill
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 14, height: 14)
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
                    selectedStructureSurfaceID = nil
                    selectedBuilding = nil
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
        icon: Ph,
        tint: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct StructurePinItem: Identifiable {
    let zoneID: UUID
    let coordinate: CLLocationCoordinate2D
    let surface: ParkingSurface
    let spot: ParkingSpot?

    var id: UUID { surface.id }

    var tint: Color {
        HeatZoneGeometry.color(for: surface.busyLevel)
    }

    var icon: Ph {
        switch surface.kind {
        case .garageFootprint: return .garage
        case .lotFootprint: return .park
        case .overviewArea, .curbSegment: return .building
        }
    }

    var kindLabel: String {
        switch surface.kind {
        case .garageFootprint:
            return "Garage"
        case .lotFootprint:
            return "Lot"
        case .overviewArea:
            return "Zone"
        case .curbSegment:
            return "Street"
        }
    }

    var title: String {
        if let spotName = spot?.lotName, !spotName.isEmpty {
            return spotName
        }
        return surface.name
    }

    var compactMetricText: String {
        if let available = spot?.spotsAvailable {
            return "\(available)"
        }
        if let capacity = spot?.capacityString {
            return capacity
        }
        return surface.busyLevel.label
    }

    var availabilitySummaryText: String {
        if let capacity = spot?.capacityString {
            return "\(capacity) spots"
        }
        return surface.busyLevel.displayName
    }

    var distanceSummaryText: String {
        guard let walkingDistance = spot?.walkingDistance else {
            return "Tap for zone"
        }

        return String(format: "%.2f mi walk", walkingDistance)
    }
}

private struct StructureParkingPin: View {
    let item: StructurePinItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                item.icon.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: 11, height: 11)
                    .frame(width: 20, height: 20)
                    .background(item.tint, in: Circle())

                Text(item.compactMetricText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(item.tint.opacity(isSelected ? 0.20 : 0.10))
            )
            .overlay(
                Capsule()
                    .strokeBorder(item.tint.opacity(isSelected ? 0.85 : 0.0), lineWidth: 1.5)
            )
            .curbyGlassSurface(tint: item.tint, cornerRadius: 16)
            .shadow(
                color: item.tint.opacity(isSelected ? 0.35 : 0.18),
                radius: isSelected ? 10 : 5,
                y: isSelected ? 4 : 2
            )
            .scaleEffect(isSelected ? 1.12 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isSelected)

            Triangle()
                .fill(item.tint)
                .frame(width: 10, height: 6)
                .rotationEffect(.degrees(180))
                .offset(y: -1)
        }
    }
}


// MARK: - Preview

#Preview {
    MainNavigationView()
}
