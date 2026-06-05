// TimelineView.swift — McBlink
// Horizontal scrubber + clip list for reviewing recorded footage.
// Swift 6 strict concurrency.

import SwiftUI
import AVKit

struct TimelineView: View {

    let initialCameraID: UUID?

    @EnvironmentObject private var appState: AppState
    @State private var selectedCameraID: UUID? = nil
    @State private var selectedDate: Date = Date()
    @State private var clips: [ClipRecord] = []
    @State private var selectedClip: ClipRecord? = nil
    @State private var player: AVPlayer? = nil
    @State private var isLoadingClips: Bool = false
    @State private var exportError: String? = nil

    private var displayedCamera: CameraProfile? {
        guard let id = selectedCameraID else { return nil }
        return appState.camera(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            topControls
                .padding(12)
                .background(.bar)

            Divider()

            scrubberView
                .frame(height: 56)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)

            Divider()

            HStack(spacing: 0) {
                clipListPanel
                    .frame(minWidth: 220, maxWidth: 300)

                Divider()

                clipPlayerPanel
            }
        }
        .navigationTitle("Timeline")
        .task(id: selectedCameraID) {
            await loadClips()
        }
        .task(id: selectedDate) {
            await loadClips()
        }
        .onAppear {
            selectedCameraID = initialCameraID ?? appState.cameras.first?.id
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Top controls

    private var topControls: some View {
        HStack(spacing: 16) {
            Picker("Camera", selection: $selectedCameraID) {
                Text("All Cameras").tag(Optional<UUID>.none)
                ForEach(appState.cameras) { cam in
                    Text(cam.name).tag(Optional(cam.id))
                }
            }
            .frame(maxWidth: 200)

            DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()

            Spacer()

            if isLoadingClips {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: - Scrubber

    private var scrubberView: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawScrubber(context: context, size: size)
            }
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func drawScrubber(context: GraphicsContext, size: CGSize) {
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let totalSeconds = dayEnd.timeIntervalSince(dayStart)

        // Background
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.gray.opacity(0.2))
        )

        for clip in clips {
            let startFraction = clip.startTime.timeIntervalSince(dayStart) / totalSeconds
            let endFraction = clip.endTime.timeIntervalSince(dayStart) / totalSeconds
            let x = CGFloat(startFraction) * size.width
            let w = max(2, CGFloat(endFraction - startFraction) * size.width)
            let rect = CGRect(x: x, y: 0, width: w, height: size.height)

            let color: Color
            if clip.detectedClasses.contains(.person) || clip.detectedClasses.contains(.vehicle) {
                color = .red
            } else if clip.detectedClasses.contains(.bark) ||
                      clip.detectedClasses.contains(.glassBreak) ||
                      clip.detectedClasses.contains(.smokeAlarm) {
                color = .blue
            } else {
                color = .orange
            }
            context.fill(Path(rect), with: .color(color.opacity(0.75)))
        }

        // Now indicator
        let nowFraction = Date().timeIntervalSince(dayStart) / totalSeconds
        if nowFraction >= 0 && nowFraction <= 1 {
            let x = CGFloat(nowFraction) * size.width
            var nowPath = Path()
            nowPath.move(to: CGPoint(x: x, y: 0))
            nowPath.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(nowPath, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        }
    }

    // MARK: - Clip list

    private var clipListPanel: some View {
        List(clips, selection: Binding(
            get: { selectedClip?.id },
            set: { id in
                selectedClip = clips.first { $0.id == id }
                if let clip = selectedClip { openClip(clip) }
            }
        )) { clip in
            ClipRow(clip: clip, onExport: { exportClip(clip) })
                .tag(clip.id)
        }
        .listStyle(.plain)
        .overlay {
            if clips.isEmpty && !isLoadingClips {
                ContentUnavailableView(
                    "No Clips",
                    systemImage: "film.stack",
                    description: Text("No recordings found for this date.")
                )
            }
        }
    }

    // MARK: - Clip player

    private var clipPlayerPanel: some View {
        Group {
            if let p = player {
                VideoPlayer(player: p)
                    .onDisappear { p.pause() }
            } else {
                ContentUnavailableView(
                    "Select a Clip",
                    systemImage: "play.rectangle",
                    description: Text("Choose a recording from the list to play it.")
                )
            }
        }
    }

    // MARK: - Data loading

    private func loadClips() async {
        isLoadingClips = true
        defer { isLoadingClips = false }

        let start = Calendar.current.startOfDay(for: selectedDate)
        let end = start.addingTimeInterval(86400)

        do {
            clips = try await appState.xpcClient.getClips(selectedCameraID, startTime: start, endTime: end)
        } catch {
            clips = []
        }
    }

    // MARK: - Clip actions

    private func openClip(_ clip: ClipRecord) {
        // Decrypt the clip to ~/Downloads/mcblink-playback/ (in the safe export path list).
        // Clean up previous decrypted files to avoid accumulating plaintext on disk.
        let tmpDir = NSHomeDirectory() + "/Downloads/mcblink-playback"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for file in existing where file.hasSuffix(".mp4") {
                try? FileManager.default.removeItem(atPath: tmpDir + "/" + file)
            }
        }
        let tmpPath = tmpDir + "/\(clip.id.uuidString).mp4"
        Task {
            do {
                try await appState.xpcClient.exportClip(clip.id, toPath: tmpPath)
                let url = URL(fileURLWithPath: tmpPath)
                player = AVPlayer(url: url)
                player?.play()
            } catch {
                exportError = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportClip(_ clip: ClipRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(clip.id.uuidString).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            Task {
                do {
                    try await appState.xpcClient.exportClip(clip.id, toPath: dest.path)
                } catch {
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - ClipRow

private struct ClipRow: View {
    let clip: ClipRecord
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                classBadges
                Spacer()
                Button {
                    onExport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Export clip")
            }

            Text(clip.startTime, style: .time)
                .font(.caption.bold())

            HStack {
                Text(durationString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sizeString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var classBadges: some View {
        HStack(spacing: 3) {
            ForEach(clip.detectedClasses, id: \.self) { cls in
                Text(cls.rawValue.capitalized)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(badgeColor(for: cls))
                    .foregroundStyle(.white)
                    .cornerRadius(3)
            }
        }
    }

    private func badgeColor(for cls: DetectionClass) -> Color {
        switch cls {
        case .person:   return .red
        case .vehicle:  return .orange
        case .animal:   return .purple
        default:        return .gray
        }
    }

    private var durationString: String {
        let d = clip.endTime.timeIntervalSince(clip.startTime)
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var sizeString: String {
        let mb = Double(clip.sizeBytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}
