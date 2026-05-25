// SentinelServiceDelegate.swift — NSXPCListenerDelegate for SentinelCore
// Swift 6 / macOS 14

import Foundation
// Darwin gives access to bsm/audit.h: au_asid_t, auditinfo_addr_t, getaudit_addr, AU_DEFAUDITSID
import Darwin

final class SentinelServiceDelegate: NSObject, NSXPCListenerDelegate {

    // Singleton service object shared across all accepted connections.
    private let service = SentinelCoreService.shared

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Validate that the connecting process belongs to the same audit session
        // (i.e., the same logged-in console user). This prevents cross-user and
        // remote-login XPC abuse.
        guard connection.auditSessionIdentifier == selfAuditSessionID() else {
            return false
        }

        connection.exportedInterface = McBlinkXPCInterface.make()
        connection.exportedObject = service

        connection.invalidationHandler = {
            // Nothing to tear down — service is a singleton; connection lifecycle
            // is managed by NSXPCConnection itself.
        }

        connection.resume()
        return true
    }
}

// MARK: - Audit session ID

/// Returns the audit session ID (au_asid_t) of the running XPC service process.
/// NSXPCConnection.auditSessionIdentifier must equal this value for the connection
/// to be accepted, ensuring only the same console-session owner can connect.
private func selfAuditSessionID() -> au_asid_t {
    var info = auditinfo_addr_t()
    if getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0 {
        return info.ai_asid
    }
    // Fallback: AU_DEFAUDITSID is the default if getaudit_addr is unavailable.
    // Returning AU_DEFAUDITSID (0) causes the guard to pass only when the connection
    // also reports 0, which is safe-fail rather than open-door.
    return au_asid_t(AU_DEFAUDITSID)
}
