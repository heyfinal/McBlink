// DatabaseManager.swift — Actor-isolated GRDB database manager for SentinelCore
// Swift 6 / macOS 14

import Foundation
import GRDB

// MARK: - DatabaseManager

actor DatabaseManager {

    // MARK: - Database handle

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    init() {
        do {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("McBlink/db", isDirectory: true)

            try FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let dbPath = appSupport.appendingPathComponent("catalog.sqlite").path
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
            try Self.runMigrations(on: dbQueue)
        } catch {
            fatalError("DatabaseManager: failed to open database — \(error)")
        }
    }

    // MARK: - Migrations

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // camera_profiles
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS camera_profiles (
                    id               TEXT PRIMARY KEY NOT NULL,
                    name             TEXT NOT NULL,
                    source           TEXT NOT NULL,
                    stream_url       TEXT NOT NULL,
                    substream_url    TEXT,
                    username         TEXT,
                    capabilities     INTEGER NOT NULL DEFAULT 0,
                    is_armed         INTEGER NOT NULL DEFAULT 0,
                    site_profile_id  TEXT NOT NULL,
                    created_at       REAL NOT NULL,
                    json_blob        TEXT NOT NULL
                )
            """)

            // detection_events
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS detection_events (
                    id               TEXT PRIMARY KEY NOT NULL,
                    camera_id        TEXT NOT NULL,
                    timestamp        REAL NOT NULL,
                    detected_classes TEXT NOT NULL,
                    confidence       REAL NOT NULL,
                    snapshot_path    TEXT,
                    clip_id          TEXT,
                    bounding_boxes   TEXT NOT NULL DEFAULT '[]'
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_camera_time
                ON detection_events (camera_id, timestamp)
            """)

            // clip_records
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clip_records (
                    id               TEXT PRIMARY KEY NOT NULL,
                    camera_id        TEXT NOT NULL,
                    start_time       REAL NOT NULL,
                    end_time         REAL NOT NULL,
                    encrypted_path   TEXT NOT NULL,
                    thumbnail_path   TEXT,
                    detected_classes TEXT NOT NULL DEFAULT '[]',
                    is_synced        INTEGER NOT NULL DEFAULT 0,
                    size_bytes       INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_clips_camera_start
                ON clip_records (camera_id, start_time)
            """)

            // site_profiles
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS site_profiles (
                    id                  TEXT PRIMARY KEY NOT NULL,
                    name                TEXT NOT NULL,
                    cameras             TEXT NOT NULL DEFAULT '[]',
                    storage_base_path   TEXT NOT NULL,
                    retention_days      INTEGER NOT NULL DEFAULT 30,
                    offsite_enabled     INTEGER NOT NULL DEFAULT 0
                )
            """)

            // health_log
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS health_log (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    camera_id       TEXT NOT NULL,
                    timestamp       REAL NOT NULL,
                    status          TEXT NOT NULL,
                    fps             REAL NOT NULL DEFAULT 0,
                    dropped_frames  INTEGER NOT NULL DEFAULT 0,
                    storage_used    INTEGER NOT NULL DEFAULT 0
                )
            """)
        }

        try migrator.migrate(queue)
    }

    // MARK: - JSON helpers

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private func toJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try Self.encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func fromJSON<T: Decodable>(_ type: T.Type, string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw DatabaseError.dataCorrupted("Cannot convert JSON string to Data")
        }
        return try Self.decoder.decode(type, from: data)
    }

    // MARK: - CameraProfile CRUD

    func fetchAllCameraProfiles() throws -> [CameraProfile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT json_blob FROM camera_profiles")
            return try rows.map { row in
                let blob: String = row["json_blob"]
                return try fromJSON(CameraProfile.self, string: blob)
            }
        }
    }

    func fetchCameraProfile(id: UUID) throws -> CameraProfile? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT json_blob FROM camera_profiles WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            let blob: String = row["json_blob"]
            return try fromJSON(CameraProfile.self, string: blob)
        }
    }

    func upsertCameraProfile(_ profile: CameraProfile) throws {
        let blob = try toJSON(profile)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO camera_profiles
                        (id, name, source, stream_url, substream_url, username,
                         capabilities, is_armed, site_profile_id, created_at, json_blob)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name            = excluded.name,
                        source          = excluded.source,
                        stream_url      = excluded.stream_url,
                        substream_url   = excluded.substream_url,
                        username        = excluded.username,
                        capabilities    = excluded.capabilities,
                        is_armed        = excluded.is_armed,
                        site_profile_id = excluded.site_profile_id,
                        json_blob       = excluded.json_blob
                """,
                arguments: [
                    profile.id.uuidString,
                    profile.name,
                    profile.source.rawValue,
                    profile.streamURL,
                    profile.substreamURL,
                    profile.username,
                    profile.capabilities.rawValue,
                    profile.isArmed ? 1 : 0,
                    profile.siteProfileID.uuidString,
                    Date().timeIntervalSinceReferenceDate,
                    blob
                ]
            )
        }
    }

    func deleteCameraProfile(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM camera_profiles WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - DetectionEvent CRUD

    func fetchEvents(
        cameraID: UUID,
        startTime: Date?,
        endTime: Date?,
        limit: Int
    ) throws -> [DetectionEvent] {
        try dbQueue.read { db in
            var sql = """
                SELECT id, camera_id, timestamp, detected_classes, confidence,
                       snapshot_path, clip_id, bounding_boxes
                FROM detection_events
                WHERE camera_id = ?
            """
            var args: [DatabaseValueConvertible] = [cameraID.uuidString]

            if let s = startTime {
                sql += " AND timestamp >= ?"
                args.append(s.timeIntervalSinceReferenceDate)
            }
            if let e = endTime {
                sql += " AND timestamp <= ?"
                args.append(e.timeIntervalSinceReferenceDate)
            }
            sql += " ORDER BY timestamp DESC LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.compactMap { row -> DetectionEvent? in
                guard
                    let idStr: String     = row["id"],
                    let camStr: String    = row["camera_id"],
                    let id                = UUID(uuidString: idStr),
                    let camID             = UUID(uuidString: camStr)
                else { return nil }

                let ts: Double            = row["timestamp"]
                let classesJSON: String   = row["detected_classes"]
                let confidence: Float     = row["confidence"]
                let snapshot: String?     = row["snapshot_path"]
                let clipStr: String?      = row["clip_id"]
                let bboxJSON: String      = row["bounding_boxes"]

                let classes     = try fromJSON([DetectionClass].self, string: classesJSON)
                let bboxes      = try fromJSON([CGRect].self, string: bboxJSON)
                let clipID      = clipStr.flatMap { UUID(uuidString: $0) }

                return DetectionEvent(
                    id: id,
                    cameraID: camID,
                    timestamp: Date(timeIntervalSinceReferenceDate: ts),
                    detectedClasses: classes,
                    confidence: confidence,
                    snapshotPath: snapshot,
                    clipID: clipID,
                    boundingBoxes: bboxes
                )
            }
        }
    }

    func upsertDetectionEvent(_ event: DetectionEvent) throws {
        let classesJSON = try toJSON(event.detectedClasses)
        let bboxJSON    = try toJSON(event.boundingBoxes)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO detection_events
                        (id, camera_id, timestamp, detected_classes, confidence,
                         snapshot_path, clip_id, bounding_boxes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id.uuidString,
                    event.cameraID.uuidString,
                    event.timestamp.timeIntervalSinceReferenceDate,
                    classesJSON,
                    event.confidence,
                    event.snapshotPath,
                    event.clipID?.uuidString,
                    bboxJSON
                ]
            )
        }
    }

    // MARK: - ClipRecord CRUD

    func fetchClips(
        cameraID: UUID,
        startTime: Date?,
        endTime: Date?
    ) throws -> [ClipRecord] {
        try dbQueue.read { db in
            var sql = """
                SELECT id, camera_id, start_time, end_time, encrypted_path,
                       thumbnail_path, detected_classes, is_synced, size_bytes
                FROM clip_records
                WHERE camera_id = ?
            """
            var args: [DatabaseValueConvertible] = [cameraID.uuidString]

            if let s = startTime {
                sql += " AND end_time >= ?"
                args.append(s.timeIntervalSinceReferenceDate)
            }
            if let e = endTime {
                sql += " AND start_time <= ?"
                args.append(e.timeIntervalSinceReferenceDate)
            }
            sql += " ORDER BY start_time DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.compactMap { row -> ClipRecord? in
                guard
                    let idStr: String  = row["id"],
                    let camStr: String = row["camera_id"],
                    let id             = UUID(uuidString: idStr),
                    let camID          = UUID(uuidString: camStr)
                else { return nil }

                let startTS: Double           = row["start_time"]
                let endTS: Double             = row["end_time"]
                let encPath: String           = row["encrypted_path"]
                let thumbPath: String?        = row["thumbnail_path"]
                let classesJSON: String       = row["detected_classes"]
                let isSyncedInt: Int          = row["is_synced"]
                let sizeBytes: Int64          = row["size_bytes"]

                let classes = try fromJSON([DetectionClass].self, string: classesJSON)

                return ClipRecord(
                    id: id,
                    cameraID: camID,
                    startTime: Date(timeIntervalSinceReferenceDate: startTS),
                    endTime: Date(timeIntervalSinceReferenceDate: endTS),
                    encryptedPath: encPath,
                    thumbnailPath: thumbPath,
                    detectedClasses: classes,
                    isSynced: isSyncedInt != 0,
                    sizeBytes: sizeBytes
                )
            }
        }
    }

    func fetchClipRecord(id: UUID) throws -> ClipRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, camera_id, start_time, end_time, encrypted_path,
                           thumbnail_path, detected_classes, is_synced, size_bytes
                    FROM clip_records WHERE id = ?
                """,
                arguments: [id.uuidString]
            ) else { return nil }

            guard
                let idStr: String  = row["id"],
                let camStr: String = row["camera_id"],
                let rid            = UUID(uuidString: idStr),
                let camID          = UUID(uuidString: camStr)
            else { return nil }

            let startTS: Double     = row["start_time"]
            let endTS: Double       = row["end_time"]
            let encPath: String     = row["encrypted_path"]
            let thumbPath: String?  = row["thumbnail_path"]
            let classesJSON: String = row["detected_classes"]
            let isSyncedInt: Int    = row["is_synced"]
            let sizeBytes: Int64    = row["size_bytes"]

            let classes = try fromJSON([DetectionClass].self, string: classesJSON)
            return ClipRecord(
                id: rid,
                cameraID: camID,
                startTime: Date(timeIntervalSinceReferenceDate: startTS),
                endTime: Date(timeIntervalSinceReferenceDate: endTS),
                encryptedPath: encPath,
                thumbnailPath: thumbPath,
                detectedClasses: classes,
                isSynced: isSyncedInt != 0,
                sizeBytes: sizeBytes
            )
        }
    }

    func upsertClipRecord(_ clip: ClipRecord) throws {
        let classesJSON = try toJSON(clip.detectedClasses)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO clip_records
                        (id, camera_id, start_time, end_time, encrypted_path,
                         thumbnail_path, detected_classes, is_synced, size_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    clip.id.uuidString,
                    clip.cameraID.uuidString,
                    clip.startTime.timeIntervalSinceReferenceDate,
                    clip.endTime.timeIntervalSinceReferenceDate,
                    clip.encryptedPath,
                    clip.thumbnailPath,
                    classesJSON,
                    clip.isSynced ? 1 : 0,
                    clip.sizeBytes
                ]
            )
        }
    }

    // MARK: - SiteProfile CRUD

    func fetchAllSiteProfiles() throws -> [SiteProfile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, name, cameras, storage_base_path, retention_days, offsite_enabled FROM site_profiles"
            )
            return try rows.compactMap { row -> SiteProfile? in
                guard
                    let idStr: String = row["id"],
                    let id = UUID(uuidString: idStr)
                else { return nil }

                let name: String              = row["name"]
                let camerasJSON: String       = row["cameras"]
                let basePath: String          = row["storage_base_path"]
                let retentionDays: Int        = row["retention_days"]
                let offsiteInt: Int           = row["offsite_enabled"]

                let cameras = try fromJSON([UUID].self, string: camerasJSON)
                return SiteProfile(
                    id: id,
                    name: name,
                    cameras: cameras,
                    storageBasePath: basePath,
                    retentionDays: retentionDays,
                    offsiteEnabled: offsiteInt != 0
                )
            }
        }
    }

    func fetchSiteProfile(id: UUID) throws -> SiteProfile? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, name, cameras, storage_base_path, retention_days, offsite_enabled FROM site_profiles WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }

            guard
                let idStr: String = row["id"],
                let rid = UUID(uuidString: idStr)
            else { return nil }

            let name: String              = row["name"]
            let camerasJSON: String       = row["cameras"]
            let basePath: String          = row["storage_base_path"]
            let retentionDays: Int        = row["retention_days"]
            let offsiteInt: Int           = row["offsite_enabled"]

            let cameras = try fromJSON([UUID].self, string: camerasJSON)
            return SiteProfile(
                id: rid,
                name: name,
                cameras: cameras,
                storageBasePath: basePath,
                retentionDays: retentionDays,
                offsiteEnabled: offsiteInt != 0
            )
        }
    }

    func upsertSiteProfile(_ profile: SiteProfile) throws {
        let camerasJSON = try toJSON(profile.cameras)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO site_profiles
                        (id, name, cameras, storage_base_path, retention_days, offsite_enabled)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    profile.id.uuidString,
                    profile.name,
                    camerasJSON,
                    profile.storageBasePath,
                    profile.retentionDays,
                    profile.offsiteEnabled ? 1 : 0
                ]
            )
        }
    }

    // MARK: - Health Log

    func insertHealthLog(
        cameraID: UUID,
        status: String,
        fps: Double,
        droppedFrames: Int,
        storageUsed: Int64
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO health_log (camera_id, timestamp, status, fps, dropped_frames, storage_used)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cameraID.uuidString,
                    Date().timeIntervalSinceReferenceDate,
                    status,
                    fps,
                    droppedFrames,
                    storageUsed
                ]
            )
        }
    }

    // MARK: - Maintenance / LRU eviction

    /// Deletes encrypted clips older than `days` days, retaining at least
    /// `retaining` most-recent clips per camera, and ensuring total on-disk
    /// usage stays under `maxBytes`. Removes DB rows and physical files.
    func deleteClipsOlderThan(days: Int, retaining: Int, maxBytes: Int64) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            .timeIntervalSinceReferenceDate

        // Collect candidates: older than cutoff, sorted oldest-first.
        let candidates: [ClipRecord] = try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, camera_id, start_time, end_time, encrypted_path,
                           thumbnail_path, detected_classes, is_synced, size_bytes
                    FROM clip_records
                    WHERE start_time < ?
                    ORDER BY start_time ASC
                """,
                arguments: [cutoff]
            )
            return try rows.compactMap { row -> ClipRecord? in
                guard
                    let idStr: String  = row["id"],
                    let camStr: String = row["camera_id"],
                    let rid            = UUID(uuidString: idStr),
                    let camID          = UUID(uuidString: camStr)
                else { return nil }

                let startTS: Double     = row["start_time"]
                let endTS: Double       = row["end_time"]
                let encPath: String     = row["encrypted_path"]
                let thumbPath: String?  = row["thumbnail_path"]
                let classesJSON: String = row["detected_classes"]
                let isSyncedInt: Int    = row["is_synced"]
                let sizeBytes: Int64    = row["size_bytes"]
                let classes             = try fromJSON([DetectionClass].self, string: classesJSON)

                return ClipRecord(
                    id: rid, cameraID: camID,
                    startTime: Date(timeIntervalSinceReferenceDate: startTS),
                    endTime: Date(timeIntervalSinceReferenceDate: endTS),
                    encryptedPath: encPath, thumbnailPath: thumbPath,
                    detectedClasses: classes, isSynced: isSyncedInt != 0,
                    sizeBytes: sizeBytes
                )
            }
        }

        // Calculate total storage to decide if we need additional LRU eviction.
        var totalBytes = try dbQueue.read { db -> Int64 in
            let row = try Row.fetchOne(db, sql: "SELECT SUM(size_bytes) AS total FROM clip_records")
            return row?["total"] ?? 0
        }

        // Count per-camera retained clips so we respect the `retaining` minimum.
        var retainedPerCamera: [UUID: Int] = [:]

        for clip in candidates {
            // Never delete if we haven't hit the retention minimum for this camera.
            let retained = retainedPerCamera[clip.cameraID] ?? 0
            if retained < retaining {
                retainedPerCamera[clip.cameraID] = retained + 1
                continue
            }

            // Skip if already within budget.
            if totalBytes <= maxBytes {
                break
            }

            // Delete physical file.
            let fileURL = URL(fileURLWithPath: clip.encryptedPath)
            try? FileManager.default.removeItem(at: fileURL)
            if let thumb = clip.thumbnailPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: thumb))
            }

            // Delete DB row.
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM clip_records WHERE id = ?",
                    arguments: [clip.id.uuidString]
                )
            }

            totalBytes -= clip.sizeBytes
        }
    }
}

// MARK: - DatabaseError

enum DatabaseError: Error {
    case dataCorrupted(String)
}
