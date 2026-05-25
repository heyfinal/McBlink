// CameraGridView.swift — McBlink
// Grid display of all camera feeds with periodic snapshot refresh.
// Swift 6 strict concurrency.

import SwiftUI

// MARK: - Layout option

enum GridLayout: Int, CaseIterable, Identifiable {
    case one   = 1
    case two   = 2
    case three = 3
    case four  = 4

    var id: Int { rawValue }
    var columns: Int { rawValue }
    var label: String { "\(rawValue)×\(rawValue)" }
}

// MARK: - CameraGridView

struct CameraGridView: View {

    let focusedCameraID: UUID?

    @EnvironmentObject private var appState: AppState
    @AppStorage("gridLayout") private var layoutRaw: Int = GridLayout.two.rawValue

    @State private var snapshots: [UUID: NSImage] = [:]
    @State private var expandedCameraID: UUID? = nil
    @State private var refreshTimer: Timer? = nil

    private var layout: GridLayout {
        GridLayout(rawValue: layoutRaw) ?? .two
    }

    private var visibleCameras: [CameraProfile] {
        if let id = focusedCameraID {
            return appState.cameras.filter { $0.id == id }
        }
        return appState.cameras
    }

    var body: some View {
        VStack(spacing: 0) {
            layoutPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

            Divider()

            if appState.cameras.isEmpty {
                emptyCameraView
            } else {
                cameraGrid
            }
        }
        .navigationTitle("Camera Grid")
        .task {
            await refreshAllSnapshots()
            startTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .sheet(item: Binding(
            get: { expandedCameraID.flatMap { appState.camera(id: $0) } },
            set: { _ in expandedCameraID = nil }
        )) { camera in
            CameraDetailView(camera: camera)
                .environmentObject(appState)
        }
    }

    // MARK: - Layout picker

    private var layoutPicker: some View {
        HStack {
            Text("Layout")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Layout", selection: $layoutRaw) {
                ForEach(GridLayout.allCases) { layout in
                    Text(layout.label).tag(layout.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            Spacer()
            Button {
                Task { await refreshAllSnapshots() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh Snapshots")
        }
    }

    // MARK: - Grid

    private var cameraGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 4),
            count: layout.columns
        )
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(visibleCameras) { camera in
                    CameraCell(
                        camera: camera,
                        snapshot: snapshots[camera.id],
                        recentEvents: appState.recentEvents(for: camera.id, within: 60)
                    ) {
                        expandedCameraID = camera.id
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                }
            }
            .padding(4)
        }
    }

    private var emptyCameraView: some View {
        ContentUnavailableView(
            "No Cameras",
            systemImage: "video.slash",
            description: Text("Add cameras in Settings to start monitoring.")
        )
    }

    // MARK: - Snapshot refresh

    private func refreshAllSnapshots() async {
        await withTaskGroup(of: (UUID, NSImage?).self) { group in
            for camera in appState.cameras {
                group.addTask {
                    let image = await fetchSnapshot(cameraID: camera.id)
                    return (camera.id, image)
                }
            }
            for await (id, image) in group {
                if let image {
                    snapshots[id] = image
                }
            }
        }
    }

    private func fetchSnapshot(cameraID: UUID) async -> NSImage? {
        guard let data = await appState.xpcClient.getSnapshot(cameraID: cameraID) else {
            return nil
        }
        return NSImage(data: data)
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { await refreshAllSnapshots() }
        }
    }
}

// MARK: - CameraCell

private struct CameraCell: View {

    let camera: CameraProfile
    let snapshot: NSImage?
    let recentEvents: [DetectionEvent]
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background / snapshot
            Group {
                if let image = snapshot {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.85))
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipped()

            // Overlays
            VStack(alignment: .leading, spacing: 4) {
                Spacer()

                // Detection badges
                if !recentEvents.isEmpty {
                    detectionBadges
                }

                HStack(spacing: 4) {
                    // Status dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    // Camera name
                    Text(camera.name)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer()

                    // Arm badge
                    if camera.isArmed {
                        Image(systemName: "shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .cornerRadius(6)
        .onTapGesture(perform: onTap)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var detectionBadges: some View {
        let classes = Set(recentEvents.flatMap(\.detectedClasses))
        return HStack(spacing: 3) {
            ForEach(Array(classes), id: \.self) { cls in
                Text(cls.rawValue.capitalized)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(badgeColor(for: cls))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private func badgeColor(for cls: DetectionClass) -> Color {
        switch cls {
        case .person:   return .red
        case .vehicle:  return .orange
        case .animal:   return .purple
        case .package:  return .blue
        case .bicycle:  return .cyan
        case .glassBreak, .smokeAlarm, .bark: return .yellow
        }
    }

    private var statusColor: Color {
        // Without live XPC health data in the cell itself, fall back to green/offline.
        // AppState.healthReports is accessible via the environment, but CameraCell
        // is a private struct — pass status in from the parent if needed.
        // For now, green = armed, gray = disarmed.
        camera.isArmed ? .green : .gray
    }
}
