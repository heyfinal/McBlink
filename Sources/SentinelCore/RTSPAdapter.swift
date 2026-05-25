// RTSPAdapter.swift — Generic RTSP camera adapter for McBlink
// Swift 6 strict concurrency / macOS 14+
//
// Live RTSP decode will use FFmpegKit in a future phase.
// For now, liveStreamURL() returns the raw RTSP URL for the UI layer to consume,
// and latestSnapshot() attempts AVFoundation then falls back to a CGImage placeholder.

import Foundation
import CoreGraphics
import AVFoundation
import Network

// MARK: - RTSPAdapter

actor RTSPAdapter: CameraAdapter {

    // MARK: Protocol conformance

    let cameraID: UUID
    let capabilities: CameraCapabilities
    private(set) var status: CameraStatus = .connecting

    // MARK: State

    private let profile: CameraProfile
    private let streamURL: URL
    private let substreamURL: URL?
    private var isArmed: Bool = false

    // MARK: Init

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile = profile

        // Build capabilities from profile; always include liveStream.
        var caps: CameraCapabilities = [.liveStream, .substream]
        if profile.capabilities.contains(.ptz) { caps.insert(.ptz) }
        if profile.capabilities.contains(.twoWayAudio) { caps.insert(.twoWayAudio) }
        self.capabilities = caps

        self.streamURL = URL(string: profile.streamURL) ?? URL(string: "rtsp://invalid")!
        self.substreamURL = profile.substreamURL.flatMap { URL(string: $0) }
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting

        let reachable = await Self.isReachable(url: streamURL)
        if reachable {
            status = .online
        } else {
            status = .offline
            throw URLError(.cannotConnectToHost)
        }
    }

    func disconnect() async {
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard status == .online || status == .degraded("") else {
            throw XPCError.connectionFailed
        }
        return streamURL
    }

    func proxyStreamURL() async throws -> URL {
        if let sub = substreamURL {
            return sub
        }
        return try await liveStreamURL()
    }

    /// Attempts to grab a frame via AVFoundation.
    /// RTSP is not universally supported by AVFoundation (only HLS/MP4/MOV are guaranteed).
    /// If AVFoundation fails, returns a gray placeholder CGImage with the camera name rendered via CoreGraphics.
    func latestSnapshot() async throws -> CGImage {
        // AVFoundation path (works if the RTSP camera emits an Apple-compatible stream).
        if let image = await Self.snapshotViaAVFoundation(url: streamURL) {
            return image
        }
        // Fallback: gray placeholder with camera name.
        return Self.placeholderImage(label: profile.name)
    }

    /// Arming is a local flag only — RTSP cameras have no remote arm API.
    /// The recording pipeline checks `isArmed` to decide whether to capture.
    func setArmed(_ armed: Bool) async throws {
        isArmed = armed
    }

    // MARK: - Reachability

    /// Attempts a TCP connection to the stream host/port to verify reachability.
    /// Falls back to a plain HEAD request for http:// URLs.
    private static func isReachable(url: URL) async -> Bool {
        guard let host = url.host else { return false }
        let port = url.port ?? defaultPort(for: url.scheme)

        if url.scheme?.lowercased().hasPrefix("rtsp") == true {
            return await tcpReachable(host: host, port: port)
        }

        // For http/https substreams try a HEAD request.
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let result = try? await URLSession.shared.data(for: request)
        return result != nil
    }

    private static func tcpReachable(host: String, port: Int) async -> Bool {
        // Swift 6: guard the continuation against concurrent resume from stateUpdateHandler
        // and the timeout DispatchQueue block using a thread-safe Once wrapper.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func run(_ block: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return }
                fired = true
                block()
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)),
                using: .tcp
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled, .waiting:
                    once.run { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                once.run { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "rtsp": return 554
        case "rtsps": return 443
        case "http": return 80
        case "https": return 443
        default: return 554
        }
    }

    // MARK: - AVFoundation Snapshot

    private static func snapshotViaAVFoundation(url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // CMTime(seconds:0) requests the first available frame.
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return result.image
        } catch {
            return nil
        }
    }

    // MARK: - Placeholder Image

    /// Returns a 640×360 gray CGImage with the camera name centered in white text.
    private static func placeholderImage(label: String) -> CGImage {
        let width = 640
        let height = 360
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            // Last-resort 1×1 gray pixel.
            return Self.onePixelGray()
        }

        // Fill gray background.
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw centered label using CoreText.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 28, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.9),
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            label as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, [])
        let x = (CGFloat(width) - lineBounds.width) / 2
        let y = (CGFloat(height) - lineBounds.height) / 2 + (-lineBounds.minY)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)

        return context.makeImage() ?? Self.onePixelGray()
    }

    private static func onePixelGray() -> CGImage {
        var pixel: UInt8 = 128
        let data = Data(bytes: &pixel, count: 1)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
