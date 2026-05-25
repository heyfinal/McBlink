// BlinkAdapter.swift — Blink camera adapter for McBlink
// Swift 6 strict concurrency / macOS 14+

import Foundation
import CoreGraphics
import ImageIO

// MARK: - BlinkAdapter

actor BlinkAdapter: CameraAdapter {

    // MARK: Protocol conformance

    let cameraID: UUID
    let capabilities: CameraCapabilities = [.liveStream, .motionEvents, .localStorage]
    private(set) var status: CameraStatus = .connecting

    // MARK: Blink-specific state

    private let profile: CameraProfile
    private var networkID: String
    private var syncModuleID: String
    private var blinkCameraID: String
    private var authToken: String?

    private let apiClient: BlinkAPIClient
    private var motionPollingTask: Task<Void, Never>?

    // Injected by startMotionPolling; used to route downloaded clips.
    var onClipAvailable: (@Sendable (Data, URL) async -> Void)?

    // MARK: Init

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile = profile
        self.apiClient = BlinkAPIClient()

        // Parse Blink-specific fields from profile's streamURL convention:
        // blink://<networkID>/<syncModuleID>/<blinkCameraID>
        // Fall back to empty strings; connect() will populate from homescreen.
        if let url = URL(string: profile.streamURL),
           url.scheme == "blink",
           let host = url.host {
            let parts = url.pathComponents.filter { $0 != "/" }
            networkID = host
            syncModuleID = parts.count > 0 ? parts[0] : ""
            blinkCameraID = parts.count > 1 ? parts[1] : ""
        } else {
            networkID = ""
            syncModuleID = ""
            blinkCameraID = ""
        }
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting

        guard let email = profile.username, !email.isEmpty else {
            status = .offline
            throw XPCError.authFailed
        }

        // Prefer Keychain token; fall back to authenticating with profile password.
        await apiClient.loadStoredCredentials(email: email)
        if await apiClient.authToken == nil {
            guard !profile.password.isEmpty else {
                status = .offline
                throw XPCError.authFailed
            }
            try await apiClient.authenticate(email: email, password: profile.password)
        }

        // Discover the network and camera IDs from the homescreen.
        let homescreenData = try await apiClient.getHomescreen()
        try populateIDs(from: homescreenData)

        status = .online
    }

    func disconnect() async {
        motionPollingTask?.cancel()
        motionPollingTask = nil
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard status == .online || status == .connecting else {
            throw XPCError.connectionFailed
        }
        do {
            let url = try await apiClient.requestLiveView(networkID: networkID, cameraID: blinkCameraID)
            return url
        } catch {
            status = .degraded("live view unavailable")
            throw error
        }
    }

    // Blink does not expose a separate substream; proxy == live.
    func proxyStreamURL() async throws -> URL {
        return try await liveStreamURL()
    }

    func latestSnapshot() async throws -> CGImage {
        let jpegData = try await apiClient.requestThumbnail(
            networkID: networkID,
            cameraID: blinkCameraID
        )
        guard
            let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw XPCError.recordingFailed
        }
        return image
    }

    func setArmed(_ armed: Bool) async throws {
        try await apiClient.setArmed(networkID: networkID, armed: armed)
    }

    // MARK: - Motion Polling

    /// Starts a background Task that polls for new Blink events every 8 seconds.
    /// On receiving a new event it downloads the clip and calls `onClipAvailable`.
    /// Backs off to 30 s on HTTP 429 (rate-limit).
    func startMotionPolling() {
        motionPollingTask?.cancel()
        motionPollingTask = Task { [weak self] in
            guard let self else { return }
            var lastSeenEventID: Int = 0
            var pollInterval: Duration = .seconds(8)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                    guard !Task.isCancelled else { break }

                    let events = try await self.apiClient.getEvents(networkID: self.networkID)

                    // Restore normal cadence after a successful poll.
                    pollInterval = .seconds(8)

                    // Events arrive newest-first; find new ones.
                    let newEvents = events.filter { $0.id > lastSeenEventID }
                    if let maxID = newEvents.max(by: { $0.id < $1.id })?.id {
                        lastSeenEventID = maxID
                    }

                    for event in newEvents {
                        guard let mediaPath = event.media_url else { continue }
                        let mediaURL: URL
                        if mediaPath.hasPrefix("http") {
                            guard let u = URL(string: mediaPath) else { continue }
                            mediaURL = u
                        } else {
                            mediaURL = BlinkAPIClient.baseURL.appending(path: mediaPath)
                        }
                        do {
                            let clipData = try await self.apiClient.downloadMedia(url: mediaURL)
                            let handler = await self.onClipAvailable
                            await handler?(clipData, mediaURL)
                        } catch {
                            print("[BlinkAdapter] clip download failed: \(error)")
                        }
                    }

                } catch let error as BlinkAPIError {
                    if case .unexpectedStatusCode(429) = error {
                        // Rate-limited: back off to 30 s.
                        pollInterval = .seconds(30)
                    } else {
                        print("[BlinkAdapter] motion poll error: \(error)")
                    }
                } catch {
                    if (error as? CancellationError) != nil { break }
                    print("[BlinkAdapter] motion poll error: \(error)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Parses the homescreen JSON to find the matching camera's networkID and blinkCameraID.
    private func populateIDs(from data: Data) throws {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BlinkAPIError.malformedResponse("homescreen response is not a JSON object")
        }

        // Homescreen contains "networks" array, each with "cameras" array.
        // Match by camera name (profile.name) as the stable cross-session identifier.
        guard let networks = json["networks"] as? [[String: Any]] else {
            // Older homescreen shape wraps under "account" > "networks".
            throw BlinkAPIError.malformedResponse("homescreen missing 'networks' key")
        }

        for network in networks {
            guard
                let netID = (network["id"] as? Int).map(String.init),
                let cameras = network["cameras"] as? [[String: Any]]
            else { continue }

            for camera in cameras {
                let camName = camera["name"] as? String ?? ""
                let camID = (camera["id"] as? Int).map(String.init) ?? ""

                // Match by name if IDs were not pre-configured.
                if camName == profile.name || camID == blinkCameraID || blinkCameraID.isEmpty {
                    networkID = netID
                    blinkCameraID = camID
                    if let syncID = (network["summary"] as? [String: Any])?["id"] as? Int {
                        syncModuleID = String(syncID)
                    }
                    return
                }
            }
        }
        // If no match found keep whatever was parsed from the stream URL.
    }
}
