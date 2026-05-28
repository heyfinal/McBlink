// SentinelCoreService.swift — Main XPC service implementation
// Swift 6 / macOS 14

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Swift 6 XPC bridge helper
// ObjC XPC reply closures are @escaping but not @Sendable.
// Wrap them so Task{} captures are satisfied without disabling strict concurrency.
private struct S<T>: @unchecked Sendable { let v: T }

// MARK: - Subsystem protocols (replaced by real actors in later phases)

protocol CameraManaging: Sendable {
    func registerCamera(_ profile: CameraProfile) async throws
    func unregisterCamera(_ id: UUID) async throws
    func arm(_ id: UUID) async throws
    func disarm(_ id: UUID) async throws
    func armAll() async throws
    func reloadSiteProfile(_ id: UUID) async throws
}

protocol OffsiteSyncProtocol: Sendable {
    func triggerImmediateSync() async
}

// MARK: - SentinelCoreService

@objc
final class SentinelCoreService: NSObject, McBlinkXPCProtocol, @unchecked Sendable {

    static let shared = SentinelCoreService()

    private let db: DatabaseManager
    private let encryption: EncryptionManager
    private let alerts: AlertManager
    private let health: HealthCollector
    private let cameras: CameraManager
    private let offsite: AnyOffsiteSync

    private override init() {
        let dbManager = DatabaseManager()
        let enc       = EncryptionManager()
        let alertMgr  = AlertManager()
        let healthMgr = HealthCollector(db: dbManager)
        let recording = RecordingEngine()
        db         = dbManager
        encryption = enc
        alerts     = alertMgr
        health     = healthMgr
        cameras    = CameraManager(
            healthCollector: healthMgr,
            recordingEngine: recording,
            encryptionManager: enc,
            db: dbManager
        )
        offsite    = AnyOffsiteSync()
        super.init()
        Task { [db, cameras] in
            try? await encryption.generateKeyIfNeeded()
            // Notification permission is requested by the host app delegate.
            // UNUserNotificationCenter is not callable from an XPC service —
            // doing so crashes with an NSAssertion abort.

            // Bring up adapters for every camera already in the DB. The seed
            // tool writes profiles directly, bypassing addCamera/registerCamera,
            // so without this pass no polling/snapshot/health work ever starts.
            // Register in parallel — each Blink adapter.connect() is ~5s of
            // Python helper startup, so 4 sequential registrations would mean
            // ~20s before all cameras are reachable for snapshot requests.
            let profiles = (try? await db.fetchAllCameraProfiles()) ?? []
            await withTaskGroup(of: Void.self) { group in
                for profile in profiles {
                    group.addTask { [cameras] in
                        try? await cameras.registerCamera(profile)
                    }
                }
            }
            // Start health polling after adapters are up. Polls every 30 s and
            // writes HealthReport entries that getHealthReport/getAllHealthReports
            // can then serve. Safe to start before all registrations complete —
            // the poll loop simply skips cameras not yet in the adapter map.
            await cameras.startHealthPolling()
        }

        // Observe ESP32-CAM motion events and deliver a user notification.
        // ESP32CAMAdapter posts .esp32MotionDetected (with "cameraID") instead of
        // running the Vision pipeline, so it bypasses sendDetectionAlert entirely.
        NotificationCenter.default.addObserver(
            forName: .esp32MotionDetected,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["cameraID"] as? UUID else { return }
            Task { [weak self] in
                guard let self else { return }
                let name = (try? await self.db.fetchCameraProfile(id: id))?.name ?? "ESP32-CAM"
                await self.alerts.sendMotionAlert(cameraID: id, cameraName: name)
            }
        }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    // MARK: - Camera CRUD

    func getCameras(reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            let profiles = (try? await db.fetchAllCameraProfiles()) ?? []
            r.v(encode(profiles))
        }
    }

    func addCamera(_ data: Data, reply: @escaping (Bool, String?) -> Void) {
        let r = S(v: reply)
        Task {
            do {
                let profile = try decode(CameraProfile.self, from: data)
                try await db.upsertCameraProfile(profile)
                try await cameras.registerCamera(profile)
                r.v(true, nil)
            } catch {
                r.v(false, error.localizedDescription)
            }
        }
    }

