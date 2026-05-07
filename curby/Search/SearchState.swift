//
//  SearchState.swift
//  curby
//
//  Search logic — manages text input, Mapbox SearchBox forward geocoding,
//  and recents. Proximity-biased: results are ranked relative to the map
//  center the user is looking at (or their current location as fallback).
//

import CoreLocation
import Foundation
import Observation

/// A saved destination for the recents list.
struct RecentDestination: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Mapbox forward decoder

private struct MapboxForwardResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let geometry: Geometry?
        let properties: Properties

        struct Geometry: Decodable {
            let coordinates: [Double]
        }

        struct Properties: Decodable {
            let name: String?
            let placeFormatted: String?
            let featureType: String?
            let mapboxID: String?

            private enum CodingKeys: String, CodingKey {
                case name
                case placeFormatted = "place_formatted"
                case featureType = "feature_type"
                case mapboxID = "mapbox_id"
            }
        }
    }
}

/// Manages search text, geocoding results (OpenStreetMap Nominatim), and recent destinations.
@Observable
final class SearchState {

    // MARK: - State

    /// Current search text.
    var searchText: String = ""

    /// Whether the search field is active (keyboard visible).
    var isSearchActive: Bool = false

    /// Geocoding results (Nominatim / OSM).
    private(set) var searchResults: [SearchResult] = []

    /// Loading state for geocoding.
    private(set) var isSearching: Bool = false

    /// Recently searched destinations.
    private(set) var recentDestinations: [RecentDestination] = []

    /// The selected destination (triggers navigation to map).
    var selectedDestination: SelectedDestination?

    /// User's current location for proximity-biased ordering.
    var userLocation: CLLocationCoordinate2D?

    /// Map center the user is currently looking at. Preferred over
    /// `userLocation` for proximity bias when set, since it reflects what
    /// the user is exploring rather than where they physically are.
    /// Observation-ignored — set frequently from camera changes; we don't
    /// want every keystroke-irrelevant map pan to trigger a SearchView
    /// recompute.
    @ObservationIgnored var mapCenter: CLLocationCoordinate2D?

    // MARK: - Private

    private var searchTask: Task<Void, Never>?
    private static let recentsKey = "curby_recent_destinations"

    // MARK: - Init

    init() {
        loadRecents()
    }

    // MARK: - Search

    /// Called when search text changes. Debounces and queries Mapbox
    /// SearchBox forward, biased toward the map center the user is looking at.
    func onSearchTextChanged() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let proximity = mapCenter ?? userLocation

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(CurbyConstants.searchDebounceInterval * 1000)))
            guard !Task.isCancelled else { return }

            let results = await geocodeMapbox(query: query, proximity: proximity)
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    // MARK: - Mapbox SearchBox forward

    private func geocodeMapbox(
        query: String,
        proximity: CLLocationCoordinate2D?
    ) async -> [SearchResult] {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              !token.isEmpty
        else { return [] }

        var components = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/forward")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "limit", value: "10"),
            // Mix area-scale (neighborhood/locality/district/place) with
            // specific destinations (address/street/poi) so a single call
            // covers both Hotspots and Locations downstream.
            URLQueryItem(name: "types", value: "neighborhood,locality,district,place,address,street,poi"),
        ]
        if let proximity {
            queryItems.append(URLQueryItem(
                name: "proximity",
                value: "\(proximity.longitude),\(proximity.latitude)"
            ))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else { return [] }

            let decoded = try JSONDecoder().decode(MapboxForwardResponse.self, from: data)

            var seenIDs = Set<String>()
            var results: [SearchResult] = []
            results.reserveCapacity(decoded.features.count)

            for feature in decoded.features {
                guard let coords = feature.geometry?.coordinates,
                      coords.count >= 2 else { continue }
                let coordinate = CLLocationCoordinate2D(
                    latitude: coords[1],
                    longitude: coords[0]
                )
                let id = feature.properties.mapboxID ?? UUID().uuidString
                guard seenIDs.insert(id).inserted else { continue }

                let name = (feature.properties.name?.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? "Untitled"
                let subtitle = feature.properties.placeFormatted ?? ""

                results.append(
                    SearchResult(
                        id: UUID(),
                        name: name,
                        subtitle: subtitle,
                        coordinate: coordinate,
                        featureType: feature.properties.featureType
                    )
                )
            }

            return results
        } catch {
            print("[SearchState] Mapbox forward error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Selection

    func selectDestination(name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {

        let destination = SelectedDestination(
            name: name,
            subtitle: subtitle,
            coordinate: coordinate
        )
        selectedDestination = destination
        addToRecents(name: name, subtitle: subtitle, coordinate: coordinate)
        isSearchActive = false
        searchText = ""
        searchResults = []
    }

    /// Clear the selected destination (go back to search).
    func clearDestination() {
        selectedDestination = nil
    }

    // MARK: - Recents

    private func addToRecents(name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        // Remove duplicates
        recentDestinations.removeAll { $0.name == name }

        let recent = RecentDestination(
            id: UUID(),
            name: name,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: Date()
        )

        recentDestinations.insert(recent, at: 0)

        // Trim to max
        if recentDestinations.count > CurbyConstants.maxRecentDestinations {
            recentDestinations = Array(recentDestinations.prefix(CurbyConstants.maxRecentDestinations))
        }

        saveRecents()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let decoded = try? JSONDecoder().decode([RecentDestination].self, from: data)
        else { return }
        recentDestinations = decoded
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recentDestinations) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentsKey)
    }
}

// MARK: - Search Result

/// A single geocoding result.
struct SearchResult: Identifiable, Hashable {
    let id: UUID
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    /// Mapbox `feature_type` — drives downstream sectioning (Hotspots vs
    /// Locations) and the mode handoff (area-scale picks open Explore mode;
    /// addresses/POIs open Destination mode).
    let featureType: String?

    init(id: UUID, name: String, subtitle: String, coordinate: CLLocationCoordinate2D, featureType: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.featureType = featureType
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Selected Destination

/// The user's chosen destination — triggers map view with heat zones.
struct SelectedDestination: Hashable {
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(subtitle)
    }

    static func == (lhs: SelectedDestination, rhs: SelectedDestination) -> Bool {
        lhs.name == rhs.name && lhs.subtitle == rhs.subtitle
    }
}
