// Models.swift — McBlink shared data model layer
// Swift 6 strict concurrency. All types are Sendable and Codable.

import Foundation
import CoreGraphics

// MARK: - Camera Source

enum CameraSource: String, Codable, Sendable, CaseIterable {
    case blink
    case rtsp
    case mjpeg
    case onvif
    case wyze
    case eufy
    case esp32cam
}

// MARK: - Camera Capabilities

struct CameraCapabilities: OptionSet, Codable, Sendable {
    let rawValue: Int

    static let liveStream    = CameraCapabilities(rawValue: 1 << 0)
    static let ptz           = CameraCapabilities(rawValue: 1 << 1)
    static let twoWayAudio   = CameraCapabilities(rawValue: 1 << 2)
    static let motionEvents  = CameraCapabilities(rawValue: 1 << 3)
    static let localStorage  = CameraCapabilities(rawValue: 1 << 4)
    static let substream     = CameraCapabilities(rawValue: 1 << 5)
}

// MARK: - Detection Zone

struct DetectionZone: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var polygon: [CGPoint]
    var isActive: Bool

    init(id: UUID = UUID(), name: String, polygon: [CGPoint], isActive: Bool = true) {
        self.id = id
        self.name = name
        self.polygon = polygon
        self.isActive = isActive
    }
}

// MARK: - Camera Profile

struct CameraProfile: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var source: CameraSource
    var streamURL: String
    var substreamURL: String?
    var username: String?
    var capabilities: CameraCapabilities
    var detectionZones: [DetectionZone]
    var isArmed: Bool
    var siteProfileID: UUID

    // Excluded from Codable — credentials belong in Keychain, not JSON blobs.
    var password: String = ""

    private enum CodingKeys: String, CodingKey {
        case id, name, source, streamURL, substreamURL, username,
             capabilities, detectionZones, isArmed, siteProfileID
    }

    init(
        id: UUID = UUID(),
        name: String,
        source: CameraSource,
        streamURL: String,
        substreamURL: String? = nil,
        username: String? = nil,
        password: String = "",
        capabilities: CameraCapabilities = [.liveStream, .motionEvents],
        detectionZones: [DetectionZone] = [],
        isArmed: Bool = false,
        siteProfileID: UUID
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.streamURL = streamURL
        self.substreamURL = substreamURL
        self.username = username
        self.password = password
        self.capabilities = capabilities
        self.detectionZones = detectionZones
        self.isArmed = isArmed
        self.siteProfileID = siteProfileID
    }
}

// MARK: - Detection Class

enum DetectionClass: String, Codable, Sendable, CaseIterable {
    case person
    case vehicle
    case animal
    case package
    case bicycle
    case glassBreak
    case smokeAlarm
    case bark
}

// MARK: - Detection Event

struct DetectionEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let cameraID: UUID
    let timestamp: Date
    let detectedClasses: [DetectionClass]
    let confidence: Float
    let snapshotPath: String?
    let clipID: UUID?
    let boundingBoxes: [CGRect]

    init(
        id: UUID = UUID(),
        cameraID: UUID,
        timestamp: Date = Date(),
        detectedClasses: [DetectionClass],
        confidence: Float,
        snapshotPath: String? = nil,
        clipID: UUID? = nil,
        boundingBoxes: [CGRect] = []
    ) {
        self.id = id
        self.cameraID = cameraID
        self.timestamp = timestamp
        self.detectedClasses = detectedClasses
        self.confidence = confidence
        self.snapshotPath = snapshotPath
        self.clipID = clipID
        self.boundingBoxes = boundingBoxes
    }
}

// MARK: - Clip Record

struct ClipRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let cameraID: UUID
    let startTime: Date
    let endTime: Date
    /// Filesystem path to the AES-256 encrypted video file.
    let encryptedPath: String
    let thumbnailPath: String?
    let detectedClasses: [DetectionClass]
    var isSynced: Bool
    let sizeBytes: Int64

    init(
        id: UUID = UUID(),
        cameraID: UUID,
        startTime: Date,
        endTime: Date,
        encryptedPath: String,
        thumbnailPath: String? = nil,
        detectedClasses: [DetectionClass] = [],
        isSynced: Bool = false,
        sizeBytes: Int64 = 0
    ) {
        self.id = id
        self.cameraID = cameraID
        self.startTime = startTime
        self.endTime = endTime
        self.encryptedPath = encryptedPath
        self.thumbnailPath = thumbnailPath
        self.detectedClasses = detectedClasses
        self.isSynced = isSynced
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Site Profile

struct SiteProfile: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var cameras: [UUID]
    var storageBasePath: String
    var retentionDays: Int
    var offsiteEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        cameras: [UUID] = [],
        storageBasePath: String,
        retentionDays: Int = 7,
        offsiteEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.cameras = cameras
        self.storageBasePath = storageBasePath
        self.retentionDays = retentionDays
        self.offsiteEnabled = offsiteEnabled
    }
}

// MARK: - Camera Status

enum CameraStatus: Sendable {
    case online
    case offline
    case degraded(String)
    case connecting
}

