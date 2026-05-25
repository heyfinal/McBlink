// AIDetectionPipeline.swift — YOLOv8n Core ML inference pipeline for McBlink
// Swift 6 strict concurrency / macOS 14+

import Foundation
import CoreML
@preconcurrency import Vision
import AVFoundation
import CoreGraphics

// Sendable carrier for Vision observation data extracted before async boundary crossing.
struct RawObservation: Sendable {
    let topLabel: String
    let confidence: Float
    let boundingBox: CGRect
}

// MARK: - AIDetectionPipeline

actor AIDetectionPipeline {

    // MARK: State

    private var vnModel: VNCoreMLModel?
    private let modelLoaded: Bool

    // MARK: Constants

    private static let modelPath: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appending(path: "McBlink", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "yolov8n.mlpackage", directoryHint: .isDirectory)
    }()

    private static let framesPerSecond: Double = 5

    // MARK: Init

    init() {
        if FileManager.default.fileExists(atPath: Self.modelPath.path) {
            do {
                let compiledURL = try MLModel.compileModel(at: Self.modelPath)
                let mlModel = try MLModel(contentsOf: compiledURL)
                vnModel = try VNCoreMLModel(for: mlModel)
                modelLoaded = true
            } catch {
                print("[AIDetectionPipeline] model load failed — using passthrough: \(error)")
                vnModel = nil
                modelLoaded = false
            }
        } else {
            vnModel = nil
            modelLoaded = false
        }
    }

    // MARK: - Clip Analysis

    /// Extracts frames from the clip at `url` at 5 fps, runs YOLO inference on each,
    /// and returns an aggregated DetectionEvent.
    func analyzeClip(
        at url: URL,
        cameraID: UUID,
        clipID: UUID,
        zones: [DetectionZone]
    ) async throws -> DetectionEvent {

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            return DetectionEvent(
                cameraID: cameraID,
                detectedClasses: [],
                confidence: 0,
                clipID: clipID
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Build sample times at targetFPS.
        let frameInterval = 1.0 / Self.framesPerSecond
        var sampleTimes: [CMTime] = []
        var t = 0.0
        while t < durationSeconds {
            sampleTimes.append(CMTime(seconds: t, preferredTimescale: 600))
            t += frameInterval
        }

        // Collect all observations across frames.
        var allObservations: [RawObservation] = []

        for await result in generator.images(for: sampleTimes) {
            guard let cgImage = try? result.image else { continue }
            let frameObservations = try await analyzeImage(cgImage, zones: zones)
            allObservations.append(contentsOf: frameObservations)
        }

        var detectedClasses: [DetectionClass] = []
        var maxConfidence: Float = 0

        for obs in allObservations {
            if let dc = labelToDetectionClass(obs.topLabel) {
                if !detectedClasses.contains(dc) { detectedClasses.append(dc) }
                if obs.confidence > maxConfidence { maxConfidence = obs.confidence }
            }
        }

        return DetectionEvent(
            cameraID: cameraID,
            detectedClasses: detectedClasses,
            confidence: maxConfidence,
            clipID: clipID
        )
    }

    // MARK: - Single Frame Analysis

    /// Runs YOLO inference on `image`, filtering results to active `zones`.
    /// Returns an empty array when no model is loaded (passthrough mode).
    func analyzeImage(
        _ image: CGImage,
        zones: [DetectionZone]
    ) async throws -> [RawObservation] {
        guard let vnModel else { return [] }

        let activeZones = zones.filter { $0.isActive }

        // Capture actor-isolated state before leaving the actor executor.
        let model = vnModel

        // handler.perform is synchronous and CPU-intensive — run on a background queue
        // so we don't block the actor's executor and stall concurrent analysis tasks.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNCoreMLRequest(model: model) { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let results = request.results as? [VNRecognizedObjectObservation] ?? []
                    let raw: [RawObservation] = results.compactMap { obs in
                        guard let top = obs.labels.first else { return nil }
                        let center = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                        if !activeZones.isEmpty && !activeZones.contains(where: { self.pointInPolygon(center, polygon: $0.polygon) }) {
                            return nil
                        }
                        return RawObservation(topLabel: top.identifier, confidence: top.confidence, boundingBox: obs.boundingBox)
                    }
                    continuation.resume(returning: raw)
                }
                request.imageCropAndScaleOption = .scaleFit
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Label Mapping

    /// Maps COCO class label strings to the McBlink DetectionClass enum.
    func labelToDetectionClass(_ label: String) -> DetectionClass? {
        switch label.lowercased() {
        case "person":
            return .person
        case "car", "truck", "bus", "motorcycle", "vehicle":
            return .vehicle
        case "cat", "dog", "bird", "horse", "sheep", "cow", "elephant",
             "bear", "zebra", "giraffe":
            return .animal
        case "backpack", "suitcase", "handbag":
            return .package
        case "bicycle":
            return .bicycle
        default:
            return nil
        }
    }

    // MARK: - Point-in-Polygon

    /// Ray-casting algorithm. `polygon` coordinates are in Vision normalized space [0,1].
    /// Returns `true` if `point` is inside the polygon.
    func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            let intersect = ((yi > point.y) != (yj > point.y))
                && (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }
}
