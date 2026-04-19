//
//  LocationService.swift
//  curby
//
//  High-frequency location updates for camera and motion awareness.
//

import CoreLocation
import Foundation
import Observation

/// Manages Core Location to provide speed, heading, and authorization status.
///
/// This service runs alongside Mapbox's internal location provider — it does NOT
/// replace it. Mapbox handles puck rendering; this feeds our camera + motion systems.
///
/// `CLLocationManagerDelegate` is invoked on an arbitrary queue; all published state
/// is updated on the main actor only.
@MainActor
@Observable
final class LocationService: NSObject {

    // MARK: - Published State

    /// Most recent location, nil until first fix.
    private(set) var currentLocation: CLLocation?

    /// Current speed in m/s, clamped to ≥ 0.
    private(set) var currentSpeed: Double = 0.0

    /// Current heading from magnetometer.
    private(set) var currentHeading: CLHeading?

    /// Current authorization status for UI to react to.
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True once the first valid location fix has been received.
    private(set) var hasInitialFix: Bool = false

    /// Horizontal accuracy of the latest fix (metres). Lower is better.
    private(set) var horizontalAccuracy: Double = -1

    // MARK: - Private

    private let locationManager = CLLocationManager()

    // MARK: - Lifecycle

    override init() {
        super.init()
        configureLocationManager()
    }

    // MARK: - Public

    /// Request location permissions. Safe to call multiple times.
    func requestPermission() {
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Start receiving location and heading updates.
    func startUpdating() {
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    /// Stop all updates to conserve battery.
    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }

    // MARK: - Private Configuration

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone // High-frequency
        locationManager.pausesLocationUpdatesAutomatically = false
        // Background updates enabled dynamically when Always is granted.
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.headingFilter = 5 // Degrees — reduces noise

        authorizationStatus = locationManager.authorizationStatus
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentLocation = latest
            // CLLocation.speed can be negative when invalid
            self.currentSpeed = max(0, latest.speed)
            self.horizontalAccuracy = latest.horizontalAccuracy

            if !self.hasInitialFix && latest.horizontalAccuracy >= 0 {
                self.hasInitialFix = true
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        Task { @MainActor [weak self] in
            self?.currentHeading = newHeading
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status

            switch status {
            case .authorizedAlways:
                self.locationManager.allowsBackgroundLocationUpdates = true
                self.locationManager.showsBackgroundLocationIndicator = true
                self.startUpdating()
            case .authorizedWhenInUse:
                self.locationManager.allowsBackgroundLocationUpdates = false
                self.locationManager.showsBackgroundLocationIndicator = false
                self.startUpdating()
            case .denied, .restricted:
                self.stopUpdating()
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Silently handle — location errors are transient on real devices.
        // In production, this could log to analytics.
        print("[LocationService] Error: \(error.localizedDescription)")
    }
}
