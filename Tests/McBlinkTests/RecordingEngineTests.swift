import XCTest
import CryptoKit

final class RecordingEngineTests: XCTestCase {

    /// Full core pipeline: a downloaded clip is encrypted at rest, cataloged in
    /// the DB, and decrypts back to the original bytes. Hermetic — injected key,
    /// in-memory DB, temp storage; never touches the real catalog or Keychain.
    func testClipEncryptCatalogRoundTrip() async throws {
        let enc = EncryptionManager(testKey: SymmetricKey(size: .bits256))
        let db = DatabaseManager(inMemory: true)
        let engine = RecordingEngine()
        let cameraID = UUID()

        let base = NSTemporaryDirectory() + "mcblink-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let original = Data("hello-mcblink-\(UUID().uuidString)".utf8)

        let clipID = try await engine.onClipDownloaded(
            cameraID: cameraID,
            clipData: original,
            sourceURL: URL(string: "blink://cam/clip")!,
            basePath: base,
            encryptionManager: enc,
            db: db
        )

        // Cataloged.
        let rec = try await db.fetchClipRecord(id: clipID)
        XCTAssertNotNil(rec, "clip should be cataloged")
        XCTAssertEqual(rec?.cameraID, cameraID)
        XCTAssertGreaterThan(rec?.sizeBytes ?? 0, 0)

        // Encrypted at rest — the stored bytes must NOT equal the plaintext.
        let encURL = URL(fileURLWithPath: rec!.encryptedPath)
        let encData = try Data(contentsOf: encURL)
        XCTAssertNotEqual(encData, original, "stored clip must be encrypted, not plaintext")

        // Decrypts back to the original.
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory() + "dec-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try await enc.decryptFile(at: encURL, to: outURL)
        let decrypted = try Data(contentsOf: outURL)
        XCTAssertEqual(decrypted, original, "decrypt must round-trip to original bytes")
    }
}
