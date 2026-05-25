// CameraAdapterFactory.swift — Adapter instantiation for SentinelCore
// Swift 6 strict concurrency / macOS 14+

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Factory

/// Instantiates the correct adapter for a given CameraProfile.
enum CameraAdapterFactory {
    static func make(for profile: CameraProfile) -> any CameraAdapter {
        switch profile.source {
        case .blink:
            return BlinkAdapter(profile: profile)
        case .rtsp, .onvif:
            return RTSPAdapter(profile: profile)
        case .mjpeg:
            return MJPEGAdapter(profile: profile)
        case .wyze:
            return WyzeAdapter(profile: profile)
        case .eufy:
            return EufyAdapter(profile: profile)
        }
    }
}

// MARK: - WyzeAdapter

/// Adapter for Wyze cameras via the unofficial Wyze RTSP firmware endpoint.
actor WyzeAdapter: CameraAdapter {
    let cameraID: UUID
    let capabilities: CameraCapabilities = [.liveStream, .motionEvents, .twoWayAudio]
    private(set) var status: CameraStatus = .connecting

    private let profile: CameraProfile

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile = profile
    }

    func connect() async throws {
        status = .connecting
        guard URL(string: profile.streamURL) != nil else {
            status = .offline
            throw URLError(.badURL)
        }
        status = .online
    }

    func disconnect() async {
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard let url = URL(string: profile.streamURL) else { throw URLError(.badURL) }
        return url
    }

    func proxyStreamURL() async throws -> URL {
        if let sub = profile.substreamURL, let url = URL(string: sub) { return url }
        return try await liveStreamURL()
    }

    func latestSnapshot() async throws -> CGImage {
        let url = try await liveStreamURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw XPCError.recordingFailed
        }
        return image
    }

    func setArmed(_ armed: Bool) async throws {
        // Wyze RTSP firmware does not expose arming via the stream URL.
        // Recording-pipeline arming only.
    }
}

// MARK: - EufyAdapter

/// Adapter for Eufy Security cameras via local RTSP (requires HomeBase LAN mode).
actor EufyAdapter: CameraAdapter {
    let cameraID: UUID
    let capabilities: CameraCapabilities = [.liveStream, .motionEvents, .twoWayAudio, .substream]
    private(set) var status: CameraStatus = .connecting

    private let profile: CameraProfile

    init(profile: CameraProfile) {
        self.cameraID = profile.id
        self.profile = profile
    }

    func connect() async throws {
        status = .connecting
        guard URL(string: profile.streamURL) != nil else {
            status = .offline
            throw URLError(.badURL)
        }
        status = .online
    }

    func disconnect() async {
        status = .offline
    }

    func liveStreamURL() async throws -> URL {
        guard let url = URL(string: profile.streamURL) else { throw URLError(.badURL) }
        return url
    }

    func proxyStreamURL() async throws -> URL {
        if let sub = profile.substreamURL, let url = URL(string: sub) { return url }
        return try await liveStreamURL()
    }

    func latestSnapshot() async throws -> CGImage {
        let url = try await liveStreamURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw XPCError.recordingFailed
        }
        return image
    }

    func setArmed(_ armed: Bool) async throws {
        // Eufy HomeBase LAN arming API not yet implemented.
    }
}