extension CameraStatus: Equatable {
    static func == (lhs: CameraStatus, rhs: CameraStatus) -> Bool {
        switch (lhs, rhs) {
        case (.online, .online): return true
        case (.offline, .offline): return true
        case (.connecting, .connecting): return true
        case (.degraded(let a), .degraded(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Health Report

struct HealthReport: Sendable {
    let cameraID: UUID
    let status: CameraStatus
    let framesPerSecond: Double
    let droppedFrames: Int
    let storageUsedBytes: Int64
    let lastEventTime: Date?
    let lastSyncTime: Date?

    init(
        cameraID: UUID,
        status: CameraStatus,
        framesPerSecond: Double = 0,
        droppedFrames: Int = 0,
        storageUsedBytes: Int64 = 0,
        lastEventTime: Date? = nil,
        lastSyncTime: Date? = nil
    ) {
        self.cameraID = cameraID
        self.status = status
        self.framesPerSecond = framesPerSecond
        self.droppedFrames = droppedFrames
        self.storageUsedBytes = storageUsedBytes
        self.lastEventTime = lastEventTime
        self.lastSyncTime = lastSyncTime
    }
}

// MARK: - HealthReport Codable

// CameraStatus is not auto-Codable due to associated value. We handle it manually.
extension HealthReport: Codable {
    private enum CodingKeys: String, CodingKey {
        case cameraID, statusKind, statusDetail, framesPerSecond,
             droppedFrames, storageUsedBytes, lastEventTime, lastSyncTime
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cameraID, forKey: .cameraID)
        try c.encode(framesPerSecond, forKey: .framesPerSecond)
        try c.encode(droppedFrames, forKey: .droppedFrames)
        try c.encode(storageUsedBytes, forKey: .storageUsedBytes)
        try c.encodeIfPresent(lastEventTime, forKey: .lastEventTime)
        try c.encodeIfPresent(lastSyncTime, forKey: .lastSyncTime)
        switch status {
        case .online:        try c.encode("online",       forKey: .statusKind)
        case .offline:       try c.encode("offline",      forKey: .statusKind)
        case .connecting:    try c.encode("connecting",   forKey: .statusKind)
        case .degraded(let msg):
            try c.encode("degraded", forKey: .statusKind)
            try c.encode(msg,        forKey: .statusDetail)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraID        = try c.decode(UUID.self,   forKey: .cameraID)
        framesPerSecond = try c.decode(Double.self,  forKey: .framesPerSecond)
        droppedFrames   = try c.decode(Int.self,     forKey: .droppedFrames)
        storageUsedBytes = try c.decode(Int64.self,  forKey: .storageUsedBytes)
        lastEventTime   = try c.decodeIfPresent(Date.self, forKey: .lastEventTime)
        lastSyncTime    = try c.decodeIfPresent(Date.self, forKey: .lastSyncTime)
        let kind = try c.decode(String.self, forKey: .statusKind)
        switch kind {
        case "online":     status = .online
        case "offline":    status = .offline
        case "connecting": status = .connecting
        default:
            let detail = (try? c.decode(String.self, forKey: .statusDetail)) ?? kind
            status = .degraded(detail)
        }
    }
}

// MARK: - App Settings (cross-process via XPC)

struct AppSettings: Codable, Sendable {
    // Notification filters
    var notifyPerson: Bool = true
    var notifyVehicle: Bool = true
    var notifyAnimal: Bool = false
    var notifyPackage: Bool = true
    var notifyGlassBreak: Bool = true
    var notifySmokeAlarm: Bool = true
    var notifyBark: Bool = false

    // Quiet hours — seconds from midnight (matches DatePicker binding)
    var quietHoursStart: Double = 23 * 3600
    var quietHoursEnd: Double = 6 * 3600

    // MQTT config (unified key names)
    var mqttHost: String = ""
    var mqttPort: Int = 1883
    var mqttTopicPrefix: String = "homeassistant/mcblink"

    // Storage config
    var retentionDays: Int = 30
    var maxDiskGB: Int = 500

    /// Returns true if the given detection class has notifications enabled.
    func isNotificationEnabled(for cls: DetectionClass) -> Bool {
        switch cls {
        case .person:     return notifyPerson
        case .vehicle:    return notifyVehicle
        case .animal:     return notifyAnimal
        case .package:    return notifyPackage
        case .bicycle:    return notifyVehicle
        case .glassBreak: return notifyGlassBreak
        case .smokeAlarm: return notifySmokeAlarm
        case .bark:       return notifyBark
        }
    }
}

// MARK: - XPC Error

enum XPCError: Error, Sendable {
    case connectionFailed
    case authFailed
    case cameraNotFound
    case recordingFailed
    case encryptionFailed
}

extension XPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .connectionFailed:  return "XPC connection to SentinelCore failed."
        case .authFailed:        return "XPC authentication failed."
        case .cameraNotFound:    return "Camera not found in SentinelCore registry."
        case .recordingFailed:   return "Recording pipeline encountered an error."
        case .encryptionFailed:  return "Clip encryption failed."
        }
    }
}
