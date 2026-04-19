//
//  ParkingWebSocketManager.swift
//  curby
//
//  Manages Curby's live parking recommendation WebSocket session.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class ParkingWebSocketManager {
    private(set) var status: CurbyParkingSearchStatus = .idle
    private(set) var activeRecommendation: CurbyParkingRecommendation?
    private(set) var pendingRouteUpdate: CurbyParkingRecommendation?
    private(set) var pendingRouteUpdateReason: String?
    private(set) var currentDestination: SelectedDestination?
    private(set) var lastErrorCode: String?

    var isSearching: Bool {
        switch status {
        case .connecting, .searching:
            return true
        case .idle, .recommended, .noData, .error, .arrived:
            return false
        }
    }

    var activeSessionID: String? {
        activeRecommendation?.sessionId
    }

    /// Origin coordinate used for the active WebSocket session (debug).
    var debugSocketOriginCoordinate: CLLocationCoordinate2D? {
        socketOriginLocation
    }

    /// Search radius last sent with `find_parking` (meters), if known.
    var debugLastSearchRadiusMeters: Double? {
        currentSearchRadiusMeters
    }

    @ObservationIgnored private let apiClient: CurbyAPIClient
    @ObservationIgnored private let remoteConfigService: RemoteConfigService
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let decoder = JSONDecoder()

    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var locationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownUserLocation: CLLocationCoordinate2D?
    @ObservationIgnored private var socketOriginLocation: CLLocationCoordinate2D?
    @ObservationIgnored private var lastSearchRefreshAt: Date?
    @ObservationIgnored private var currentSearchRadiusMeters: Double?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private let searchRefreshDistanceMeters: Double = 45
    @ObservationIgnored private let searchRefreshMinimumInterval: TimeInterval = 15
    @ObservationIgnored private let autoArrivalRadiusMeters: Double = 120

    init(
        apiClient: CurbyAPIClient,
        remoteConfigService: RemoteConfigService,
        session: URLSession = .shared
    ) {
        self.apiClient = apiClient
        self.remoteConfigService = remoteConfigService
        self.session = session
    }

    func updateCurrentLocation(_ location: CLLocationCoordinate2D?) {
        lastKnownUserLocation = location
        scheduleLocationDrivenRefreshIfNeeded()
    }

    func findParking(
        for destination: SelectedDestination,
        currentLocation: CLLocationCoordinate2D?,
        searchRadiusMeters: Double? = nil
    ) async {
        guard CurbyConstants.isWithinAustinArea(destination.coordinate) else {
            status = .error("Curby currently supports live parking only in Austin.")
            lastErrorCode = "OUTSIDE_AUSTIN"
            return
        }

        guard let currentLocation else {
            status = .error("Current location is required before Curby can route you to parking.")
            lastErrorCode = "NO_USER_LOCATION"
            return
        }

        updateCurrentLocation(currentLocation)
        currentDestination = destination
        currentSearchRadiusMeters = searchRadiusMeters
        pendingRouteUpdate = nil
        pendingRouteUpdateReason = nil
        activeRecommendation = nil
        status = .connecting
        reconnectAttempts = 0

        await disconnectSocket()

        do {
            let request = try apiClient.webSocketRequest(for: currentLocation)
            let task = session.webSocketTask(with: request)
            webSocketTask = task
            socketOriginLocation = currentLocation
            lastSearchRefreshAt = .now
            task.resume()

            startReceiveLoop(for: task)
            startHeartbeatLoop()

            status = .searching
            let effectiveRadius = searchRadiusMeters ?? remoteConfigService.config.search.defaultRadiusMeters

            try await sendCommand([
                "type": "find_parking",
                "destLat": destination.coordinate.latitude,
                "destLng": destination.coordinate.longitude,
                "radius": effectiveRadius
            ])
        } catch {
            status = .error(error.localizedDescription)
            lastErrorCode = "SOCKET_CONNECT_FAILED"
        }
    }

    func retryCurrentSearch() async {
        guard let currentDestination else { return }
        await findParking(
            for: currentDestination,
            currentLocation: lastKnownUserLocation,
            searchRadiusMeters: currentSearchRadiusMeters
        )
    }

    func cancelSearch() async {
        if let sessionId = activeSessionID {
            try? await sendCommand([
                "type": "cancel",
                "sessionId": sessionId
            ])
        }

        await disconnectSocket()
        clearSessionState()
    }

    func markArrivedIfNeeded() async {
        guard activeRecommendation != nil, isEligibleForAutoArrival() else { return }
        await markArrived()
    }

    func markArrived() async {
        guard let sessionId = activeSessionID else { return }

        do {
            try await sendCommand([
                "type": "arrived",
                "sessionId": sessionId
            ])
        } catch {
            status = .error(error.localizedDescription)
            lastErrorCode = "ARRIVED_SEND_FAILED"
        }
    }

    func acceptPendingUpdate() async {
        guard
            let pendingRecommendation = pendingRouteUpdate,
            let sessionId = activeSessionID ?? self.pendingRouteUpdate?.sessionId
        else {
            return
        }

        activeRecommendation = pendingRecommendation
        pendingRouteUpdate = nil
        pendingRouteUpdateReason = nil
        status = .recommended

        try? await sendCommand([
            "type": "accept_update",
            "sessionId": sessionId
        ])
    }

    func rejectPendingUpdate() async {
        guard let sessionId = activeSessionID ?? pendingRouteUpdate?.sessionId else {
            return
        }

        pendingRouteUpdate = nil
        pendingRouteUpdateReason = nil

        try? await sendCommand([
            "type": "reject_update",
            "sessionId": sessionId
        ])
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    try await self.handleIncomingMessage(message)
                } catch {
                    guard !Task.isCancelled else { break }
                    await self.handleSocketFailure(error)
                    break
                }
            }
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }

                do {
                    try await self.sendCommand(["type": "heartbeat"])
                } catch {
                    await self.handleSocketFailure(error)
                    break
                }
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        let payload: Data

        switch message {
        case let .string(string):
            payload = Data(string.utf8)
        case let .data(data):
            payload = data
        @unknown default:
            return
        }

        let event = try decodeEvent(from: payload)
        lastErrorCode = nil

        switch event {
        case let .recommendation(recommendation):
            reconnectAttempts = 0
            activeRecommendation = recommendation
            pendingRouteUpdate = nil
            pendingRouteUpdateReason = nil
            status = .recommended

        case let .routeUpdate(recommendation):
            pendingRouteUpdate = recommendation
            pendingRouteUpdateReason = recommendation.reasoning

        case let .noData(message):
            activeRecommendation = nil
            pendingRouteUpdate = nil
            pendingRouteUpdateReason = nil
            status = .noData(message)

        case let .error(code, message):
            status = .error(message)
            lastErrorCode = code

        case let .confirmed(sessionId):
            if activeRecommendation?.sessionId == sessionId {
                status = .arrived
            }

        case .heartbeatAck:
            break
        }
    }

    private func handleSocketFailure(_ error: Error) async {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        webSocketTask = nil

        guard currentDestination != nil, reconnectAttempts < 3 else {
            if case .arrived = status {
                return
            }

            if case .noData = status {
                return
            } else {
                status = .error(error.localizedDescription)
                lastErrorCode = "SOCKET_DISCONNECTED"
            }
            return
        }

        reconnectAttempts += 1
        status = .connecting

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(Double(reconnectAttempts) * 2))
            guard !Task.isCancelled else { return }
            await self.retryCurrentSearch()
        }
    }

    private func decodeEvent(from payload: Data) throws -> CurbyWebSocketEvent {
        let envelope = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let type = envelope?["type"] as? String ?? ""

        switch type {
        case "recommendation":
            let event = try decoder.decode(CurbyRecommendationEvent.self, from: payload)
            return .recommendation(
                CurbyParkingRecommendation(
                    sessionId: event.sessionId,
                    area: event.area,
                    route: event.route,
                    score: event.score,
                    reasoning: event.reasoning
                )
            )

        case "route_update":
            let event = try decoder.decode(CurbyRouteUpdateEvent.self, from: payload)
            return .routeUpdate(
                CurbyParkingRecommendation(
                    sessionId: event.sessionId,
                    area: event.newArea,
                    route: event.newRoute,
                    score: event.newScore,
                    reasoning: event.reason
                )
            )

        case "no_data":
            let event = try decoder.decode(CurbyNoDataEvent.self, from: payload)
            return .noData(event.message)

        case "error":
            let event = try decoder.decode(CurbyErrorEvent.self, from: payload)
            return .error(code: event.code, message: event.message)

        case "confirmed":
            let event = try decoder.decode(CurbyConfirmedEvent.self, from: payload)
            return .confirmed(sessionId: event.sessionId)

        case "heartbeat_ack":
            _ = try decoder.decode(CurbyHeartbeatAckEvent.self, from: payload)
            return .heartbeatAck

        default:
            return .error(code: "UNKNOWN_EVENT", message: "Unexpected backend event: \(type)")
        }
    }

    private func sendCommand(_ command: [String: Any]) async throws {
        guard let webSocketTask else {
            throw CurbyAPIClientError.invalidResponse
        }

        let data = try JSONSerialization.data(withJSONObject: command, options: [])
        let string = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(string))
    }

    private func disconnectSocket() async {
        reconnectTask?.cancel()
        locationRefreshTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func clearSessionState() {
        status = .idle
        activeRecommendation = nil
        pendingRouteUpdate = nil
        pendingRouteUpdateReason = nil
        currentDestination = nil
        lastErrorCode = nil
        currentSearchRadiusMeters = nil
        socketOriginLocation = nil
        lastSearchRefreshAt = nil
    }

    private func scheduleLocationDrivenRefreshIfNeeded() {
        guard
            currentDestination != nil,
            let currentLocation = lastKnownUserLocation,
            let socketOriginLocation,
            status == .searching || status == .recommended || status == .connecting
        else {
            return
        }

        let currentCLLocation = CLLocation(
            latitude: currentLocation.latitude,
            longitude: currentLocation.longitude
        )
        let originCLLocation = CLLocation(
            latitude: socketOriginLocation.latitude,
            longitude: socketOriginLocation.longitude
        )

        guard currentCLLocation.distance(from: originCLLocation) >= searchRefreshDistanceMeters else {
            return
        }

        if
            let lastSearchRefreshAt,
            Date.now.timeIntervalSince(lastSearchRefreshAt) < searchRefreshMinimumInterval
        {
            return
        }

        locationRefreshTask?.cancel()
        locationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard self.status != .arrived else { return }

            self.lastSearchRefreshAt = .now
            await self.retryCurrentSearch()
        }
    }

    private func isEligibleForAutoArrival() -> Bool {
        guard
            let currentLocation = lastKnownUserLocation,
            let recommendation = activeRecommendation
        else {
            return false
        }

        let current = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
        let area = CLLocation(
            latitude: recommendation.area.coordinate.latitude,
            longitude: recommendation.area.coordinate.longitude
        )

        if current.distance(from: area) <= autoArrivalRadiusMeters {
            return true
        }

        guard let destination = currentDestination?.coordinate else {
            return false
        }

        let destinationLocation = CLLocation(
            latitude: destination.latitude,
            longitude: destination.longitude
        )
        return current.distance(from: destinationLocation) <= autoArrivalRadiusMeters
    }
}
