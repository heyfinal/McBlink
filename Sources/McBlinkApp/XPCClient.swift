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
        let conn = NSXPCConnection(machServiceName: serviceName, options: [])
        conn.remoteObjectInterface = McBlinkXPCInterface.make()

        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleInvalidation()
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleInvalidation()
            }
        }

        conn.resume()
        connection = conn
        isConnected = true
        reconnectDelay = 1.0
        onConnectionStateChanged?(true)
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
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
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
        let p = try proxyWithErrorHandler()
        return try await withCheckedThrowingContinuation { continuation in
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

    /// Returns the latest JPEG snapshot for the camera.
    /// The XPC protocol does not yet declare getSnapshot; SentinelCore will add
    /// it when Phase 2 live view is wired. For now this method returns nil, which
    /// callers treat as "no snapshot available."
    func getSnapshot(cameraID: UUID) async -> Data? {
        nil
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
}
