// main.swift — SentinelWatchdog process entry point
// Swift 6 / macOS 14+
//
// This tool is managed by launchd. It connects to the SentinelCore XPC service
// every 30 seconds. After 3 consecutive failures it posts a UNUserNotification
// and continues polling.

import Foundation
import UserNotifications

// MARK: - Logging

let logURL: URL = {
    let logDir = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    ).first!.appending(path: "Logs/McBlink", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    return logDir.appending(path: "watchdog.log")
}()

let logFileHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    return try? FileHandle(forWritingTo: logURL)
}()

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        logFileHandle?.seekToEndOfFile()
        logFileHandle?.write(data)
    }
    // Also print to stdout for launchd journald capture.
    print(line, terminator: "")
}

// MARK: - XPC Probe

/// Attempts one synchronous XPC ping to SentinelCore.
/// Returns `true` if the connection is accepted and a reply arrives within the timeout.
func probeSentinelCore() -> Bool {
    let connection = NSXPCConnection(serviceName: "com.heyfinal.mcblink.sentinelcore")
    connection.remoteObjectInterface = NSXPCInterface(with: McBlinkXPCProtocol.self)
    connection.resume()

    var succeeded = false
    let semaphore = DispatchSemaphore(value: 0)

    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        log("XPC proxy error: \(error.localizedDescription)")
        semaphore.signal()
    } as? McBlinkXPCProtocol

    proxy?.getAllHealthReports { _ in
        succeeded = true
        semaphore.signal()
    }

    // 10-second timeout per probe.
    let result = semaphore.wait(timeout: .now() + 10)
    connection.invalidate()

    if result == .timedOut { log("XPC probe timed out.") }
    return succeeded
}

// MARK: - Notification

func postUnresponsiveNotification() {
    let center = UNUserNotificationCenter.current()

    // Request authorization if not already granted.
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { log("Notification auth error: \(error)") }
        guard granted else { log("Notification permission denied."); return }

        let content = UNMutableNotificationContent()
        content.title = "McBlink — SentinelCore Unresponsive"
        content.body = "SentinelCore failed to respond 3 times in a row. Recording may be interrupted."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.heyfinal.mcblink.watchdog.unresponsive-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately.
        )
        center.add(request) { error in
            if let error { log("Failed to post notification: \(error)") }
        }
    }
}

// MARK: - SIGTERM Handler

nonisolated(unsafe) var shouldRun = true
signal(SIGTERM) { _ in shouldRun = false }

// MARK: - Main Poll Loop

log("SentinelWatchdog started.")

// Request notification permission on launch.
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

var consecutiveFailures = 0
let pollInterval: TimeInterval = 30

Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { timer in
    guard shouldRun else {
        timer.invalidate()
        log("SentinelWatchdog received SIGTERM — exiting.")
        exit(0)
    }

    let alive = probeSentinelCore()
    if alive {
        if consecutiveFailures > 0 {
            log("SentinelCore recovered after \(consecutiveFailures) failure(s).")
        }
        consecutiveFailures = 0
    } else {
        consecutiveFailures += 1
        log("SentinelCore probe failed (\(consecutiveFailures)/3).")
        if consecutiveFailures >= 3 {
            log("SentinelCore unresponsive — posting user notification.")
            postUnresponsiveNotification()
            // Reset counter so we don't spam; next alert fires after 3 more failures.
            consecutiveFailures = 0
        }
    }
}

RunLoop.main.run()
