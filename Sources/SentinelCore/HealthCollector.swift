// HealthCollector.swift — Camera health metrics aggregator for SentinelCore
// Swift 6 / macOS 14

import Foundation

// MARK: - HealthCollector

actor HealthCollector {

    // MARK: - State

    private var reports: [UUID: HealthReport] = [:]
    private let db: DatabaseManager

    // MARK: - Init

    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Update

    /// Records a new health sample for `cameraID` and refreshes the in-memory report.
    func update(cameraID: UUID, status: CameraStatus, fps: Double, dropped: Int) {
        let existing  = reports[cameraID]
        let newReport = HealthReport(
            cameraID: cameraID,
            status: status,
            framesPerSecond: fps,
            droppedFrames: dropped,
            storageUsedBytes: existing?.storageUsedBytes ?? 0,
            lastEventTime: existing?.lastEventTime,
            lastSyncTime: existing?.lastSyncTime
        )
        reports[cameraID] = newReport

        // Persist asynchronously; do not block the caller.
        Task {
            await persistHealthLog(report: newReport)
        }
    }

    /// Updates the `lastEventTime` field for a camera after a detection event fires.
    func recordEvent(cameraID: UUID, at time: Date) {
        guard var report = reports[cameraID] else { return }
        report = HealthReport(
            cameraID: cameraID,
            status: report.status,
            framesPerSecond: report.framesPerSecond,
            droppedFrames: report.droppedFrames,
            storageUsedBytes: report.storageUsedBytes,
            lastEventTime: time,
            lastSyncTime: report.lastSyncTime
        )
        reports[cameraID] = report
    }

    /// Updates the `lastSyncTime` field after a successful offsite sync.
    func recordSync(cameraID: UUID, at time: Date) {
        guard var report = reports[cameraID] else { return }
        report = HealthReport(
            cameraID: cameraID,
            status: report.status,
            framesPerSecond: report.framesPerSecond,
            droppedFrames: report.droppedFrames,
            storageUsedBytes: report.storageUsedBytes,
            lastEventTime: report.lastEventTime,
            lastSyncTime: time
        )
        reports[cameraID] = report
    }

    // MARK: - Queries

    func getReport(cameraID: UUID) -> HealthReport? {
        reports[cameraID]
    }

    func getAllReports() -> [HealthReport] {
        Array(reports.values)
    }

    // MARK: - Storage accounting

    /// Walks `basePath` recursively, summing file sizes.
    /// Returns total bytes used; returns 0 if the path does not exist or cannot be read.
    func calculateStorageUsed(basePath: String) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { return total }

            while let obj = enumerator.nextObject(), let url = obj as? URL {
                guard
                    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                    attrs.isRegularFile == true,
                    let size = attrs.fileSize
                else { continue }
                total += Int64(size)
            }
            return total
        }.value
    }

    /// Updates the in-memory storageUsedBytes for a camera based on its base path.
    func refreshStorageUsed(cameraID: UUID, basePath: String) async {
        let used = await calculateStorageUsed(basePath: basePath)
        guard var report = reports[cameraID] else { return }
        report = HealthReport(
            cameraID: cameraID,
            status: report.status,
            framesPerSecond: report.framesPerSecond,
            droppedFrames: report.droppedFrames,
            storageUsedBytes: used,
            lastEventTime: report.lastEventTime,
            lastSyncTime: report.lastSyncTime
        )
        reports[cameraID] = report
    }

    // MARK: - Persistence

    /// Writes a health sample to the `health_log` table.
    func persistHealthLog(report: HealthReport) async {
        let statusString: String
        switch report.status {
        case .online:              statusString = "online"
        case .offline:             statusString = "offline"
        case .connecting:          statusString = "connecting"
        case .degraded(let msg):   statusString = "degraded:\(msg)"
        }
        try? await db.insertHealthLog(
            cameraID: report.cameraID,
            status: statusString,
            fps: report.framesPerSecond,
            droppedFrames: report.droppedFrames,
            storageUsed: report.storageUsedBytes
        )
    }
}
