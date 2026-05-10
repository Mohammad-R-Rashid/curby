//
//  MainNavigationView.swift
//  curby
//
//  Apple Maps-style root view: full-screen map + draggable bottom sheet.
//

import CoreLocation
import MapboxMaps
import MapKit
import os
import SwiftUI
import UIKit

private let parkSaveLogger = Logger(subsystem: "com.curby.app", category: "ParkSave")

/// Root container post-onboarding.
///
/// Full-screen Mapbox map with live parking POIs,
/// backend-routed recommendations, and an always-visible
/// draggable bottom sheet (Apple Maps style).
struct MainNavigationView: View {

    // MARK: - Dependencies

    @State private var locationService = LocationService()
    @State private var remoteConfigService: RemoteConfigService
    @State private var motionStateManager: MotionStateManager
    @State private var cameraController: CameraController
    @State private var parkingAreaManager = ParkingAreaManager()
    @State private var telemetryUploader: TelemetryUploader
    @State private var parkingEventDetector: ParkingEventDetector
    @State private var parkingWebSocketManager: ParkingWebSocketManager
    @State private var searchState = SearchState()
    @State private var liveActivityController = LiveParkingActivityController()
    /// True from the moment the user taps Navigate until they clear the
    /// destination / exit Explore. Drives the on-map route line.
    @State private var isNavigating: Bool = false

    // MARK: - Sheet State

    @State private var sheetDetent: PresentationDetent = .fraction(0.30)
    @State private var selectedParkingArea: LiveParkingArea?
    /// User-confirmed park (Supabase `active_parks`); tap the map pin to confirm removal.
    @State private var savedParkPin: SavedParkPinState?
    /// Drives the visible state of the "Park here" action so taps stop being
    /// silent: spinner while the POST is in flight, ✓ Parked on success, an
    /// inline error card with Retry on failure.
    @State private var parkSaveState: ParkSaveState = .idle
    @State private var parkSaveResetTask: Task<Void, Never>?
    @State private var showRemoveParkedConfirm = false
    @State private var walkingGeofenceMeters = OnboardingState.storedWalkingDistanceMeters
    @State private var geofenceRefreshTask: Task<Void, Never>?
    @State private var hasSetInitialViewport = false
    @State private var showSettings = false
    @State private var developerModeEnabled = OnboardingState.storedDeveloperModeEnabled

    // MARK: - Zone State

    @State private var heatZoneManager = HeatZoneManager()
    @State private var currentMapZoom: Double = CurbyConstants.zoomDefault
    @State private var lastHeatZoneLoadCenter: CLLocationCoordinate2D?
    @State private var placesSearchCoordinate: CLLocationCoordinate2D?
    /// Coalesces zone-alignment work to only run after the camera settles —
    /// otherwise we'd query Mapbox road features and run an O(surfaces × roads)
    /// pass on every camera tick during a pan.
    @State private var alignZonesTask: Task<Void, Never>?
    /// Defers heat-zone generation until the camera fly-to has finished.
    /// Loading polygons mid-flight forces Mapbox to drop style updates and
    /// stalls the render pipeline (~2s observed) — defer instead.
    @State private var heatZoneLoadTask: Task<Void, Never>?

    // MARK: - Places Pins (shown when no destination is selected)
    /// Owns the dynamic landmark/area places used by both the bottom-sheet
    /// carousel and the on-map place pins. No more per-city hardcoded lists.
    @State private var placesService = DynamicPlacesService()

    // MARK: - Explore Mode (browse parking near a Place without setting a destination)
    @State private var exploredPlace: PopularLocation?
    @State private var hoveredPlace: PopularLocation?
    @State private var hoverDetectTask: Task<Void, Never>?

    // MARK: - Dropped Pin State

    @State private var customPinCoordinate: CLLocationCoordinate2D?
    @State private var isDraggingPin = false
    @State private var pinDragStart: CLLocationCoordinate2D?

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Init

