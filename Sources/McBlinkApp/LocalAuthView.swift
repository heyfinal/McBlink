// LocalAuthView.swift — McBlink
// Touch ID / password gate shown on launch.
// Swift 6 strict concurrency. LocalAuthentication framework.

import SwiftUI
import LocalAuthentication
import CommonCrypto

struct LocalAuthView: View {

    let onAuthenticated: @MainActor () -> Void

    // MARK: - State

    @State private var biometryAvailable: Bool = false
    @State private var biometryType: LABiometryType = .none
    @State private var passwordEntry: String = ""
    @State private var showPasswordField: Bool = false
    @State private var failedAttempts: Int = 0
    @State private var lockedOutUntil: Date? = nil
    @State private var lockoutCountdown: Int = 0
    @State private var errorMessage: String? = nil
    @State private var isAuthenticating: Bool = false
    @FocusState private var passwordFocused: Bool

    private let maxAttempts = 3
    private let lockoutSeconds = 30
    private let passwordKey = "McBlinkAuthPasswordHash"

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "video.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("McBlink")
                .font(.largeTitle.bold())

            Text("Authenticate to continue")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if let lockedUntil = lockedOutUntil, Date() < lockedUntil {
                lockoutBanner
            } else if showPasswordField || !biometryAvailable {
                passwordFieldView
            } else {
                touchIDButton
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(width: 380, height: 480)
        .task {
            await checkBiometry()
            if biometryAvailable {
                await attemptBiometricAuth()
            }
        }
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            updateLockoutCountdown()
        }
    }

    // MARK: - Subviews

    private var touchIDButton: some View {
        VStack(spacing: 12) {
            Button {
                Task { await attemptBiometricAuth() }
            } label: {
                Label(
                    biometryType == .touchID ? "Authenticate with Touch ID" : "Authenticate with Face ID",
                    systemImage: biometryType == .touchID ? "touchid" : "faceid"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)
            .frame(maxWidth: 280)

            Button("Use Password Instead") {
                showPasswordField = true
                errorMessage = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var passwordFieldView: some View {
        VStack(spacing: 12) {
            SecureField("Password", text: $passwordEntry)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($passwordFocused)
                .onSubmit { Task { await attemptPasswordAuth() } }
                .onAppear { passwordFocused = true }

            Button("Unlock") {
                Task { await attemptPasswordAuth() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 280)
            .disabled(passwordEntry.isEmpty || isAuthenticating)

            if biometryAvailable {
                Button("Use Touch ID Instead") {
                    showPasswordField = false
                    errorMessage = nil
                    Task { await attemptBiometricAuth() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var lockoutBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Too many failed attempts")
                .font(.headline)
            Text("Try again in \(lockoutCountdown)s")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Biometry

    private func checkBiometry() async {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometryAvailable = canEvaluate
        biometryType = context.biometryType
        if !canEvaluate {
            showPasswordField = true
        }
    }

    private func attemptBiometricAuth() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to access McBlink"
            )
            if success {
                onAuthenticated()
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userFallback:
                showPasswordField = true
                errorMessage = nil
            case .biometryNotAvailable, .biometryNotEnrolled:
                biometryAvailable = false
                showPasswordField = true
            case .userCancel:
                errorMessage = nil
            default:
                recordFailedAttempt(message: laError.localizedDescription)
            }
        } catch {
            recordFailedAttempt(message: error.localizedDescription)
        }
    }

    // MARK: - Password

    private func attemptPasswordAuth() async {
        guard !isAuthenticating, !passwordEntry.isEmpty else { return }
        isAuthenticating = true
        errorMessage = nil
        defer {
            isAuthenticating = false
            passwordEntry = ""
        }

        let entered = passwordEntry
        let storedHash = keychainPasswordHash()

        if storedHash == nil {
            // First launch: hash and store in Keychain (never UserDefaults).
            setKeychainPasswordHash(sha256(entered))
            onAuthenticated()
            return
        }

        if sha256(entered) == storedHash {
            failedAttempts = 0
            onAuthenticated()
        } else {
            recordFailedAttempt(message: "Incorrect password.")
        }
    }

    // MARK: - Lockout

    private func recordFailedAttempt(message: String) {
        failedAttempts += 1
        if failedAttempts >= maxAttempts {
            let until = Date().addingTimeInterval(TimeInterval(lockoutSeconds))
            lockedOutUntil = until
            lockoutCountdown = lockoutSeconds
            errorMessage = nil
        } else {
            errorMessage = message + " (\(maxAttempts - failedAttempts) attempt(s) remaining)"
        }
    }

    private func updateLockoutCountdown() {
        guard let until = lockedOutUntil else { return }
        let remaining = Int(until.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            lockedOutUntil = nil
            lockoutCountdown = 0
            failedAttempts = 0
        } else {
            lockoutCountdown = remaining
        }
    }

    // MARK: - Hashing

    // MARK: - Keychain password hash (never store auth data in UserDefaults)

    private let keychainService = "com.heyfinal.mcblink.auth"
    private let keychainAccount = "fallback-password-hash"

    private func keychainPasswordHash() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func setKeychainPasswordHash(_ hash: String) {
        guard let data = hash.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
