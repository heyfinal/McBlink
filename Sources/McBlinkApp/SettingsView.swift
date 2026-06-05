// SettingsView.swift — McBlink
// Tabbed settings: Cameras, Storage, Notifications, Offsite Sync,
// Remote Access, Integrations, About.
// Swift 6 strict concurrency.

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            CamerasSettingsTab()
                .tabItem { Label("Cameras", systemImage: "video") }
                .environmentObject(appState)

            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .environmentObject(appState)

            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .environmentObject(appState)

            OffsiteSyncSettingsTab()
                .tabItem { Label("Offsite Sync", systemImage: "icloud") }

            RemoteAccessSettingsTab()
                .tabItem { Label("Remote Access", systemImage: "network") }

            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .environmentObject(appState)

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Cameras tab

private struct CamerasSettingsTab: View {

    @EnvironmentObject private var appState: AppState
    @State private var showAddCamera: Bool = false
    @State private var editingCamera: CameraProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(appState.cameras) { camera in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name).font(.body)
                            Text(camera.source.rawValue.uppercased() + " · " + camera.streamURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingCamera = camera }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { appState.cameras[$0].id }
                    Task {
                        for id in ids { try? await appState.xpcClient.removeCamera(id) }
                        await appState.loadCameras()
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Add Camera") { showAddCamera = true }
                    .buttonStyle(.borderedProminent)
                    .padding(10)
            }
        }
        .sheet(isPresented: $showAddCamera) {
            CameraEditSheet(camera: nil,
                            defaultSiteProfileID: appState.siteProfiles.first?.id ?? UUID()
            ) { profile in
                Task {
                    try? await appState.xpcClient.addCamera(profile)
                    if !profile.password.isEmpty {
                        try? await appState.xpcClient.storeCameraCredential(
                            profile.id, password: profile.password)
                    }
                    await appState.loadCameras()
                }
            }
        }
        .sheet(item: $editingCamera) { camera in
            CameraEditSheet(camera: camera,
                            defaultSiteProfileID: appState.siteProfiles.first?.id ?? UUID()
            ) { updated in
                Task {
                    try? await appState.xpcClient.addCamera(updated)
                    if !updated.password.isEmpty {
                        try? await appState.xpcClient.storeCameraCredential(
                            updated.id, password: updated.password)
                    }
                    await appState.loadCameras()
                }
            }
        }
    }
}

// MARK: - Camera edit sheet

private struct CameraEditSheet: View {

    let camera: CameraProfile?
    let defaultSiteProfileID: UUID
    let onSave: (CameraProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var source: CameraSource
    @State private var streamURL: String
    @State private var substreamURL: String
    @State private var username: String
    @State private var password: String

    init(camera: CameraProfile?, defaultSiteProfileID: UUID, onSave: @escaping (CameraProfile) -> Void) {
        self.camera = camera
        self.defaultSiteProfileID = defaultSiteProfileID
        self.onSave = onSave
        _name = State(initialValue: camera?.name ?? "")
        _source = State(initialValue: camera?.source ?? .rtsp)
        _streamURL = State(initialValue: camera?.streamURL ?? "")
        _substreamURL = State(initialValue: camera?.substreamURL ?? "")
        _username = State(initialValue: camera?.username ?? "")
        _password = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Camera Name", text: $name)
                    Picker("Source", selection: $source) {
                        ForEach(CameraSource.allCases, id: \.self) { src in
                            Text(src.rawValue.uppercased()).tag(src)
                        }
                    }
                }

                Section("Stream") {
                    TextField("Stream URL", text: $streamURL)
                        .font(.system(.body, design: .monospaced))
                    TextField("Substream URL (optional)", text: $substreamURL)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(camera == nil ? "Add Camera" : "Edit Camera")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || streamURL.isEmpty)
                }
            }
        }
        .frame(width: 440, height: 380)
    }

    private func save() {
        let profile = CameraProfile(
            id: camera?.id ?? UUID(),
            name: name,
            source: source,
            streamURL: streamURL,
            substreamURL: substreamURL.isEmpty ? nil : substreamURL,
            username: username.isEmpty ? nil : username,
            password: password,
            capabilities: camera?.capabilities ?? [.liveStream, .motionEvents],
            detectionZones: camera?.detectionZones ?? [],
            isArmed: camera?.isArmed ?? false,
            siteProfileID: camera?.siteProfileID ?? defaultSiteProfileID
        )
        onSave(profile)
        dismiss()
    }
}

// MARK: - Storage tab

private struct StorageSettingsTab: View {

    @EnvironmentObject private var appState: AppState
    @AppStorage("storageBasePath") private var storageBasePath: String = ""

