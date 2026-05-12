//
//  ParkingHeatMapManager.swift
//  curby
//
//  Owns the iOS side of the /v1/parking-heat-map request lifecycle. Holds
//  the latest tiles for the current anchor (destination or hotspot), kicks
//  off a refetch when the anchor or radius changes, and quietly re-polls
//  every minute so the heat map stays reasonably fresh as traffic and
//  active_parks density shift through the day.
//

import CoreLocation
import Foundation
import Observation
import os

private let heatMapLogger = Logger(subsystem: "com.curby.app", category: "HeatMap")

@MainActor
@Observable
final class ParkingHeatMapManager {
    private(set) var tiles: [CurbyHeatMapTile] = []
    private(set) var isLoading: Bool = false
    private(set) var lastErrorMessage: String?
    /// True when the latest response was scored from traffic only (no
    /// `active_parks` signal). The UI can surface this as a quiet badge.
    private(set) var fallback: Bool = false
    /// Most recent successful response timestamp.
    private(set) var lastUpdatedAt: Date?

    @ObservationIgnored private let apiClient: CurbyAPIClient
    @ObservationIgnored private var currentAnchor: CLLocationCoordinate2D?
    @ObservationIgnored private var currentRadiusM: Double = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTimerTask: Task<Void, Never>?

    /// How often we re-poll the backend while an anchor is active. The
    /// server-side cache TTL is 60s, so anything shorter just burns KV
    /// reads and gets the same payload back.
    private static let refreshIntervalSec: TimeInterval = 60

    init(apiClient: CurbyAPIClient) {
        self.apiClient = apiClient
    }

    /// Switch to a new anchor. If the anchor + radius matches the one
    /// already loaded, no-op (the periodic refresh keeps it warm).
    func setAnchor(_ anchor: CLLocationCoordinate2D, radiusM: Double) {
        if let current = currentAnchor,
           sameCoordinate(current, anchor),
           abs(currentRadiusM - radiusM) < 1
        {
            return
        }

        currentAnchor = anchor
        currentRadiusM = radiusM
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.fetchOnce()
        }
        startRefreshTimer()
    }

    /// Drop the heat map (destination cleared / explore exited).
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        currentAnchor = nil
        currentRadiusM = 0
        tiles = []
        isLoading = false
        lastErrorMessage = nil
        fallback = false
        lastUpdatedAt = nil
    }

    // MARK: - Internals

    private func startRefreshTimer() {
        refreshTimerTask?.cancel()
        refreshTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshIntervalSec))
                guard !Task.isCancelled else { return }
                await self?.fetchOnce()
            }
        }
    }

    private func fetchOnce() async {
        guard let anchor = currentAnchor else { return }
        let radius = currentRadiusM
        isLoading = true
        do {
            let response = try await apiClient.fetchParkingHeatMap(
                anchor: anchor,
                radiusM: radius
            )
            // Guard against an anchor change mid-flight — drop stale payloads.
            guard let cur = currentAnchor,
                  sameCoordinate(cur, anchor),
                  abs(currentRadiusM - radius) < 1
            else {
                isLoading = false
                return
            }
            tiles = response.tiles
            fallback = response.fallback
            lastErrorMessage = nil
            lastUpdatedAt = Date()
        } catch {
            heatMapLogger.error("Heat-map fetch failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            // Keep prior tiles on transient failures so the map doesn't flash empty.
        }
        isLoading = false
    }

    private func sameCoordinate(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Bool {
        abs(a.latitude - b.latitude) < 1e-6 && abs(a.longitude - b.longitude) < 1e-6
    }
}
