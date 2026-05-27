// EncryptionManager.swift — AES-256-GCM clip encryption for SentinelCore
// Swift 6 / macOS 14
// File format: [12-byte nonce][ciphertext][16-byte tag]

import Foundation
import CryptoKit
import Security

// MARK: - EncryptionManager

actor EncryptionManager {

    // MARK: - Keychain constants

    private static let keychainService = "com.heyfinal.mcblink.clipkey"
    private static let keychainAccount = "sentinelcore"

    // MARK: - Cached key (loaded once per process lifetime)

    private var cachedKey: SymmetricKey?

    init() {}

    /// Test/hermetic init: injects a key so no Keychain access ever occurs.
    init(testKey: SymmetricKey) {
        self.cachedKey = testKey
    }

    // MARK: - Key management

    /// Loads the master key from the Keychain. Generates and stores a new
    /// 256-bit key if none exists yet.
    func generateKeyIfNeeded() throws {
        if cachedKey != nil { return }

        if let existing = try loadKeyFromKeychain() {
            cachedKey = existing
            return
        }

        // Generate a new random 256-bit key.
        let newKey = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(newKey)
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

    // MARK: - Keychain

    private func loadKeyFromKeychain() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService,
            kSecAttrAccount:      Self.keychainAccount,
            kSecReturnData:       kCFBooleanTrue!,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw EncryptionError.malformedKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptionError.keychainError(status)
        }
    }

    private func storeKeyInKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        // Delete any stale entry first.
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:                      kSecClassGenericPassword,
            kSecAttrService:                Self.keychainService,
            kSecAttrAccount:                Self.keychainAccount,
            kSecValueData:                  keyData,
            kSecAttrAccessible:             kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrIsPermanent:            kCFBooleanTrue!
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
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
