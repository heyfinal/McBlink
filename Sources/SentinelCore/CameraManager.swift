// CameraManager.swift — McBlink central camera registry and orchestrator
// Swift 6 strict concurrency / macOS 14+

import Foundation
import CoreGraphics

// MARK: - CameraManager

/// Central registry for all active camera adapters.
/// All mutable state is confined to the actor's executor.
actor CameraManager {

    // MARK: State

    var adapters: [UUID: any CameraAdapter] = [:]
    var profiles: [UUID: CameraProfile] = [:]

    let healthCollector: HealthCollector
    private let recordingEngine: RecordingEngine
    private let encryptionManager: EncryptionManager
    private let db: DatabaseManager
    private let ai: AIDetectionPipeline
    private let alerts: AlertManager

    private var healthPollingTask: Task<Void, Never>?
    private var pollCycleCount: Int = 0
    private var offlineSince: [UUID: Date] = [:]

    // MARK: Init

    init(
        healthCollector: HealthCollector,
        recordingEngine: RecordingEngine,
        encryptionManager: EncryptionManager,
        db: DatabaseManager,
        ai: AIDetectionPipeline,
        alerts: AlertManager
    ) {
        self.healthCollector = healthCollector
        self.recordingEngine = recordingEngine
        self.encryptionManager = encryptionManager
        self.db = db
        self.ai = ai
        self.alerts = alerts
    }

    // MARK: Registration

    /// Creates the adapter for `profile`, calls `connect()`, and stores both.
    /// For Blink cameras, routes downloaded clips into the RecordingEngine and
    /// starts adaptive motion-event polling.
    func register(profile: CameraProfile) async throws {
        let adapter = CameraAdapterFactory.make(for: profile)
        try await adapter.connect()
        adapters[profile.id] = adapter
        profiles[profile.id] = profile

        // Route motion-triggered media into the recording pipeline for adapters
        // that support it (ESP32-CAM motion snapshots). BlinkBridgeAdapter is
        // snapshot-only (no clip download without a Sync Module + USB storage),
        // so it does not receive a clip handler here.
        if let esp = adapter as? ESP32CAMAdapter {
            await esp.setClipHandler(await makeClipHandler(for: profile))
            // Honour the persisted armed state — don't silently re-arm a camera
            // the user explicitly disarmed before the service last stopped.
            if profile.isArmed {
                try? await esp.setArmed(true)
            }
        }
    }

    /// Builds a Sendable clip handler that runs AI analysis on the plaintext clip,
    /// encrypts + catalogs incoming media for `profile`, fires filtered detection alerts,
    /// and records health events.
    private func makeClipHandler(for profile: CameraProfile) async -> @Sendable (Data, URL) async -> Void {
        let engine = recordingEngine
        let enc = encryptionManager
        let database = db
        let aiPipeline = ai
        let alertMgr = alerts
        let healthCol = healthCollector
        let camID = profile.id
        let camName = profile.name
        let zones = profile.detectionZones
        let basePath: String
        if let site = try? await db.fetchSiteProfile(id: profile.siteProfileID) {
            basePath = site.storageBasePath
        } else {
            basePath = Self.defaultClipsBasePath(for: profile.id)
        }
        try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        return { data, sourceURL in
            do {
                let clipID = try await engine.onClipDownloaded(
                    cameraID: camID, clipData: data, sourceURL: sourceURL,
                    basePath: basePath, encryptionManager: enc, db: database
                )

                // AI analysis on the plaintext temp file kept by RecordingEngine.
                let tempPath = FileManager.default.temporaryDirectory
                    .appending(path: "\(clipID.uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: tempPath) }
                if FileManager.default.fileExists(atPath: tempPath.path) {
                    let event = try await aiPipeline.analyzeClip(
                        at: tempPath, cameraID: camID, clipID: clipID, zones: zones)
                    if !event.detectedClasses.isEmpty {
                        try? await database.upsertDetectionEvent(event)
                        await healthCol.recordEvent(cameraID: camID, at: event.timestamp)
                        // Check notification filters before alerting
                        let settings = (try? await database.fetchSettings()) ?? AppSettings()
                        let enabledClasses = event.detectedClasses.filter {
                            settings.isNotificationEnabled(for: $0)
                        }
                        if !enabledClasses.isEmpty {
                            await alertMgr.sendDetectionAlert(event: event, cameraName: camName)
                        }
                    }
                }
            } catch {
                print("[CameraManager] clip ingest failed for \(camID): \(error)")
            }
        }
    }

    /// Tears down the adapter for `cameraID` and removes it from both maps.
    func unregister(cameraID: UUID) async {
        if let adapter = adapters[cameraID] {
            await adapter.disconnect()
        }
        adapters.removeValue(forKey: cameraID)
        profiles.removeValue(forKey: cameraID)
    }

    /// Returns the adapter for `id`, or nil if not registered.
    func adapter(for id: UUID) -> (any CameraAdapter)? {
        adapters[id]
    }

    // MARK: Arming

    func armCamera(_ id: UUID) async throws {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        try await adapter.setArmed(true)
    }

    func disarmCamera(_ id: UUID) async throws {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        try await adapter.setArmed(false)
    }

    /// Arms all registered cameras concurrently, ignoring individual failures.
    func armAll() async {
        await withTaskGroup(of: Void.self) { group in
            for (id, adapter) in adapters {
                group.addTask {
                    do {
                        try await adapter.setArmed(true)
                    } catch {
                        // Individual arm failures are logged but do not abort the group.
                        print("[CameraManager] armAll: camera \(id) failed — \(error)")
                    }
                }
            }
        }
    }

    // MARK: Stream / Snapshot Passthrough

    func esp32SetFlash(_ id: UUID, on: Bool) async throws {
        guard let adapter = adapters[id] as? ESP32CAMAdapter else { throw XPCError.cameraNotFound }
        try await adapter.setFlash(on)
    }

    func latestSnapshot(for id: UUID) async throws -> CGImage {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        return try await adapter.latestSnapshot()
    }

    /// Forces a freshly-captured snapshot when the adapter supports it; falls
    /// back to the cached snapshot for adapters with no fresh-capture path.
    func freshSnapshot(for id: UUID) async throws -> CGImage {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        if let bridge = adapter as? BlinkBridgeAdapter {
            return try await bridge.latestSnapshot(fresh: true)
        }
        return try await adapter.latestSnapshot()
    }

    func liveStreamURL(for id: UUID) async throws -> URL {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        return try await adapter.liveStreamURL()
    }

    func proxyStreamURL(for id: UUID) async throws -> URL {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
        return try await adapter.proxyStreamURL()
    }

    // MARK: Health Polling

    /// Starts a background Task that queries each adapter's status every 30 seconds
    /// and writes a HealthReport to `healthCollector`.
    /// Safe to call multiple times — cancels any existing poll before starting a new one.
    func startHealthPolling() {
        healthPollingTask?.cancel()
        healthPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollAllAdapters()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break // Task cancelled
                }
            }
        }
    }

    /// Queries every registered adapter's status, attempts reconnection for
    /// offline cameras, publishes HealthReports, fires offline alerts after 60s,
    /// and periodically refreshes storage metrics.
    private func pollAllAdapters() async {
        pollCycleCount += 1
        let snapshot = adapters
        let profileSnapshot = profiles
        await withTaskGroup(of: (UUID, CameraStatus)?.self) { group in
            for (id, adapter) in snapshot {
                group.addTask {
                    let status = await adapter.status
                    // Attempt reconnection for offline cameras.
                    if case .offline = status, let profile = profileSnapshot[id] {
                        do {
                            try await adapter.connect()
                            NSLog("[McBlink] reconnected camera '%@'", profile.name)
                            return (id, await adapter.status)
                        } catch {
                            return (id, CameraStatus.offline)
                        }
                    }
                    return (id, status)
                }
            }
            for await result in group {
                guard let (id, status) = result else { continue }

                // Track offline duration and fire alert after 60s
                if case .offline = status {
                    if offlineSince[id] == nil {
                        offlineSince[id] = Date()
                    } else if let since = offlineSince[id],
                              Date().timeIntervalSince(since) >= 60 {
                        let name = profileSnapshot[id]?.name ?? "Unknown"
                        await alerts.sendCameraOfflineAlert(cameraID: id, cameraName: name)
                        // Reset so we don't spam — next alert after another 60s gap
                        offlineSince[id] = Date()
                    }
                } else {
                    offlineSince.removeValue(forKey: id)
                }

                // FPS is 0 for snapshot-based adapters (ESP32, Blink) — accurate, not a bug.
                await healthCollector.update(
                    cameraID: id,
                    status: status,
                    fps: 0,
                    dropped: 0
                )
            }
        }

        // Every 10 poll cycles (~5 min at 30s interval), refresh storage metrics
        if pollCycleCount % 10 == 0 {
            for (id, profile) in profileSnapshot {
                let basePath: String
                if let site = try? await db.fetchSiteProfile(id: profile.siteProfileID) {
                    basePath = site.storageBasePath
                } else {
                    basePath = Self.defaultClipsBasePath(for: id)
                }
                await healthCollector.refreshStorageUsed(cameraID: id, basePath: basePath)
            }
        }
    }

    // MARK: Paths

    /// Default per-camera clips directory under Application Support, created if needed.
    private static func defaultClipsBasePath(for cameraID: UUID) -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("McBlink/clips/\(cameraID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: Deallocation

    deinit {
        healthPollingTask?.cancel()
    }
}

// MARK: - CameraManaging conformance
// Adapts the actor's method names to the protocol the XPC service depends on.

extension CameraManager: CameraManaging {
    func registerCamera(_ profile: CameraProfile) async throws {
        try await register(profile: profile)
    }
    func unregisterCamera(_ id: UUID) async throws {
        await unregister(cameraID: id)
    }
    func arm(_ id: UUID) async throws {
        try await armCamera(id)
    }
    func disarm(_ id: UUID) async throws {
        try await disarmCamera(id)
    }
    // `armAll()` (non-throwing) already satisfies the throwing requirement.
    func reloadSiteProfile(_ id: UUID) async throws {
        // Live multi-site switching is Phase 5; no-op preserves single-site behavior.
    }
}