    var body: some View {
        Form {
            Section("Location") {
                HStack {
                    TextField("Storage Base Path", text: $storageBasePath)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK {
                            storageBasePath = panel.url?.path ?? storageBasePath
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Retention") {
                VStack(alignment: .leading) {
                    Text("Keep recordings for \(appState.settings.retentionDays) days")
                    Slider(
                        value: Binding(
                            get: { Double(appState.settings.retentionDays) },
                            set: { val in
                                var s = appState.settings
                                s.retentionDays = Int(val)
                                appState.saveSettings(s)
                            }
                        ),
                        in: 1...365, step: 1
                    )
                }
                VStack(alignment: .leading) {
                    Text("Max disk usage: \(appState.settings.maxDiskGB) GB")
                    Slider(
                        value: Binding(
                            get: { Double(appState.settings.maxDiskGB) },
                            set: { val in
                                var s = appState.settings
                                s.maxDiskGB = Int(val)
                                appState.saveSettings(s)
                            }
                        ),
                        in: 10...2000, step: 10
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications tab

private struct NotificationsSettingsTab: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Detection Classes") {
                Toggle("Person detected",      isOn: settingsBinding(\.notifyPerson))
                Toggle("Vehicle detected",     isOn: settingsBinding(\.notifyVehicle))
                Toggle("Animal detected",      isOn: settingsBinding(\.notifyAnimal))
                Toggle("Package detected",     isOn: settingsBinding(\.notifyPackage))
                Toggle("Glass break detected", isOn: settingsBinding(\.notifyGlassBreak))
                Toggle("Smoke alarm detected", isOn: settingsBinding(\.notifySmokeAlarm))
                Toggle("Bark detected",        isOn: settingsBinding(\.notifyBark))
            }

            Section("Quiet Hours") {
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { timeIntervalToDate(appState.settings.quietHoursStart) },
                        set: { newDate in
                            var s = appState.settings
                            s.quietHoursStart = newDate.timeIntervalSince(Calendar.current.startOfDay(for: newDate))
                            appState.saveSettings(s)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "End",
                    selection: Binding(
                        get: { timeIntervalToDate(appState.settings.quietHoursEnd) },
                        set: { newDate in
                            var s = appState.settings
                            s.quietHoursEnd = newDate.timeIntervalSince(Calendar.current.startOfDay(for: newDate))
                            appState.saveSettings(s)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
        }
        .formStyle(.grouped)
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                var s = appState.settings
                s[keyPath: keyPath] = newValue
                appState.saveSettings(s)
            }
        )
    }

    private func timeIntervalToDate(_ interval: Double) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(interval)
    }
}

// MARK: - Offsite Sync tab

private struct OffsiteSyncSettingsTab: View {

    @AppStorage("iCloudSyncEnabled")    private var iCloudEnabled: Bool = false
    @AppStorage("s3SyncEnabled")        private var s3Enabled: Bool = false
    @AppStorage("s3Bucket")             private var s3Bucket: String = ""
    @AppStorage("syncOnDetection")      private var syncOnDetection: Bool = false

    @State private var s3AccessKey: String = ""
    @State private var s3Secret: String = ""

    var body: some View {
        Form {
            Section("iCloud Drive") {
                Toggle("Sync clips to iCloud Drive", isOn: $iCloudEnabled)
            }

            Section("Amazon S3") {
                Toggle("Sync clips to S3", isOn: $s3Enabled)
                if s3Enabled {
                    TextField("Bucket", text: $s3Bucket)
                    TextField("Access Key ID", text: $s3AccessKey)
                        .onChange(of: s3AccessKey) { _, _ in saveS3Creds() }
                    SecureField("Secret Access Key", text: $s3Secret)
                        .onChange(of: s3Secret) { _, _ in saveS3Creds() }
                }
            }

            Section("Behavior") {
                Toggle("Sync immediately on detection", isOn: $syncOnDetection)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadS3Creds() }
    }

    private static var s3CredsURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("McBlink/.s3creds")
    }

    private func loadS3Creds() {
        guard let data = try? Data(contentsOf: Self.s3CredsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        s3AccessKey = obj["accessKey"] ?? ""
        s3Secret = obj["secret"] ?? ""
    }

    private func saveS3Creds() {
        let obj: [String: String] = ["accessKey": s3AccessKey, "secret": s3Secret]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = Self.s3CredsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Remote Access tab

private struct RemoteAccessSettingsTab: View {

    @AppStorage("localHTTPSEnabled") private var localHTTPSEnabled: Bool = false
    @AppStorage("localHTTPSPort")    private var localHTTPSPort: Double = 8443

    var body: some View {
        Form {
            Section("Tailscale") {
                HStack {
                    Image(systemName: isTailscaleRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isTailscaleRunning ? .green : .red)
                    Text(isTailscaleRunning ? "Tailscale running" : "Tailscale not detected")
                    Spacer()
                    Button("Open Tailscale") {
                        NSWorkspace.shared.open(URL(string: "https://tailscale.com")!)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Local HTTPS Server") {
                Toggle("Enable local HTTPS server", isOn: $localHTTPSEnabled)
                if localHTTPSEnabled {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $localHTTPSPort, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isTailscaleRunning: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
    }
}

// MARK: - Integrations tab

private struct IntegrationsSettingsTab: View {

    @EnvironmentObject private var appState: AppState
    @State private var showBlinkConnect: Bool = false
    @State private var blinkConnected: Bool = false

    var body: some View {
        Form {
            Section("Blink") {
                HStack {
                    Image(systemName: blinkConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(blinkConnected ? .green : .secondary)
                    Text(blinkConnected ? "Connected" : "Not connected")
                    Spacer()
                    Button(blinkConnected ? "Re-connect" : "Connect") {
                        showBlinkConnect = true
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Home Assistant — MQTT") {
                TextField("Host", text: Binding(
                    get: { appState.settings.mqttHost },
                    set: { val in
                        var s = appState.settings
                        s.mqttHost = val
                        appState.saveSettings(s)
                    }
                ))
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: Binding(
                        get: { appState.settings.mqttPort },
                        set: { val in
                            var s = appState.settings
                            s.mqttPort = val
                            appState.saveSettings(s)
                        }
                    ), format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Topic Prefix", text: Binding(
                    get: { appState.settings.mqttTopicPrefix },
                    set: { val in
                        var s = appState.settings
                        s.mqttTopicPrefix = val
                        appState.saveSettings(s)
                    }
                ))
            }

            Section("Shortcuts") {
                Text("McBlink exposes detection events via NSUserNotification and can be triggered from Shortcuts using URL schemes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { checkBlinkStatus() }
        .sheet(isPresented: $showBlinkConnect) {
            BlinkConnectSheet {
                checkBlinkStatus()
                Task { await appState.loadCameras() }
            }
            .environmentObject(appState)
        }
    }

    private func checkBlinkStatus() {
        let credsURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("McBlink/blink_creds.json")
        blinkConnected = FileManager.default.fileExists(atPath: credsURL.path)
    }
}

// MARK: - Blink connect sheet

private struct BlinkConnectSheet: View {

    let onSuccess: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var pin: String = ""
    @State private var needsPin: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if needsPin {
                    Section {
                        Text("Blink sent a verification code to your email or phone. Enter it below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("6-digit code", text: $pin)
                            .font(.system(.body, design: .monospaced))
                    } header: { Text("Verification") }
                } else {
                    Section("Blink Account") {
                        TextField("Email", text: $email)
                        SecureField("Password", text: $password)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect Blink")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button(needsPin ? "Verify" : "Connect") { submit() }
                            .disabled(needsPin ? pin.count < 4 : (email.isEmpty || password.isEmpty))
                    }
                }
            }
        }
        .frame(width: 380, height: 260)
    }

    private func submit() {
        isLoading = true
        errorMessage = nil
        Task {
            if needsPin {
                let result = await appState.xpcClient.blinkAuthPin(pin)
                if result.ok {
                    onSuccess()
                    dismiss()
                } else {
                    errorMessage = result.message ?? "Verification failed — check the code and try again."
                }
            } else {
                let result = await appState.xpcClient.blinkAuth(email: email, password: password)
                if result.needsPin {
                    needsPin = true
                } else if result.ok {
                    onSuccess()
                    dismiss()
                } else {
                    errorMessage = result.message ?? "Login failed — check your credentials."
                }
            }
            isLoading = false
        }
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {

    @State private var checkingUpdate: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "video.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("McBlink")
                .font(.title.bold())

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                checkForUpdates()
            } label: {
                if checkingUpdate {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text("Check for Updates…")
                }
            }
            .buttonStyle(.bordered)
            .disabled(checkingUpdate)

            Button("View Licenses") {
                NSWorkspace.shared.open(
                    Bundle.main.url(forResource: "Licenses", withExtension: "txt")
                    ?? URL(string: "about:blank")!
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func checkForUpdates() {
        // Sparkle's SPUStandardUpdaterController is set up in McBlinkApp.
        // Post a notification that the app delegate picks up.
        checkingUpdate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checkingUpdate = false
        }
    }
}
