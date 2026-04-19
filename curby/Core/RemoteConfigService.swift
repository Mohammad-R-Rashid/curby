//
//  RemoteConfigService.swift
//  curby
//
//  Fetches and caches Curby's backend-driven runtime configuration.
//

import Foundation
import Observation

@MainActor
@Observable
final class RemoteConfigService {
    private(set) var config: CurbyRemoteConfig = .default
    private(set) var lastUpdatedAt: Date?
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let apiClient: CurbyAPIClient
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private static let cacheKey = "curby.remote-config.cache"
    private static let refreshIntervalSeconds: UInt64 = 300

    init(apiClient: CurbyAPIClient) {
        self.apiClient = apiClient
        loadCachedConfig()
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.refreshIntervalSeconds)
                )
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        do {
            if let fetchedConfig = try await apiClient.fetchConfig(currentVersion: config.version) {
                config = fetchedConfig
                saveCachedConfig()
            }
            lastUpdatedAt = .now
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func loadCachedConfig() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.cacheKey),
            let cachedConfig = try? JSONDecoder().decode(CurbyRemoteConfig.self, from: data)
        else {
            return
        }

        config = cachedConfig
    }

    private func saveCachedConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
