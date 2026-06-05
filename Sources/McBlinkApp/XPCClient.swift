// XPCClient.swift — McBlink
// Manages the NSXPCConnection lifecycle to SentinelCore.
// Swift 6 strict concurrency. @MainActor isolates all state mutations.

import Foundation

enum XPCClientError: Error, LocalizedError {
    case notConnected
    case invalidProxy

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection to SentinelCore is not available."
        case .invalidProxy: return "Could not obtain SentinelCore remote proxy."
        }
    }
}

@MainActor
final class XPCClient {

    // MARK: - State

    // nonisolated(unsafe) is required because deinit is nonisolated in Swift 6
    // but NSXPCConnection.invalidate() is thread-safe and must be called there.
    nonisolated(unsafe) private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private let serviceName = "com.heyfinal.mcblink.sentinelcore"

    private(set) var isConnected: Bool = false
    var onConnectionStateChanged: ((Bool) -> Void)?

    // MARK: - Lifecycle

    init() {
        connect()
    }

    deinit {
        connection?.invalidate()
    }

    // MARK: - Connection management

    private func connect() {
        // Embedded XPC services (Contents/XPCServices/*.xpc) are reached by their
        // bundle identifier via serviceName — NOT machServiceName (that's for
        // launchd-registered mach services).
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.remoteObjectInterface = McBlinkXPCInterface.make()

        // XPC invokes these handlers off the MainActor executor. The closures
        // must be @Sendable (non-isolated); the inner Task hops to MainActor.
        conn.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleInvalidation()
            }
        }
        conn.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleInvalidation()
            }
        }

        conn.resume()
        connection = conn
        reconnectDelay = 1.0
        // Validate the connection with a lightweight XPC call before
        // reporting connected. conn.resume() alone doesn't guarantee
        // the remote service is reachable.
        let weakSelf = self
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable _ in
            Task { @MainActor in
                weakSelf.handleInvalidation()
            }
        }
        if let p = proxy as? any McBlinkXPCProtocol {
            p.getCameras { @Sendable _ in
                Task { @MainActor in
                    weakSelf.isConnected = true
                    weakSelf.onConnectionStateChanged?(true)
                }
            }
        }
    }

    private func handleInvalidation() {
        connection = nil
        isConnected = false
        onConnectionStateChanged?(false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.connect()
        }
    }

    // MARK: - Proxy access

    private func proxy() throws -> any McBlinkXPCProtocol {
        guard let conn = connection else { throw XPCClientError.notConnected }
        guard let proxy = conn.remoteObjectProxy as? any McBlinkXPCProtocol else {
            throw XPCClientError.invalidProxy
        }
        return proxy
    }

    private func proxyWithErrorHandler() throws -> any McBlinkXPCProtocol {
        guard let conn = connection else { throw XPCClientError.notConnected }
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor in
                self?.handleInvalidation()
            }
        }
        guard let typed = proxy as? any McBlinkXPCProtocol else {
            throw XPCClientError.invalidProxy
        }
        return typed
    }

    // MARK: - Camera registry

    func getCameras() async throws -> [CameraProfile] {
        guard let conn = connection else { throw XPCClientError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            // Per-call error handler resumes the continuation on XPC failure,
            // otherwise an unreachable service causes loadCameras to hang forever.
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in
                continuation.resume(throwing: error)
            }
            guard let p = proxy as? any McBlinkXPCProtocol else {
                continuation.resume(throwing: XPCClientError.invalidProxy)
                return
            }
            p.getCameras { data in
                do {
                    let profiles = try JSONDecoder().decode([CameraProfile].self, from: data)
                    continuation.resume(returning: profiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func addCamera(_ profile: CameraProfile) async throws {
        let p = try proxyWithErrorHandler()
        let data = try JSONEncoder().encode(profile)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.addCamera(data) { success, _ in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.cameraNotFound) }
            }
        }
    }

    func removeCamera(_ id: UUID) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.removeCamera(id.uuidString) { success in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.cameraNotFound) }
            }
        }
    }

    // MARK: - Arm / Disarm

    func armCamera(_ id: UUID) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.armCamera(id.uuidString) { success, _ in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.recordingFailed) }
            }
        }
    }

    func disarmCamera(_ id: UUID) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.disarmCamera(id.uuidString) { success, _ in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.recordingFailed) }
            }
        }
    }

    // MARK: - Events & Clips

    func getRecentEvents(_ cameraID: UUID?, limit: Int = 50) async throws -> [DetectionEvent] {
        let p = try proxyWithErrorHandler()
        let idStr = cameraID?.uuidString ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            p.getRecentEvents(idStr, limit: limit) { data in
                do {
                    let events = try JSONDecoder().decode([DetectionEvent].self, from: data)
                    continuation.resume(returning: events)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func getClips(_ cameraID: UUID?, startTime: Date, endTime: Date) async throws -> [ClipRecord] {
        let p = try proxyWithErrorHandler()
        let idStr = cameraID?.uuidString ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            p.getClips(
                idStr,
                startTime: startTime.timeIntervalSince1970,
                endTime: endTime.timeIntervalSince1970
            ) { data in
                do {
                    let clips = try JSONDecoder().decode([ClipRecord].self, from: data)
                    continuation.resume(returning: clips)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func exportClip(_ clipID: UUID, toPath: String) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.exportClip(clipID.uuidString, toPath: toPath) { success, _ in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.recordingFailed) }
            }
        }
    }

    // MARK: - Snapshot

    /// Returns the latest JPEG snapshot (cached cloud thumbnail). Nil if unavailable.
    func getSnapshot(cameraID: UUID) async -> Data? {
        await snapshotCall(cameraID: cameraID, fresh: false)
    }

    /// Forces a fresh capture from the camera (slow, costs battery).
    func getFreshSnapshot(cameraID: UUID) async -> Data? {
        await snapshotCall(cameraID: cameraID, fresh: true)
    }

    private func snapshotCall(cameraID: UUID, fresh: Bool) async -> Data? {
        guard let conn = connection else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable _ in
                cont.resume(returning: nil)
            }
            guard let p = proxy as? any McBlinkXPCProtocol else {
                cont.resume(returning: nil)
                return
            }
            let handler: (Data) -> Void = { data in
                cont.resume(returning: data.isEmpty ? nil : data)
            }
            if fresh {
                p.getFreshSnapshot(cameraID.uuidString, reply: handler)
            } else {
                p.getSnapshot(cameraID.uuidString, reply: handler)
            }
        }
    }

    // MARK: - Health

    func getHealthReport(_ cameraID: UUID) async throws -> HealthReport {
        let p = try proxyWithErrorHandler()
        return try await withCheckedThrowingContinuation { continuation in
            p.getHealthReport(cameraID.uuidString) { data in
                do {
                    let report = try JSONDecoder().decode(HealthReport.self, from: data)
                    continuation.resume(returning: report)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func getAllHealthReports() async throws -> [HealthReport] {
        let p = try proxyWithErrorHandler()
        return try await withCheckedThrowingContinuation { continuation in
            p.getAllHealthReports { data in
                do {
                    let reports = try JSONDecoder().decode([HealthReport].self, from: data)
                    continuation.resume(returning: reports)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Lockdown

    func triggerLockdown() async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.triggerLockdown { success in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.connectionFailed) }
            }
        }
    }

    // MARK: - Site Profiles

    func getSiteProfiles() async throws -> [SiteProfile] {
        let p = try proxyWithErrorHandler()
        return try await withCheckedThrowingContinuation { continuation in
            p.getSiteProfiles { data in
                do {
                    let profiles = try JSONDecoder().decode([SiteProfile].self, from: data)
                    continuation.resume(returning: profiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func switchSiteProfile(_ id: UUID) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.switchSiteProfile(id.uuidString) { success, _ in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.cameraNotFound) }
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ settings: AppSettings) async throws {
        let p = try proxyWithErrorHandler()
        let data = try JSONEncoder().encode(settings)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.updateSettings(data) { success in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.connectionFailed) }
            }
        }
    }

    func getSettings() async throws -> AppSettings {
        let p = try proxyWithErrorHandler()
        return try await withCheckedThrowingContinuation { continuation in
            p.getSettings { data in
                do {
                    let settings = try JSONDecoder().decode(AppSettings.self, from: data)
                    continuation.resume(returning: settings)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Credentials

    func storeCameraCredential(_ cameraID: UUID, password: String) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.storeCameraCredential(cameraID.uuidString, password: password) { success in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.connectionFailed) }
            }
        }
    }

    // MARK: - ESP32-CAM controls

    func esp32SetFlash(_ cameraID: UUID, on: Bool) async throws {
        let p = try proxyWithErrorHandler()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.esp32SetFlash(cameraID.uuidString, on: on) { success in
                if success { cont.resume() } else { cont.resume(throwing: XPCError.connectionFailed) }
            }
        }
    }

    // MARK: - Blink Auth

    struct BlinkAuthResult {
        let ok: Bool
        let needsPin: Bool
        let message: String?
    }

    func blinkAuth(email: String, password: String) async -> BlinkAuthResult {
        guard let conn = connection else {
            return BlinkAuthResult(ok: false, needsPin: false, message: "XPC not connected")
        }
        return await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable err in
                cont.resume(returning: BlinkAuthResult(ok: false, needsPin: false,
                                                       message: err.localizedDescription))
            }
            guard let p = proxy as? any McBlinkXPCProtocol else {
                cont.resume(returning: BlinkAuthResult(ok: false, needsPin: false, message: "No proxy"))
                return
            }
            p.blinkAuth(email, password: password) { data in
                cont.resume(returning: Self.parseBlinkStatus(data))
            }
        }
    }

    func blinkAuthPin(_ pin: String) async -> BlinkAuthResult {
        guard let conn = connection else {
            return BlinkAuthResult(ok: false, needsPin: false, message: "XPC not connected")
        }
        return await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable err in
                cont.resume(returning: BlinkAuthResult(ok: false, needsPin: false,
                                                       message: err.localizedDescription))
            }
            guard let p = proxy as? any McBlinkXPCProtocol else {
                cont.resume(returning: BlinkAuthResult(ok: false, needsPin: false, message: "No proxy"))
                return
            }
            p.blinkAuthPin(pin) { data in
                cont.resume(returning: Self.parseBlinkStatus(data))
            }
        }
    }

    private static func parseBlinkStatus(_ data: Data) -> BlinkAuthResult {
        guard
            let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return BlinkAuthResult(ok: false, needsPin: false, message: "Invalid response from helper")
        }
        let status = dict["status"] ?? ""
        return BlinkAuthResult(
            ok: status == "ok",
            needsPin: status == "needs_pin",
            message: dict["message"]
        )
    }
}
