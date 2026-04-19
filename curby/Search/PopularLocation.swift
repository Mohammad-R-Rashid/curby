//
//  PopularLocation.swift
//  curby
//
//  Model and mock data for popular/busy locations near the user.
//

import CoreLocation
import Foundation
import PhosphorSwift

/// A well-known location where parking is competitive.
struct PopularLocation: Identifiable, Hashable {
    let id: UUID
    let name: String
    let icon: Ph
    let coordinate: CLLocationCoordinate2D
    let busyLevel: BusyLevel
    let subtitle: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PopularLocation, rhs: PopularLocation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Mock Data (Austin, TX)

extension PopularLocation {

    /// Hardcoded popular locations in Austin, TX.
    /// Future: fetched from API based on user's city.
    static let austinLocations: [PopularLocation] = [
        PopularLocation(
            id: UUID(),
            name: "Downtown Austin",
            icon: .buildings,
            coordinate: CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431),
            busyLevel: .veryBusy,
            subtitle: "6th Street & Congress"
        ),
        PopularLocation(
            id: UUID(),
            name: "West Campus",
            icon: .graduationCap,
            coordinate: CLLocationCoordinate2D(latitude: 30.2849, longitude: -97.7514),
            busyLevel: .veryBusy,
            subtitle: "Near UT Austin"
        ),
        PopularLocation(
            id: UUID(),
            name: "UT Campus",
            icon: .bookOpen,
            coordinate: CLLocationCoordinate2D(latitude: 30.2862, longitude: -97.7394),
            busyLevel: .busy,
            subtitle: "University of Texas"
        ),
        PopularLocation(
            id: UUID(),
            name: "The Domain",
            icon: .bag,
            coordinate: CLLocationCoordinate2D(latitude: 30.4021, longitude: -97.7253),
            busyLevel: .busy,
            subtitle: "Shopping & Dining"
        ),
        PopularLocation(
            id: UUID(),
            name: "South Congress",
            icon: .storefront,
            coordinate: CLLocationCoordinate2D(latitude: 30.2487, longitude: -97.7489),
            busyLevel: .busy,
            subtitle: "SoCo District"
        ),
        PopularLocation(
            id: UUID(),
            name: "Mueller",
            icon: .leaf,
            coordinate: CLLocationCoordinate2D(latitude: 30.2990, longitude: -97.7056),
            busyLevel: .open,
            subtitle: "Mueller Development"
        ),
        PopularLocation(
            id: UUID(),
            name: "Zilker Park",
            icon: .tree,
            coordinate: CLLocationCoordinate2D(latitude: 30.2669, longitude: -97.7729),
            busyLevel: .busy,
            subtitle: "Barton Springs Area"
        ),
        PopularLocation(
            id: UUID(),
            name: "East 6th",
            icon: .musicNotes,
            coordinate: CLLocationCoordinate2D(latitude: 30.2638, longitude: -97.7284),
            busyLevel: .veryBusy,
            subtitle: "East Side Entertainment"
        )
    ]
}
