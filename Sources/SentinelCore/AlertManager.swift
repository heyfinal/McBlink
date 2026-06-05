// AlertManager.swift — Notifications and MQTT alerts for SentinelCore
// Swift 6 / macOS 14
// Uses UserNotifications and Network.framework; no external dependencies.

import Foundation
import UserNotifications
import Network

// MARK: - AlertManager

actor AlertManager {

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Notification permission

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Detection alert

    func sendDetectionAlert(event: DetectionEvent, cameraName: String) async {
        guard await !inQuietHours() else { return }

        let className = event.detectedClasses.first?.rawValue.capitalized ?? "Object"
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let timeStr = formatter.string(from: event.timestamp)

        let content = UNMutableNotificationContent()
        content.title    = "McBlink: \(className) detected"
        content.subtitle = cameraName
        content.body     = "Detected at \(timeStr)"
        content.sound    = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "detection-\(event.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)

        // Also publish via MQTT if configured.
        if let (host, port, prefix) = await mqttConfig() {
            let topic   = "\(prefix)/detection/\(event.cameraID.uuidString)"
            let payload = try? JSONEncoder().encode(event)
            await publishMQTT(host: host, port: port, topic: topic, payload: payload ?? Data())
        }
    }

    // MARK: - ESP32-CAM motion alert

    /// Plain-motion notification for ESP32-CAM cameras (no Vision pipeline, no clip).
    func sendMotionAlert(cameraID: UUID, cameraName: String) async {
        guard await !inQuietHours() else { return }

        let content = UNMutableNotificationContent()
        content.title    = "McBlink: Motion detected"
        content.subtitle = cameraName
        content.body     = "Motion detected at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        content.sound    = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "motion-\(cameraID.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)

        if let (host, port, prefix) = await mqttConfig() {
            let topic   = "\(prefix)/motion/\(cameraID.uuidString)"
            let payload = (try? JSONEncoder().encode(["camera": cameraName, "ts": ISO8601DateFormatter().string(from: Date())])) ?? Data()
            await publishMQTT(host: host, port: port, topic: topic, payload: payload)
        }
    }

    // MARK: - Camera offline alert

    func sendCameraOfflineAlert(cameraID: UUID, cameraName: String) async {
        guard await !inQuietHours() else { return }

        let content = UNMutableNotificationContent()
        content.title    = "McBlink: Camera offline"
        content.subtitle = cameraName
        content.body     = "Camera has been offline for more than 60 seconds."
        content.sound    = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "offline-\(cameraID.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Storage alert

    func sendStorageAlert(percentUsed: Double) async {
        guard await !inQuietHours() else { return }
        guard percentUsed > 90 else { return }

        let content = UNMutableNotificationContent()
        content.title = "McBlink: Storage warning"
        content.body  = String(format: "Clip storage is %.0f%% full. Old clips may be deleted.", percentUsed)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "storage-warning",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Lockdown alert

    /// Critical-priority alert sent when triggerLockdown() is called.
    /// Not suppressed by quiet hours.
    func sendLockdownAlert() async {
        let content = UNMutableNotificationContent()
        content.title             = "McBlink: LOCKDOWN ACTIVATED"
        content.body              = "All cameras armed. Remote access disabled."
        content.sound             = .defaultCritical
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "lockdown-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Quiet hours

    private func inQuietHours() async -> Bool {
        guard let settings = try? await db.fetchSettings() else { return false }
        let startSecs = settings.quietHoursStart
        let endSecs   = settings.quietHoursEnd
        guard startSecs != endSecs else { return false }

        let cal  = Calendar.current
        let now  = Date()
        let comps = cal.dateComponents([.hour, .minute], from: now)
        guard let h = comps.hour, let m = comps.minute else { return false }

        let nowMins   = h * 60 + m
        let startMins = Int(startSecs) / 60
        let endMins   = Int(endSecs) / 60

        if startMins <= endMins {
            return nowMins >= startMins && nowMins < endMins
        } else {
            return nowMins >= startMins || nowMins < endMins
        }
    }

    // MARK: - MQTT config helper

    private func mqttConfig() async -> (host: String, port: UInt16, prefix: String)? {
        guard let settings = try? await db.fetchSettings(),
              !settings.mqttHost.isEmpty
        else { return nil }
        let port = UInt16(settings.mqttPort.clamped(to: 1...65535))
        return (settings.mqttHost, port, settings.mqttTopicPrefix)
    }

    // MARK: - MQTT publish (raw TCP, no library)

    /// Sends a minimal MQTT 3.1.1 CONNECT → PUBLISH → DISCONNECT sequence.
    /// Suitable for fire-and-forget telemetry; does not implement subscriptions,
    /// QoS > 0, persistent sessions, or TLS (add Network.framework TLS options
    /// in production).
    func publishMQTT(host: String, port: UInt16, topic: String, payload: Data) async {
        // Swift 6: use Once class to safely guard the Void continuation across concurrent callbacks.
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var fired = false
            func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; guard !fired else { return }; fired = true; f() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            // Use TLS when the configured port is the MQTT-over-TLS default (8883).
            // Plain TCP on port 1883 remains available for LAN-only brokers.
            let params: NWParameters = (port == 8883) ? .tls : .tcp
            let conn = NWConnection(to: endpoint, using: params)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let connectPacket = MQTTPacketBuilder.connect(clientID: "mcblink-sentinel")
                    conn.send(content: connectPacket, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 4, maximumLength: 64) { _, _, _, _ in
                            let publishPacket = MQTTPacketBuilder.publish(topic: topic, payload: payload)
                            conn.send(content: publishPacket, completion: .contentProcessed { _ in
                                let disconnectPacket = MQTTPacketBuilder.disconnect()
                                conn.send(content: disconnectPacket, completion: .contentProcessed { _ in
                                    once.run { conn.cancel(); continuation.resume() }
                                })
                            })
                        }
                    })
                case .failed, .cancelled:
                    once.run { continuation.resume() }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.run { conn.cancel(); continuation.resume() }
            }
        }
    }
}

