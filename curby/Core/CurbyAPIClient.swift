//
//  CurbyAPIClient.swift
//  curby
//
//  REST and WebSocket endpoint builder for the deployed Curby backend.
//

import CoreLocation
import Foundation

enum CurbyAPIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case badStatusCode(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The Curby backend URL is invalid."
        case .invalidResponse:
            return "The Curby backend returned an invalid response."
        case let .badStatusCode(statusCode, body):
            if let body, !body.isEmpty {
                return "Backend request failed with status \(statusCode): \(body)"
            }
            return "Backend request failed with status \(statusCode)."
        }
    }
}

final class CurbyAPIClient {
    let userID: String

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseURL: URL

    init(session: URLSession = .shared, userID: String = CurbyUserIdentity.loadOrCreateUserID()) {
        self.session = session
        self.userID = userID

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let configuredURLString = Bundle.main.object(
            forInfoDictionaryKey: "CurbyAPIBaseURL"
        ) as? String

        let baseURLString = configuredURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURLString = CurbyConstants.apiBaseURL

        self.baseURL = URL(string: baseURLString?.isEmpty == false ? baseURLString! : fallbackURLString)
            ?? URL(string: fallbackURLString)!
    }

    func fetchConfig(currentVersion: Int?) async throws -> CurbyRemoteConfig? {
        var request = URLRequest(url: buildURL(path: "/v1/config", queryItems: {
            guard let currentVersion else { return [] }
            return [URLQueryItem(name: "version", value: String(currentVersion))]
        }()))
        request.httpMethod = "GET"
        request.setValue(userID, forHTTPHeaderField: "X-User-Id")

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(response)

        switch httpResponse.statusCode {
        case 200:
            return try decoder.decode(CurbyRemoteConfig.self, from: data)
        case 304:
            return nil
        default:
            throw CurbyAPIClientError.badStatusCode(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8)
            )
        }
    }

    func postTelemetry(_ payload: CurbyTelemetryPayload) async throws {
        try await postJSON(payload, path: "/v1/telemetry", expectedStatusCodes: [202])
    }

    func postParkEvent(_ payload: CurbyParkEventPayload) async throws {
        try await postJSON(payload, path: "/v1/events/park", expectedStatusCodes: [201])
    }

    func postDepartEvent(_ payload: CurbyDepartEventPayload) async throws {
        try await postJSON(payload, path: "/v1/events/depart", expectedStatusCodes: [200, 404])
    }

    func webSocketRequest(for location: CLLocationCoordinate2D) throws -> URLRequest {
        guard var components = URLComponents(
            url: buildURL(path: "/v1/park"),
            resolvingAgainstBaseURL: false
        ) else {
            throw CurbyAPIClientError.invalidBaseURL
        }

        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }

        components.queryItems = [
            URLQueryItem(name: "lat", value: String(location.latitude)),
            URLQueryItem(name: "lng", value: String(location.longitude)),
            URLQueryItem(name: "userId", value: userID)
        ]

        guard let url = components.url else {
            throw CurbyAPIClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userID, forHTTPHeaderField: "X-User-Id")
        return request
    }

    private func postJSON<T: Encodable>(
        _ value: T,
        path: String,
        expectedStatusCodes: Set<Int>
    ) async throws {
        var request = URLRequest(url: buildURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userID, forHTTPHeaderField: "X-User-Id")
        request.httpBody = try encoder.encode(value)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(response)

        guard expectedStatusCodes.contains(httpResponse.statusCode) else {
            throw CurbyAPIClientError.badStatusCode(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8)
            )
        }
    }

    private func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CurbyAPIClientError.invalidResponse
        }
        return httpResponse
    }

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url ?? baseURL.appendingPathComponent(path)
    }
}
