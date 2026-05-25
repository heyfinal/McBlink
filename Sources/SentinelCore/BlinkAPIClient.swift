// BlinkAPIClient.swift — Blink HTTP API client for McBlink
// Swift 6 strict concurrency / macOS 14+
// API reference: unofficial Blink docs at https://github.com/MattTW/BlinkMonitorProtocol

import Foundation
import Security

// MARK: - BlinkEvent

struct BlinkEvent: Codable, Sendable, Identifiable {
    let id: Int
    let created_at: String
    let camera_id: Int
    let network_id: Int
    let type: String
    let media_url: String?
}

// MARK: - API Errors

enum BlinkAPIError: Error, Sendable {
    case unexpectedStatusCode(Int)
    case mfaRequired
    case malformedResponse(String)
    case mediaUnavailable
}

extension BlinkAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatusCode(let code): return "Blink API returned HTTP \(code)."
        case .mfaRequired: return "Blink account requires MFA verification."
        case .malformedResponse(let hint): return "Unexpected Blink API response: \(hint)"
        case .mediaUnavailable: return "Blink media URL is unavailable."
        }
    }
}

// MARK: - BlinkAPIClient

actor BlinkAPIClient {

    // MARK: Constants

    static let baseURL = URL(string: "https://rest-prod.immedia-semi.com")!
    private static let keychainService = "com.heyfinal.mcblink.blink"
    private static let thumbnailPollInterval: TimeInterval = 2
    private static let thumbnailPollTimeout: TimeInterval = 30

    // MARK: State

    var authToken: String?
    var accountID: String?
    var clientID: String?

    private let session: URLSession

    // MARK: Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Authentication

    /// Authenticates with the Blink backend.
    /// On HTTP 202 (MFA required) stores partial state and throws `BlinkAPIError.mfaRequired`.
    /// On success, persists the auth token to Keychain keyed by `email`.
    func authenticate(email: String, password: String) async throws {
        let url = Self.baseURL.appending(path: "/api/v4/account/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("McBlink/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "email": email,
            "password": password,
            "unique_id": UUID().uuidString,
            "device_identifier": "McBlink-macOS",
            "client_name": "McBlink",
            "reauth": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 202 {
            // MFA required — parse partial fields so verifyPin can proceed.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let account = json["account"] as? [String: Any],
               let auth = json["auth"] as? [String: Any] {
                accountID = (account["id"] as? Int).map(String.init)
                clientID = (account["client_id"] as? Int).map(String.init)
                authToken = auth["token"] as? String
            }
            throw BlinkAPIError.mfaRequired
        }

        guard statusCode == 200 else {
            throw BlinkAPIError.unexpectedStatusCode(statusCode)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["account"] as? [String: Any],
            let auth = json["auth"] as? [String: Any],
            let token = auth["token"] as? String
        else {
            throw BlinkAPIError.malformedResponse("login response missing account/auth fields")
        }

        authToken = token
        accountID = (account["id"] as? Int).map(String.init)
        clientID = (account["client_id"] as? Int).map(String.init)

        storeTokenInKeychain(token: token, account: email)
    }

    /// Verifies the MFA PIN sent to the user's email/phone.
    func verifyPin(pin: String) async throws {
        guard let accountID, let clientID, let token = authToken else {
            throw BlinkAPIError.malformedResponse("verifyPin called before authenticate")
        }
        let url = Self.baseURL.appending(
            path: "/api/v4/account/\(accountID)/client/\(clientID)/pin/verify"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "TOKEN_AUTH")
        let body = ["pin": pin]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            throw BlinkAPIError.unexpectedStatusCode(statusCode)
        }
    }

    /// Reads the stored auth token from Keychain for `email` and populates `authToken`.
    func loadStoredCredentials(email: String) async {
        authToken = readTokenFromKeychain(account: email)
    }

    // MARK: - Network Requests

    func getHomescreen() async throws -> Data {
        guard let accountID else { throw BlinkAPIError.malformedResponse("accountID not set") }
        let url = Self.baseURL.appending(path: "/api/v3/accounts/\(accountID)/homescreen")
        return try await get(url: url)
    }

    func getEvents(networkID: String) async throws -> [BlinkEvent] {
        let url = Self.baseURL.appending(path: "/api/v1/events/network/\(networkID)")
        let data = try await get(url: url)
        // Response: {"event": [...]}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventsArray = json["event"] as? [[String: Any]],
            let eventsData = try? JSONSerialization.data(withJSONObject: eventsArray)
        else {
            return []
        }
        return (try? JSONDecoder().decode([BlinkEvent].self, from: eventsData)) ?? []
    }

    func downloadMedia(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw BlinkAPIError.unexpectedStatusCode(statusCode) }
        return data
    }

    /// Requests a fresh thumbnail for a camera, polls for job completion, and returns JPEG data.
    func requestThumbnail(networkID: String, cameraID: String) async throws -> Data {
        guard let accountID else { throw BlinkAPIError.malformedResponse("accountID not set") }
        let postURL = Self.baseURL.appending(
            path: "/api/v5/accounts/\(accountID)/networks/\(networkID)/cameras/\(cameraID)/thumbnail/jobs"
        )
        // POST to start the job
        var postRequest = URLRequest(url: postURL)
        postRequest.httpMethod = "POST"
        applyAuthHeaders(to: &postRequest)
        let (postData, postResponse) = try await session.data(for: postRequest)
        let postStatus = (postResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard postStatus == 200 else { throw BlinkAPIError.unexpectedStatusCode(postStatus) }

        // Parse job ID
        guard
            let json = try? JSONSerialization.jsonObject(with: postData) as? [String: Any],
            let jobID = json["id"] as? Int
        else {
            throw BlinkAPIError.malformedResponse("thumbnail job response missing id")
        }

        // Poll for completion
        let deadline = Date().addingTimeInterval(Self.thumbnailPollTimeout)
        let jobURL = Self.baseURL.appending(
            path: "/api/v5/accounts/\(accountID)/networks/\(networkID)/cameras/\(cameraID)/thumbnail/jobs/\(jobID)"
        )

        while Date() < deadline {
            try await Task.sleep(for: .seconds(Self.thumbnailPollInterval))
            let pollData = try await get(url: jobURL)
            guard
                let pollJSON = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any]
            else { continue }

            let state = pollJSON["status"] as? String ?? ""
            if state == "done", let mediaURL = pollJSON["thumbnail"] as? String {
                // Blink returns a relative path; prepend base URL
                let fullURL: URL
                if mediaURL.hasPrefix("http") {
                    fullURL = URL(string: mediaURL)!
                } else {
                    fullURL = Self.baseURL.appending(path: mediaURL)
                }
                return try await downloadMedia(url: fullURL)
            }
            if state == "error" {
                throw BlinkAPIError.mediaUnavailable
            }
        }
        throw BlinkAPIError.mediaUnavailable
    }

    func setArmed(networkID: String, armed: Bool) async throws {
        let path = "/api/v1/network/\(networkID)/\(armed ? "arm" : "disarm")"
        let url = Self.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuthHeaders(to: &request)
        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw BlinkAPIError.unexpectedStatusCode(statusCode) }
    }

    /// Requests a live view session and returns the RTMP or WSS stream URL.
    func requestLiveView(networkID: String, cameraID: String) async throws -> URL {
        guard let accountID else { throw BlinkAPIError.malformedResponse("accountID not set") }
        let url = Self.baseURL.appending(
            path: "/api/v5/accounts/\(accountID)/networks/\(networkID)/cameras/\(cameraID)/liveview"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuthHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw BlinkAPIError.unexpectedStatusCode(statusCode) }

        // Response shape (unofficial, may vary by firmware):
        // {"server": "rtmp://...", "token": "...", "duration": 30}
        // or {"server": "wss://...", "token": "..."}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let server = json["server"] as? String,
            let token = json["token"] as? String
        else {
            throw BlinkAPIError.malformedResponse("liveview response missing server or token")
        }

        // The Janus signalling token is appended as a query parameter.
        var components = URLComponents(string: server)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: token))
        components?.queryItems = queryItems

        guard let streamURL = components?.url else {
            throw BlinkAPIError.malformedResponse("could not construct stream URL from: \(server)")
        }
        return streamURL
    }

    // MARK: - Helpers

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw BlinkAPIError.unexpectedStatusCode(statusCode) }
        return data
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        if let token = authToken {
            request.setValue(token, forHTTPHeaderField: "TOKEN_AUTH")
        }
        request.setValue("McBlink/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
    }

    // MARK: - Keychain

    private func storeTokenInKeychain(token: String, account: String) {
        let tokenData = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[McBlink][BlinkAPI] Keychain add failed: \(addStatus)")
            }
        } else {
            print("[McBlink][BlinkAPI] Keychain update failed: \(updateStatus)")
        }
    }

    private func readTokenFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
