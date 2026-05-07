//
//  PopularLocation.swift
//  curby
//
//  Model for a popular/busy location near the user. Instances are produced
//  dynamically by DynamicPlacesService (MKLocalSearch around the current map
//  center) — the hardcoded per-city arrays that used to live here have been
//  removed.
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
