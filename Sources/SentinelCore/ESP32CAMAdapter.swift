// ESP32CAMAdapter.swift — McBlink adapter for AI-Thinker ESP32-CAM
// Swift 6 strict concurrency / macOS 14+
//
// The ESP32-CAM garage_cam firmware exposes:
//   GET /stream                  — MJPEG multipart stream
//   GET /capture                 — single JPEG snapshot (faster than parsing stream)
//   GET /status                  — JSON: ip, rssi, flash, motion (bool), uptime
//   GET /control?var=VAR&val=N   — flash, framesize, quality, hmirror, vflip, etc.
//
// McBlink configuration:
//   source:    .esp32cam
//   streamURL: "http://<camera-ip>"   (base URL, NOT /stream)

import Foundation
import CoreGraphics
import ImageIO

// MARK: - ESP32CAMAdapter

actor ESP32CAMAdapter: CameraAdapter {

    // MARK: Protocol conformance

    let cameraID: UUID
    let capabilities: CameraCapabilities = [.liveStream, .motionEvents, .localStorage]
    private(set) var status: CameraStatus = .connecting

    // MARK: State

    private let profile: CameraProfile
    private let baseURL: URL
    private var motionPollingTask: Task<Void, Never>?

    // MARK: Constants

    private static let timeout: TimeInterval = 6
    private static let motionPollInterval: UInt64 = 2_000_000_000  // 2 seconds in ns

    // MARK: Init

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile  = profile
        // Accept either "http://ip" or "http://ip/stream" as the configured streamURL.
        if let url = URL(string: profile.streamURL),
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.path  = ""
            comps.query = nil
            self.baseURL = comps.url ?? URL(string: "http://invalid")!
        } else {
            self.baseURL = URL(string: "http://invalid")!
        }
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting
        let url = baseURL.appendingPathComponent("status")
        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                status = .online
            } else {
                status = .offline
                throw URLError(.badServerResponse)
            }
        } catch {
            status = .offline
            throw error
        }
    }

    func disconnect() async {
        motionPollingTask?.cancel()
        motionPollingTask = nil
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard status == .online else { throw XPCError.connectionFailed }
        return baseURL.appendingPathComponent("stream")
    }

    func proxyStreamURL() async throws -> URL {
        // ESP32-CAM SVGA is already modest bandwidth; reuse the single stream.
        return try await liveStreamURL()
    }

    /// Hits /capture directly — one JPEG round-trip, no MJPEG parsing needed.
    func latestSnapshot() async throws -> CGImage {
        let url = baseURL.appendingPathComponent("capture")
        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.setValue("McBlink/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image  = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw XPCError.recordingFailed
        }
        return image
    }

    /// Armed = start polling /status for the on-device motion flag every 2s.
    func setArmed(_ armed: Bool) async throws {
        if armed {
            startMotionPolling()
        } else {
            motionPollingTask?.cancel()
            motionPollingTask = nil
        }
    }

    // MARK: - ESP32-CAM-specific controls (beyond the protocol)

    /// Toggles the onboard flash LED (GPIO 4).
    func setFlash(_ on: Bool) async throws {
        try await sendControl(var: "flash", val: on ? 1 : 0)
    }

    /// Sets resolution. Common framesize_t values:
    ///   5 = QVGA (320×240)  8 = VGA (640×480)
    ///  10 = SVGA (800×600) 13 = UXGA (1600×1200)
    func setFramesize(_ val: Int) async throws {
        try await sendControl(var: "framesize", val: val)
    }

    func setHMirror(_ on: Bool) async throws { try await sendControl(var: "hmirror", val: on ? 1 : 0) }
    func setVFlip(_ on: Bool) async throws   { try await sendControl(var: "vflip",   val: on ? 1 : 0) }

    // MARK: - Private

    private func sendControl(var name: String, val: Int) async throws {
        var comps = URLComponents(url: baseURL.appendingPathComponent("control"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "var", value: name),
            URLQueryItem(name: "val", value: "\(val)")
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        let (_, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    private func startMotionPolling() {
        motionPollingTask?.cancel()
        motionPollingTask = Task {
            while !Task.isCancelled {
                await self.pollMotionFlag()
                try? await Task.sleep(nanoseconds: Self.motionPollInterval)
            }
        }
    }

    private func pollMotionFlag() async {
        guard let (data, _) = try? await URLSession.shared.data(
            from: baseURL.appendingPathComponent("status")
        ),
        let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let motion = json["motion"] as? Bool,
        motion
        else { return }

        NotificationCenter.default.post(
            name: .esp32MotionDetected,
            object: nil,
            userInfo: ["cameraID": cameraID]
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    static let esp32MotionDetected = Notification.Name("McBlink.ESP32MotionDetected")
}
