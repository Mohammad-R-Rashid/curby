//
//  OnboardingState.swift
//  curby
//
//  Manages onboarding flow state — permissions and preferences.
//

import CoreLocation
import EventKit
import Foundation
import Observation

/// Manages the onboarding flow: permission requests and user preferences.
@Observable
final class OnboardingState {

    // MARK: - Permission State

    /// Whether location access has been granted.
    private(set) var locationGranted: Bool = false

    /// Whether calendar access has been granted.
    private(set) var calendarGranted: Bool = false

    /// Current location authorization status for UI feedback.
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

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
    private let eventStore = EKEventStore()
    private var locationDelegate: OnboardingLocationDelegate?

    private static let walkingKey = "curby_walking_circumference"
    private static let onboardingKey = "curby_has_completed_onboarding"

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.walkingKey)
        self.walkingCircumference = saved > 0 ? saved : CurbyConstants.walkingCircumferenceDefault

        // Check current permission states
        let status = locationManager.authorizationStatus
        self.locationStatus = status
        self.locationGranted = (status == .authorizedWhenInUse || status == .authorizedAlways)

        // Calendar — check current status
        let ekStatus = EKEventStore.authorizationStatus(for: .event)
        self.calendarGranted = (ekStatus == .fullAccess || ekStatus == .authorized)
    }

    // MARK: - Permission Requests

    /// Request location permission. Updates `locationGranted` when the user responds.
    func requestLocationPermission() {
        let delegate = OnboardingLocationDelegate { [weak self] status in
            self?.locationStatus = status
            self?.locationGranted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        }
        self.locationDelegate = delegate
        locationManager.delegate = delegate
        locationManager.requestWhenInUseAuthorization()
    }

    /// Request calendar permission.
    func requestCalendarPermission() {
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.calendarGranted = granted
            }
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
