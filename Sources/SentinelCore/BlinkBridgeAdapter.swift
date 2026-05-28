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

    // MARK: - Path resolution (no hardcoded user paths)

    /// ~/Library/Application Support/McBlink
    private static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("McBlink")
    }

    /// The venv Python binary: ~/Library/Application Support/McBlink/blink-venv/bin/python
    private static var venvPython: String {
        appSupportDir.appendingPathComponent("blink-venv/bin/python").path
    }

    /// blink_creds.json: Application Support first, legacy path as fallback.
    private static var credsPath: String {
        let primary = appSupportDir.appendingPathComponent("blink_creds.json").path
        if FileManager.default.fileExists(atPath: primary) { return primary }
        // Migrate creds from the old location on first run.
        let legacy = NSHomeDirectory() + "/.mcblink_capture/blink_creds.json"
        if FileManager.default.fileExists(atPath: legacy) {
            try? FileManager.default.createDirectory(
                at: appSupportDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(
                atPath: legacy, toPath: primary)
        }
        return primary
    }

    /// blink_helper.py: bundled resource first, Application Support copy as fallback.
    private static var helperPath: String {
        if let bundled = Bundle.main.path(forResource: "blink_helper", ofType: "py") {
            return bundled
        }
        // Dev fallback when running un-bundled from Xcode.
        return NSHomeDirectory() + "/.mcblink_capture/blink_helper.py"
    }

    /// Python interpreter: venv if it exists, system python3 otherwise.
    private static var pythonPath: String {
        FileManager.default.fileExists(atPath: venvPython)
            ? venvPython
            : "/usr/bin/python3"
    }

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.blinkCameraName = profile.name
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting
        // First-run: create venv + install blinkpy in Application Support.
        try await ensureVenv()
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
        try await latestSnapshot(fresh: false)
    }

    /// Pulls a snapshot from Blink. With `fresh: true` the camera is woken to
    /// capture a new image (~10s, battery-costly); otherwise the cached cloud
    /// thumbnail is returned (instant, no wake).
    func latestSnapshot(fresh: Bool) async throws -> CGImage {
        let tmp = NSTemporaryDirectory() + "mcblink-blink-\(cameraID.uuidString).jpg"
        var args = ["snapshot", blinkCameraName, tmp]
        if fresh { args.append("--fresh") }
        let data = try await runHelper(args)
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

    // MARK: - Venv bootstrap

    /// Creates ~/Library/Application Support/McBlink/blink-venv and installs
    /// blinkpy + aiohttp if the venv doesn't already exist. No-op on subsequent calls.
    private func ensureVenv() async throws {
        guard !FileManager.default.fileExists(atPath: Self.venvPython) else { return }
        try? FileManager.default.createDirectory(
            at: Self.appSupportDir, withIntermediateDirectories: true)
        let venvDir = Self.appSupportDir.appendingPathComponent("blink-venv").path
        // python3 -m venv <dir>
        try await runProcess("/usr/bin/python3", args: ["-m", "venv", venvDir])
        // Prefer requirements.txt from the bundle; fall back to explicit packages.
        let pip = Self.appSupportDir.appendingPathComponent("blink-venv/bin/pip").path
        if let reqsPath = Bundle.main.path(forResource: "requirements", ofType: "txt") {
            try await runProcess(pip, args: ["install", "-r", reqsPath, "--quiet"])
        } else {
            try await runProcess(pip, args: [
                "install", "blinkpy>=0.22.2", "aiohttp>=3.9", "--quiet"
            ])
        }
    }

    // MARK: - Helper process

    /// Runs the blinkpy helper with `args` and returns its stdout (JSON).
    /// BLINK_CREDS is injected so the script never needs a hardcoded path.
    private func runHelper(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: Self.pythonPath)
                proc.arguments    = [Self.helperPath] + args
                proc.environment  = ProcessInfo.processInfo.environment
                    .merging(["BLINK_CREDS": Self.credsPath]) { _, new in new }
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError  = Pipe()
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

    /// Runs an arbitrary executable and waits for it to exit.
    /// Throws XPCError.connectionFailed if the process exits non-zero.
    private func runProcess(_ executable: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments     = args
                proc.standardOutput = Pipe()
                proc.standardError  = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: ())
                    } else {
                        cont.resume(throwing: XPCError.connectionFailed)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
