import CryptoKit
import Foundation
import Security

nonisolated struct MediaEncryptionIdentityRegistrationMetadata: Codable, Equatable, Sendable {
    static let currentScheme = "x25519-v1"

    let scheme: String
    let publicKeyBase64: String
    let fingerprint: String

    init(
        scheme: String = Self.currentScheme,
        publicKeyBase64: String,
        fingerprint: String
    ) {
        self.scheme = scheme
        self.publicKeyBase64 = publicKeyBase64
        self.fingerprint = fingerprint
    }
}

nonisolated struct MediaEncryptionPeerIdentityPayload: Codable, Equatable, Sendable {
    let scheme: String
    let publicKeyBase64: String
    let fingerprint: String
    let status: String?
    let createdAt: String?
    let updatedAt: String?

    var activeRegistration: MediaEncryptionIdentityRegistrationMetadata? {
        guard status == nil || status == "active" else { return nil }
        guard scheme == MediaEncryptionIdentityRegistrationMetadata.currentScheme else { return nil }
        guard let normalizedFingerprint = MediaEncryptionIdentityManager.normalizedFingerprint(fingerprint) else {
            return nil
        }
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == MediaEncryptionIdentityManager.x25519PublicKeyByteCount else {
            return nil
        }
        return MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: publicKeyData.base64EncodedString(),
            fingerprint: normalizedFingerprint
        )
    }
}

nonisolated struct MediaEncryptionLocalIdentity: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let registration: MediaEncryptionIdentityRegistrationMetadata
}

nonisolated enum MediaEncryptionIdentityError: Error, LocalizedError, Equatable {
    case keyLookupFailed(OSStatus)
    case keySaveFailed(OSStatus)
    case invalidStoredKey

    var errorDescription: String? {
        switch self {
        case .keyLookupFailed(let status):
            return "Media encryption key lookup failed: \(Self.describe(status))"
        case .keySaveFailed(let status):
            return "Media encryption key save failed: \(Self.describe(status))"
        case .invalidStoredKey:
            return "Media encryption key is invalid"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}

nonisolated enum MediaEncryptionIdentityManager {
    static let x25519PublicKeyByteCount = 32
    private static let service = "to.beepbeep.media-encryption"

    static func provisionIdentity(deviceID: String) throws -> MediaEncryptionLocalIdentity {
        let privateKey = try loadOrCreatePrivateKey(deviceID: deviceID)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let registration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: publicKeyData.base64EncodedString(),
            fingerprint: fingerprint(forPublicKey: publicKeyData)
        )
        return MediaEncryptionLocalIdentity(privateKey: privateKey, registration: registration)
    }

    static func normalizedFingerprint(_ fingerprint: String?) -> String? {
        guard let fingerprint else { return nil }
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("sha256:") else { return nil }
        let hex = String(trimmed.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "sha256:\(hex)"
    }

    static func fingerprint(forPublicKey publicKeyData: Data) -> String {
        var fingerprintInput = Data(MediaEncryptionIdentityRegistrationMetadata.currentScheme.utf8)
        fingerprintInput.append(0)
        fingerprintInput.append(publicKeyData)
        let digest = SHA256.hash(data: fingerprintInput)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreatePrivateKey(deviceID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try loadPrivateKey(deviceID: deviceID) {
            return existing
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try savePrivateKey(privateKey, deviceID: deviceID)
        return privateKey
    }

    private static func loadPrivateKey(deviceID: String) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            keychainQuery(deviceID: deviceID, returnData: true) as CFDictionary,
            &item
        )
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                throw MediaEncryptionIdentityError.invalidStoredKey
            }
            return privateKey
        case errSecItemNotFound:
            return nil
        default:
            throw MediaEncryptionIdentityError.keyLookupFailed(status)
        }
    }

    private static func savePrivateKey(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        deviceID: String
    ) throws {
        var query = keychainQuery(deviceID: deviceID, returnData: false)
        query[kSecValueData as String] = privateKey.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw MediaEncryptionIdentityError.keySaveFailed(status)
        }
    }

    private static func keychainQuery(deviceID: String, returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}
