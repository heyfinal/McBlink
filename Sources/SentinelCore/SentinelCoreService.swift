// SentinelCoreService.swift — Main XPC service implementation
// Swift 6 / macOS 14

import Foundation

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
    private let cameras: AnyCameraManager
    private let offsite: AnyOffsiteSync

    private override init() {
        let dbManager = DatabaseManager()
        let enc       = EncryptionManager()
        let alertMgr  = AlertManager()
        db         = dbManager
        encryption = enc
        alerts     = alertMgr
        health     = HealthCollector(db: dbManager)
        cameras    = AnyCameraManager()
        offsite    = AnyOffsiteSync()
        super.init()
        Task {
            try? await encryption.generateKeyIfNeeded()
            await alerts.requestNotificationPermission()
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

// MARK: - No-op stubs (replaced by real actors in Phase 1+)

final class AnyCameraManager: CameraManaging, @unchecked Sendable {
    func registerCamera(_ profile: CameraProfile) async throws {}
    func unregisterCamera(_ id: UUID) async throws {}
    func arm(_ id: UUID) async throws {}
    func disarm(_ id: UUID) async throws {}
    func armAll() async throws {}
    func reloadSiteProfile(_ id: UUID) async throws {}
}

final class AnyOffsiteSync: OffsiteSyncProtocol, @unchecked Sendable {
    func triggerImmediateSync() async {}
}