    init() {
        let location = LocationService()
        let apiClient = CurbyAPIClient()
        let remoteConfig = RemoteConfigService(apiClient: apiClient)
        let motion = MotionStateManager(
            locationService: location,
            remoteConfigService: remoteConfig
        )
        let camera = CameraController(locationService: location, motionStateManager: motion)
        let telemetryUploader = TelemetryUploader(
            apiClient: apiClient,
            remoteConfigService: remoteConfig
        )
        let parkingEventDetector = ParkingEventDetector(
            apiClient: apiClient,
            remoteConfigService: remoteConfig
        )
        let parkingWebSocketManager = ParkingWebSocketManager(
            apiClient: apiClient,
            remoteConfigService: remoteConfig
        )

        _locationService = State(initialValue: location)
        _remoteConfigService = State(initialValue: remoteConfig)
        _motionStateManager = State(initialValue: motion)
        _cameraController = State(initialValue: camera)
        _telemetryUploader = State(initialValue: telemetryUploader)
        _parkingEventDetector = State(initialValue: parkingEventDetector)
        _parkingWebSocketManager = State(initialValue: parkingWebSocketManager)
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

            // MARK: Hover popup — "you're in [place]" prompt
            if let hoveredPlace {
                VStack {
                    HoverPlacePopup(
                        place: hoveredPlace,
                        onTap: { place in
                            enterExploreMode(for: place)
                        }
                    )
                    .padding(.top, 60)
                    Spacer().allowsHitTesting(false)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: hoveredPlace.id)
            }

            // MARK: Map overlay controls
            overlayControls

            if developerModeEnabled {
                DeveloperMapDiagnosticsOverlay(
                    mapZoom: currentMapZoom,
                    searchState: searchState,
                    parkingAreaManager: parkingAreaManager,
                    parkingWebSocketManager: parkingWebSocketManager,
                    remoteConfigService: remoteConfigService,
                    heatZoneManager: heatZoneManager,
                    telemetryUploader: telemetryUploader,
                    parkingEventDetector: parkingEventDetector,
                    locationService: locationService,
                    motionStateManager: motionStateManager,
                    walkingGeofenceMeters: walkingGeofenceMeters
                )
            }
        }
        .sheet(isPresented: .constant(true)) {
            sheetContent
                .presentationDetents(
                    [.fraction(0.25), .fraction(0.30), .medium, .large],
                    selection: $sheetDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            locationService.requestPermission()
            setupInitialViewport()
            searchState.userLocation = locationService.currentLocation?.coordinate
            remoteConfigService.start()
            telemetryUploader.start()
            parkingEventDetector.start()
            parkingWebSocketManager.updateCurrentLocation(locationService.currentLocation?.coordinate)
            telemetryUploader.updateLatestSample(
                location: locationService.currentLocation,
                heading: locationService.currentHeading
            )
            parkingEventDetector.updateLatestLocation(locationService.currentLocation)
            parkingEventDetector.onParked = {
                CurbyHaptics.medium()
                Task { await parkingWebSocketManager.markArrivedIfNeeded() }
                syncSavedParkPinFromDetector()
            }
            syncSavedParkPinFromDetector()
            // Populate place pins for the map (dynamic — MKLocalSearch).
            if let coord = locationService.currentLocation?.coordinate {
                placesService.fetchIfNeeded(near: coord)
            }
        }
        .onChange(of: parkingEventDetector.presenceState) { _, new in
            if new == .driving {
                savedParkPin = nil
            } else if new == .parked {
                syncSavedParkPinFromDetector()
            }
        }
        .onChange(of: locationService.authorizationStatus) { _, newStatus in
            handleAuthorizationChange(newStatus)
        }
        .onChange(of: locationService.currentSpeed) { _, _ in
            cameraController.updateForCurrentSpeed()
        }
        .onChange(of: locationService.currentHeading) { _, newHeading in
            telemetryUploader.updateLatestSample(
                location: locationService.currentLocation,
                heading: newHeading
            )
        }
        .onChange(of: locationService.currentLocation) { _, newLoc in
            searchState.userLocation = newLoc?.coordinate
            telemetryUploader.updateLatestSample(location: newLoc, heading: locationService.currentHeading)
            parkingEventDetector.updateLatestLocation(newLoc)
            parkingWebSocketManager.updateCurrentLocation(newLoc?.coordinate)
            liveActivityController.update(currentLocation: newLoc)
        }
        .onChange(of: parkingWebSocketManager.activeSessionID) { _, _ in
            guard let recommendation = parkingWebSocketManager.activeRecommendation else {
                return
            }
            focusRecommendation(recommendation)
        }
        .onChange(of: parkingAreaManager.areas.map(\.id)) { _, newIDs in
            // TEMP: heat-zone generation disabled while we isolate the
            // parking-with-results freeze. Re-enable after diagnosis.
            // heatZoneLoadTask?.cancel()
            // heatZoneLoadTask = Task { @MainActor in
            //     try? await Task.sleep(for: .milliseconds(1_200))
            //     guard !Task.isCancelled else { return }
            //     heatZoneManager.loadZones(from: parkingAreaManager.areas)
            // }
            heatZoneManager.clearZones()

            guard let selectedParkingArea else { return }
            if
                !newIDs.contains(selectedParkingArea.id),
                parkingWebSocketManager.activeRecommendation?.area.id != selectedParkingArea.id
            {
                self.selectedParkingArea = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OnboardingState.preferencesDidChangeNotification)) { _ in
            developerModeEnabled = OnboardingState.storedDeveloperModeEnabled
            let updatedGeofenceMeters = OnboardingState.storedWalkingDistanceMeters
            guard abs(updatedGeofenceMeters - walkingGeofenceMeters) > 1 else { return }
            walkingGeofenceMeters = updatedGeofenceMeters
            geofenceRefreshTask?.cancel()
            geofenceRefreshTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                refreshParkingExperienceForCurrentDestination(retryBackend: true)
            }
        }
        .animation(
            .easeInOut(duration: CurbyConstants.uiFadeAnimationDuration),
            value: cameraController.showRecenterButton
        )
        .confirmationDialog(
            "Remove parked location?",
            isPresented: $showRemoveParkedConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                CurbyHaptics.medium()
                Task { await clearSavedParkPinIfPresent() }
            }
            Button("Cancel", role: .cancel) {
                CurbyHaptics.light()
            }
        } message: {
            Text("Clears your spot from the live map.")
        }
    }

    // MARK: - Map View

    @ViewBuilder
    private var mapView: some View {
        MapReader { proxy in
            Map(viewport: $cameraController.viewport) {
                // User location puck
                Puck2D(bearing: .heading)

                // Live per-segment traffic. Self-driven by Mapbox's traffic
                // vector tiles — no client-side state, no per-area polygons.
                // Hidden below LiveTrafficMapStyleContent.minimumZoom.
                LiveTrafficMapStyleContent()

                // Geo-fenced busy/open zones — rendered at all zoom levels
                ParkingZoneMapStyleContent(
                    zones: heatZoneManager.heatZones,
                    selectedZoneID: nil,
                    zoom: currentMapZoom
                )

                if developerModeEnabled {
                    DeveloperDebugMapStyleContent(
                        userLocation: locationService.currentLocation,
                        destinationCoordinate: searchState.selectedDestination?.coordinate,
                        parkingAreas: parkingAreaManager.areas,
                        activeRecommendation: parkingWebSocketManager.activeRecommendation,
                        socketOriginCoordinate: parkingWebSocketManager.debugSocketOriginCoordinate
                    )
                }

                CurbyLiveParkingMapStyleContent(
                    destinationCoordinate: searchState.selectedDestination?.coordinate,
                    walkingGeofenceRadiusMeters: walkingGeofenceMeters,
                    activeRecommendation: parkingWebSocketManager.activeRecommendation,
                    pendingRecommendation: parkingWebSocketManager.pendingRouteUpdate,
                    isNavigating: isNavigating,
                    developerMode: developerModeEnabled
                )

                if let destination = searchState.selectedDestination {
                    MapViewAnnotation(coordinate: destination.coordinate) {
                        DestinationMapPin(name: destination.name)
                            .onTapGesture {
                                cameraController.navigateToDestination(destination.coordinate, zoom: 16.0)
                            }
                    }
                    .allowOverlap(true)
                    .priority(5)
                }

                if let recommendation = parkingWebSocketManager.activeRecommendation {
                    MapViewAnnotation(coordinate: recommendation.area.coordinate) {
                        RecommendationMapPin(
                            recommendation: recommendation,
                            isArrived: parkingWebSocketManager.status == .arrived,
                            developerMode: developerModeEnabled
                        )
                        .onTapGesture {
                            focusRecommendation(recommendation)
                        }
                    }
                    .allowZElevate(true)
                    .allowOverlap(true)
                    .priority(9)
                }

                // Show parking areas as labeled pins when zoomed in enough
                if currentMapZoom >= 11.0 {
                    ForEvery(visibleParkingAreas) { area in
                        MapViewAnnotation(coordinate: area.coordinate) {
                            LiveParkingAreaMapPin(
                                area: area,
                                isSelected: selectedParkingArea?.id == area.id,
                                showLabel: currentMapZoom >= 13.0,
                                developerLabels: developerModeEnabled
                            )
                            .onTapGesture {
                                selectParkingArea(area)
                            }
                        }
                        .allowZElevate(true)
                        .allowOverlap(currentMapZoom >= 14.0)
                        .priority(selectedParkingArea?.id == area.id ? 7 : (area.kind == .street ? 5 : 4))
                    }
                }

                // Popular places pins — visible when browsing (no destination selected)
                if searchState.selectedDestination == nil, currentMapZoom >= 10.0 {
                    ForEvery(placesService.places) { place in
                        MapViewAnnotation(coordinate: place.coordinate) {
                            PlaceMapPin(
                                place: place,
                                showLabel: currentMapZoom >= 11.5
                            )
                            .onTapGesture {
                                enterExploreMode(for: place)
                            }
                        }
                        .allowZElevate(true)
                        .allowOverlap(currentMapZoom >= 12.5)
                        .priority(3)
                    }
                }
                if developerModeEnabled {
                    ForEvery(parkingAreaManager.areas.filter { area in
                        navigationCoordinateDiffers(from: area)
                    }) { area in
                        MapViewAnnotation(coordinate: area.navigationCoordinate) {
                            NavigationAnchorMapPin(areaName: area.mapLabel)
                        }
                        .allowZElevate(true)
                        .allowOverlap(true)
                        .priority(6)
                    }

                    if let wsOrigin = parkingWebSocketManager.debugSocketOriginCoordinate {
                        MapViewAnnotation(coordinate: wsOrigin) {
                            WebSocketOriginMapPin()
                        }
                        .allowZElevate(true)
                        .allowOverlap(true)
                        .priority(8)
                    }
                }

                if let pin = savedParkPin {
                    MapViewAnnotation(coordinate: pin.coordinate) {
                        SavedParkMapPin(title: pin.title)
                            .onTapGesture {
                                showRemoveParkedConfirm = true
                            }
                    }
                    .allowZElevate(true)
                    .allowOverlap(true)
                    .priority(10)
                }

                // Long press drops a draggable pin when no destination is active
                if searchState.selectedDestination == nil {
                    LongPressInteraction { context in
                        dropCustomPin(at: context.coordinate)
                        return false
                    }
                }

                // Dropped pin annotation
                if let coord = customPinCoordinate, searchState.selectedDestination == nil {
                    MapViewAnnotation(coordinate: coord) {
                        DroppedPinView(
                            isDragging: $isDraggingPin,
                            onDragChanged: { translation in
                                if pinDragStart == nil { pinDragStart = customPinCoordinate }
                                guard let start = pinDragStart else { return }
                                customPinCoordinate = coordinateByDragging(
                                    from: start,
                                    translation: translation,
                                    zoom: currentMapZoom
                                )
                            },
                            onDragEnded: {
                                pinDragStart = nil
                            },
                            onTap: {
                                setCustomPinAsDestination()
                            }
                        )
                    }
                    .allowOverlap(true)
                    .priority(11)
                }

                TapInteraction { _ in
                    if selectedParkingArea != nil {
                        selectedParkingArea = nil
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
            .onCameraChanged { change in
                let newZoom = change.cameraState.zoom
                // Quantize zoom updates to 0.2-step deltas so the entire mapView
                // body doesn't recompute (and rebuild ~120 zone polygons) on
                // every fractional tick during a pinch/zoom.
                if abs(newZoom - currentMapZoom) >= 0.2 {
                    currentMapZoom = newZoom
                }
                let center = change.cameraState.center

                // Throttle places-related state updates by a 100m distance
                // threshold. Without this, every camera tick mutates two
                // @State properties and forces MainNavigationView's body —
                // which contains every map annotation — to recompute.
                let centerMovedSignificantly: Bool = {
                    guard let last = placesSearchCoordinate else { return true }
                    return CLLocation(latitude: last.latitude, longitude: last.longitude)
                        .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) > 100
                }()

                if newZoom >= 10.0, centerMovedSignificantly {
                    placesSearchCoordinate = center
                    // Bias typed search to where the user is exploring, not
                    // just where they physically are.
                    searchState.mapCenter = center
                    if searchState.selectedDestination == nil {
                        placesService.fetchIfNeeded(near: center)
                    }
                }

                detectHoveredPlace(at: center, zoom: newZoom)
                scheduleZoneAlignment(proxy: proxy, zoom: newZoom)
            }
        }
    }

    // MARK: - Zone Alignment

    /// Run alignZonesIfNeeded only after the camera has been still for ~250ms.
    /// During an active pan/zoom we'd otherwise pile up MapBox source queries
    /// and main-actor alignment work on every tick.
    private func scheduleZoneAlignment(proxy: MapboxMaps.MapProxy, zoom: Double) {
        alignZonesTask?.cancel()
        alignZonesTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            alignZonesIfNeeded(proxy: proxy, zoom: zoom)
        }
    }

    private func alignZonesIfNeeded(proxy: MapboxMaps.MapProxy, zoom: Double) {
        guard let map = proxy.map else { return }

        if heatZoneManager.needsStreetSurfaceAlignment,
           zoom >= CurbyConstants.parkingStreetDetailZoom
        {
            let opts = SourceQueryOptions(
                sourceLayerIds: [ParkingRoadNetworkIDs.roadSourceLayer],
                filter: Exp(.all)
            )
            _ = try? map.querySourceFeatures(
                for: ParkingRoadNetworkIDs.source,
                options: opts
            ) { result in
                guard let features = try? result.get(), !features.isEmpty else { return }
                Task { @MainActor in
                    heatZoneManager.alignStreetSurfaces(
                        to: ParkingRoadAlignment.roadFeatures(from: features)
                    )
                }
            }
        }

        if heatZoneManager.needsStructureSurfaceAlignment,
           zoom >= CurbyConstants.parkingStructureDetailZoom
        {
            let opts = SourceQueryOptions(
                sourceLayerIds: [ParkingRoadNetworkIDs.buildingSourceLayer],
                filter: Exp(.all)
            )
            _ = try? map.querySourceFeatures(
                for: ParkingRoadNetworkIDs.source,
                options: opts
            ) { result in
                guard let features = try? result.get(), !features.isEmpty else { return }
                Task { @MainActor in
                    heatZoneManager.alignStructureSurfaces(
                        to: ParkingStructureAlignment.buildingFeatures(from: features)
                    )
                }
            }
        }
    }

    // MARK: - Dropped Pin

    private func dropCustomPin(at coordinate: CLLocationCoordinate2D) {
        customPinCoordinate = coordinate
        CurbyHaptics.heavy()
    }

    private func setCustomPinAsDestination() {
        guard let coord = customPinCoordinate else { return }
        CurbyHaptics.notify(.success)
        searchState.selectDestination(
            name: "Custom Location",
            subtitle: "Dropped pin",
            coordinate: coord
        )
        customPinCoordinate = nil
    }

    /// Converts a 2D screen drag translation to a new coordinate, accounting for map zoom scale.
    private func coordinateByDragging(
        from start: CLLocationCoordinate2D,
        translation: CGSize,
        zoom: Double
    ) -> CLLocationCoordinate2D {
        let metersPerPixel = 156543.03392 * cos(start.latitude * .pi / 180.0) / pow(2.0, zoom)
        return HeatZoneGeometry.offsetCoordinate(
            from: start,
            northMeters: -Double(translation.height) * metersPerPixel,
            eastMeters: Double(translation.width) * metersPerPixel
        )
    }

    // MARK: - Area Selection

    private func selectParkingArea(_ area: LiveParkingArea) {
        CurbyHaptics.selection()
        withAnimation(.spring(response: 0.3)) {
            selectedParkingArea = area
            sheetDetent = .medium
        }
        cameraController.navigateToDestination(
            area.coordinate,
            zoom: area.kind == .street ? 17.1 : 16.4
        )
    }

    private func focusRecommendation(_ recommendation: CurbyParkingRecommendation) {
        CurbyHaptics.selection()
        selectedParkingArea = parkingAreaManager.areas.first(where: { $0.id == recommendation.area.id }) ??
            LiveParkingArea(
                id: recommendation.area.id,
                name: recommendation.area.name,
                coordinate: recommendation.area.coordinate,
                navigationCoordinate: recommendation.area.coordinate,
                address: "",
                fullAddress: "",
                placeFormatted: "",
                phone: nil,
                website: nil,
                openHoursText: [],
                categoryIDs: [recommendation.area.category],
                distanceMeters: nil,
                destinationDistanceMeters: nil,
                kind: LiveParkingArea.kind(
                    forName: recommendation.area.name,
                    categoryIDs: [recommendation.area.category]
                )
            )
        cameraController.navigateToDestination(recommendation.area.coordinate, zoom: 16.0)
    }

    private var visibleParkingAreas: [LiveParkingArea] {
        parkingAreaManager.areas.filter { area in
            parkingWebSocketManager.activeRecommendation?.area.id != area.id
        }
    }

    private func handleDestinationSelected(_ dest: SelectedDestination) {
        customPinCoordinate = nil
        selectedParkingArea = nil
        // Picking a real address ends any exploration session.
        exploredPlace = nil
        hoveredPlace = nil
        parkingAreaManager.loadAreas(
            around: dest.coordinate,
            userLocation: locationService.currentLocation?.coordinate,
            walkingRadiusMeters: walkingGeofenceMeters
        )
        cameraController.navigateToDestination(dest.coordinate)
        sheetDetent = .fraction(0.25)
        Task {
            await parkingWebSocketManager.findParking(
                for: dest,
                currentLocation: locationService.currentLocation?.coordinate,
                searchRadiusMeters: walkingGeofenceMeters
            )
        }
    }

    /// Browse parking + heat zones around a popular place without committing
    /// to it as a routed destination. No `findParking` request is sent.
    private func enterExploreMode(for place: PopularLocation) {
        CurbyHaptics.selection()
        customPinCoordinate = nil
        selectedParkingArea = nil
        hoveredPlace = nil
        if searchState.selectedDestination != nil {
            searchState.clearDestination()
            Task { await parkingWebSocketManager.cancelSearch() }
        }
        exploredPlace = place
        parkingAreaManager.loadAreas(
            around: place.coordinate,
            userLocation: locationService.currentLocation?.coordinate,
            walkingRadiusMeters: walkingGeofenceMeters
        )
        cameraController.navigateToDestination(place.coordinate)
        sheetDetent = .fraction(0.30)
    }

    private func exitExploreMode() {
        exploredPlace = nil
        selectedParkingArea = nil
        parkingAreaManager.clear()
        heatZoneManager.clearZones()
        liveActivityController.end()
        isNavigating = false
        sheetDetent = .fraction(0.30)
    }

    /// Show the floating "you're in [place]" prompt when the map has been
    /// holding still over a popular place for a beat. We debounce so the
    /// label doesn't flash while the user pans through.
    private func detectHoveredPlace(at center: CLLocationCoordinate2D, zoom: Double) {
        // Don't compete with explicit modes.
        guard searchState.selectedDestination == nil,
              exploredPlace == nil,
              !searchState.isSearchActive,
              zoom >= 12.0
        else {
            hoverDetectTask?.cancel()
            if hoveredPlace != nil { hoveredPlace = nil }
            return
        }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let nearest = placesService.places
            .map { ($0, CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: centerLocation)) }
            .filter { $0.1 < 350 }
            .min(by: { $0.1 < $1.1 })?
            .0

        guard let nearest else {
            hoverDetectTask?.cancel()
            if hoveredPlace != nil { hoveredPlace = nil }
            return
        }

        // Already showing this one — debounce reset isn't needed.
        if hoveredPlace?.id == nearest.id { return }

        hoverDetectTask?.cancel()
        hoverDetectTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            hoveredPlace = nearest
        }
    }

    private func refreshParkingExperienceForCurrentDestination(retryBackend: Bool) {
        guard let destination = searchState.selectedDestination else { return }

        parkingAreaManager.loadAreas(
            around: destination.coordinate,
            userLocation: locationService.currentLocation?.coordinate,
            walkingRadiusMeters: walkingGeofenceMeters
        )

        guard retryBackend else { return }

        Task {
            await parkingWebSocketManager.findParking(
                for: destination,
                currentLocation: locationService.currentLocation?.coordinate,
                searchRadiusMeters: walkingGeofenceMeters
            )
        }
    }

    // MARK: - Overlay Controls (Liquid Glass)

    private var overlayControls: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(spacing: 10) {
                    settingsButton
                    if cameraController.showRecenterButton {
                        recenterMapButton
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(
                    .easeInOut(duration: CurbyConstants.uiFadeAnimationDuration),
                    value: cameraController.showRecenterButton
                )
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
        }
    }

    // MARK: - Map Overlay Buttons (Liquid Glass)

    /// Outlined gearshape — lighter / more iOS-native than the filled
    /// variant, which read as too heavy sitting on top of the map.
    private var settingsButton: some View {
        glassCircleButton(systemImage: "gearshape", size: 17) {
            CurbyHaptics.light()
            showSettings = true
        }
        .accessibilityLabel("Settings")
    }

    /// Apple-Maps-style "snap back to me" button. Floats with the settings
    /// icon at the top-right whenever the camera has drifted off the user's
    /// puck. Replaces the in-sheet / search-bar inline recenter chrome that
    /// used to live on the destination card.
    private var recenterMapButton: some View {
        glassCircleButton(systemImage: "location.fill", size: 16) {
            CurbyHaptics.light()
            cameraController.recenter()
        }
        .accessibilityLabel("Recenter map on your location")
    }

    @ViewBuilder
    private func glassCircleButton(
        systemImage: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay {
            Circle()
                .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
        }
    }

    // MARK: - Recenter (sheet — moves with bottom panel)

    private var sheetRecenterButton: some View {
        Button {
            CurbyHaptics.light()
            cameraController.recenter()
        } label: {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CurbyGlass.primaryTint)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map on your location")
    }

    // MARK: - Sheet Content (Contextual)

    @ViewBuilder
    private var sheetContent: some View {
        if let selectedParkingArea {
            VStack(spacing: 0) {
                // ── Parking-detail nav header — deliberately NOT styled like
                // the search bar (no liquid-glass pill). Plain top bar with a
                // back chevron and the parking name, so it reads as a separate
                // pane instead of "the search bar morphed into something".
                HStack(spacing: 12) {
                    Button {
                        CurbyHaptics.light()
                        withAnimation {
                            self.selectedParkingArea = nil
                            // Don't carry a pending failure state onto the next
                            // sheet — if a save just failed in this detail
                            // view, its error card would otherwise re-render
                            // attached to a different action.
                            parkSaveResetTask?.cancel()
                            if case .failed = parkSaveState { parkSaveState = .idle }
                            if let recommendation = parkingWebSocketManager.activeRecommendation {
                                cameraController.navigateToDestination(
                                    recommendation.area.coordinate,
                                    zoom: 16.0
                                )
                            } else if let dest = searchState.selectedDestination {
                                cameraController.navigateToDestination(dest.coordinate)
                            } else if let place = exploredPlace {
                                cameraController.navigateToDestination(place.coordinate)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)

                    Text(selectedParkingArea.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    sheetRecenterButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)

                ParkingAreaDetailView(
                    area: selectedParkingArea,
                    recommendation: parkingWebSocketManager.activeRecommendation?.area.id == selectedParkingArea.id
                        ? parkingWebSocketManager.activeRecommendation
                        : nil,
                    isParkedHere: isParkedAtSelectedParkingArea,
                    onNavigate: {
                        openInMaps(
                            coordinate: selectedParkingArea.navigationCoordinate,
                            name: selectedParkingArea.name
                        )
                    },
                    onMarkAsParked: {
                        Task { await saveParkPin(for: selectedParkingArea) }
                    },
                    parkSaveState: parkSaveState
                )
            }
        } else {
            // SEARCH / DESTINATION / EXPLORE MODE
            SearchView(
                searchState: searchState,
                parkingAreaManager: parkingAreaManager,
                parkingSearchManager: parkingWebSocketManager,
                parkingEventDetector: parkingEventDetector,
                exploredPlace: exploredPlace,
                dynamicPlaces: placesService.places,
                mapCenter: placesSearchCoordinate,
                onMarkAsParked: {
                    Task { await saveParkPinFromDestinationSheet() }
                },
                parkSaveState: parkSaveState,
                onDestinationSelected: { dest in
                    handleDestinationSelected(dest)
                },
                onParkingAreaSelected: { area in
                    selectParkingArea(area)
                },
                onPlaceExplored: { place in
                    enterExploreMode(for: place)
                },
                onExitExplore: {
                    CurbyHaptics.light()
                    exitExploreMode()
                    cameraController.recenter()
                },
                onClearDestination: {
                    CurbyHaptics.light()
                    Task { await parkingWebSocketManager.cancelSearch() }
                    parkingAreaManager.clear()
                    heatZoneManager.clearZones()
                    liveActivityController.end()
                    isNavigating = false
                    customPinCoordinate = nil
                    selectedParkingArea = nil
                    parkSaveResetTask?.cancel()
                    parkSaveState = .idle
                    cameraController.recenter()
                    sheetDetent = .fraction(0.30)
                },
                onExpandWalkingRadius: {
                    CurbyHaptics.medium()
                    OnboardingState.addWalkingCircumferenceMiles(CurbyConstants.parkingSearchRadiusExpandStepMiles)
                }
            )
        }
    }

    private var isParkedAtSelectedParkingArea: Bool {
        guard parkingEventDetector.presenceState == .parked,
              let pin = savedParkPin,
              let area = selectedParkingArea
        else { return false }
        let pinLoc = CLLocation(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
        let navLoc = CLLocation(
            latitude: area.navigationCoordinate.latitude,
            longitude: area.navigationCoordinate.longitude
        )
        return pinLoc.distance(from: navLoc) < 120
    }

    private func syncSavedParkPinFromDetector() {
        guard parkingEventDetector.presenceState == .parked,
              let coord = parkingEventDetector.parkedCoordinateForMap
        else { return }
        savedParkPin = SavedParkPinState(
            coordinate: coord,
            title: parkingEventDetector.parkedPinDisplayTitle
        )
    }

    private func saveParkPin(for area: LiveParkingArea) async {
        await applySavedPark(
            coordinate: area.navigationCoordinate,
            title: area.displayName
        )
    }

    private func saveParkPinFromDestinationSheet() async {
        if let rec = parkingWebSocketManager.activeRecommendation {
            await applySavedPark(coordinate: rec.area.coordinate, title: rec.area.name)
            return
        }
        if let coord = locationService.currentLocation?.coordinate {
            await applySavedPark(coordinate: coord, title: "Parked near you")
        }
    }

    private func applySavedPark(coordinate: CLLocationCoordinate2D, title: String) async {
        parkSaveResetTask?.cancel()
        parkSaveState = .saving

        do {
            try await parkingEventDetector.recordExplicitPark(at: coordinate, displayTitle: title)
            savedParkPin = SavedParkPinState(coordinate: coordinate, title: title)
            CurbyHaptics.notify(.success)

            if let rec = parkingWebSocketManager.activeRecommendation {
                let chosen = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let suggested = CLLocation(
                    latitude: rec.area.coordinate.latitude,
                    longitude: rec.area.coordinate.longitude
                )
                if chosen.distance(from: suggested) < 90 {
                    await parkingWebSocketManager.markArrived()
                }
            }

            parkSaveState = .succeeded
            // Collapse the sheet so the orange "Your Car" pin on the map is
            // actually visible — otherwise the only visible result of a
            // successful save was hidden behind a half-open sheet.
            withAnimation(.spring(response: 0.35)) {
                sheetDetent = .fraction(0.30)
            }
            parkSaveResetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                parkSaveState = .idle
            }
        } catch {
            parkSaveLogger.error("Park save failed: \(error.localizedDescription, privacy: .public)")
            CurbyHaptics.notify(.error)
            parkSaveState = .failed(error.localizedDescription)
        }
    }

    private func clearSavedParkPinIfPresent() async {
        guard savedParkPin != nil else { return }
        do {
            try await parkingEventDetector.recordExplicitDepart()
            savedParkPin = nil
            CurbyHaptics.medium()
        } catch {
            savedParkPin = nil
            CurbyHaptics.notify(.error)
        }
    }

    // MARK: - Open in Maps

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
        CurbyHaptics.light()

        // Mark that an active navigation session has begun. The on-map route
        // line is gated on this — it should not draw simply because a
        // recommendation arrived; only after the user has explicitly tapped
        // Navigate.
        isNavigating = true

        // Start (or restart) the Live Activity / Dynamic Island session for
        // the trip before handing off to Apple Maps. Curby will be backgrounded
        // while Apple Maps does turn-by-turn; the activity is what keeps the
        // parking + busyness context visible on top.
        startLiveActivityForNavigation(parkingCoordinate: coordinate, parkingName: name)

        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func startLiveActivityForNavigation(
        parkingCoordinate: CLLocationCoordinate2D,
        parkingName: String
    ) {
        // Resolve what we treat as the trip destination (where the
        // walking-radius geofence is anchored). Prefer an explicit destination,
        // then the current Explore-mode place, then fall back to the parking
        // itself (covers "navigate to a parking pin without a destination set").
        let destinationName: String
        let destinationCoordinate: CLLocationCoordinate2D
        if let dest = searchState.selectedDestination {
            destinationName = dest.name
            destinationCoordinate = dest.coordinate
        } else if let place = exploredPlace {
            destinationName = place.name
            destinationCoordinate = place.coordinate
        } else {
            destinationName = parkingName
            destinationCoordinate = parkingCoordinate
        }

        let busynessLabel = parkingWebSocketManager.activeRecommendation?.matchQualityShortLabel
            ?? "Open"

        liveActivityController.start(
            destinationName: destinationName,
            destinationCoordinate: destinationCoordinate,
            parkingName: parkingName,
            parkingCoordinate: parkingCoordinate,
            walkingRadiusMeters: walkingGeofenceMeters,
            currentLocation: locationService.currentLocation,
            busynessLabel: busynessLabel
        )
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

    /// True when Mapbox’s routable point is meaningfully offset from the POI centroid (debug routing).
    private func navigationCoordinateDiffers(from area: LiveParkingArea, thresholdMeters: Double = 12) -> Bool {
        let base = CLLocation(latitude: area.coordinate.latitude, longitude: area.coordinate.longitude)
        let nav = CLLocation(latitude: area.navigationCoordinate.latitude, longitude: area.navigationCoordinate.longitude)
        return base.distance(from: nav) >= thresholdMeters
    }
}

// MARK: - Developer diagnostics

private struct DeveloperMapDiagnosticsOverlay: View {
    let mapZoom: Double
    let searchState: SearchState
    let parkingAreaManager: ParkingAreaManager
    let parkingWebSocketManager: ParkingWebSocketManager
    let remoteConfigService: RemoteConfigService
    let heatZoneManager: HeatZoneManager
    let telemetryUploader: TelemetryUploader
    let parkingEventDetector: ParkingEventDetector
    let locationService: LocationService
    let motionStateManager: MotionStateManager
    let walkingGeofenceMeters: Double

    @State private var developerLogExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("DEVELOPER")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange, in: Capsule())

                Text(liveContextLine)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.75)
                    }
            }
            .padding(.horizontal, CurbyConstants.overlayPadding)
            .padding(.top, 52)

            Spacer()

            if developerLogExpanded {
                developerLogPanel
            } else {
                developerLogPeekChip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(true)
    }

    private var developerLogPeekChip: some View {
        Button {
            developerLogExpanded = true
        } label: {
            HStack(spacing: 8) {
                Text("Developer log")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CurbyConstants.overlayPadding)
        .padding(.bottom, 120)
    }

    private var developerLogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                developerLogExpanded = false
            } label: {
                HStack(spacing: 8) {
                    Text("Hide developer log")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    line("Map key (on map)", mapLegendLine)

                    line("Dest", searchState.selectedDestination?.name ?? "—")
                    if let c = searchState.selectedDestination?.coordinate {
                        line("Dest lat/lng", String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    }

                    let street = parkingAreaManager.streetAreas.count
                    let structure = parkingAreaManager.structureAreas.count
                    line(
                        "POIs in fence",
                        "\(parkingAreaManager.areas.count) total · street \(street) · structure \(structure)"
                    )

                    if parkingAreaManager.isLoading {
                        line("Mapbox", "loading…")
                    }
                    if let err = parkingAreaManager.lastErrorMessage, !err.isEmpty {
                        line("Mapbox", err)
                    }

                    line(
                        "Geofence r",
                        String(format: "%.0f m (%.2f mi)", walkingGeofenceMeters, walkingGeofenceMeters / CurbyConstants.metersPerMile)
                    )
                    line("Heat zones", "\(heatZoneManager.heatZones.count) loaded")
                    ForEach(Array(heatZoneManager.heatZones.prefix(6))) { zone in
                        line(
                            "Zone · \(zone.name.prefix(18))",
                            "score \(zone.busyScore) · \(zone.busyLevel.displayName) · \(zone.parkingSpots.count) spots"
                        )
                    }

                    Divider().opacity(0.35)

                    line("User id", String(CurbyUserIdentity.loadOrCreateUserID().prefix(13)) + "…")

                    if let loc = locationService.currentLocation {
                        line(
                            "GPS fix",
                            String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude)
                        )
                        line(
                            "GPS quality",
                            gpsQualityLine(for: loc)
                        )
                    } else {
                        line("GPS fix", "none")
                    }

                    line("Motion", "\(motionStateManager.motionState) · reduceAnim \(motionStateManager.shouldReduceAnimations ? "on" : "off")")

                    Divider().opacity(0.35)

                    line("Presence", "\(parkingEventDetector.presenceState.rawValue)")
                    if let t = parkingEventDetector.lastTransitionAt {
                        line("Last presence Δ", t.formatted(date: .omitted, time: .standard))
                    }
                    if let pe = parkingEventDetector.lastErrorMessage, !pe.isEmpty {
                        line("Park detector err", pe)
                    }

                    line("Telemetry Q", "\(telemetryUploader.pendingUploadCount) pending")
                    if let last = telemetryUploader.lastUploadAt {
                        line("Telemetry last OK", last.formatted(date: .omitted, time: .standard))
                    }
                    if let te = telemetryUploader.lastErrorMessage, !te.isEmpty {
                        line("Telemetry err", te)
                    }
                    line(
                        "Telemetry cfg",
                        "every \(remoteConfigService.config.telemetry.uploadIntervalSec)s · min Δ \(Int(remoteConfigService.config.telemetry.minDistanceMeters)) m"
                    )

                    Divider().opacity(0.35)

                    line("Live session", parkingWebSocketManager.status.developerSummaryLine)

                    if let sid = parkingWebSocketManager.activeSessionID {
                        line("Session id", String(sid.prefix(10)) + "…")
                    }
                    if let r = parkingWebSocketManager.debugLastSearchRadiusMeters {
                        line("WS radius sent", String(format: "%.0f m", r))
                    }
                    if let origin = parkingWebSocketManager.debugSocketOriginCoordinate {
                        line(
                            "WS origin",
                            String(format: "%.5f, %.5f", origin.latitude, origin.longitude)
                        )
                    }
                    line(
                        "WS refresh rule",
                        "re-open if you move ≥45 m from WS origin (min 15 s apart)"
                    )
                    line("Auto-arrival", "≤120 m from pick or destination puck")
                    if let code = parkingWebSocketManager.lastErrorCode {
                        line("Last WS code", code)
                    }

                    if let pending = parkingWebSocketManager.pendingRouteUpdate {
                        let r = pending.reasoning
                        line(
                            "Pending reroute",
                            pending.matchQualityShortLabel + " · " + String(r.prefix(100)) + (r.count > 100 ? "…" : "")
                        )
                    } else if let reason = parkingWebSocketManager.pendingRouteUpdateReason, !reason.isEmpty {
                        line("Pending reason", String(reason.prefix(120)))
                    }

                    if let rec = parkingWebSocketManager.activeRecommendation {
                        let b = rec.score.breakdown
                        line("Match rank", String(format: "%.0f%% overall", rec.score.score * 100))
                        line(
                            "Factor mix",
                            String(
                                format: "avail %.0f · turnover %.0f · travel %.0f · walk %.0f · loadBal %.0f · conf %.0f",
                                b.availability,
                                b.turnover,
                                b.travelTime,
                                b.walkDistance,
                                b.loadBalance,
                                b.confidence ?? 0
                            )
                        )
                        if let congestion = b.congestion {
                            line("Congestion", String(format: "%.0f", congestion))
                        }
                        line(
                            "Route / walk",
                            "\(rec.route.driveMinutesText) · \(rec.route.walkMinutesText) · \(rec.route.distanceMilesText)"
                        )
                        line(
                            "Backend reasoning",
                            String(rec.reasoning.prefix(160)) + (rec.reasoning.count > 160 ? "…" : "")
                        )
                    }

                    Divider().opacity(0.35)

                    let w = remoteConfigService.config.algorithm.weights
                    line(
                        "Cfg · all weights",
                        String(
                            format: "avail %.2f · turn %.2f · travel %.2f · walk %.2f · loadBal %.2f · cong %.2f · conf %.2f",
                            w.availability,
                            w.turnover,
                            w.travelTime,
                            w.walkDistance,
                            w.loadBalance,
                            w.congestion ?? 0,
                            w.confidence ?? 0
                        )
                    )
                    let algo = remoteConfigService.config.algorithm
                    line(
                        "Cfg · algo knobs",
                        "cap/zone \(algo.estimatedCapacityPerArea) · reEval \(algo.reEvaluationIntervalSec)s · scoreΔ \(algo.scoreUpdateThreshold) · loadK \(algo.loadPenaltyK) · minUsers \(algo.confidenceMinUsers)"
                    )
                    let det = remoteConfigService.config.detection
                    line(
                        "Cfg · detection",
                        "park \(det.parkDetectionDurationSec)s / \(Int(det.parkDetectionDriftMeters)) m · depart \(det.departDetectionDurationSec)s"
                    )
                    line(
                        "Cfg search",
                        "default \(Int(remoteConfigService.config.search.defaultRadiusMeters)) m · max \(Int(remoteConfigService.config.search.maxRadiusMeters)) m · candidates \(remoteConfigService.config.search.maxCandidates) · occ \(Int(remoteConfigService.config.search.occupancyRadiusMeters)) m"
                    )
                    if let updated = remoteConfigService.lastUpdatedAt {
                        line("Cfg updated", updated.formatted(date: .omitted, time: .shortened))
                    }
                    if let cfgErr = remoteConfigService.lastErrorMessage, !cfgErr.isEmpty {
                        line("Cfg error", cfgErr)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(.horizontal, CurbyConstants.overlayPadding)
        .padding(.bottom, 120)
    }

    private var liveContextLine: String {
        let zoom = String(format: "z%.1f", mapZoom)
        let motion = "\(motionStateManager.motionState)"
        let speed = String(format: "%.1f m/s", locationService.currentSpeed)
        let acc: String = {
            let h = locationService.horizontalAccuracy
            guard h > 0 else { return "acc —" }
            return String(format: "±%.0fm", h)
        }()
        return "\(zoom) · \(motion) · \(speed) · \(acc)"
    }

    private var mapLegendLine: String {
        "yellow dots · POI centroids in fence · white fan→POIs · pink POI→Nav · cyan you→dest · yellow line you→pick · orange ±GPS · purple 45m WS · green 120m pick · teal 120m dest · no geofence fill (ring only)"
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gpsQualityLine(for loc: CLLocation) -> String {
        let acc = max(0, loc.horizontalAccuracy)
        let spd = max(0, loc.speed)
        let coursePart: String = {
            guard loc.course >= 0 else { return "course —" }
            return String(format: "course %.0f°", loc.course)
        }()
        return String(format: "±%.0f m · %.1f m/s · %@", acc, spd, coursePart)
    }
}

private extension CurbyParkingSearchStatus {
    var developerSummaryLine: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting…"
        case .searching:
            return "searching…"
        case .recommended:
            return "recommended"
        case .noData(let message):
            return "no_data: \(message)"
        case .error(let message):
            return "error: \(message)"
        case .arrived:
            return "arrived"
        }
    }
}

