import CryptoKit
import Foundation

nonisolated struct MediaEncryptionContext: Codable, Equatable, Sendable {
    let channelID: String
    let sessionID: String
    let senderDeviceID: String
    let receiverDeviceID: String

    init(
        channelID: String,
        sessionID: String,
        senderDeviceID: String,
        receiverDeviceID: String
    ) {
        self.channelID = channelID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
    }
}

nonisolated struct MediaEncryptedAudioPacket: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let currentAlgorithm = "chacha20-poly1305"

    let version: Int
    let algorithm: String
    let keyID: String
    let sequenceNumber: UInt64
    let sealedPayloadBase64: String

    init(
        version: Int = Self.currentVersion,
        algorithm: String = Self.currentAlgorithm,
        keyID: String,
        sequenceNumber: UInt64,
        sealedPayloadBase64: String
    ) {
        self.version = version
        self.algorithm = algorithm
        self.keyID = keyID
        self.sequenceNumber = sequenceNumber
        self.sealedPayloadBase64 = sealedPayloadBase64
    }

    static func isEncodedPacket(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let packet = try? JSONDecoder().decode(MediaEncryptedAudioPacket.self, from: data) else {
            return false
        }
        return packet.version == currentVersion && packet.algorithm == currentAlgorithm
    }
}

nonisolated enum MediaEndToEndEncryptionError: Error, Equatable, LocalizedError {
    case invalidPacketEncoding
    case invalidSealedPayload
    case invalidPeerIdentity
    case requiredSessionUnavailable
    case unsupportedPacket(version: Int, algorithm: String)
    case openFailed

    var errorDescription: String? {
        switch self {
        case .invalidPacketEncoding:
            return "Encrypted audio packet could not be decoded"
        case .invalidSealedPayload:
            return "Encrypted audio packet payload is invalid"
        case .invalidPeerIdentity:
            return "Media encryption peer identity is invalid"
        case .requiredSessionUnavailable:
            return "Media encryption is required but the session is unavailable"
        case .unsupportedPacket(let version, let algorithm):
            return "Encrypted audio packet is unsupported: v\(version) \(algorithm)"
        case .openFailed:
            return "Encrypted audio packet could not be opened"
        }
    }
}

nonisolated enum MediaEndToEndEncryption {
    static let keyByteCount = 32
    static let sessionIDPrefix = "media-e2ee-v1"

    static func sessionID(channelID: String) -> String {
        "\(sessionIDPrefix):\(channelID)"
    }

    static func keyID(
        localFingerprint: String,
        peerFingerprint: String,
        channelID: String
    ) -> String {
        let orderedFingerprints = [localFingerprint, peerFingerprint].sorted().joined(separator: "|")
        let data = Data("\(MediaEncryptionIdentityRegistrationMetadata.currentScheme)|\(channelID)|\(orderedFingerprints)".utf8)
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func deriveSymmetricKey(
        from sharedSecret: SharedSecret,
        context: MediaEncryptionContext
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("turbo.media.e2ee.v1".utf8),
            sharedInfo: associatedData(
                context: context,
                keyID: "session-key",
                sequenceNumber: 0
            ),
            outputByteCount: keyByteCount
        )
    }

    static func deriveSymmetricKey(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerIdentity: MediaEncryptionIdentityRegistrationMetadata,
        context: MediaEncryptionContext
    ) throws -> SymmetricKey {
        guard let publicKeyData = Data(base64Encoded: peerIdentity.publicKeyBase64),
              publicKeyData.count == MediaEncryptionIdentityManager.x25519PublicKeyByteCount else {
            throw MediaEndToEndEncryptionError.invalidPeerIdentity
        }
        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw MediaEndToEndEncryptionError.invalidPeerIdentity
        }
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        return deriveSymmetricKey(from: sharedSecret, context: context)
    }

    static func sealTransportPayload(
        _ payload: String,
        using key: SymmetricKey,
        keyID: String,
        sequenceNumber: UInt64,
        context: MediaEncryptionContext
    ) throws -> String {
        let plaintext = Data(payload.utf8)
        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: associatedData(
                context: context,
                keyID: keyID,
                sequenceNumber: sequenceNumber
            )
        )
        let packet = MediaEncryptedAudioPacket(
            keyID: keyID,
            sequenceNumber: sequenceNumber,
            sealedPayloadBase64: sealedBox.combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(packet)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw MediaEndToEndEncryptionError.invalidPacketEncoding
        }
        return encoded
    }

    static func openTransportPayload(
        _ encryptedPayload: String,
        using key: SymmetricKey,
        context: MediaEncryptionContext
    ) throws -> String {
        let packet = try decodePacket(encryptedPayload)
        guard packet.version == MediaEncryptedAudioPacket.currentVersion,
              packet.algorithm == MediaEncryptedAudioPacket.currentAlgorithm else {
            throw MediaEndToEndEncryptionError.unsupportedPacket(
                version: packet.version,
                algorithm: packet.algorithm
            )
        }
        guard let combined = Data(base64Encoded: packet.sealedPayloadBase64),
              let sealedBox = try? ChaChaPoly.SealedBox(combined: combined) else {
            throw MediaEndToEndEncryptionError.invalidSealedPayload
        }

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: key,
                authenticating: associatedData(
                    context: context,
                    keyID: packet.keyID,
                    sequenceNumber: packet.sequenceNumber
                )
            )
        } catch {
            throw MediaEndToEndEncryptionError.openFailed
        }

        guard let payload = String(data: plaintext, encoding: .utf8) else {
            throw MediaEndToEndEncryptionError.invalidPacketEncoding
        }
        return payload
    }

    static func decodePacket(_ encryptedPayload: String) throws -> MediaEncryptedAudioPacket {
        guard let packetData = encryptedPayload.data(using: .utf8),
              let packet = try? JSONDecoder().decode(MediaEncryptedAudioPacket.self, from: packetData) else {
            throw MediaEndToEndEncryptionError.invalidPacketEncoding
        }
        return packet
    }

    private static func associatedData(
        context: MediaEncryptionContext,
        keyID: String,
        sequenceNumber: UInt64
    ) -> Data {
        var data = Data()
        appendLengthPrefixed("turbo.media.audio.v1", to: &data)
        appendLengthPrefixed(context.channelID, to: &data)
        appendLengthPrefixed(context.sessionID, to: &data)
        appendLengthPrefixed(context.senderDeviceID, to: &data)
        appendLengthPrefixed(context.receiverDeviceID, to: &data)
        appendLengthPrefixed(keyID, to: &data)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func appendLengthPrefixed(_ text: String, to data: inout Data) {
        let bytes = Data(text.utf8)
        let length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
