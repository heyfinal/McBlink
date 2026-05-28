// CameraDetailView.swift — McBlink
// Full-screen camera detail sheet. Phase 1: snapshot + event list.
// Swift 6 strict concurrency.

import SwiftUI
import AVKit

struct CameraDetailView: View {

    let camera: CameraProfile

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: NSImage? = nil
    @State private var recentEvents: [DetectionEvent] = []
    @State private var isLoadingSnapshot: Bool = false
    @State private var showTimeline: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isTogglingArm: Bool = false
    @State private var pollTask: Task<Void, Never>? = nil

    /// Cached-thumbnail poll interval. 2s feels live during motion (Blink updates
    /// the cloud thumbnail every ~1-2s while a clip is recording) without waking
    /// the camera or burning battery.
    private static let livePollInterval: TimeInterval = 2.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    snapshotArea
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)

                    Divider()

                    controlBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                    Divider()

                    eventsList
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .navigationTitle(camera.name)
            .navigationSubtitle(camera.source.rawValue.uppercased())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadData()
                startLivePolling()
            }
            .onDisappear {
                pollTask?.cancel()
                pollTask = nil
            }
            .sheet(isPresented: $showTimeline) {
                TimelineView(initialCameraID: camera.id)
                    .environmentObject(appState)
                    .frame(minWidth: 800, minHeight: 500)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    // MARK: - Snapshot area

    private var snapshotArea: some View {
        ZStack {
            Rectangle().fill(Color.black)

            if isLoadingSnapshot {
                ProgressView()
                    .tint(.white)
            } else if let img = snapshot {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()

                    // Detection zone overlays
                    if !camera.detectionZones.isEmpty {
                        GeometryReader { geo in
                            ForEach(camera.detectionZones) { zone in
                                DetectionZoneOverlay(zone: zone, frameSize: geo.size)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No snapshot available")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Status badge top-right
            VStack {
                HStack {
                    Spacer()
                    statusBadge
                        .padding(8)
                }
                Spacer()
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(camera.isArmed ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(camera.isArmed ? "ARMED" : "DISARMED")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            // Arm/Disarm toggle
            Button {
                Task { await toggleArm() }
            } label: {
                Label(
                    camera.isArmed ? "Disarm" : "Arm",
                    systemImage: camera.isArmed ? "shield.slash" : "shield"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.isArmed ? .orange : .blue)
            .disabled(isTogglingArm)

            // Take snapshot (forces a fresh capture — wakes camera)
            Button {
                Task { await loadFreshSnapshot() }
            } label: {
                Label("Snapshot", systemImage: "camera")
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingSnapshot)

            // View timeline
            Button {
                showTimeline = true
            } label: {
                Label("Timeline", systemImage: "timeline.selection")
            }
            .buttonStyle(.bordered)

            Spacer()

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Events list

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Detections")
                .font(.headline)
                .padding(.bottom, 2)

            if recentEvents.isEmpty {
                Text("No recent detections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(recentEvents.prefix(10)) { event in
                    DetectionEventRow(event: event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    // MARK: - Actions

    private func loadData() async {
        async let snapshotLoad: () = loadFreshSnapshot()
        async let eventsLoad: () = loadEvents()
        await snapshotLoad
        await eventsLoad
    }

    /// Cached thumbnail — instant, no camera wake. Used by the auto-poll loop.
    private func loadCachedSnapshot() async {
        if let data = await appState.xpcClient.getSnapshot(cameraID: camera.id),
           let img = NSImage(data: data) {
            snapshot = img
        }
    }

    /// Wakes the camera and pulls a freshly captured image (~10s). Used on view
    /// open and when the Snapshot button is tapped.
    private func loadFreshSnapshot() async {
        isLoadingSnapshot = true
        defer { isLoadingSnapshot = false }
        if let data = await appState.xpcClient.getFreshSnapshot(cameraID: camera.id),
           let img = NSImage(data: data) {
            snapshot = img
        }
    }

    private func startLivePolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.livePollInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                await loadCachedSnapshot()
            }
        }
    }

    private func loadEvents() async {
        if let events = try? await appState.xpcClient.getRecentEvents(camera.id, limit: 10) {
            recentEvents = events
        }
    }

    private func toggleArm() async {
        isTogglingArm = true
        defer { isTogglingArm = false }
        errorMessage = nil
        if camera.isArmed {
            await appState.disarmCamera(camera.id)
        } else {
            await appState.armCamera(camera.id)
        }
        if let err = appState.lastError { errorMessage = err }
    }
}

// MARK: - Detection zone overlay

private struct DetectionZoneOverlay: View {
    let zone: DetectionZone
    let frameSize: CGSize

    var body: some View {
        Canvas { context, _ in
            guard zone.polygon.count >= 2 else { return }
            var path = Path()
            let first = denormalize(zone.polygon[0])
            path.move(to: first)
            for point in zone.polygon.dropFirst() {
                path.addLine(to: denormalize(point))
            }
            path.closeSubpath()
            context.stroke(path, with: .color(.yellow.opacity(0.8)), lineWidth: 1.5)
            context.fill(path, with: .color(.yellow.opacity(0.12)))
        }
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * frameSize.width, y: point.y * frameSize.height)
    }
}

// MARK: - Detection event row

private struct DetectionEventRow: View {
    let event: DetectionEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForEvent)
                .foregroundStyle(colorForEvent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.detectedClasses.map(\.rawValue).joined(separator: ", ").capitalized)
                    .font(.caption.bold())
                Text(event.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%.0f%%", event.confidence * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var iconForEvent: String {
        if event.detectedClasses.contains(.person) { return "person.fill" }
        if event.detectedClasses.contains(.vehicle) { return "car.fill" }
        if event.detectedClasses.contains(.animal) { return "pawprint.fill" }
        if event.detectedClasses.contains(.glassBreak) { return "waveform" }
        if event.detectedClasses.contains(.smokeAlarm) { return "smoke.fill" }
        return "dot.radiowaves.left.and.right"
    }

    private var colorForEvent: Color {
        if event.detectedClasses.contains(.person) { return .red }
        if event.detectedClasses.contains(.vehicle) { return .orange }
        if event.detectedClasses.contains(.glassBreak) { return .yellow }
        return .blue
    }
}
