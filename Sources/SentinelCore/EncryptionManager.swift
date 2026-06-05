// EncryptionManager.swift — AES-256-GCM clip encryption for SentinelCore
// Swift 6 / macOS 14
// File format: [12-byte nonce][ciphertext][16-byte tag]

import Foundation
import CryptoKit
import Security

// MARK: - EncryptionManager

actor EncryptionManager {

    // MARK: - Key file path

    private static let keyFileName = ".clipkey"

    private static var keyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("McBlink/db/\(keyFileName)")
    }

    // MARK: - Cached key (loaded once per process lifetime)

    private var cachedKey: SymmetricKey?

    init() {}

    /// Test/hermetic init: injects a key so no Keychain access ever occurs.
    init(testKey: SymmetricKey) {
        self.cachedKey = testKey
    }

    // MARK: - Key management

    /// Loads the master key from a protected file. Generates and stores a new
    /// 256-bit key if none exists yet. No Keychain access — avoids ad-hoc
    /// signing prompts on every rebuild.
    func generateKeyIfNeeded() throws {
        if cachedKey != nil { return }

        if let existing = try loadKeyFromFile() {
            cachedKey = existing
            return
        }

        let newKey = SymmetricKey(size: .bits256)
        try storeKeyInFile(newKey)
        cachedKey = newKey
    }

    // MARK: - Encrypt

    /// Encrypts `sourceURL` → `destinedURL`.
    /// Output format: [12-byte nonce][ciphertext][16-byte tag]
    func encryptFile(at sourceURL: URL, to destinedURL: URL) async throws {
        let key = try masterKey()
        let plaintext = try Data(contentsOf: sourceURL)

        // CryptoKit generates the nonce internally; we need it explicitly for our layout.
        let nonce = try AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        // sealedBox.combined = nonce(12) + ciphertext + tag(16)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.sealFailed
        }
        try combined.write(to: destinedURL, options: .atomic)
    }

    // MARK: - Decrypt

    /// Decrypts `encryptedURL` → `destinedURL`.
    /// Expects format: [12-byte nonce][ciphertext][16-byte tag]
    func decryptFile(at encryptedURL: URL, to destinedURL: URL) async throws {
        let key = try masterKey()
        let combined = try Data(contentsOf: encryptedURL)

        // AES.GCM.SealedBox(combined:) parses the nonce+ciphertext+tag layout.
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        try plaintext.write(to: destinedURL, options: .atomic)
    }

    // MARK: - Secure delete

    /// Best-effort secure wipe: overwrites the file with random bytes, then removes it.
    func secureDelete(url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            if size > 0 {
                let noise = (try? generateRandomData(count: size)) ?? Data(count: size)
                try noise.write(to: url, options: .atomic)
            }
            try FileManager.default.removeItem(at: url)
        } catch {
            // Best-effort; log but do not throw.
        }
    }

    // MARK: - Private helpers

    private func masterKey() throws -> SymmetricKey {
        if let k = cachedKey { return k }
        try generateKeyIfNeeded()
        guard let k = cachedKey else { throw EncryptionError.keyUnavailable }
        return k
    }

    private func generateRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw EncryptionError.randomGenerationFailed }
        return Data(bytes)
    }

    // MARK: - File-based key storage

    private func loadKeyFromFile() throws -> SymmetricKey? {
        let url = Self.keyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count == 32 else {
            throw EncryptionError.malformedKey
        }
        return SymmetricKey(data: data)
    }

    private func storeKeyInFile(_ key: SymmetricKey) throws {
        let url = Self.keyFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let keyData = key.withUnsafeBytes { Data($0) }
        try keyData.write(to: url, options: [.atomic, .completeFileProtection])

        // Owner-only read/write (0600).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - EncryptionError

enum EncryptionError: Error, LocalizedError {
    case keyUnavailable
    case malformedKey
    case sealFailed
    case randomGenerationFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable:          return "Master encryption key is not available."
        case .malformedKey:            return "Keychain returned malformed key data."
        case .sealFailed:              return "AES-GCM seal did not produce combined output."
        case .randomGenerationFailed:  return "SecRandomCopyBytes failed."
        case .keychainError(let s):    return "Keychain error: OSStatus \(s)."
        }
    }
}
