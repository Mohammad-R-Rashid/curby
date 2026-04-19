//
//  TelemetryUploader.swift
//  curby
//
//  Ships user telemetry to the backend on the live cadence from remote config.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class TelemetryUploader {
    private(set) var pendingUploadCount: Int = 0
    private(set) var lastUploadAt: Date?
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let apiClient: CurbyAPIClient
    @ObservationIgnored private let remoteConfigService: RemoteConfigService
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    @ObservationIgnored private var latestLocation: CLLocation?
    @ObservationIgnored private var latestHeading: Double = 0
    @ObservationIgnored private var pendingPayloads: [CurbyTelemetryPayload] = []
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private let timestampFormatter = ISO8601DateFormatter()

    private static let pendingKey = "curby.telemetry.pending"

    init(apiClient: CurbyAPIClient, remoteConfigService: RemoteConfigService) {
        self.apiClient = apiClient
        self.remoteConfigService = remoteConfigService
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        loadPendingPayloads()
    }

    func start() {
        guard loopTask == nil else { return }

        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await flushPendingPayloads()

            while !Task.isCancelled {
                let interval = max(1, remoteConfigService.config.telemetry.uploadIntervalSec)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                enqueueLatestSampleIfAvailable()
                await flushPendingPayloads()
            }
        }
    }

    func updateLatestSample(location: CLLocation?, heading: CLHeading?) {
        latestLocation = location
        if let trueHeading = heading?.trueHeading, trueHeading >= 0 {
            latestHeading = trueHeading
        } else if let magneticHeading = heading?.magneticHeading, magneticHeading >= 0 {
            latestHeading = magneticHeading
        }
    }

    private func enqueueLatestSampleIfAvailable() {
        guard let latestLocation else { return }

        let payload = CurbyTelemetryPayload(
            userId: apiClient.userID,
            lat: latestLocation.coordinate.latitude,
            lng: latestLocation.coordinate.longitude,
            speed: max(0, latestLocation.speed),
            heading: max(0, min(360, latestHeading)),
            accuracy: max(0, latestLocation.horizontalAccuracy),
            timestamp: timestampFormatter.string(from: latestLocation.timestamp)
        )

        pendingPayloads.append(payload)
        if pendingPayloads.count > 250 {
            pendingPayloads.removeFirst(pendingPayloads.count - 250)
        }
        pendingUploadCount = pendingPayloads.count
        savePendingPayloads()
    }

    private func flushPendingPayloads() async {
        guard !isFlushing, !pendingPayloads.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let payload = pendingPayloads.first {
            do {
                try await apiClient.postTelemetry(payload)
                pendingPayloads.removeFirst()
                pendingUploadCount = pendingPayloads.count
                lastUploadAt = .now
                lastErrorMessage = nil
                savePendingPayloads()
            } catch {
                lastErrorMessage = error.localizedDescription
                break
            }
        }
    }

    private func loadPendingPayloads() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.pendingKey),
            let payloads = try? JSONDecoder().decode([CurbyTelemetryPayload].self, from: data)
        else {
            return
        }

        pendingPayloads = payloads
        pendingUploadCount = payloads.count
    }

    private func savePendingPayloads() {
        guard let data = try? JSONEncoder().encode(pendingPayloads) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingKey)
    }
}
