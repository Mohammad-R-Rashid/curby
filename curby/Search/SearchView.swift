//
//  SearchView.swift
//  curby
//
//  Bottom sheet content — contextual search, destination, and heat zones.
//

import MapKit
import PhosphorSwift
import SwiftUI

/// Sheet content that fully adapts based on app state.
///
/// - **No destination**: Search bar + Places + Recents (Apple Maps style)
/// - **Destination selected**: Destination card + Navigate button + Parking Zones
/// - Typing always shows geocoding results
struct SearchView: View {

    @Bindable var searchState: SearchState
    let heatZoneManager: HeatZoneManager
    /// Shown when the map is in free-explore mode (user panned away from follow).
    var showRecenterButton: Bool = false
    var onRecenter: (() -> Void)?
    let onDestinationSelected: (SelectedDestination) -> Void
    let onZoneSelected: (HeatZone) -> Void
    let onClearDestination: () -> Void

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
                        searchResultsSection
                    } else if let dest = searchState.selectedDestination {
                        // DESTINATION MODE — destination summary lives in the search bar
                        navigateButton(dest)

                        if heatZoneManager.isLoading {
                            loadingIndicator
                        } else if !heatZoneManager.heatZones.isEmpty {
                            heatZonesSection
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
        }
    }

    // MARK: - Search Bar (Liquid Glass)

    private var searchBar: some View {
        GlassEffectContainer(spacing: CurbyGlass.chromeSpacing) {
            HStack(spacing: 12) {
                Ph.magnifyingGlass.regular
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(CurbyGlass.primaryTint)
                    .frame(width: 17, height: 17)

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

                        if showRecenterButton {
                            barAccessoryButton(
                                icon: .crosshairSimple,
                                tint: CurbyGlass.primaryTint,
                                accessibilityLabel: "Recenter map on your location"
                            ) {
                                onRecenter?()
                            }
                        }

                        barAccessoryButton(
                            icon: .x,
                            tint: .secondary,
                            accessibilityLabel: "Clear destination"
                        ) {
                            searchState.clearDestination()
                            onClearDestination()
                        }
                    }
                } else {
                    // Search mode — text field
                    TextField("Where to?", text: $searchState.searchText)
                        .font(.system(size: 17))
                        .focused($isSearchFocused)
                        .onChange(of: searchState.searchText) { _, _ in
                            searchState.isSearchActive = true
                            searchState.onSearchTextChanged()
                        }

                    if !searchState.searchText.isEmpty {
                        barAccessoryButton(
                            icon: .x,
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
                            icon: .crosshairSimple,
                            tint: CurbyGlass.primaryTint,
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .curbyGlassSurface(cornerRadius: CurbyGlass.barCornerRadius)
        }
    }

    // MARK: - Navigate Button (Liquid Glass)

    private func navigateButton(_ dest: SelectedDestination) -> some View {
        Button {
            openInMaps(coordinate: dest.coordinate, name: dest.name)
        } label: {
            HStack(spacing: 8) {
                Ph.navigationArrow.fill
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)

                Text("Navigate")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(CurbyGlass.primaryTint)
        .padding(.horizontal, 16)
    }

    // MARK: - Search Results

    private var searchResultsSection: some View {
        VStack(spacing: 2) {
            ForEach(searchState.searchResults) { result in
                Button {
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
                                .fill(CurbyGlass.primaryTint.opacity(0.16))
                                .frame(width: 36, height: 36)

                            Ph.mapPin.fill
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundStyle(CurbyGlass.primaryTint)
                                .frame(width: 15, height: 15)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)

                            Text(result.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Ph.caretRight.bold
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.tertiary)
                            .frame(width: 11, height: 11)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .curbyGlassSurface(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    // MARK: - Heat Zones Section

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(CurbyGlass.primaryTint)
                .scaleEffect(0.7)
            Text("Finding parking zones…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .curbyGlassSurface(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    private var heatZonesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Parking Zones", icon: .mapPinArea)

            VStack(spacing: 8) {
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
        HStack(spacing: 14) {
            // Busy level color bar
            RoundedRectangle(cornerRadius: 3)
                .fill(HeatZoneGeometry.color(for: zone.busyLevel))
                .frame(width: 4, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(zone.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(zone.parkingSpots.count) spots")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10))

                    Text("Score: \(zone.busyScore)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HeatZoneGeometry.color(for: zone.busyLevel))
                }
            }

            Spacer()

            // Badge
            Text(zone.busyLevel.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(HeatZoneGeometry.color(for: zone.busyLevel))
                )

            Ph.caretRight.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tertiary)
                .frame(width: 11, height: 11)
        }
        .padding(14)
        .curbyGlassSurface(
            tint: HeatZoneGeometry.color(for: zone.busyLevel),
            cornerRadius: CurbyGlass.compactCornerRadius
        )
    }

    // MARK: - Places Section (Liquid Glass circles)

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Places", icon: .mapPinArea)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(PopularLocation.austinLocations) { location in
                        Button {
                            searchState.selectDestination(
                                name: location.name,
                                subtitle: location.subtitle,
                                coordinate: location.coordinate
                            )
                            if let dest = searchState.selectedDestination {
                                onDestinationSelected(dest)
                            }
                        } label: {
                            placeCircle(location: location)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func placeCircle(location: PopularLocation) -> some View {
        VStack(spacing: 6) {
            location.icon.regular
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(HeatZoneGeometry.color(for: location.busyLevel))
                .frame(width: 26, height: 26)
                .frame(width: 56, height: 56)
                .glassEffect(
                    .regular.tint(HeatZoneGeometry.color(for: location.busyLevel).opacity(0.18)),
                    in: .circle
                )
                .overlay {
                    Circle()
                        .strokeBorder(CurbyGlass.outline, lineWidth: 0.75)
                }

            Text(location.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 70)

            Circle()
                .fill(HeatZoneGeometry.color(for: location.busyLevel))
                .frame(width: 5, height: 5)
        }
    }

    // MARK: - Recents Section

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Recents", icon: .clockCounterClockwise)

            VStack(spacing: 2) {
                ForEach(searchState.recentDestinations) { recent in
                    Button {
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

                                Ph.clockCounterClockwise.regular
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(recent.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(recent.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Ph.dotsThree.bold
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 16)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 6)
            .curbyGlassSurface(cornerRadius: 18)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Helpers

    private func barAccessoryButton(
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
                .frame(width: 17, height: 17)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func sectionHeader(title: String, icon: Ph) -> some View {
        HStack(spacing: 6) {
            icon.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(CurbyGlass.primaryTint)
                .frame(width: 15, height: 15)

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

            Ph.caretRight.bold
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
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
    SearchView(
        searchState: SearchState(),
        heatZoneManager: HeatZoneManager(),
        showRecenterButton: true,
        onRecenter: {},
        onDestinationSelected: { _ in },
        onZoneSelected: { _ in },
        onClearDestination: { }
    )
}
