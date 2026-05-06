//
//  LiveParkingActivityController.swift
//  curby
//
//  Owns the lifecycle of the Curby Live Activity (lock-screen banner +
//  Dynamic Island) while the user is navigating to a picked parking spot.
//
//  Flow:
//   - `start(...)` is called when the user taps Navigate. We open Apple Maps
//     elsewhere; this manages the Live Activity that rides on top of it.
//   - `update(currentLocation:)` is called from MainNavigationView when the
//     user's location changes. We recompute distance + ETA + the
//     "entered walking radius" geofence and push an update to the activity
//     (throttled — Live Activities have a tight update budget).
//   - `end(...)` is called on cancel, on arrival, or when the user clears
//     the destination.
//

import ActivityKit
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LiveParkingActivityController {

    /// Whether a Live Activity is currently running.
    private(set) var isActive: Bool = false

    @ObservationIgnored private var activity: Activity<CurbyLiveActivityAttributes>?
    @ObservationIgnored private var destinationCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var parkingCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var walkingRadiusMeters: Double = 400
    @ObservationIgnored private var lastUpdatePushedAt: Date?
    @ObservationIgnored private var lastPushedDistance: Double?
    @ObservationIgnored private var hasEnteredWalkingRadius: Bool = false

    /// Minimum interval between pushed updates (Live Activity budget).
    private let updateMinInterval: TimeInterval = 12
    /// Push an update if distance to parking changed by at least this much
    /// since the last push, regardless of the time interval.
    private let updateMinDistanceDeltaMeters: Double = 80

    /// Begin a navigation Live Activity. Silently no-ops if Live Activities
    /// are disabled in Settings or unavailable on the device.
    func start(
        destinationName: String,
        destinationCoordinate: CLLocationCoordinate2D,
        parkingName: String,
        parkingCoordinate: CLLocationCoordinate2D,
        walkingRadiusMeters: Double,
        currentLocation: CLLocation?,
        busynessLabel: String
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // If one was already running for a different trip, end it first.
        if activity != nil {
            Task { await endCurrent() }
        }

        self.destinationCoordinate = destinationCoordinate
        self.parkingCoordinate = parkingCoordinate
        self.walkingRadiusMeters = walkingRadiusMeters
        self.hasEnteredWalkingRadius = false
        self.lastUpdatePushedAt = .now
        self.lastPushedDistance = nil

        let initialState = CurbyLiveActivityAttributes.ContentState(
            distanceToDestinationMeters: distance(from: currentLocation, to: parkingCoordinate),
            etaMinutes: estimatedMinutes(
                from: currentLocation,
                to: parkingCoordinate,
                speed: currentLocation?.speed
            ),
            hasEnteredWalkingRadius: false,
            busynessLabel: busynessLabel,
            lastUpdated: .now
        )

        let attributes = CurbyLiveActivityAttributes(
            destinationName: destinationName,
            parkingName: parkingName,
            walkingRadiusMeters: walkingRadiusMeters
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            isActive = true
        } catch {
            // Activity request can fail if the user revoked permission mid-session
            // or if iOS is rate-limiting starts. Fail silently — Apple Maps still
            // opens and the in-app destination experience continues.
        }
    }

    /// Recompute distance/ETA/geofence and push an update if anything material
    /// changed and we're outside the throttle window.
    func update(currentLocation: CLLocation?) {
        guard isActive,
              let activity,
              let parkingCoordinate,
              let destinationCoordinate
        else { return }

        let distanceToParking = distance(from: currentLocation, to: parkingCoordinate)
        let distanceToDestination = distance(from: currentLocation, to: destinationCoordinate)
        let crossedRadius = distanceToDestination <= walkingRadiusMeters

        let crossedFlipped = (crossedRadius != hasEnteredWalkingRadius)
        let distanceDelta = abs((lastPushedDistance ?? .greatestFiniteMagnitude) - distanceToParking)
        let timeSinceLast = Date.now.timeIntervalSince(lastUpdatePushedAt ?? .distantPast)

        // Always push when the geofence flips. Otherwise respect the throttle.
        guard crossedFlipped
                || (timeSinceLast >= updateMinInterval && distanceDelta >= updateMinDistanceDeltaMeters)
        else { return }

        hasEnteredWalkingRadius = crossedRadius
        lastUpdatePushedAt = .now
        lastPushedDistance = distanceToParking

        let nextState = CurbyLiveActivityAttributes.ContentState(
            distanceToDestinationMeters: distanceToParking,
            etaMinutes: estimatedMinutes(
                from: currentLocation,
                to: parkingCoordinate,
                speed: currentLocation?.speed
            ),
            hasEnteredWalkingRadius: crossedRadius,
            busynessLabel: activity.content.state.busynessLabel,
            lastUpdated: .now
        )

        Task {
            await activity.update(.init(state: nextState, staleDate: nil))
        }
    }

    func end() {
        Task { await endCurrent() }
    }

    private func endCurrent() async {
        guard let activity else {
            isActive = false
            return
        }
        await activity.end(activity.content, dismissalPolicy: .immediate)
        self.activity = nil
        self.isActive = false
        self.destinationCoordinate = nil
        self.parkingCoordinate = nil
        self.lastUpdatePushedAt = nil
        self.lastPushedDistance = nil
        self.hasEnteredWalkingRadius = false
    }

    // MARK: - Helpers

    private func distance(from location: CLLocation?, to coordinate: CLLocationCoordinate2D) -> Double {
        guard let location else { return 0 }
        return location.distance(from: CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
    }

    /// Rough ETA in whole minutes. Uses the current speed when meaningful,
    /// otherwise falls back to a city-driving average.
    private func estimatedMinutes(
        from location: CLLocation?,
        to coordinate: CLLocationCoordinate2D,
        speed: CLLocationSpeed?
    ) -> Int {
        let meters = distance(from: location, to: coordinate)
        guard meters > 0 else { return 0 }
        // Use measured speed if it's plausibly a driving pace; otherwise
        // assume ~12 m/s (~27 mph) city average.
        let metersPerSecond: Double
        if let speed, speed > 3 {
            metersPerSecond = speed
        } else {
            metersPerSecond = 12
        }
        let seconds = meters / metersPerSecond
        return max(1, Int((seconds / 60).rounded()))
    }
}
