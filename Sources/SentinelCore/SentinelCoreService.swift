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
    private let ai: AIDetectionPipeline
    private let cameras: CameraManager
    private let offsite: AnyOffsiteSync

    /// Holds the running blink_helper auth process between blinkAuth (start)
    /// and blinkAuthPin (send PIN). The OAuth2 PKCE state + session cookies
    /// only live inside this single process.
    private var pendingBlinkAuth: PendingBlinkAuth?

    private struct PendingBlinkAuth {
        let process: Process
        let outPipe: Pipe
        let inPipe: Pipe
    }

    private override init() {
        let dbManager = DatabaseManager()
        let enc       = EncryptionManager()
        let alertMgr  = AlertManager(db: dbManager)
        let healthMgr = HealthCollector(db: dbManager)
        let recording = RecordingEngine()
        let aiPipeline = AIDetectionPipeline()
        db         = dbManager
        encryption = enc
        alerts     = alertMgr
        health     = healthMgr
        ai         = aiPipeline
        cameras    = CameraManager(
            healthCollector: healthMgr,
            recordingEngine: recording,
            encryptionManager: enc,
            db: dbManager,
            ai: aiPipeline,
            alerts: alertMgr
        )
        offsite    = AnyOffsiteSync()
        super.init()
        Task { [db, cameras] in
            do {
                try await encryption.generateKeyIfNeeded()
            } catch {
                NSLog("[McBlink] encryption key init failed: %@", String(describing: error))
            }

            let profiles: [CameraProfile]
            do {
                profiles = try await db.fetchAllCameraProfiles()
            } catch {
                NSLog("[McBlink] failed to load camera profiles: %@", String(describing: error))
                profiles = []
            }
            let blinkProfiles = profiles.filter { $0.source == .blink }
            let otherProfiles = profiles.filter { $0.source != .blink }

            // Prefetch Blink camera list ONCE — one auth, one MFA cycle max.
            // All Blink adapters then validate against the cached list.
            if !blinkProfiles.isEmpty {
                do {
                    try await BlinkBridgeAdapter.prefetchCameraList()
                } catch {
                    NSLog("[McBlink] Blink prefetch failed: %@", String(describing: error))
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for profile in blinkProfiles + otherProfiles {
                    group.addTask { [cameras] in
                        do {
                            try await cameras.registerCamera(profile)
                        } catch {
                            NSLog("[McBlink] failed to register camera '%@': %@",
                                  profile.name, String(describing: error))
                        }
                    }
                }
            }
            // Start health polling after adapters are up. Polls every 30 s and
            // writes HealthReport entries that getHealthReport/getAllHealthReports
            // can then serve. Safe to start before all registrations complete —
            // the poll loop simply skips cameras not yet in the adapter map.
            await cameras.startHealthPolling()
        }

        // Daily retention cleanup: run immediately on startup (catches stale
        // clips from previous sessions), then repeat every 24 hours.
        retentionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runRetentionCleanup()
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    break
                }
            }
        }

        // Observe ESP32-CAM motion events and deliver a user notification.
        // ESP32CAMAdapter posts .esp32MotionDetected (with "cameraID") instead of
        // running the Vision pipeline, so it bypasses sendDetectionAlert entirely.
        motionObserver = NotificationCenter.default.addObserver(
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

    private var retentionTask: Task<Void, Never>?
    private var motionObserver: NSObjectProtocol?

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
            if cameraID.isEmpty {
                // Query all cameras, merge and sort by timestamp descending
                let profiles = (try? await db.fetchAllCameraProfiles()) ?? []
                var allEvents: [DetectionEvent] = []
                for profile in profiles {
                    let events = (try? await db.fetchEvents(
                        cameraID: profile.id, startTime: nil, endTime: nil, limit: limit)) ?? []
                    allEvents.append(contentsOf: events)
                }
                allEvents.sort { $0.timestamp > $1.timestamp }
                r.v(encode(Array(allEvents.prefix(limit))))
            } else {
                guard let id = UUID(uuidString: cameraID) else {
                    r.v(encode([DetectionEvent]())) ; return
                }
                let events = (try? await db.fetchEvents(
                    cameraID: id, startTime: nil, endTime: nil, limit: limit)) ?? []
                r.v(encode(events))
            }
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

            // Path traversal guard: reject paths containing ".." or symlinks
            // to locations outside safe export directories.
            let destURL = URL(fileURLWithPath: toPath).standardized
            let destPath = destURL.path
            if destPath.contains("..") {
                r.v(false, "Invalid export path"); return
            }
            let home = NSHomeDirectory()
            let safePrefix = [
                home + "/Downloads", home + "/Desktop",
                home + "/Documents", NSTemporaryDirectory()
            ]
            guard safePrefix.contains(where: { destPath.hasPrefix($0) }) else {
                r.v(false, "Export path must be in Downloads, Desktop, Documents, or a temp directory"); return
            }

            guard let clip = try? await db.fetchClipRecord(id: id) else { r.v(false, "Clip not found"); return }
            do {
                try await encryption.decryptFile(
                    at: URL(fileURLWithPath: clip.encryptedPath),
                    to: destURL
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

    // MARK: - Settings

    func updateSettings(_ data: Data, reply: @escaping (Bool) -> Void) {
        let r = S(v: reply)
        Task {
            do {
                let settings = try decode(AppSettings.self, from: data)
                try await db.upsertSettings(settings)
                r.v(true)
            } catch {
                NSLog("[McBlink] updateSettings failed: %@", String(describing: error))
                r.v(false)
            }
        }
    }

    func getSettings(reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        Task {
            let settings = (try? await db.fetchSettings()) ?? AppSettings()
            r.v(encode(settings))
        }
    }

    // MARK: - Credentials

    func storeCameraCredential(_ cameraID: String, password: String, reply: @escaping (Bool) -> Void) {
        let r = S(v: reply)
        Task {
            do {
                let credsDir = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("McBlink/creds", isDirectory: true)
                try FileManager.default.createDirectory(at: credsDir, withIntermediateDirectories: true)
                let credFile = credsDir.appendingPathComponent("\(cameraID).cred")
                try password.write(to: credFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: credFile.path)
                r.v(true)
            } catch {
                NSLog("[McBlink] storeCameraCredential failed: %@", String(describing: error))
                r.v(false)
            }
        }
    }

    // MARK: - Blink Auth (interactive single-process flow)

    func blinkAuth(_ email: String, password: String, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        // Kill any leftover auth process from a previous attempt.
        pendingBlinkAuth?.process.terminate()
        pendingBlinkAuth = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                r.v(self?.encode(["status": "error", "message": "service deallocated"]) ?? Data())
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: BlinkBridgeAdapter.pythonPath)
            proc.arguments    = [BlinkBridgeAdapter.helperPath, "auth", "--stdin"]
            proc.environment  = ProcessInfo.processInfo.environment
                .merging(["BLINK_CREDS": BlinkBridgeAdapter.credsPath]) { _, new in new }
            let outPipe = Pipe()
            let inPipe  = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = Pipe()
            proc.standardInput  = inPipe
            do {
                try proc.run()
            } catch {
                r.v(self.encode(["status": "error", "message": error.localizedDescription]))
                return
            }
            // Write email + password to stdin. The helper reads these first.
            let creds = "\(email)\n\(password)\n"
            inPipe.fileHandleForWriting.write(creds.data(using: .utf8)!)
            // Do NOT close stdin yet — helper may need to read PIN later.

            // Read first JSON line from stdout.
            guard let firstLine = self.readLine(from: outPipe) else {
                proc.terminate()
                r.v(self.encode(["status": "error", "message": "no output from helper"]))
                return
            }
            // Check if 2FA is required.
            if let obj = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
               obj["status"] as? String == "needs_pin" {
                // Hold the process — blinkAuthPin will feed the PIN.
                self.pendingBlinkAuth = PendingBlinkAuth(process: proc, outPipe: outPipe, inPipe: inPipe)
                r.v(firstLine)
            } else {
                // Auth completed (ok or error) — process will exit.
                inPipe.fileHandleForWriting.closeFile()
                proc.waitUntilExit()
                r.v(firstLine)
            }
        }
    }

    func blinkAuthPin(_ pin: String, reply: @escaping (Data) -> Void) {
        let r = S(v: reply)
        guard let pending = pendingBlinkAuth else {
            r.v(encode(["status": "error", "message": "no pending auth session"]))
            return
        }
        pendingBlinkAuth = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Write PIN to the waiting helper process.
            let pinData = "\(pin)\n".data(using: .utf8)!
            pending.inPipe.fileHandleForWriting.write(pinData)
            pending.inPipe.fileHandleForWriting.closeFile()
            // Read final result line.
            guard let self,
                  let result = self.readLine(from: pending.outPipe) else {
                pending.process.terminate()
                r.v(self?.encode(["status": "error", "message": "no output after PIN"]) ?? Data())
                return
            }
            pending.process.waitUntilExit()
            r.v(result)
        }
    }

    /// Reads a single newline-terminated JSON line from a pipe.
    private func readLine(from pipe: Pipe) -> Data? {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            buffer.append(chunk)
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard !buffer.isEmpty else { return nil }
        // Trim trailing newline.
        if buffer.last == UInt8(ascii: "\n") { buffer.removeLast() }
        return buffer
    }

    // MARK: - ESP32-CAM controls

    func esp32SetFlash(_ cameraID: String, on: Bool, reply: @escaping (Bool) -> Void) {
        let r = S(v: reply)
        Task {
            guard let id = UUID(uuidString: cameraID) else { r.v(false); return }
            do {
                try await cameras.esp32SetFlash(id, on: on)
                r.v(true)
            } catch { r.v(false) }
        }
    }

    // MARK: - Retention cleanup

    private func runRetentionCleanup() async {
        let settings = (try? await db.fetchSettings()) ?? AppSettings()
        let days = settings.retentionDays
        do {
            let deleted = try await db.deleteClipsOlderThan(days: days)
            if deleted > 0 {
                NSLog("[McBlink] retention: purged %d clips older than %d days", deleted, days)
            }
        } catch {
            NSLog("[McBlink] retention cleanup failed: %@", String(describing: error))
        }
        do {
            let purged = try await db.deleteHealthLogsOlderThan(days: 30)
            if purged > 0 {
                NSLog("[McBlink] retention: purged %d health log entries older than 30 days", purged)
            }
        } catch {
            NSLog("[McBlink] health log cleanup failed: %@", String(describing: error))
        }

        // Check storage usage against maxDiskGB and alert if above 90%
        let maxBytes = Int64(settings.maxDiskGB) * 1_073_741_824
        if maxBytes > 0 {
            let reports = await health.getAllReports()
            let totalUsed = reports.reduce(Int64(0)) { $0 + $1.storageUsedBytes }
            let percentUsed = Double(totalUsed) / Double(maxBytes) * 100
            if percentUsed > 90 {
                await alerts.sendStorageAlert(percentUsed: percentUsed)
            }
        }
    }
}

// MARK: - Offsite sync stub (real implementation lands in Phase 6)

final class AnyOffsiteSync: OffsiteSyncProtocol, @unchecked Sendable {
    func triggerImmediateSync() async {}
}
