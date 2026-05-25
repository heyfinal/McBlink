// HealthDashboardView.swift — McBlink
// Per-camera and system-level health monitoring.
// Swift 6 strict concurrency.

import SwiftUI

struct HealthDashboardView: View {

    @EnvironmentObject private var appState: AppState
    @State private var refreshTimer: Timer? = nil
    @State private var now: Date = Date()

    private var offlineAlertCameras: [CameraProfile] {
        appState.cameras.filter { camera in
            guard let report = appState.healthReport(for: camera.id) else { return false }
            switch report.status {
            case .offline:
                if let since = report.lastSyncTime {
                    return since.timeIntervalSinceNow < -120
                }
                return true
            default:
                return false
            }
        }
    }

    private var highStorageCameras: [CameraProfile] {
        appState.cameras.filter { camera in
            guard let report = appState.healthReport(for: camera.id) else { return false }
            let totalApprox: Int64 = 500 * 1_073_741_824 // 500 GB nominal
            return report.storageUsedBytes > Int64(Double(totalApprox) * 0.9)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !offlineAlertCameras.isEmpty || !highStorageCameras.isEmpty {
                    alertBanners
                }

                systemCard

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(appState.cameras) { camera in
                        HealthReportCard(
                            camera: camera,
                            report: appState.healthReport(for: camera.id)
                        )
                    }
                }

                if appState.cameras.isEmpty {
                    ContentUnavailableView(
                        "No Cameras",
                        systemImage: "video.slash",
                        description: Text("Add cameras in Settings.")
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("Health Dashboard")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await appState.refreshHealth() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .task {
            await appState.refreshHealth()
            startTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Alert banners

    private var alertBanners: some View {
        VStack(spacing: 6) {
            ForEach(offlineAlertCameras) { camera in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("\(camera.name) has been offline for over 2 minutes")
                        .font(.caption.bold())
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            ForEach(highStorageCameras) { camera in
                HStack {
                    Image(systemName: "externaldrive.fill.badge.exclamationmark")
                        .foregroundStyle(.red)
                    Text("\(camera.name) storage is above 90% capacity")
                        .font(.caption.bold())
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.10))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - System card

    private var systemCard: some View {
        GroupBox("System") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Label("SentinelCore", systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.xpcConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(appState.xpcConnected ? "Running" : "Disconnected")
                            .font(.caption.bold())
                    }
                }
                GridRow {
                    Label("Cameras", systemImage: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(appState.cameras.count) registered")
                        .font(.caption.bold())
                }
                GridRow {
                    Label("Armed", systemImage: "shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(appState.cameras.filter(\.isArmed).count) / \(appState.cameras.count)")
                        .font(.caption.bold())
                }
                GridRow {
                    Label("Lockdown", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.isLockedDown ? "ACTIVE" : "Inactive")
                        .font(.caption.bold())
                        .foregroundStyle(appState.isLockedDown ? .red : .secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await appState.refreshHealth() }
        }
    }
}

// MARK: - HealthReportCard

private struct HealthReportCard: View {

    let camera: CameraProfile
    let report: HealthReport?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(camera.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    statusBadge
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("FPS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(report.map { String(format: "%.1f", $0.framesPerSecond) } ?? "—")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Dropped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(report.map { "\($0.droppedFrames)" } ?? "—")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Storage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(report.map { formatBytes($0.storageUsedBytes) } ?? "—")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Last event")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let t = report?.lastEventTime {
                            Text(t, style: .relative)
                                .font(.caption)
                        } else {
                            Text("—").font(.caption)
                        }
                    }
                    GridRow {
                        Text("Last sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let t = report?.lastSyncTime {
                            Text(t, style: .relative)
                                .font(.caption)
                        } else {
                            Text("—").font(.caption)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            guard let r = report else { return ("Unknown", .gray) }
            switch r.status {
            case .online:           return ("Online",     .green)
            case .offline:          return ("Offline",    .red)
            case .degraded:         return ("Degraded",   .orange)
            case .connecting:       return ("Connecting", .yellow)
            }
        }()

        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
