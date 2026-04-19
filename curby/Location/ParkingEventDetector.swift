//
//  ParkingEventDetector.swift
//  curby
//
//  Detects park and depart events on-device and reports them to the backend.
//

import CoreLocation
import Foundation
import Observation

enum ParkingPresenceState: String, Codable {
    case driving
    case parked
}

private struct PersistedParkingState: Codable {
    let presence: ParkingPresenceState
    let parkedAt: Date?
    let latitude: Double?
    let longitude: Double?
    /// User-facing label for the map pin (explicit “mark parked” only).
    let pinTitle: String?
}

@MainActor
@Observable
final class ParkingEventDetector {
    private(set) var presenceState: ParkingPresenceState = .driving
    private(set) var lastTransitionAt: Date?
    private(set) var lastErrorMessage: String?

    var onParked: (() -> Void)?
    var onDeparted: (() -> Void)?

    @ObservationIgnored private let apiClient: CurbyAPIClient
    @ObservationIgnored private let remoteConfigService: RemoteConfigService
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    @ObservationIgnored private var latestLocation: CLLocation?
    @ObservationIgnored private var stationaryAnchorLocation: CLLocation?
    @ObservationIgnored private var stationaryStartAt: Date?
    @ObservationIgnored private var departCandidateStartAt: Date?
    @ObservationIgnored private var parkedLocation: CLLocation?
    /// Persisted with `PersistedParkingState` when the user confirms a park label.
    @ObservationIgnored private var persistedParkPinTitle: String?

    private static let persistedStateKey = "curby.parking-detector.state"

    init(apiClient: CurbyAPIClient, remoteConfigService: RemoteConfigService) {
        self.apiClient = apiClient
        self.remoteConfigService = remoteConfigService
        loadPersistedState()
    }

    func start() {
        guard loopTask == nil else { return }

        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await self.evaluateLatestSample()
            }
        }
    }

    func updateLatestLocation(_ location: CLLocation?) {
        latestLocation = location
    }

    /// Map pin title while parked (explicit save supplies a name; auto-detect uses the default).
    var parkedPinDisplayTitle: String {
        persistedParkPinTitle ?? "Parked spot"
    }

    /// Live coordinate for the parked map annotation when `presenceState == .parked`.
    var parkedCoordinateForMap: CLLocationCoordinate2D? {
        presenceState == .parked ? parkedLocation?.coordinate : nil
    }

    /// Records a user-confirmed park at a specific coordinate (writes `active_parks` via `/v1/events/park`).
    func recordExplicitPark(at coordinate: CLLocationCoordinate2D, displayTitle: String? = nil) async throws {
        let now = Date.now
        let timestamp = ISO8601DateFormatter().string(from: now)

        try await apiClient.postParkEvent(
            CurbyParkEventPayload(
                userId: apiClient.userID,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                timestamp: timestamp
            )
        )

        presenceState = .parked
        parkedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        persistedParkPinTitle = displayTitle
        lastTransitionAt = now
        stationaryAnchorLocation = nil
        stationaryStartAt = nil
        departCandidateStartAt = nil
        lastErrorMessage = nil
        persistState()
    }

    /// Clears the user's active park in Supabase (`/v1/events/depart`) and returns presence to driving.
    func recordExplicitDepart() async throws {
        let now = Date.now
        let timestamp = ISO8601DateFormatter().string(from: now)

        try await apiClient.postDepartEvent(
            CurbyDepartEventPayload(
                userId: apiClient.userID,
                timestamp: timestamp
            )
        )

        presenceState = .driving
        parkedLocation = nil
        persistedParkPinTitle = nil
        lastTransitionAt = now
        departCandidateStartAt = nil
        lastErrorMessage = nil
        persistState()
    }

    private func evaluateLatestSample() async {
        guard let location = latestLocation else { return }

        let detection = remoteConfigService.config.detection
        let now = Date.now
        let speed = max(0, location.speed)

        switch presenceState {
        case .driving:
            guard speed <= detection.speedStationaryMs else {
                stationaryAnchorLocation = nil
                stationaryStartAt = nil
                return
            }

            if stationaryAnchorLocation == nil || stationaryStartAt == nil {
                stationaryAnchorLocation = location
                stationaryStartAt = now
                return
            }

            guard let stationaryAnchorLocation, let stationaryStartAt else { return }

            if location.distance(from: stationaryAnchorLocation) > detection.parkDetectionDriftMeters {
                self.stationaryAnchorLocation = location
                self.stationaryStartAt = now
                return
            }

            let stationaryDuration = now.timeIntervalSince(stationaryStartAt)
            guard stationaryDuration >= TimeInterval(detection.parkDetectionDurationSec) else {
                return
            }

            presenceState = .parked
            parkedLocation = location
            persistedParkPinTitle = nil
            lastTransitionAt = now
            departCandidateStartAt = nil
            self.stationaryAnchorLocation = nil
            self.stationaryStartAt = nil
            persistState()

            do {
                try await apiClient.postParkEvent(
                    CurbyParkEventPayload(
                        userId: apiClient.userID,
                        lat: location.coordinate.latitude,
                        lng: location.coordinate.longitude,
                        timestamp: ISO8601DateFormatter().string(from: now)
                    )
                )
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }

            onParked?()

        case .parked:
            guard speed > detection.speedWalkingMs else {
                departCandidateStartAt = nil
                return
            }

            if departCandidateStartAt == nil {
                departCandidateStartAt = now
                return
            }

            guard let departCandidateStartAt else { return }

            let departDuration = now.timeIntervalSince(departCandidateStartAt)
            guard departDuration >= TimeInterval(detection.departDetectionDurationSec) else {
                return
            }

            presenceState = .driving
            lastTransitionAt = now
            self.departCandidateStartAt = nil
            parkedLocation = nil
            persistedParkPinTitle = nil
            persistState()

            do {
                try await apiClient.postDepartEvent(
                    CurbyDepartEventPayload(
                        userId: apiClient.userID,
                        timestamp: ISO8601DateFormatter().string(from: now)
                    )
                )
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }

            onDeparted?()
        }
    }

    private func loadPersistedState() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.persistedStateKey),
            let persisted = try? JSONDecoder().decode(PersistedParkingState.self, from: data)
        else {
            return
        }

        presenceState = persisted.presence
        if
            let latitude = persisted.latitude,
            let longitude = persisted.longitude
        {
            parkedLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        persistedParkPinTitle = persisted.pinTitle
    }

    private func persistState() {
        let payload = PersistedParkingState(
            presence: presenceState,
            parkedAt: lastTransitionAt,
            latitude: parkedLocation?.coordinate.latitude,
            longitude: parkedLocation?.coordinate.longitude,
            pinTitle: persistedParkPinTitle
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedStateKey)
    }
}