// MARK: - MQTT Packet Builder

private enum MQTTPacketBuilder {

    /// MQTT 3.1.1 CONNECT packet for a clean session with no credentials.
    static func connect(clientID: String) -> Data {
        var packet = Data()
        let cidBytes = Array(clientID.utf8)

        // Variable header: protocol name, level, flags, keepalive
        let varHeader: [UInt8] = [
            0x00, 0x04,                         // protocol name length
            0x4D, 0x51, 0x54, 0x54,             // "MQTT"
            0x04,                               // protocol level 4 (3.1.1)
            0x02,                               // connect flags: CleanSession
            0x00, 0x3C                          // keepalive 60s
        ]

        // Client ID string
        let cidLen: [UInt8] = [
            UInt8((cidBytes.count >> 8) & 0xFF),
            UInt8(cidBytes.count & 0xFF)
        ]

        let payload = cidLen + cidBytes
        let remaining = varHeader + payload

        // Fixed header: type 0x10 (CONNECT) + remaining length
        packet.append(0x10)
        packet.append(contentsOf: encodeMQTTLength(remaining.count))
        packet.append(contentsOf: remaining)
        return packet
    }

    /// MQTT 3.1.1 PUBLISH packet, QoS 0 (fire and forget, no packet ID).
    static func publish(topic: String, payload: Data) -> Data {
        var packet = Data()
        let topicBytes = Array(topic.utf8)

        var varHeader = Data()
        varHeader.append(UInt8((topicBytes.count >> 8) & 0xFF))
        varHeader.append(UInt8(topicBytes.count & 0xFF))
        varHeader.append(contentsOf: topicBytes)
        // No packet ID for QoS 0.

        let remaining = varHeader + payload

        packet.append(0x30)   // PUBLISH, QoS 0, no retain, no dup
        packet.append(contentsOf: encodeMQTTLength(remaining.count))
        packet.append(contentsOf: remaining)
        return packet
    }

    /// MQTT 3.1.1 DISCONNECT packet (2 bytes, no payload).
    static func disconnect() -> Data {
        Data([0xE0, 0x00])
    }

    /// MQTT variable-length encoding (up to 4 bytes).
    private static func encodeMQTTLength(_ length: Int) -> [UInt8] {
        var result: [UInt8] = []
        var x = length
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            result.append(byte)
        } while x > 0
        return result
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