private struct WebSocketOriginMapPin: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("WS")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 18)
                .background(Color.purple.opacity(0.92), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text("session origin")
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.55), lineWidth: 1)
        }
        .accessibilityLabel("WebSocket session origin")
    }
}

private struct NavigationAnchorMapPin: View {
    let areaName: String

    var body: some View {
        VStack(spacing: 2) {
            Text("Nav")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 16)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(areaName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 96)
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Routable navigation point for \(areaName)")
    }
}

private struct DestinationMapPin: View {
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "mappin")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(CurbyGlass.destinationTint, in: Circle())

                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .curbyGlassSurface(tint: CurbyGlass.destinationTint, cornerRadius: 18)

            Triangle()
                .fill(CurbyGlass.destinationTint)
                .frame(width: 10, height: 6)
                .rotationEffect(.degrees(180))
                .offset(y: -1)
        }
    }
}

private struct RecommendationMapPin: View {
    let recommendation: CurbyParkingRecommendation
    let isArrived: Bool
    var developerMode: Bool = false

    private var pinTint: Color { isArrived ? CurbyGlass.successTint : CurbyGlass.primaryTint }

    var body: some View {
        VStack(spacing: 2) {
            // "Best Match" badge sits above the balloon
            if !isArrived {
                Text("Best Match")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(pinTint, in: Capsule())
                    .shadow(color: pinTint.opacity(0.3), radius: 4, y: 2)
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "p.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pinTint, in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(recommendation.area.categoryLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text(recommendation.area.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if developerMode {
                            Text(developerScoreLine)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(developerRouteLine)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .curbyGlassSurface(tint: pinTint, cornerRadius: 18)
                .shadow(color: pinTint.opacity(0.22), radius: 10, y: 5)

                Triangle()
                    .fill(pinTint)
                    .frame(width: 10, height: 6)
                    .rotationEffect(.degrees(180))
                    .offset(y: -1)
            }
        }
    }

