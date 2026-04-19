//
//  OnboardingState.swift
//  curby
//
//  Manages onboarding flow state — permissions and preferences.
//

import CoreLocation
import Foundation
import Observation
import UIKit

/// Manages the onboarding flow: permission requests and user preferences.
@Observable
final class OnboardingState {

    // MARK: - Permission State

    /// Whether location access has been granted (WhenInUse or Always).
    private(set) var locationGranted: Bool = false

    /// Current location authorization status for UI feedback.
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    /// True when the user previously denied location and must go to Settings.
    var locationDenied: Bool {
        locationStatus == .denied || locationStatus == .restricted
    }

    // MARK: - Preferences

    /// User's comfortable walking distance in miles.
    var walkingCircumference: Double {
        didSet {
            UserDefaults.standard.set(walkingCircumference, forKey: Self.walkingKey)
        }
    }

    // MARK: - Navigation

    /// True once the user taps Continue on the onboarding screen.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingKey) }
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var locationDelegate: OnboardingLocationDelegate?

    private static let walkingKey = "curby_walking_circumference"
    private static let onboardingKey = "curby_has_completed_onboarding"

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.walkingKey)
        self.walkingCircumference = saved > 0 ? saved : CurbyConstants.walkingCircumferenceDefault

        // Check current permission state
        let status = locationManager.authorizationStatus
        self.locationStatus = status
        self.locationGranted = (status == .authorizedWhenInUse || status == .authorizedAlways)
    }

    // MARK: - Permission Requests

    /// Request location permission.
    ///
    /// If the user hasn't decided yet, requests WhenInUse first.
    /// If we already have WhenInUse, escalates to Always.
    /// If the user previously denied, opens system Settings.
    func requestLocationPermission() {
        if locationDenied {
            openAppSettings()
            return
        }

        let delegate = OnboardingLocationDelegate { [weak self] status in
            self?.locationStatus = status
            self?.locationGranted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        }
        self.locationDelegate = delegate
        locationManager.delegate = delegate

        // If we already have WhenInUse, escalate to Always.
        if locationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Complete onboarding and persist flag.
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    /// Retrieve stored walking circumference (for use outside onboarding).
    static var storedWalkingCircumference: Double {
        let saved = UserDefaults.standard.double(forKey: walkingKey)
        return saved > 0 ? saved : CurbyConstants.walkingCircumferenceDefault
    }

    /// Refresh permission states from system (for Settings screen re-entry).
    func refreshPermissions() {
        let status = locationManager.authorizationStatus
        locationStatus = status
        locationGranted = (status == .authorizedWhenInUse || status == .authorizedAlways)
    }

    // MARK: - Helpers

    /// Opens the app's system Settings page.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Location Delegate

/// Lightweight delegate to capture authorization changes during onboarding.
private final class OnboardingLocationDelegate: NSObject, CLLocationManagerDelegate {
    let onChange: (CLAuthorizationStatus) -> Void

    init(onChange: @escaping (CLAuthorizationStatus) -> Void) {
        self.onChange = onChange
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange(manager.authorizationStatus)
    }
}
