// BlinkBridgeAdapter.swift — Blink camera adapter via the blinkpy helper.
// Swift 6 strict concurrency / macOS 14+
//
// Blink migrated to OAuth2 PKCE; the in-Swift v4 client is obsolete. This adapter
// shells out to a maintained blinkpy helper (path B) that owns auth + the API.
// Snapshot mode only: without a subscription AND without Sync-Module USB local
// storage, Blink stores no downloadable clips, so "recording" is snapshot-on-poll.
// When local storage is added, extend the helper with a clip-download command and
// route it into RecordingEngine like BlinkAdapter does.

import Foundation
import CoreGraphics
import ImageIO

actor BlinkBridgeAdapter: CameraAdapter {

    // MARK: Protocol conformance

    let cameraID: UUID
    let capabilities: CameraCapabilities = [.motionEvents]
    private(set) var status: CameraStatus = .connecting

    // MARK: Blink-specific state

    /// The Blink camera display name (matches the helper's `snapshot <name>`).
    private let blinkCameraName: String

    // Local-only paths for the personal-project prototype. TODO: bundle the helper
    // + venv inside the app and resolve these relative to the bundle.
    private static let pythonPath = "/Users/daniel/.mcblink_capture/venv/bin/python"
    private static let helperPath = "/Users/daniel/.mcblink_capture/blink_helper.py"

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.blinkCameraName = profile.name
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting
        let data = try await runHelper(["cameras"])
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cams = obj["cameras"] as? [[String: Any]]
        else {
            status = .offline
            throw XPCError.connectionFailed
        }
        let names = cams.compactMap { $0["name"] as? String }
        guard names.contains(blinkCameraName) else {
            status = .degraded("camera '\(blinkCameraName)' not found in Blink account")
            throw XPCError.cameraNotFound
        }
        status = .online
    }

    func disconnect() async {
        status = .offline
    }

    // Blink live video isn't available through the bridge (on-demand WebRTC only).
    func liveStreamURL() async throws -> URL {
        throw XPCError.connectionFailed
    }

    func proxyStreamURL() async throws -> URL {
        throw XPCError.connectionFailed
    }

    func latestSnapshot() async throws -> CGImage {
        let tmp = NSTemporaryDirectory() + "mcblink-blink-\(cameraID.uuidString).jpg"
        let data = try await runHelper(["snapshot", blinkCameraName, tmp])
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["error"] != nil {
            throw XPCError.recordingFailed
        }
        let url = URL(fileURLWithPath: tmp)
        defer { try? FileManager.default.removeItem(at: url) }
        guard
            let imgData = try? Data(contentsOf: url),
            let src = CGImageSourceCreateWithData(imgData as CFData, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw XPCError.recordingFailed
        }
        return img
    }

    // Arming via the bridge is not yet exposed by the helper; no-op for now.
    func setArmed(_ armed: Bool) async throws {}

    // MARK: - Helper process

    /// Runs the blinkpy helper with `args` and returns its stdout (JSON).
    private func runHelper(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: Self.pythonPath)
                proc.arguments = [Self.helperPath] + args
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: out)
            }
        }
    }
}
