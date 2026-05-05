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

    /// Hardcoded popular locations in the Bay Area, CA.
    static let bayAreaLocations: [PopularLocation] = [
        PopularLocation(
            id: UUID(),
            name: "Downtown SF",
            icon: .buildings,
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            busyLevel: .veryBusy,
            subtitle: "Financial District"
        ),
        PopularLocation(
            id: UUID(),
            name: "Stanford",
            icon: .graduationCap,
            coordinate: CLLocationCoordinate2D(latitude: 37.4275, longitude: -122.1697),
            busyLevel: .veryBusy,
            subtitle: "Stanford University"
        ),
        PopularLocation(
            id: UUID(),
            name: "Santana Row",
            icon: .bag,
            coordinate: CLLocationCoordinate2D(latitude: 37.3202, longitude: -121.9479),
            busyLevel: .busy,
            subtitle: "Shopping & Dining"
        ),
        PopularLocation(
            id: UUID(),
            name: "Downtown SJ",
            icon: .storefront,
            coordinate: CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863),
            busyLevel: .busy,
            subtitle: "San Jose"
        ),
        PopularLocation(
            id: UUID(),
            name: "Golden Gate",
            icon: .bridge,
            coordinate: CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783),
            busyLevel: .veryBusy,
            subtitle: "Golden Gate Park"
        ),
        PopularLocation(
            id: UUID(),
            name: "Palo Alto",
            icon: .coffee,
            coordinate: CLLocationCoordinate2D(latitude: 37.4419, longitude: -122.1430),
            busyLevel: .busy,
            subtitle: "University Ave"
        )
    ]

    /// Returns mock locations sorted by distance to the provided coordinate.
    static func locations(near coordinate: CLLocationCoordinate2D?) -> [PopularLocation] {
        guard let coordinate = coordinate else { return austinLocations }
        
        let allLocations = austinLocations + bayAreaLocations
        let mapLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        // Sort all mock locations by distance from the center of the screen
        let sorted = allLocations.sorted { loc1, loc2 in
            let cl1 = CLLocation(latitude: loc1.coordinate.latitude, longitude: loc1.coordinate.longitude)
            let cl2 = CLLocation(latitude: loc2.coordinate.latitude, longitude: loc2.coordinate.longitude)
            return cl1.distance(from: mapLocation) < cl2.distance(from: mapLocation)
        }
        
        // Return the closest 6
        return Array(sorted.prefix(6))
    }
}
