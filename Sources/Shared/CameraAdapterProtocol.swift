// CameraAdapterProtocol.swift — McBlink camera adapter abstraction layer
// Swift 6 strict concurrency. All adapters are actors.

import Foundation
import CoreGraphics

// MARK: - CameraAdapter Protocol

/// Implemented by each camera brand/protocol adapter.
/// Conforming types must be actors to satisfy Swift 6 data isolation.
protocol CameraAdapter: Actor {
    var cameraID: UUID { get }
    var capabilities: CameraCapabilities { get }
    var status: CameraStatus { get }

    /// Opens the network connection and verifies credentials.
    func connect() async throws

    /// Tears down the connection gracefully. Never throws.
    func disconnect() async

    /// Returns the full-resolution RTSP or WebRTC URL for AVPlayer / live view.
    func liveStreamURL() async throws -> URL

    /// Returns a reduced-resolution (≤ 480p) URL suitable for continuous
    /// AI inference without saturating the recording pipeline.
    func proxyStreamURL() async throws -> URL

    /// Grabs the current frame as a decoded CGImage (JPEG or raw, adapter decides).
    func latestSnapshot() async throws -> CGImage

    /// Enables or disables motion detection and event generation on the camera.
    func setArmed(_ armed: Bool) async throws
}
