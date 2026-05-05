//
//  SearchState.swift
//  curby
//
//  Search logic — manages text input, OSM Nominatim geocoding, and recents.
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

private struct NominatimSearchItem: Decodable {
    let lat: String
    let lon: String
    let displayName: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case lat, lon, name
        case displayName = "display_name"
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

    // MARK: - Private

    private var searchTask: Task<Void, Never>?
    private static let recentsKey = "curby_recent_destinations"

    // MARK: - Init

    init() {
        loadRecents()
    }

    // MARK: - Search

    /// Called when search text changes. Debounces and queries Nominatim.
    func onSearchTextChanged() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(CurbyConstants.searchDebounceInterval * 1000)))
            guard !Task.isCancelled else { return }

            let results = await geocodeNominatim(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    // MARK: - Nominatim (OpenStreetMap)

    private func geocodeNominatim(query: String) async -> [SearchResult] {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "countrycodes", value: "us"),
        ]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(CurbyConstants.nominatimUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else { return [] }

            let items = try JSONDecoder().decode([NominatimSearchItem].self, from: data)

            var seen = Set<String>()
            var results: [SearchResult] = []
            results.reserveCapacity(items.count)

            for item in items {
                guard let lat = Double(item.lat),
                      let lon = Double(item.lon)
                else { continue }

                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                let key = String(format: "%.4f,%.4f", lat, lon)
                guard seen.insert(key).inserted else { continue }

                let primary = (item.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? primaryName(from: item.displayName)

                let subtitle = subtitleFromDisplayName(item.displayName, excludingPrimary: primary)

                results.append(
                    SearchResult(
                        id: UUID(),
                        name: primary,
                        subtitle: subtitle,
                        coordinate: coordinate
                    )
                )
            }

            // Keep Nominatim relevance order (do not re-sort by distance — hurts ranking for partial queries).
            return Array(results.prefix(10))
        } catch {
            print("[SearchState] Nominatim error: \(error.localizedDescription)")
            return []
        }
    }

    private func primaryName(from displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else { return trimmed }
        return String(trimmed[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subtitleFromDisplayName(_ displayName: String, excludingPrimary primary: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(primary + ",") {
            let rest = trimmed.dropFirst(primary.count).drop(while: { $0 == "," || $0 == " " })
            return String(rest)
        }
        return trimmed
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
