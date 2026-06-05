// LocalAuthView.swift — McBlink
// Single system auth dialog on launch (Touch ID or macOS password).
// Uses deviceOwnerAuthentication — no Keychain access needed.
// Swift 6 strict concurrency. LocalAuthentication framework.

import SwiftUI
import LocalAuthentication

struct LocalAuthView: View {

    let onAuthenticated: @MainActor () -> Void

    @State private var errorMessage: String? = nil
    @State private var isAuthenticating: Bool = false

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

            Button {
                Task { await authenticate() }
            } label: {
                Label("Unlock", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)
            .frame(maxWidth: 280)

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
            await authenticate()
        }
    }

    private func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Quit"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to access McBlink"
            )
            if success {
                onAuthenticated()
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel:
                errorMessage = nil
            default:
                errorMessage = laError.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
