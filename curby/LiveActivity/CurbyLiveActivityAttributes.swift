//
//  CurbyLiveActivityAttributes.swift
//  curby + CurbyLiveActivity (shared)
//
//  Shape of the Live Activity / Dynamic Island content. Lives in the main
//  app target AND the widget extension target — both compile this file.
//
//  Static `attributes` are set once when the activity starts. `ContentState`
//  is the part that updates as the drive progresses.
//

import ActivityKit
import Foundation

struct CurbyLiveActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        /// Distance from the user to the trip destination, in meters.
        var distanceToDestinationMeters: Double
        /// Estimated minutes to arrival (whole minutes; UI rounds).
        var etaMinutes: Int
        /// True once the user has crossed inside their walking radius around
        /// the destination — the "you're close, come back to refine" prompt
        /// uses this.
        var hasEnteredWalkingRadius: Bool
        /// Short label for the picked parking's busyness ("Open", "Busy", "Very Busy").
        var busynessLabel: String
        /// When this state was last updated.
        var lastUpdated: Date

        /// Display string the widget uses for the distance value.
        var distanceText: String {
            let miles = distanceToDestinationMeters / 1609.344
            if distanceToDestinationMeters < 240 {
                return "\(Int((distanceToDestinationMeters * 3.28084).rounded())) ft"
            }
            return String(format: "%.1f mi", miles)
        }

        var etaText: String {
            etaMinutes <= 1 ? "1 min" : "\(etaMinutes) min"
        }
    }

    /// Display name of the trip destination ("Apple Park", "Downtown SJ", …).
    var destinationName: String
    /// Display name of the picked parking spot.
    var parkingName: String
    /// Walking radius the user configured, in meters. Drives the geofence
    /// that flips `hasEnteredWalkingRadius`.
    var walkingRadiusMeters: Double
}
