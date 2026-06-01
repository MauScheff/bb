import CryptoKit
import Foundation
import Security

nonisolated struct DirectQuicIdentityRegistrationMetadata: Codable, Equatable {
    let fingerprint: String
}

nonisolated enum DirectQuicIdentitySource: String, Equatable {
    case production
    case debugP12 = "debug-p12"
    case missing
}

nonisolated struct DirectQuicResolvedIdentity {
    let label: String
    let identity: SecIdentity
    let certificateFingerprint: String
    let source: DirectQuicIdentitySource
}

nonisolated enum DirectQuicProductionIdentityError: Error, LocalizedError, Equatable {
    case keyGenerationFailed(OSStatus)
    case keyLookupFailed(OSStatus)
    case publicKeyMissing
    case publicKeyExportFailed(OSStatus)
    case signingFailed(OSStatus)
    case certificateCreationFailed
    case certificateSaveFailed(OSStatus)
    case identityLookupFailed(OSStatus)
    case identityMissing

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let status):
            return "Direct QUIC production key generation failed: \(Self.describe(status))"
        case .keyLookupFailed(let status):
            return "Direct QUIC production key lookup failed: \(Self.describe(status))"
        case .publicKeyMissing:
            return "Direct QUIC production key is missing its public key"
        case .publicKeyExportFailed(let status):
            return "Direct QUIC production public key export failed: \(Self.describe(status))"
        case .signingFailed(let status):
            return "Direct QUIC production certificate signing failed: \(Self.describe(status))"
        case .certificateCreationFailed:
            return "Direct QUIC production certificate creation failed"
        case .certificateSaveFailed(let status):
            return "Direct QUIC production certificate save failed: \(Self.describe(status))"
        case .identityLookupFailed(let status):
            return "Direct QUIC production identity lookup failed: \(Self.describe(status))"
        case .identityMissing:
            return "Direct QUIC production identity is missing"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}

