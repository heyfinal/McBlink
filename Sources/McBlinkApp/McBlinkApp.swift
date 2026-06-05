// McBlinkApp.swift — McBlink entry point
// Swift 6 strict concurrency. @main SwiftUI App.

import SwiftUI
import AppKit
import UserNotifications

// MARK: - App Delegate

final class McBlinkAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, Sendable {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Become a regular foreground app and take key focus so the launch
        // auth window can actually receive keyboard input.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - App

@main
struct McBlinkApp: App {

    @NSApplicationDelegateAdaptor(McBlinkAppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    @State private var isAuthenticated: Bool = false

    var body: some Scene {
        WindowGroup {
            if isAuthenticated {
                ContentView()
                    .environmentObject(appState)
                    .task {
                        await appState.loadSettings()
                        await appState.loadCameras()
                        await appState.loadSiteProfiles()
                        await appState.refreshHealth()
                        await appState.refreshRecentEvents()
                    }
            } else {
                LocalAuthView {
                    isAuthenticated = true
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            McBlinkCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Menu Bar Commands

struct McBlinkCommands: Commands {

    let appState: AppState

    var body: some Commands {
        CommandMenu("Camera") {
            Button("Arm All") {
                Task { await appState.armAll() }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("Disarm All") {
                Task { await appState.disarmAll() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Lockdown") {
                Task { await appState.triggerLockdown() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift, .control])

            Divider()

            Button("Refresh") {
                Task {
                    await appState.loadCameras()
                    await appState.refreshHealth()
                    await appState.refreshRecentEvents()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }
}
