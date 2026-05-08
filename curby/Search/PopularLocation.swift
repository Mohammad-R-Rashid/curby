//
//  PopularLocation.swift
//  curby
//
//  Model for a popular/busy location near the user. Instances are produced
//  dynamically by DynamicPlacesService.
//

import CoreLocation
import Foundation

/// A well-known location where parking is competitive.
struct PopularLocation: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// SF Symbol name (e.g. "graduationcap", "bag.fill"). Apple iconography
    /// throughout — Phosphor is no longer used for surfaced places.
    let sfSymbol: String
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
