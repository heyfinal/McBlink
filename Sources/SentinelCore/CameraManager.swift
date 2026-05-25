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

    private var healthPollingTask: Task<Void, Never>?

    // MARK: Init

    init(
        healthCollector: HealthCollector,
        recordingEngine: RecordingEngine,
        encryptionManager: EncryptionManager,
        db: DatabaseManager
    ) {
        self.healthCollector = healthCollector
        self.recordingEngine = recordingEngine
        self.encryptionManager = encryptionManager
        self.db = db
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

        if let blink = adapter as? BlinkAdapter {
            let engine = recordingEngine
            let enc = encryptionManager
            let database = db
            let camID = profile.id

            // Clips are stored under the owning site profile's storage path,
            // falling back to the per-camera app-support clips directory.
            let basePath: String
            if let site = try? await db.fetchSiteProfile(id: profile.siteProfileID) {
                basePath = site.storageBasePath
            } else {
                basePath = Self.defaultClipsBasePath(for: profile.id)
            }
            try? FileManager.default.createDirectory(
                atPath: basePath, withIntermediateDirectories: true
            )
            await blink.setClipHandler { data, sourceURL in
                do {
                    try await engine.onClipDownloaded(
                        cameraID: camID,
                        clipData: data,
                        sourceURL: sourceURL,
                        basePath: basePath,
                        encryptionManager: enc,
                        db: database
                    )
                } catch {
                    print("[CameraManager] clip ingest failed for \(camID): \(error)")
                }
            }
            await blink.startMotionPolling()
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

    func latestSnapshot(for id: UUID) async throws -> CGImage {
        guard let adapter = adapters[id] else { throw XPCError.cameraNotFound }
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

    /// Queries every registered adapter's status and publishes a HealthReport.
    private func pollAllAdapters() async {
        // Snapshot current adapter map to avoid holding the actor lock across awaits.
        let snapshot = adapters
        await withTaskGroup(of: (UUID, CameraStatus)?.self) { group in
            for (id, adapter) in snapshot {
                group.addTask {
                    let status = await adapter.status
                    return (id, status)
                }
            }
            for await result in group {
                guard let (id, status) = result else { continue }
                await healthCollector.update(
                    cameraID: id,
                    status: status,
                    fps: 0,
                    dropped: 0
                )
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
