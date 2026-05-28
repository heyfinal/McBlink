// SentinelServiceDelegate.swift — NSXPCListenerDelegate for SentinelCore
// Swift 6 / macOS 14

import Foundation

final class SentinelServiceDelegate: NSObject, NSXPCListenerDelegate {

    // Singleton service object shared across all accepted connections.
    private let service = SentinelCoreService.shared

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Same-user gate: SentinelCore is an embedded application-scoped XPC
        // service, so launchd already restricts connections to the same UID
        // as the host. Earlier audit-session matching silently rejected valid
        // connections when the service and caller landed in different sessions.
        if connection.effectiveUserIdentifier != geteuid() {
            return false
        }

        connection.exportedInterface = McBlinkXPCInterface.make()
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