    private var developerScoreLine: String {
        let b = recommendation.score.breakdown
        return String(
            format: "Score %.0f%% · loadBal %.0f · travel %.0f",
            recommendation.score.score * 100,
            b.loadBalance,
            b.travelTime
        )
    }

    private var developerRouteLine: String {
        "\(recommendation.route.driveMinutesText) · \(recommendation.route.walkMinutesText)"
    }
}

private struct LiveParkingAreaMapPin: View {
    let area: LiveParkingArea
    let isSelected: Bool
    var showLabel: Bool = true
    var developerLabels: Bool = false

    var body: some View {
        if isSelected || showLabel {
            // Full labeled balloon
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: sfSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(tint, in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(kindLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text(area.mapLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if developerLabels {
                            Text(developerSubtitle)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .curbyGlassSurface(tint: isSelected ? tint : nil, cornerRadius: 18)
                .shadow(color: (isSelected ? tint : .black).opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 8 : 4, y: isSelected ? 4 : 2)

                Triangle()
                    .fill(isSelected ? tint : Color.gray.opacity(0.5))
                    .frame(width: 10, height: 6)
                    .rotationEffect(.degrees(180))
                    .offset(y: -1)
            }
        } else {
            // Compact dot — visible when zoomed out
            ZStack {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Circle()
                            .strokeBorder(tint, lineWidth: 2.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                Image(systemName: sfSymbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
    }

    private var sfSymbol: String {
        switch area.kind {
        case .garage:  return "building.2.fill"
        case .lot:     return "square.dashed"
        case .street:  return "road.lanes"
        case .general: return "p.circle.fill"
        }
    }

    private var kindLabel: String {
        switch area.kind {
        case .garage: return "Garage"
        case .lot: return "Lot"
        case .street: return "Street"
        case .general: return "Parking"
        }
    }

    private var kindInitial: String {
        switch area.kind {
        case .garage: return "G"
        case .lot: return "L"
        case .street: return "S"
        case .general: return "P"
        }
    }

    private var developerSubtitle: String {
        var parts: [String] = []
        if let meters = area.destinationDistanceMeters {
            parts.append(String(format: "Δ dest %.0f m", meters))
        } else if let meters = area.distanceMeters {
            parts.append(String(format: "prox %.0f m", meters))
        }
        if !area.categoryIDs.isEmpty {
            parts.append(area.categoryIDs.prefix(2).joined(separator: ","))
        }
        parts.append(String(area.id.prefix(10)))
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch area.kind {
        case .garage:
            return CurbyGlass.primaryTint
        case .lot:
            return CurbyGlass.warningTint
        case .street:
            return CurbyGlass.successTint
        case .general:
            return CurbyGlass.destinationTint
        }
    }
}

// MARK: - Preview

// MARK: - Place Map Pin (popular locations on browse map)

private struct PlaceMapPin: View {
    let place: PopularLocation
    var showLabel: Bool = true

    var body: some View {
        if showLabel {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: place.sfSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(tint, in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(place.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .curbyGlassSurface(cornerRadius: 18)
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)

                Triangle()
                    .fill(tint.opacity(0.6))
                    .frame(width: 10, height: 6)
                    .rotationEffect(.degrees(180))
                    .offset(y: -1)
            }
        } else {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .strokeBorder(tint, lineWidth: 2.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                Image(systemName: place.sfSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    private var tint: Color {
        HeatZoneGeometry.color(for: place.busyLevel)
    }
}

// MARK: - Hover popup ("you're in [place]" prompt above the map)

private struct HoverPlacePopup: View {
    let place: PopularLocation
    let onTap: (PopularLocation) -> Void

    var body: some View {
        Button {
            onTap(place)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: place.sfSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("You're in \(place.name)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Tap to see parking & busy areas")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .curbyGlassSurface(cornerRadius: 22)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        HeatZoneGeometry.color(for: place.busyLevel)
    }
}

#Preview {
    MainNavigationView()
}
// MARK: - Saved park pin (manual Supabase `active_parks`)

private struct SavedParkPinState: Equatable {
    let coordinate: CLLocationCoordinate2D
    let title: String

    static func == (lhs: SavedParkPinState, rhs: SavedParkPinState) -> Bool {
        lhs.title == rhs.title
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

private struct SavedParkMapPin: View {
    let title: String

    @State private var pulse = false

    private var tint: Color { .orange }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    // Pulsing halo so the pin is unmistakable on a busy map.
                    Circle()
                        .stroke(tint.opacity(0.45), lineWidth: 3)
                        .frame(width: 38, height: 38)
                        .scaleEffect(pulse ? 1.4 : 1.0)
                        .opacity(pulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                            value: pulse
                        )

                    Image(systemName: "car.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .frame(width: 32, height: 32)
                        .background(tint.gradient, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Car")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .curbyGlassSurface(tint: tint, cornerRadius: 22)
            .shadow(color: tint.opacity(0.35), radius: 10, y: 4)

            Triangle()
                .fill(tint)
                .frame(width: 12, height: 7)
                .rotationEffect(.degrees(180))
                .offset(y: -1)
        }
        .onAppear { pulse = true }
    }
}
