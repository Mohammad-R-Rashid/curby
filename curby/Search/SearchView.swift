//
//  SearchView.swift
//  curby
//
//  Bottom sheet content — contextual search, destination, and heat zones.
//

import MapKit
import SwiftUI

/// Sheet content that fully adapts based on app state.
///
/// - **No destination**: Search bar + Hotspots + Recents (Apple Maps style)
/// - **Destination selected**: Destination card + Navigate button + Parking Zones
/// - Typing always shows geocoding results
struct SearchView: View {

    @Bindable var searchState: SearchState
    let parkingAreaManager: ParkingAreaManager
    let parkingSearchManager: ParkingWebSocketManager
    let parkingEventDetector: ParkingEventDetector
    /// Place the user is browsing (no destination set). Drives the Explore-mode UI.
    var exploredPlace: PopularLocation?
    /// Dynamic landmark/area places, owned by DynamicPlacesService in the
    /// parent view and passed in here.
    var dynamicPlaces: [PopularLocation] = []
    /// Coordinate to use for suggesting local places (updates as map pans)
    var mapCenter: CLLocationCoordinate2D?
    /// Shown when the map is in free-explore mode (user panned away from follow).
    var showRecenterButton: Bool = false
    var onRecenter: (() -> Void)?
    var onMarkAsParked: (() -> Void)?
    var parkSaveState: ParkSaveState = .idle
    let onDestinationSelected: (SelectedDestination) -> Void
    let onParkingAreaSelected: (LiveParkingArea) -> Void
    /// Tapping a Place card / pin enters Explore mode instead of routing.
    var onPlaceExplored: ((PopularLocation) -> Void)?
    var onExitExplore: (() -> Void)?
    let onClearDestination: () -> Void
    /// Widen walking geofence when Mapbox returns no POIs in the current radius.
    var onExpandWalkingRadius: (() -> Void)?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search Bar (always visible)
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.3)

            // MARK: - Scrollable Content
            ScrollView {
                VStack(spacing: 20) {
                    // Active search results (always priority)
                    if searchState.isSearchActive && !searchState.searchText.isEmpty {
                        activeSearchContent
                    } else if let dest = searchState.selectedDestination {
                        // DESTINATION MODE — destination summary lives in the search bar.
                        //
                        // Navigate-to-destination is dropped from this row when an active
                        // parking recommendation exists, because UnifiedRecommendationCard
                        // below already renders Navigate-to-parking — two identical-looking
                        // "Navigate" buttons going to different places was confusing.
                        let hasActiveRec = parkingSearchManager.activeRecommendation != nil
                        MinimalActionButtonRow(
                            onNavigate: hasActiveRec ? nil : {
                                openInMaps(coordinate: dest.coordinate, name: dest.name)
                            },
                            onMarkAsParked: hasActiveRec ? { onMarkAsParked?() } : nil,
                            parkSaveState: parkSaveState
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                        liveParkingSection

                        if parkingAreaManager.isLoading {
                            areaLoadingIndicator
                        } else if !parkingAreaManager.areas.isEmpty {
                            nearbyParkingSection
                        } else if parkingAreaManager.noParkingInGeofence {
                            noParkingInRadiusSection
                        } else if let error = parkingAreaManager.lastErrorMessage {
                            MinimalStatusCard(
                                title: "Nearby parking unavailable",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: CurbyGlass.destinationTint,
                                detail: error
                            )
                        }
                    } else if let place = exploredPlace {
                        // EXPLORE MODE — browsing parking near a place, no routing.
                        exploringHeader(for: place)

                        if parkingAreaManager.isLoading {
                            areaLoadingIndicator
                        } else if !parkingAreaManager.areas.isEmpty {
                            nearbyParkingSection
                        } else if parkingAreaManager.noParkingInGeofence {
                            noParkingInRadiusSection
                        } else if let error = parkingAreaManager.lastErrorMessage {
                            MinimalStatusCard(
                                title: "Nearby parking unavailable",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: CurbyGlass.destinationTint,
                                detail: error
                            )
                        }
                    } else {
                        // SEARCH MODE — show places + recents
                        placesSection

                        if !searchState.recentDestinations.isEmpty {
                            recentsSection
                        }
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private var activeSearchContent: some View {
        let query = searchState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchState.isSearching && searchState.searchResults.isEmpty {
            searchLoadingPlaceholder
        } else if searchState.searchResults.isEmpty {
            searchEmptyPlaceholder(queryLength: query.count)
        } else {
            searchResultsSection
        }
    }

    private var searchLoadingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(CurbyGlass.primaryTint)
                .scaleEffect(1.05)
            Text("Searching places…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .curbyGlassSurface(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    private func searchEmptyPlaceholder(queryLength: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(queryLength < 2 ? "Keep typing" : "No matches in this area")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            Text(
                queryLength < 2
                    ? "Enter at least two characters to search streets, places, and businesses."
                    : "Try a street name, neighborhood, business, or landmark."
            )
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .curbyGlassSurface(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    // MARK: - Search Bar (Liquid Glass)

    private var searchBar: some View {
        GlassEffectContainer(spacing: CurbyGlass.chromeSpacing) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)

                if let dest = searchState.selectedDestination, !searchState.isSearchActive {
                    // Destination mode — name + subtitle in the bar (no duplicate header card)
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dest.name)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if !dest.subtitle.isEmpty {
                                Text(dest.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        if showRecenterInDestinationBar {
                            destinationRecenterButton
                        }

                        barAccessoryButton(
                            systemImage: "xmark.circle.fill",
                            tint: .secondary,
                            accessibilityLabel: "Clear destination"
                        ) {
                            searchState.clearDestination()
                            onClearDestination()
                        }
                    }
                } else {
                    // Search mode — text field
                    TextField("Search Maps", text: $searchState.searchText)
                        .font(.system(size: 17))
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            searchState.onSearchTextChanged()
                        }
                        .onChange(of: searchState.searchText) { _, _ in
                            searchState.isSearchActive = true
                            searchState.onSearchTextChanged()
                        }

                    if !searchState.searchText.isEmpty {
                        barAccessoryButton(
                            systemImage: "xmark.circle.fill",
                            tint: .secondary,
                            accessibilityLabel: "Clear search"
                        ) {
                            searchState.searchText = ""
                            searchState.isSearchActive = false
                            isSearchFocused = false
                        }
                    }

                    if showRecenterButton {
                        barAccessoryButton(
                            systemImage: "location.north.fill",
                            tint: .primary,
                            accessibilityLabel: "Recenter map on your location"
                        ) {
                            onRecenter?()
                        }
                    }

                    if searchState.isSearching {
                        ProgressView()
                            .tint(CurbyGlass.primaryTint)
                            .scaleEffect(0.8)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay(Capsule().strokeBorder(CurbyGlass.outline, lineWidth: 0.75))
        }
    }

    /// After a destination is pinned in the sheet, always offer “snap back to me” with a standard location icon.
    private var showRecenterInDestinationBar: Bool {
        showRecenterButton || (searchState.selectedDestination != nil && !searchState.isSearchActive)
    }

    private var destinationRecenterButton: some View {
        Button {
            CurbyHaptics.light()
            onRecenter?()
        } label: {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CurbyGlass.primaryTint)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map on your location")
    }

    // MARK: - Search Results

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search results")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(searchState.searchResults) { result in
                    Button {
                        CurbyHaptics.selection()
                        searchState.selectDestination(
                            name: result.name,
                            subtitle: result.subtitle,
                            coordinate: result.coordinate
                        )
                        if let dest = searchState.selectedDestination {
                            onDestinationSelected(dest)
                        }
                        isSearchFocused = false
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemGray5))
                                    .frame(width: 36, height: 36)

                                Image(systemName: "mappin")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)

                                Text(result.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if result.id != searchState.searchResults.last?.id {
                        Divider()
                            .opacity(0.35)
                            .padding(.leading, 64)
                    }
                }
            }
            .curbyGlassSurface(cornerRadius: 18)

            Text("Data © OpenStreetMap contributors")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Explore Mode Header

    private func exploringHeader(for place: PopularLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: place.sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(HeatZoneGeometry.color(for: place.busyLevel), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Browsing \(place.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(place.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                CurbyHaptics.light()
                onExitExplore?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit place browsing")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Nearby Parking Section

    private var noParkingInRadiusSection: some View {
        let step = CurbyConstants.parkingSearchRadiusExpandStepMiles
        let canExpand = OnboardingState.canAddWalkingCircumferenceMiles(step)

        return VStack(alignment: .leading, spacing: 12) {
            MinimalStatusCard(
                title: "No nearby parking",
                systemImage: "exclamationmark.triangle.fill",
                tint: CurbyGlass.destinationTint,
                actionTitle: canExpand ? "Expand search" : nil,
                action: canExpand ? { onExpandWalkingRadius?() } : nil
            )
        }
    }

    private var areaLoadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(CurbyGlass.primaryTint)
                .scaleEffect(0.7)
            Text("Loading nearby parking…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .curbyGlassSurface(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    private var nearbyParkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Parking Zones", systemImage: "p.circle.fill")
            geofenceSummaryCard

            if !parkingAreaManager.streetAreas.isEmpty {
                parkingAreaGroup(
                    title: "Street Parking",
                    systemImage: "road.lanes",
                    areas: parkingAreaManager.streetAreas
                )
            }

            if !parkingAreaManager.structureAreas.isEmpty {
                parkingAreaGroup(
                    title: "Garages & Lots",
                    systemImage: "building.2.fill",
                    areas: parkingAreaManager.structureAreas
                )
            }
        }
    }

    private var geofenceSummaryCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(parkingAreaManager.areas.count) options inside \(parkingAreaManager.geofenceDistanceText)")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func parkingAreaGroup(
        title: String,
        systemImage: String,
        areas: [LiveParkingArea]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 8) {
                ForEach(areas) { area in
                    Button {
                        CurbyHaptics.selection()
                        onParkingAreaSelected(area)
                    } label: {
                        nearbyParkingCard(area)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var liveParkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Live Parking", systemImage: "location.north.fill")

            if parkingSearchManager.isSearching {
                MinimalStatusCard(
                    title: "Searching...",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: CurbyGlass.primaryTint
                )
            }

            if case .noData(_) = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "No route available",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: CurbyGlass.warningTint
                )
            }

            if case .error(_) = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "Connection issue",
                    systemImage: "wifi.exclamationmark",
                    tint: CurbyGlass.destinationTint,
                    actionTitle: "Retry"
                ) {
                    Task { await parkingSearchManager.retryCurrentSearch() }
                }
            }

            if case .arrived = parkingSearchManager.status {
                MinimalStatusCard(
                    title: "Arrived",
                    systemImage: "checkmark.circle.fill",
                    tint: CurbyGlass.successTint
                )
            }

            if let recommendation = parkingSearchManager.activeRecommendation {
                UnifiedRecommendationCard(
                    recommendation: recommendation,
                    isParked: parkingEventDetector.presenceState == .parked,
                    onNavigate: {
                        openInMaps(
                            coordinate: recommendation.area.coordinate,
                            name: recommendation.area.name
                        )
                    },
                    onCancel: {
                        Task { await parkingSearchManager.cancelSearch() }
                    },
                    onRetry: {
                        Task { await parkingSearchManager.retryCurrentSearch() }
                    }
                )
            }

            if let pendingUpdate = parkingSearchManager.pendingRouteUpdate {
                VStack(spacing: 8) {
                    MinimalStatusCard(
                        title: "Better parking found",
                        systemImage: "sparkles",
                        tint: CurbyGlass.warningTint,
                        actionTitle: "Switch"
                    ) {
                        Task { await parkingSearchManager.acceptPendingUpdate() }
                    }
                }
            }
        }
    }

    private func nearbyParkingCard(_ area: LiveParkingArea) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(pinTint(for: area).opacity(0.18))
                    .frame(width: 38, height: 38)

                Image(systemName: pinSFSymbol(for: area))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(pinTint(for: area))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(area.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle = area.subtitleText {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(kindLabel(for: area))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Distance is only meaningful when there's a real
                    // destination to walk to. In Explore mode the parking
                    // distance was being computed against the Hotspot's
                    // centroid, which the user never asked about.
                    if searchState.selectedDestination != nil {
                        Text("•")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 10))

                        Text(area.distanceText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                }
            }

            Spacer()

            Text(kindLabel(for: area))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(pinTint(for: area))
                )

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .curbyGlassSurface(
            tint: pinTint(for: area),
            cornerRadius: CurbyGlass.compactCornerRadius
        )
    }

    // MARK: - Hotspots Section (Liquid Glass circles)

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Hotspots", systemImage: "sparkles")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    let placesToDisplay = dynamicPlaces
                    ForEach(placesToDisplay) { location in
                        Button {
                            onPlaceExplored?(location)
                        } label: {
                            placeCircle(location: location)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func placeCircle(location: PopularLocation) -> some View {
        VStack(spacing: 8) {
            Image(systemName: location.sfSymbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(HeatZoneGeometry.color(for: location.busyLevel))
                .frame(width: 78, height: 78)
                .glassEffect(
                    .regular.tint(HeatZoneGeometry.color(for: location.busyLevel).opacity(0.18)),
                    in: .circle
                )
                .overlay {
                    Circle()
                        .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
                }

            Text(location.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 88)

            Circle()
                .fill(HeatZoneGeometry.color(for: location.busyLevel))
                .frame(width: 5, height: 5)
        }
    }

    // MARK: - Recents Section

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Recents", systemImage: "clock.fill")

            VStack(spacing: 2) {
                ForEach(searchState.recentDestinations) { recent in
                    Button {
                        CurbyHaptics.selection()
                        searchState.selectDestination(
                            name: recent.name,
                            subtitle: recent.subtitle,
                            coordinate: recent.coordinate
                        )
                        if let dest = searchState.selectedDestination {
                            onDestinationSelected(dest)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemGray5))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(recent.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(recent.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .curbyGlassSurface(cornerRadius: 18)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Helpers

    private func barAccessoryButton(
        systemImage: String,
        tint: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            CurbyHaptics.selection()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func pinSFSymbol(for area: LiveParkingArea) -> String {
        switch area.kind {
        case .garage:  return "building.2.fill"
        case .lot:     return "square.dashed"
        case .street:  return "road.lanes"
        case .general: return "p.circle.fill"
        }
    }

    private func pinTint(for area: LiveParkingArea) -> Color {
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

    private func kindLabel(for area: LiveParkingArea) -> String {
        switch area.kind {
        case .garage:
            return "Garage"
        case .lot:
            return "Lot"
        case .street:
            return "Street"
        case .general:
            return "Parking"
        }
    }

    private var fallbackArea: LiveParkingArea {
        LiveParkingArea(
            id: "fallback",
            name: "Parking",
            coordinate: CurbyConstants.defaultCoordinate,
            navigationCoordinate: CurbyConstants.defaultCoordinate,
            address: "",
            fullAddress: "",
            placeFormatted: "",
            phone: nil,
            website: nil,
            openHoursText: [],
            categoryIDs: [],
            distanceMeters: nil,
            destinationDistanceMeters: nil,
            kind: .general
        )
    }

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
        CurbyHaptics.light()
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

}

// MARK: - Preview

#Preview {
    let apiClient = CurbyAPIClient()
    let remoteConfig = RemoteConfigService(apiClient: apiClient)
    let parkingSearchManager = ParkingWebSocketManager(
        apiClient: apiClient,
        remoteConfigService: remoteConfig
    )
    let parkingEventDetector = ParkingEventDetector(
        apiClient: apiClient,
        remoteConfigService: remoteConfig
    )

    SearchView(
        searchState: SearchState(),
        parkingAreaManager: ParkingAreaManager(),
        parkingSearchManager: parkingSearchManager,
        parkingEventDetector: parkingEventDetector,
        showRecenterButton: true,
        onRecenter: {},
        onMarkAsParked: {},
        onDestinationSelected: { _ in },
        onParkingAreaSelected: { _ in },
        onClearDestination: { }
    )
}
