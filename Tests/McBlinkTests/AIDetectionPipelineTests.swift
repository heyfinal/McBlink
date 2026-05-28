import XCTest
import CoreGraphics

final class AIDetectionPipelineTests: XCTestCase {

    private func solidImage(_ w: Int = 320, _ h: Int = 240) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// With no CoreML model on disk, analyzeImage takes the built-in Vision path.
    /// A blank frame must run cleanly and produce no person/animal detections.
    func testBuiltInDetectionRunsAndIsEmptyOnBlankFrame() async throws {
        let pipeline = AIDetectionPipeline()
        let result = try await pipeline.analyzeImage(solidImage(), zones: [])
        XCTAssertTrue(result.isEmpty, "blank frame should yield no detections")
    }

    /// COCO label mapping feeds DetectionClass aggregation correctly.
    func testLabelMapping() async {
        let p = AIDetectionPipeline()
        let person = await p.labelToDetectionClass("person")
        let vehicle = await p.labelToDetectionClass("Truck")
        let animal = await p.labelToDetectionClass("Cat")
        let none = await p.labelToDetectionClass("toaster")
        XCTAssertEqual(person, .person)
        XCTAssertEqual(vehicle, .vehicle)
        XCTAssertEqual(animal, .animal)
        XCTAssertNil(none)
    }
}
