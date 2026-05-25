// XPCProtocol.swift — McBlink NSXPCConnection protocol definition
// Swift 6 / macOS 14. All methods use completion-handler style required by @objc XPC.

import Foundation

/// The interface exposed by SentinelCore over NSXPCConnection.
/// All methods return results via completion handlers — async/await is not
/// supported across the XPC boundary via NSXPCInterface.
@objc protocol McBlinkXPCProtocol {

    // MARK: Camera CRUD

    /// Returns JSON-encoded [CameraProfile] array.
    func getCameras(reply: @escaping (Data) -> Void)

    /// Accepts JSON-encoded CameraProfile. Returns (success, errorMessage?).
    func addCamera(_ data: Data, reply: @escaping (Bool, String?) -> Void)

    /// Removes camera by UUID string. Returns success.
    func removeCamera(_ cameraID: String, reply: @escaping (Bool) -> Void)

    // MARK: Arming

    /// Arms the camera (enables motion detection + recording). Returns (success, errorMessage?).
    func armCamera(_ cameraID: String, reply: @escaping (Bool, String?) -> Void)

    /// Disarms the camera. Returns (success, errorMessage?).
    func disarmCamera(_ cameraID: String, reply: @escaping (Bool, String?) -> Void)

    // MARK: Events & Clips

    /// Returns JSON-encoded [DetectionEvent], most recent first, capped at `limit`.
    func getRecentEvents(_ cameraID: String, limit: Int, reply: @escaping (Data) -> Void)

    /// Returns JSON-encoded [ClipRecord] whose start/endTime overlaps the given
    /// UNIX timestamp range (startTime..endTime, inclusive).
    func getClips(_ cameraID: String, startTime: Double, endTime: Double, reply: @escaping (Data) -> Void)

    /// Decrypts and exports the clip to `toPath`. Returns (success, errorMessage?).
    func exportClip(_ clipID: String, toPath: String, reply: @escaping (Bool, String?) -> Void)

    // MARK: Health

    /// Returns JSON-encoded HealthReport for the given camera.
    func getHealthReport(_ cameraID: String, reply: @escaping (Data) -> Void)

    /// Returns JSON-encoded [HealthReport] for all registered cameras.
    func getAllHealthReports(reply: @escaping (Data) -> Void)

    // MARK: Security

    /// Immediately arms all cameras, halts remote access, and triggers
    /// offsite backup flush. Returns success.
    func triggerLockdown(reply: @escaping (Bool) -> Void)

    // MARK: Site Profiles

    /// Returns JSON-encoded [SiteProfile].
    func getSiteProfiles(reply: @escaping (Data) -> Void)

    /// Switches the active site profile. Returns (success, errorMessage?).
    func switchSiteProfile(_ profileID: String, reply: @escaping (Bool, String?) -> Void)
}

// MARK: - Interface Builder

/// Builds a reusable NSXPCInterface for McBlinkXPCProtocol.
/// Call this on both ends of the connection so NSXPCConnection can
/// whilelist the correct classes for secure coding.
enum McBlinkXPCInterface {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: McBlinkXPCProtocol.self)

        // Allow Data (NSData) as reply payload for all methods that return Data.
        // NSXPCInterface restricts allowed classes to prevent object-graph injection.
        let dataClasses: NSSet = [NSData.self]

        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getCameras(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getRecentEvents(_:limit:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getClips(_:startTime:endTime:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getHealthReport(_:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getAllHealthReports(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            dataClasses as! Set<AnyHashable>,
            for: #selector(McBlinkXPCProtocol.getSiteProfiles(reply:)),
            argumentIndex: 0,
            ofReply: true
        )

        return interface
    }
}

// MARK: - Client-side async wrappers

/// Wraps the callback-based XPC protocol in Swift concurrency.
/// Use from the app target only — never across the XPC boundary itself.
extension McBlinkXPCProtocol {

    func getCamerasAsync() async throws -> [CameraProfile] {
        try await withCheckedThrowingContinuation { continuation in
            getCameras { data in
                do {
                    let profiles = try JSONDecoder().decode([CameraProfile].self, from: data)
                    continuation.resume(returning: profiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func addCameraAsync(_ profile: CameraProfile) async throws {
        let data = try JSONEncoder().encode(profile)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            addCamera(data) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.cameraNotFound)
                }
            }
        }
    }

    func removeCameraAsync(_ cameraID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removeCamera(cameraID.uuidString) { success in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.cameraNotFound)
                }
            }
        }
    }

    func armCameraAsync(_ cameraID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            armCamera(cameraID.uuidString) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.recordingFailed)
                }
            }
        }
    }

    func disarmCameraAsync(_ cameraID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            disarmCamera(cameraID.uuidString) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.recordingFailed)
                }
            }
        }
    }

    func getRecentEventsAsync(_ cameraID: UUID, limit: Int = 50) async throws -> [DetectionEvent] {
        try await withCheckedThrowingContinuation { continuation in
            getRecentEvents(cameraID.uuidString, limit: limit) { data in
                do {
                    let events = try JSONDecoder().decode([DetectionEvent].self, from: data)
                    continuation.resume(returning: events)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func getClipsAsync(_ cameraID: UUID, range: ClosedRange<Date>) async throws -> [ClipRecord] {
        try await withCheckedThrowingContinuation { continuation in
            getClips(
                cameraID.uuidString,
                startTime: range.lowerBound.timeIntervalSince1970,
                endTime: range.upperBound.timeIntervalSince1970
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

    func exportClipAsync(_ clipID: UUID, toPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportClip(clipID.uuidString, toPath: toPath) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.recordingFailed)
                }
            }
        }
    }

    func getHealthReportAsync(_ cameraID: UUID) async throws -> HealthReport {
        try await withCheckedThrowingContinuation { continuation in
            getHealthReport(cameraID.uuidString) { data in
                do {
                    let report = try JSONDecoder().decode(HealthReport.self, from: data)
                    continuation.resume(returning: report)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func getAllHealthReportsAsync() async throws -> [HealthReport] {
        try await withCheckedThrowingContinuation { continuation in
            getAllHealthReports { data in
                do {
                    let reports = try JSONDecoder().decode([HealthReport].self, from: data)
                    continuation.resume(returning: reports)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func triggerLockdownAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            triggerLockdown { success in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.connectionFailed)
                }
            }
        }
    }

    func getSiteProfilesAsync() async throws -> [SiteProfile] {
        try await withCheckedThrowingContinuation { continuation in
            getSiteProfiles { data in
                do {
                    let profiles = try JSONDecoder().decode([SiteProfile].self, from: data)
                    continuation.resume(returning: profiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func switchSiteProfileAsync(_ profileID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            switchSiteProfile(profileID.uuidString) { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: XPCError.cameraNotFound)
                }
            }
        }
    }
}
