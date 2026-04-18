//
//  SearchState.swift
//  curby
//
//  Search logic — manages text input, Mapbox geocoding, and recents.
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

/// Manages search text, Mapbox geocoding results, and recent destinations.
@Observable
final class SearchState {

    // MARK: - State

    /// Current search text.
    var searchText: String = ""

    /// Whether the search field is active (keyboard visible).
    var isSearchActive: Bool = false

    /// Geocoding results from Mapbox.
    private(set) var searchResults: [SearchResult] = []

    /// Loading state for geocoding.
    private(set) var isSearching: Bool = false

    /// Recently searched destinations.
    private(set) var recentDestinations: [RecentDestination] = []

    /// The selected destination (triggers navigation to map).
    var selectedDestination: SelectedDestination?

    /// User's current location for proximity-biased search.
    var userLocation: CLLocationCoordinate2D?

    // MARK: - Private

    private var searchTask: Task<Void, Never>?
    private static let recentsKey = "curby_recent_destinations"

    /// Mapbox access token from Info.plist.
    private var mapboxToken: String? {
        Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String
    }

    // MARK: - Init

    init() {
        loadRecents()
    }

    // MARK: - Search

    /// Called when search text changes. Debounces and triggers Mapbox geocoding.
    func onSearchTextChanged() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task { @MainActor in
            // Debounce
            try? await Task.sleep(for: .milliseconds(Int(CurbyConstants.searchDebounceInterval * 1000)))
            guard !Task.isCancelled else { return }

            let results = await geocode(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    // MARK: - Mapbox Geocoding

    /// Call the Mapbox Geocoding API to find addresses/places.
    private func geocode(query: String) async -> [SearchResult] {
        guard let token = mapboxToken,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return [] }

        var urlString = "https://api.mapbox.com/geocoding/v5/mapbox.places/\(encoded).json"
        urlString += "?access_token=\(token)"
        urlString += "&limit=6"
        urlString += "&types=address,poi,neighborhood,locality,place"

        // Proximity bias — prefer results near the user
        if let loc = userLocation {
            urlString += "&proximity=\(loc.longitude),\(loc.latitude)"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else { return [] }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let features = json?["features"] as? [[String: Any]] ?? []

            return features.compactMap { feature -> SearchResult? in
                guard let center = feature["center"] as? [Double],
                      center.count == 2
                else { return nil }

                let placeName = feature["place_name"] as? String ?? ""
                let text = feature["text"] as? String ?? placeName

                // Build a clean subtitle from the full place name
                let subtitle: String
                if placeName.hasPrefix(text + ", ") {
                    subtitle = String(placeName.dropFirst(text.count + 2))
                } else {
                    subtitle = placeName
                }

                return SearchResult(
                    id: UUID(),
                    name: text,
                    subtitle: subtitle,
                    coordinate: CLLocationCoordinate2D(
                        latitude: center[1],
                        longitude: center[0]
                    )
                )
            }
        } catch {
            print("[SearchState] Geocoding error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Selection

    /// Select a destination from search results, popular locations, or recents.
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
