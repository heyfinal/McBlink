import XCTest
import CoreGraphics

/// The XPC layer ships these types across the boundary as JSON (JSONEncoder/Decoder).
/// A silent Codable break — especially in CGPoint (polygons) or the CameraCapabilities
/// OptionSet — would corrupt everything, so pin the round-trip.
final class CodableModelsTests: XCTestCase {

    func testCameraProfileJSONRoundTrip() throws {
        let zone = DetectionZone(
            name: "driveway",
            polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 0.5)],
            isActive: true
        )
        let original = CameraProfile(
            name: "Front door", source: .esp32cam, streamURL: "http://10.0.0.5",
            substreamURL: "http://10.0.0.5/capture", username: "admin",
            capabilities: [.liveStream, .motionEvents],
            detectionZones: [zone], isArmed: true, siteProfileID: UUID()
        )

        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(CameraProfile.self, from: data)

        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.source, .esp32cam)
        XCTAssertEqual(back.streamURL, original.streamURL)
        XCTAssertEqual(back.substreamURL, original.substreamURL)
        XCTAssertEqual(back.capabilities, original.capabilities)
        XCTAssertEqual(back.isArmed, true)
        XCTAssertEqual(back.detectionZones.count, 1)
        XCTAssertEqual(back.detectionZones.first?.polygon.count, 3)
        XCTAssertEqual(back.detectionZones.first?.polygon.last, CGPoint(x: 0.5, y: 0.5))
    }

    func testClipRecordJSONRoundTrip() throws {
        let rec = ClipRecord(
            id: UUID(), cameraID: UUID(),
            startTime: Date(timeIntervalSince1970: 1000),
            endTime: Date(timeIntervalSince1970: 1010),
            encryptedPath: "/clips/abc.enc", thumbnailPath: nil,
            detectedClasses: [.person, .animal], isSynced: false, sizeBytes: 4096
        )

        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(ClipRecord.self, from: data)

        XCTAssertEqual(back.id, rec.id)
        XCTAssertEqual(back.cameraID, rec.cameraID)
        XCTAssertEqual(back.detectedClasses, [.person, .animal])
        XCTAssertEqual(back.encryptedPath, "/clips/abc.enc")
        XCTAssertEqual(back.sizeBytes, 4096)
    }
}
