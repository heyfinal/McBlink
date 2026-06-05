// RecordingEngine.swift — Clip recording and storage pipeline for McBlink
// Swift 6 strict concurrency / macOS 14+

import Foundation

// MARK: - Supporting Types

enum RecordingMode: Sendable {
    case continuous
    case motionTriggered
    case scheduled
}

struct RecordingSession: Sendable {
    let cameraID: UUID
    let tempPath: URL
    let startTime: Date
    let mode: RecordingMode
    /// Ring buffer of raw stream chunks written before a motion trigger (pre-roll).
    var preBuffer: [Data]
    private static let preBufferCapacity = 60 // ~30 s at 2 chunks/s

    init(cameraID: UUID, tempPath: URL, startTime: Date = Date(), mode: RecordingMode) {
        self.cameraID = cameraID
        self.tempPath = tempPath
        self.startTime = startTime
        self.mode = mode
        self.preBuffer = []
        self.preBuffer.reserveCapacity(Self.preBufferCapacity)
    }

    mutating func appendToPreBuffer(_ chunk: Data) {
        preBuffer.append(chunk)
        if preBuffer.count > Self.preBufferCapacity {
            preBuffer.removeFirst()
        }
    }
}

// MARK: - RecordingEngine Errors

enum RecordingEngineError: Error, Sendable {
    case sessionNotFound(UUID)
    case clipWriteFailed
}

// MARK: - RecordingEngine

actor RecordingEngine {

    // MARK: State

    var activeRecordings: [UUID: RecordingSession] = [:]

    // MARK: - Continuous Recording

    /// Starts a continuous recording session for `cameraID`.
    /// Downloads stream segments from `proxyURL` and buffers them for pre-roll.
    func startContinuousRecording(
        for cameraID: UUID,
        proxyURL: URL,
        encryptionManager: EncryptionManager,
        db: DatabaseManager
    ) async {
        guard activeRecordings[cameraID] == nil else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let tempPath = tempDir.appending(
            path: "mcblink-\(cameraID.uuidString)-\(Date().timeIntervalSince1970).mp4"
        )
        let session = RecordingSession(cameraID: cameraID, tempPath: tempPath, mode: .continuous)
        activeRecordings[cameraID] = session

        Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: proxyURL)
            request.timeoutInterval = 60
            do {
                let (asyncBytes, _) = try await URLSession.shared.bytes(for: request)
                var chunkBuffer = Data()
                chunkBuffer.reserveCapacity(65_536)
                for try await byte in asyncBytes {
                    guard await self.activeRecordings[cameraID] != nil else { break }
                    chunkBuffer.append(byte)
                    if chunkBuffer.count >= 32_768 {
                        let chunk = chunkBuffer
                        await self.appendChunk(chunk, toCameraID: cameraID)
                        chunkBuffer.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                print("[RecordingEngine] continuous stream error for \(cameraID): \(error)")
            }
        }
    }

    private func appendChunk(_ chunk: Data, toCameraID id: UUID) {
        activeRecordings[id]?.appendToPreBuffer(chunk)
    }

    // MARK: - Motion-Triggered Recording

    /// Writes `clipData` to a temp file, encrypts it, records a ClipRecord in the DB,
    /// and returns the new ClipRecord's UUID.
    /// When `keepTempFile` is true, the plaintext temp file at
    /// `<tempDir>/<clipID>.mp4` is preserved for post-encryption analysis (e.g. AI pipeline).
    /// The caller is responsible for deleting it.
    @discardableResult
    func startMotionTriggeredRecording(
        for cameraID: UUID,
        clipData: Data,
        encryptedBasePath: String,
        encryptionManager: EncryptionManager,
        db: DatabaseManager,
        keepTempFile: Bool = false
    ) async throws -> UUID {
        let clipID = UUID()
        let now = Date()

        let tempDir = FileManager.default.temporaryDirectory
        let tempPath = tempDir.appending(path: "\(clipID.uuidString).mp4")
        let encPath = URL(fileURLWithPath: encryptedBasePath)
            .appending(path: "\(clipID.uuidString).enc")

        // Write raw clip to temp file.
        do {
            try clipData.write(to: tempPath, options: .atomic)
        } catch {
            throw RecordingEngineError.clipWriteFailed
        }

        // Encrypt temp file → .enc file. encryptFile(at:to:) is async throws -> Void.
        do {
            try await encryptionManager.encryptFile(at: tempPath, to: encPath)
        } catch {
            try? FileManager.default.removeItem(at: tempPath)
            throw error
        }

        if !keepTempFile {
            try? FileManager.default.removeItem(at: tempPath)
        }

        // Measure the encrypted file size.
        let encryptedSize: Int64 = (try? FileManager.default.attributesOfItem(
            atPath: encPath.path
        ))?[.size] as? Int64 ?? 0

        // Build ClipRecord — AI fills detectedClasses after analysis.
        let record = ClipRecord(
            id: clipID,
            cameraID: cameraID,
            startTime: now,
            endTime: now,
            encryptedPath: encPath.path,
            thumbnailPath: nil,
            detectedClasses: [],
            isSynced: false,
            sizeBytes: encryptedSize
        )

        try await db.upsertClipRecord(record)
        return clipID
    }

    // MARK: - Blink Clip Handler

    /// Called by BlinkAdapter when a clip download completes.
    /// Keeps the temp file for AI analysis; caller cleans it up.
    @discardableResult
    func onClipDownloaded(
        cameraID: UUID,
        clipData: Data,
        sourceURL: URL,
        basePath: String,
        encryptionManager: EncryptionManager,
        db: DatabaseManager
    ) async throws -> UUID {
        return try await startMotionTriggeredRecording(
            for: cameraID,
            clipData: clipData,
            encryptedBasePath: basePath,
            encryptionManager: encryptionManager,
            db: db,
            keepTempFile: true
        )
    }

    // MARK: - Stop

    func stopRecording(for cameraID: UUID) async {
        guard let session = activeRecordings.removeValue(forKey: cameraID) else { return }
        try? FileManager.default.removeItem(at: session.tempPath)
    }
}
