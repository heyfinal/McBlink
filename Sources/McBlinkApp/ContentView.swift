// ContentView.swift — McBlink
// Main navigation shell: NavigationSplitView sidebar + detail NavigationStack.
// Swift 6 strict concurrency.

import SwiftUI

// MARK: - Navigation destination enum

enum AppDestination: Hashable {
    case cameraGrid
    case timeline(cameraID: UUID?)
    case health
    case rules
    case settings
}

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedDestination: AppDestination? = .cameraGrid
    @State private var selectedCameraID: UUID? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailStack
        }
        .overlay(alignment: .top) {
            if !appState.xpcConnected {
                disconnectedBanner
            }
        }
        .overlay(alignment: .top) {
            if appState.isLockedDown {
                lockdownBanner
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedDestination) {
            siteProfilesSection
            camerasSection
            Divider()
            navSection
        }
        .listStyle(.sidebar)
        .navigationTitle("McBlink")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                toolbarActions
            }
        }
    }

    private var siteProfilesSection: some View {
        Section("Site Profiles") {
            ForEach(appState.siteProfiles) { profile in
                Button {
                    Task { await appState.switchSiteProfile(profile.id) }
                } label: {
                    Label(
                        profile.name,
                        systemImage: appState.activeSiteProfileID == profile.id
                            ? "building.2.fill" : "building.2"
                    )
                    .foregroundStyle(
                        appState.activeSiteProfileID == profile.id ? .blue : .primary
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var camerasSection: some View {
        Section("Cameras") {
            ForEach(appState.cameras) { camera in
                CameraSidebarRow(camera: camera, isSelected: selectedCameraID == camera.id)
                    .onTapGesture {
                        selectedCameraID = camera.id
                        selectedDestination = .cameraGrid
                    }
            }
        }
    }

    private var navSection: some View {
        Section {
            NavigationLink(value: AppDestination.cameraGrid) {
                Label("Camera Grid", systemImage: "square.grid.2x2")
            }
            NavigationLink(value: AppDestination.timeline(cameraID: nil)) {
                Label("Timeline", systemImage: "timeline.selection")
            }
            NavigationLink(value: AppDestination.health) {
                Label("Health Dashboard", systemImage: "heart.text.square")
            }
            NavigationLink(value: AppDestination.rules) {
                Label("Rules", systemImage: "list.bullet.rectangle")
            }
            NavigationLink(value: AppDestination.settings) {
                Label("Settings", systemImage: "gear")
            }
        }
    }

    // MARK: - Detail

    private var detailStack: some View {
        NavigationStack {
            Group {
                switch selectedDestination {
                case .cameraGrid, .none:
                    CameraGridView(focusedCameraID: selectedCameraID)
                case .timeline(let cameraID):
                    TimelineView(initialCameraID: cameraID)
                case .health:
                    HealthDashboardView()
                case .rules:
                    RulesPlaceholderView()
                case .settings:
                    SettingsView()
                }
            }
            .environmentObject(appState)
        }
    }

    // MARK: - Toolbar

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            // Connection status
            Circle()
                .fill(appState.xpcConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .help(appState.xpcConnected ? "SentinelCore connected" : "SentinelCore disconnected")

            // Arm/Disarm toggle
            let allArmed = !appState.cameras.isEmpty && appState.cameras.allSatisfy(\.isArmed)
            Button {
                Task {
                    if allArmed { await appState.disarmAll() } else { await appState.armAll() }
                }
            } label: {
                Image(systemName: allArmed ? "shield.fill" : "shield")
            }
            .help(allArmed ? "Disarm All" : "Arm All")
            .foregroundStyle(allArmed ? .blue : .secondary)

            // Lockdown button
            Button {
                Task { await appState.triggerLockdown() }
            } label: {
                Image(systemName: appState.isLockedDown ? "exclamationmark.skull.fill" : "exclamationmark.shield")
            }
            .help("Trigger Lockdown")
            .foregroundStyle(appState.isLockedDown ? .red : .orange)
        }
    }

    // MARK: - Banners

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("SentinelCore Disconnected — Camera monitoring is paused")
                .font(.caption.bold())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var lockdownBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.skull.fill")
                .foregroundStyle(.red)
            Text("LOCKDOWN ACTIVE — All cameras armed, remote access disabled")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Camera sidebar row

private struct CameraSidebarRow: View {
    let camera: CameraProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(camera.name)
                .lineLimit(1)
            Spacer()
            if camera.isArmed {
                Image(systemName: "shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch camera.source {
        default: return .green
        }
    }
}

// MARK: - Rules placeholder

private struct RulesPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Detection Rules",
            systemImage: "list.bullet.rectangle",
            description: Text("Rule configuration is coming in a future release.")
        )
    }
}
