// MJPEGAdapter.swift — MJPEG-over-HTTP camera adapter for McBlink
// Swift 6 strict concurrency / macOS 14+
//
// MJPEG streams use multipart/x-mixed-replace boundaries to deliver a
// continuous sequence of JPEG frames over a single HTTP connection.
// latestSnapshot() opens the stream, scans for the first complete JPEG
// (SOI marker 0xFFD8 … EOI marker 0xFFD9), and decodes it.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - MJPEGAdapter

actor MJPEGAdapter: CameraAdapter {

    // MARK: Protocol conformance

    let cameraID: UUID
    let capabilities: CameraCapabilities = [.liveStream]
    private(set) var status: CameraStatus = .connecting

    // MARK: State

    private let profile: CameraProfile
    private let streamURL: URL
    private var isArmed: Bool = false

    // MARK: Constants

    private static let soiMarker: [UInt8] = [0xFF, 0xD8]
    private static let eoiMarker: [UInt8] = [0xFF, 0xD9]
    /// Maximum bytes to read from the stream when hunting for a JPEG frame.
    private static let maxStreamBytes = 1_500_000
    /// Connection timeout for stream HEAD check and snapshot read.
    private static let timeoutSeconds: TimeInterval = 8

    // MARK: Init

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile = profile
        self.streamURL = URL(string: profile.streamURL) ?? URL(string: "http://invalid")!
    }

    // MARK: - CameraAdapter

    func connect() async throws {
        status = .connecting
        var request = URLRequest(url: streamURL, timeoutInterval: Self.timeoutSeconds)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 200 and 206 both indicate a live stream.
            if code == 200 || code == 206 {
                status = .online
            } else {
                status = .offline
                throw URLError(.badServerResponse)
            }
        } catch {
            status = .offline
            throw error
        }
    }

    func disconnect() async {
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard status == .online else { throw XPCError.connectionFailed }
        return streamURL
    }

    func proxyStreamURL() async throws -> URL {
        return try await liveStreamURL()
    }

    /// Opens the MJPEG stream, reads until a complete JPEG frame is found,
    /// and decodes it to a CGImage.
    func latestSnapshot() async throws -> CGImage {
        var request = URLRequest(url: streamURL, timeoutInterval: Self.timeoutSeconds)
        request.setValue("McBlink/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        // Use the delegate-based session to bound total bytes read.
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 || httpResponse?.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }

        // Accumulate up to maxStreamBytes, extract first JPEG.
        var buffer = [UInt8]()
        buffer.reserveCapacity(65_536)

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count > Self.maxStreamBytes { break }

            // Once we have enough data to contain SOI+EOI, try to extract a frame.
            if buffer.count > 4, let jpeg = Self.extractFirstJPEG(from: buffer) {
                guard
                    let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    throw XPCError.recordingFailed
                }
                return image
            }
        }
        throw XPCError.recordingFailed
    }

    /// Arming is local-flag only for MJPEG cameras.
    func setArmed(_ armed: Bool) async throws {
        isArmed = armed
    }

    // MARK: - JPEG Extraction

    /// Scans `buffer` for the first SOI…EOI JPEG frame and returns it as Data.
    private static func extractFirstJPEG(from buffer: [UInt8]) -> Data? {
        guard let soiIndex = findSequence(soiMarker, in: buffer, from: 0) else { return nil }
        guard let eoiIndex = findSequence(eoiMarker, in: buffer, from: soiIndex + 2) else { return nil }
        let frameEnd = eoiIndex + 2
        guard frameEnd <= buffer.count else { return nil }
        return Data(buffer[soiIndex..<frameEnd])
    }

    /// Returns the index of the first occurrence of `sequence` in `data` starting at `startIndex`.
    private static func findSequence(_ sequence: [UInt8], in data: [UInt8], from startIndex: Int) -> Int? {
        guard sequence.count > 0, data.count >= sequence.count else { return nil }
        let limit = data.count - sequence.count
        guard startIndex <= limit else { return nil }
        for i in startIndex...limit {
            if data[i] == sequence[0] {
                var match = true
                for j in 1..<sequence.count {
                    if data[i + j] != sequence[j] { match = false; break }
                }
                if match { return i }
            }
        }
        return nil
    }
}
