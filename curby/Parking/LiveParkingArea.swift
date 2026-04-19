//
//  LiveParkingArea.swift
//  curby
//
//  Real parking POIs loaded from Mapbox Search Box category search.
//

import CoreLocation
import Foundation

enum LiveParkingAreaKind: String, Codable, Hashable {
    case garage
    case lot
    case street
    case general
}

struct LiveParkingArea: Identifiable, Hashable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let navigationCoordinate: CLLocationCoordinate2D
    let address: String
    let fullAddress: String
    let placeFormatted: String
    let phone: String?
    let website: String?
    let openHoursText: [String]
    let categoryIDs: [String]
    let distanceMeters: Double?
    let destinationDistanceMeters: Double?
    let kind: LiveParkingAreaKind

    var detailSubtitle: String {
        if !address.isEmpty {
            return address
        }
        if !placeFormatted.isEmpty {
            return placeFormatted
        }
        return "Austin, Texas"
    }

    var distanceText: String {
        guard let effectiveDistanceMeters else { return "Nearby" }

        let miles = effectiveDistanceMeters / CurbyConstants.metersPerMile
        if miles < 0.15 {
            return "\(Int((effectiveDistanceMeters * 3.28084).rounded())) ft"
        }
        return String(format: "%.1f mi", miles)
    }

    var effectiveDistanceMeters: Double? {
        destinationDistanceMeters ?? distanceMeters
    }

    /// Rough walk time from the trip destination to this spot (when distance is known).
    var estimatedWalkMinutesFromDestination: Int? {
        guard let meters = destinationDistanceMeters, meters > 0 else { return nil }
        // ~1.35 m/s average walking pace
        return max(1, Int((meters / 1.35 / 60).rounded()))
    }

    var primaryHoursText: String? {
        openHoursText.first
    }

    var displayName: String {
        if prefersStreetLabel, let streetLabel {
            return streetLabel
        }
        return name
    }

    var subtitleText: String? {
        if prefersStreetLabel, name != displayName, !isGenericParkingName {
            return name
        }

        let subtitle = detailSubtitle
        if !subtitle.isEmpty, subtitle != displayName {
            return subtitle
        }

        return nil
    }

    var mapLabel: String {
        if let shortStreetLabel, prefersStreetLabel {
            return shortStreetLabel
        }
        return displayName
    }

    var streetLabel: String? {
        Self.cleanedStreetLabel(from: address) ?? Self.cleanedStreetLabel(from: fullAddress)
    }

    private var shortStreetLabel: String? {
        guard let streetLabel else { return nil }
        let words = streetLabel.split(separator: " ")
        guard words.count > 3 else { return streetLabel }
        return words.prefix(3).joined(separator: " ")
    }

    private var prefersStreetLabel: Bool {
        kind == .street || isGenericParkingName
    }

    private var isGenericParkingName: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "parking" ||
            normalized == "public parking" ||
            normalized == "parking lot" ||
            normalized.hasPrefix("parking ") ||
            normalized.hasSuffix(" parking")
    }

    static func kind(forName name: String, categoryIDs: [String] = []) -> LiveParkingAreaKind {
        let normalizedCategories = categoryIDs.map { $0.lowercased() }
        if normalizedCategories.contains(where: { $0.contains("garage") }) {
            return .garage
        }
        if normalizedCategories.contains(where: { $0.contains("lot") }) {
            return .lot
        }
        if normalizedCategories.contains(where: { $0.contains("meter") || $0.contains("street") || $0.contains("curb") }) {
            return .street
        }

        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("garage") {
            return .garage
        }
        if normalized.contains("lot") || normalized.contains("surface") {
            return .lot
        }
        if normalized.contains("street") || normalized.contains("meter") || normalized.contains("curb") {
            return .street
        }
        if
            normalized.contains("public parking") ||
            normalized.hasPrefix("parking ") ||
            normalized.hasSuffix(" parking") ||
            normalized == "parking"
        {
            return .street
        }
        return .general
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LiveParkingArea, rhs: LiveParkingArea) -> Bool {
        lhs.id == rhs.id
    }

    private static func cleanedStreetLabel(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let head = trimmed.split(separator: ",").first.map(String.init) ?? trimmed
        let stripped = head.replacingOccurrences(
            of: #"^\d+[A-Za-z\-]*\s+"#,
            with: "",
            options: .regularExpression
        )
        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
