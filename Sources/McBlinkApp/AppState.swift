// AppState.swift — McBlink
// Central observable state for the app. All mutations on MainActor.
// Swift 6 strict concurrency.

import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var cameras: [CameraProfile] = []
    @Published var siteProfiles: [SiteProfile] = []
    @Published var activeSiteProfileID: UUID?
    @Published var healthReports: [UUID: HealthReport] = [:]
    @Published var recentEvents: [DetectionEvent] = []
    @Published var isLockedDown: Bool = false
    @Published var xpcConnected: Bool = false
    @Published var lastError: String?

    // MARK: - XPC

    let xpcClient: XPCClient

    // MARK: - Init

    init() {
        self.xpcClient = XPCClient()
        self.xpcClient.onConnectionStateChanged = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.xpcConnected = connected
            }
        }
        self.xpcConnected = xpcClient.isConnected
    }

    // MARK: - Camera loading

    func loadCameras() async {
        do {
            let result = try await xpcClient.getCameras()
            NSLog("[McBlink] loadCameras returned %d cameras", result.count)
            cameras = result
        } catch {
            NSLog("[McBlink] loadCameras error: %@", String(describing: error))
            lastError = error.localizedDescription
        }
    }

    // MARK: - Arming

    func armCamera(_ id: UUID) async {
        do {
            try await xpcClient.armCamera(id)
            if let idx = cameras.firstIndex(where: { $0.id == id }) {
                cameras[idx].isArmed = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disarmCamera(_ id: UUID) async {
        do {
            try await xpcClient.disarmCamera(id)
            if let idx = cameras.firstIndex(where: { $0.id == id }) {
                cameras[idx].isArmed = false
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func armAll() async {
        await withTaskGroup(of: Void.self) { group in
            for camera in cameras where !camera.isArmed {
                group.addTask { await self.armCamera(camera.id) }
            }
        }
    }

    func disarmAll() async {
        await withTaskGroup(of: Void.self) { group in
            for camera in cameras where camera.isArmed {
                group.addTask { await self.disarmCamera(camera.id) }
            }
        }
    }

    // MARK: - Lockdown

    func triggerLockdown() async {
        do {
            try await xpcClient.triggerLockdown()
            isLockedDown = true
            // Mirror arm state locally so the UI reflects immediately.
            for idx in cameras.indices {
                cameras[idx].isArmed = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Site Profiles

    func loadSiteProfiles() async {
        do {
            siteProfiles = try await xpcClient.getSiteProfiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func switchSiteProfile(_ id: UUID) async {
        do {
            try await xpcClient.switchSiteProfile(id)
            activeSiteProfileID = id
            await loadCameras()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Health

    func refreshHealth() async {
        do {
            let reports = try await xpcClient.getAllHealthReports()
            var map: [UUID: HealthReport] = [:]
            for report in reports {
                map[report.cameraID] = report
            }
            healthReports = map
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Recent Events

    func refreshRecentEvents(cameraID: UUID? = nil) async {
        do {
            recentEvents = try await xpcClient.getRecentEvents(cameraID, limit: 100)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    func camera(id: UUID) -> CameraProfile? {
        cameras.first { $0.id == id }
    }

    func healthReport(for cameraID: UUID) -> HealthReport? {
        healthReports[cameraID]
    }

    /// Returns events in the last `seconds` seconds for the given camera.
    func recentEvents(for cameraID: UUID, within seconds: TimeInterval = 60) -> [DetectionEvent] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return recentEvents.filter { $0.cameraID == cameraID && $0.timestamp > cutoff }
    }
}