nonisolated enum DirectQuicProductionIdentityManager {
    static func provisionIdentity(label: String, deviceID: String) throws -> DirectQuicResolvedIdentity {
        if let existing = try loadIdentity(label: label) {
            return try resolvedIdentity(label: label, identity: existing, source: .production)
        }

        let privateKey = try loadOrCreatePrivateKey(label: label)
        let certificateDER = try makeSelfSignedCertificateDER(
            privateKey: privateKey,
            label: label,
            deviceID: deviceID
        )
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw DirectQuicProductionIdentityError.certificateCreationFailed
        }
        try saveCertificate(certificate, label: label)

        guard let identity = try loadIdentity(label: label) else {
            throw DirectQuicProductionIdentityError.identityMissing
        }
        return try resolvedIdentity(label: label, identity: identity, source: .production)
    }

    static func existingIdentity(label: String) -> DirectQuicResolvedIdentity? {
        guard let identity = try? loadIdentity(label: label) else { return nil }
        return try? resolvedIdentity(label: label, identity: identity, source: .production)
    }

    static func normalizedFingerprint(_ fingerprint: String?) -> String? {
        guard let fingerprint else { return nil }
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("sha256:") else { return nil }
        let hex = String(trimmed.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "sha256:\(hex)"
    }

    static func fingerprint(for certificateDER: Data) -> String {
        let digest = SHA256.hash(data: certificateDER)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedIdentity(
        label: String,
        identity: SecIdentity,
        source: DirectQuicIdentitySource
    ) throws -> DirectQuicResolvedIdentity {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DirectQuicProbeError.certificateMissing
        }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        return DirectQuicResolvedIdentity(
            label: label,
            identity: identity,
            certificateFingerprint: fingerprint(for: certificateDER),
            source: source
        )
    }

    private static func loadIdentity(label: String) throws -> SecIdentity? {
        var item: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw DirectQuicProductionIdentityError.identityLookupFailed(status)
        }
        return (item as! SecIdentity)
    }

    private static func loadOrCreatePrivateKey(label: String) throws -> SecKey {
        if let key = try loadPrivateKey(label: label) {
            return key
        }
        return try createPrivateKey(label: label, useSecureEnclave: true)
    }

    private static func loadPrivateKey(label: String) throws -> SecKey? {
        var item: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyApplicationTag(label),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw DirectQuicProductionIdentityError.keyLookupFailed(status)
        }
        return (item as! SecKey)
    }

    private static func createPrivateKey(label: String, useSecureEnclave: Bool) throws -> SecKey {
        var privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: keyApplicationTag(label),
            kSecAttrLabel: label,
        ]
        if useSecureEnclave {
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.privateKeyUsage],
                &accessControlError
            ) else {
                throw DirectQuicProductionIdentityError.keyGenerationFailed(errSecParam)
            }
            privateAttributes[kSecAttrAccessControl] = accessControl
            privateAttributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
        } else {
            privateAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateAttributes,
        ]

        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) {
            return key
        }

        if useSecureEnclave {
            return try createPrivateKey(label: label, useSecureEnclave: false)
        }
        let status = ((error?.takeRetainedValue() as Error?) as NSError?)?.code ?? Int(errSecParam)
        throw DirectQuicProductionIdentityError.keyGenerationFailed(OSStatus(status))
    }

    private static func saveCertificate(_ certificate: SecCertificate, label: String) throws {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw DirectQuicProductionIdentityError.certificateSaveFailed(status)
        }
    }

    private static func keyApplicationTag(_ label: String) -> Data {
        Data("to.rounded.turbo.direct-quic.production.\(label)".utf8)
    }

    private static func makeSelfSignedCertificateDER(
        privateKey: SecKey,
        label: String,
        deviceID: String
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DirectQuicProductionIdentityError.publicKeyMissing
        }
        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            let status = ((exportError?.takeRetainedValue() as Error?) as NSError?)?.code ?? Int(errSecParam)
            throw DirectQuicProductionIdentityError.publicKeyExportFailed(OSStatus(status))
        }

        let serial = Data(SHA256.hash(data: Data("\(label):\(deviceID)".utf8)).prefix(16))
        let issuer = ASN1.sequence([
            ASN1.set([ASN1.sequence([ASN1.oid([2, 5, 4, 3]), ASN1.utf8String("Turbo Direct QUIC")])])
        ])
        let subject = ASN1.sequence([
            ASN1.set([ASN1.sequence([ASN1.oid([2, 5, 4, 3]), ASN1.utf8String("Turbo \(deviceID)")])])
        ])
        let validity = ASN1.sequence([
            ASN1.utcTime(Date(timeIntervalSinceNow: -300)),
            ASN1.utcTime(Date(timeIntervalSinceNow: 60 * 60 * 24 * 365 * 20)),
        ])
        let algorithm = ASN1.sequence([
            ASN1.oid([1, 2, 840, 10045, 4, 3, 2])
        ])
        let spki = ASN1.sequence([
            ASN1.sequence([
                ASN1.oid([1, 2, 840, 10045, 2, 1]),
                ASN1.oid([1, 2, 840, 10045, 3, 1, 7]),
            ]),
            ASN1.bitString(publicKeyData),
        ])
        let tbs = ASN1.sequence([
            ASN1.explicit(0, ASN1.integer(Data([0x02]))),
            ASN1.integer(serial),
            algorithm,
            issuer,
            validity,
            subject,
            spki,
        ])

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &signingError
        ) as Data? else {
            let status = ((signingError?.takeRetainedValue() as Error?) as NSError?)?.code ?? Int(errSecParam)
            throw DirectQuicProductionIdentityError.signingFailed(OSStatus(status))
        }
        return ASN1.sequence([tbs, algorithm, ASN1.bitString(signature)])
    }
}

nonisolated private enum ASN1 {
    static func sequence(_ children: [Data]) -> Data {
        tagged(0x30, children.reduce(Data(), +))
    }

    static func set(_ children: [Data]) -> Data {
        tagged(0x31, children.reduce(Data(), +))
    }

    static func explicit(_ tag: UInt8, _ child: Data) -> Data {
        tagged(0xA0 + tag, child)
    }

    static func integer(_ raw: Data) -> Data {
        var bytes = raw
        while bytes.count > 1, bytes.first == 0, (bytes.dropFirst().first ?? 0) < 0x80 {
            bytes.removeFirst()
        }
        if (bytes.first ?? 0) >= 0x80 {
            bytes.insert(0, at: 0)
        }
        return tagged(0x02, bytes)
    }

    static func oid(_ components: [Int]) -> Data {
        precondition(components.count >= 2)
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body.append(contentsOf: encoded)
        }
        return tagged(0x06, body)
    }

    static func utf8String(_ value: String) -> Data {
        tagged(0x0C, Data(value.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    static func bitString(_ value: Data) -> Data {
        var body = Data([0x00])
        body.append(value)
        return tagged(0x03, body)
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        var data = Data([tag])
        data.append(length(body.count))
        data.append(body)
        return data
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
