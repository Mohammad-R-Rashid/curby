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

    static let preferencesDidChangeNotification = Notification.Name("curby.preferencesDidChange")

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
            NotificationCenter.default.post(name: Self.preferencesDidChangeNotification, object: nil)
        }
    }

    /// When enabled, the map shows diagnostic pins, routing anchors, and a live session panel.
    var developerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerModeEnabled, forKey: Self.developerModeKey)
            NotificationCenter.default.post(name: Self.preferencesDidChangeNotification, object: nil)
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
    private static let developerModeKey = "curby_developer_mode_enabled"

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.walkingKey)
        self.walkingCircumference = saved > 0 ? saved : CurbyConstants.walkingCircumferenceDefault
        self.developerModeEnabled = UserDefaults.standard.object(forKey: Self.developerModeKey) as? Bool ?? false

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

    static var storedWalkingDistanceMeters: Double {
        storedWalkingCircumference * CurbyConstants.metersPerMile
    }

    /// Adds miles to the saved walking geofence, clamped to `walkingCircumferenceMin`…`max`, then notifies `preferencesDidChangeNotification`.
    static func addWalkingCircumferenceMiles(_ deltaMiles: Double) {
        let current = storedWalkingCircumference
        let next = min(
            max(current + deltaMiles, CurbyConstants.walkingCircumferenceMin),
            CurbyConstants.walkingCircumferenceMax
        )
        guard abs(next - current) > 0.000_1 else { return }
        UserDefaults.standard.set(next, forKey: walkingKey)
        NotificationCenter.default.post(name: preferencesDidChangeNotification, object: nil)
    }

    /// Whether `addWalkingCircumferenceMiles` would actually change storage (false when already at max).
    static func canAddWalkingCircumferenceMiles(_ deltaMiles: Double) -> Bool {
        let current = storedWalkingCircumference
        let next = min(
            max(current + deltaMiles, CurbyConstants.walkingCircumferenceMin),
            CurbyConstants.walkingCircumferenceMax
        )
        return abs(next - current) > 0.000_1
    }

    static var storedDeveloperModeEnabled: Bool {
        UserDefaults.standard.object(forKey: developerModeKey) as? Bool ?? false
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