    func removeCamera(_ cameraID: String, reply: @escaping (Bool) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else { r.v(false); return }
            do {
                try await cameras.unregisterCamera(id)
                try await db.deleteCameraProfile(id: id)
                r.v(true)
            } catch { r.v(false) }
        }
    }

    // MARK: - Arming

    func armCamera(_ cameraID: String, reply: @escaping (Bool, String?) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else { r.v(false, "Invalid UUID"); return }
            do {
                try await cameras.arm(id)
                if var p = try? await db.fetchCameraProfile(id: id) {
                    p.isArmed = true
                    try await db.upsertCameraProfile(p)
                }
                r.v(true, nil)
            } catch { r.v(false, error.localizedDescription) }
        }
    }

    func disarmCamera(_ cameraID: String, reply: @escaping (Bool, String?) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else { r.v(false, "Invalid UUID"); return }
            do {
                try await cameras.disarm(id)
                if var p = try? await db.fetchCameraProfile(id: id) {
                    p.isArmed = false
                    try await db.upsertCameraProfile(p)
                }
                r.v(true, nil)
            } catch { r.v(false, error.localizedDescription) }
        }
    }

    // MARK: - Events & Clips

    func getRecentEvents(_ cameraID: String, limit: Int, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else {
                r.v(encode([DetectionEvent]())) ; return
            }
            let events = (try? await db.fetchEvents(cameraID: id, startTime: nil, endTime: nil, limit: limit)) ?? []
            r.v(encode(events))
        }
    }

    func getClips(_ cameraID: String, startTime: Double, endTime: Double, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else {
                r.v(encode([ClipRecord]())) ; return
            }
            let start = startTime > 0 ? Date(timeIntervalSince1970: startTime) : nil
            let end   = endTime   > 0 ? Date(timeIntervalSince1970: endTime)   : nil
            let clips = (try? await db.fetchClips(cameraID: id, startTime: start, endTime: end)) ?? []
            r.v(encode(clips))
        }
    }

    // MARK: - Snapshot

    func getSnapshot(_ cameraID: String, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task { [cameras] in
            guard let id = UUID(uuidString: cameraID) else { r.v(Data()); return }
            do {
                let cg = try await cameras.latestSnapshot(for: id)
                r.v(encodeJPEG(cg) ?? Data())
            } catch {
                r.v(Data())
            }
        }
    }

    func getFreshSnapshot(_ cameraID: String, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task { [cameras] in
            guard let id = UUID(uuidString: cameraID) else { r.v(Data()); return }
            do {
                let cg = try await cameras.freshSnapshot(for: id)
                r.v(encodeJPEG(cg) ?? Data())
            } catch {
                r.v(Data())
            }
        }
    }

    private func encodeJPEG(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func exportClip(_ clipID: String, toPath: String, reply: @escaping (Bool, String?) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: clipID) else { r.v(false, "Invalid clip UUID"); return }
            guard let clip = try? await db.fetchClipRecord(id: id) else { r.v(false, "Clip not found"); return }
            do {
                try await encryption.decryptFile(
                    at: URL(fileURLWithPath: clip.encryptedPath),
                    to: URL(fileURLWithPath: toPath)
                )
                r.v(true, nil)
            } catch { r.v(false, error.localizedDescription) }
        }
    }

    // MARK: - Health

    func getHealthReport(_ cameraID: String, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else { r.v(Data()); return }
            if let report = await health.getReport(cameraID: id) {
                r.v(encode(report))
            } else { r.v(Data()) }
        }
    }

    func getAllHealthReports(reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            r.v(encode(await health.getAllReports()))
        }
    }

    // MARK: - Lockdown

    func triggerLockdown(reply: @escaping (Bool) -> Void) {
        let r = S(v: reply)
        Task {
            let profiles = (try? await db.fetchAllCameraProfiles()) ?? []
            for profile in profiles {
                try? await cameras.arm(profile.id)
                if var p = try? await db.fetchCameraProfile(id: profile.id) {
                    p.isArmed = true
                    try? await db.upsertCameraProfile(p)
                }
            }
            await alerts.sendLockdownAlert()
            await offsite.triggerImmediateSync()
            r.v(true)
        }
    }

    // MARK: - Site Profiles

    func getSiteProfiles(reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            r.v(encode((try? await db.fetchAllSiteProfiles()) ?? []))
        }
    }

    func switchSiteProfile(_ profileID: String, reply: @escaping (Bool, String?) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: profileID) else { r.v(false, "Invalid UUID"); return }
            guard (try? await db.fetchSiteProfile(id: id)) != nil else { r.v(false, "Profile not found"); return }
            do {
                try await cameras.reloadSiteProfile(id)
                r.v(true, nil)
            } catch { r.v(false, error.localizedDescription) }
        }
    }
}

// MARK: - Offsite sync stub (real implementation lands in Phase 6)

final class AnyOffsiteSync: OffsiteSyncProtocol, @unchecked Sendable {
    func triggerImmediateSync() async {}
}
