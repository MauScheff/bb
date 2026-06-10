import CryptoKit
import Darwin
import Foundation
import Network
import Security

nonisolated enum DirectQuicAttemptRole: String, Equatable {
    case listenerOfferer
    case dialerAnswerer

    static func resolve(localDeviceID: String, peerDeviceID: String) -> DirectQuicAttemptRole {
        localDeviceID.localizedStandardCompare(peerDeviceID) == .orderedAscending
            ? .listenerOfferer
            : .dialerAnswerer
    }
}

nonisolated enum DirectQuicIdentityConfiguration {
    static let storageKey = "TurboDirectQuicIdentityLabel"
    static let launchArgument = "-TurboDirectQuicIdentityLabel"
    static let environmentKey = "TURBO_DIRECT_QUIC_IDENTITY_LABEL"
    static let infoPlistKey = "TurboDirectQuicIdentityLabel"
    static let selectedFingerprintStorageKey = "TurboDirectQuicInstalledIdentityFingerprint"

    static func preferredLabel(
        deviceID: String?,
        fallbackHandle: String
    ) -> String {
        let rawSuffix = deviceID ?? fallbackHandle
        let sanitizedSuffix = rawSuffix
            .lowercased()
            .map { character -> Character in
                switch character {
                case "a"..."z", "0"..."9", "-", "_":
                    return character
                default:
                    return "-"
                }
            }
        let collapsedSuffix = String(sanitizedSuffix)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let suffix = collapsedSuffix.isEmpty ? "default" : collapsedSuffix
        return "turbo.direct-quic.identity.\(suffix)"
    }

    static func resolvedLabel(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> String? {
        resolvedLabel(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults,
            bundleInfo: bundle.infoDictionary
        )
    }

    static func resolvedLabel(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard,
        bundleInfo: [String: Any]?
    ) -> String? {
        if let launchValue = launchArgumentValue(arguments), !launchValue.isEmpty {
            return launchValue
        }
        if let environmentValue = environment[environmentKey], !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = defaults.string(forKey: storageKey), !storedValue.isEmpty {
            return storedValue
        }
        if let infoValue = bundleInfo?[infoPlistKey] as? String, !infoValue.isEmpty {
            return infoValue
        }
        return nil
    }

    static func setResolvedLabel(_ label: String?, defaults: UserDefaults = .standard) {
        defaults.set(label, forKey: storageKey)
    }

    static func setSelectedInstalledIdentityFingerprint(
        _ fingerprint: String?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(fingerprint, forKey: selectedFingerprintStorageKey)
    }

    static func selectedInstalledIdentityFingerprint(
        defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: selectedFingerprintStorageKey)
    }

    static func status(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> DirectQuicIdentityStatus {
        guard let label = resolvedLabel(
            processInfo: processInfo,
            defaults: defaults,
            bundle: bundle
        ), !label.isEmpty else {
            return .missingLabel
        }
        if let productionIdentity = DirectQuicProductionIdentityManager.existingIdentity(label: label) {
            return .readyProduction(label, productionIdentity.certificateFingerprint)
        }
        if let debugIdentity = loadIdentityIfPresent(label: label),
           let fingerprint = try? Self.fingerprint(for: debugIdentity) {
            return .readyDebug(label, fingerprint)
        }
        if let fingerprint = selectedInstalledIdentityFingerprint(defaults: defaults),
           loadInstalledIdentityMatchingFingerprint(fingerprint) != nil {
            return .readyInstalled(label, fingerprint)
        }
        return .missingIdentity(label)
    }

    static func provisionProductionIdentity(
        label: String,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) throws -> DirectQuicResolvedIdentity {
        let identity = try DirectQuicProductionIdentityManager.provisionIdentity(
            label: label,
            deviceID: deviceID
        )
        setResolvedLabel(label, defaults: defaults)
        setSelectedInstalledIdentityFingerprint(nil, defaults: defaults)
        return identity
    }

    static func productionIdentityRegistrationMetadata(label: String) -> DirectQuicIdentityRegistrationMetadata? {
        guard let identity = DirectQuicProductionIdentityManager.existingIdentity(label: label) else {
            return nil
        }
        return DirectQuicIdentityRegistrationMetadata(
            fingerprint: identity.certificateFingerprint
        )
    }

    static func importPKCS12Identity(
        data: Data,
        password: String,
        label: String
    ) throws {
        let options = [kSecImportExportPassphrase as String: password] as NSDictionary
        var rawItems: CFArray?
        let importStatus = SecPKCS12Import(data as CFData, options, &rawItems)
        guard importStatus == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let importedValue = items.first?[kSecImportItemIdentity as String] else {
            throw DirectQuicIdentityImportError.pkcs12ImportFailed(importStatus)
        }
        let identity = importedValue as! SecIdentity

        let deleteQuery = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
        ] as CFDictionary
        let deleteStatus = SecItemDelete(deleteQuery)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw DirectQuicIdentityImportError.keychainDeleteFailed(deleteStatus)
        }

        let addQuery = [
            kSecValueRef: identity,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as NSDictionary
        let addStatus = SecItemAdd(addQuery, nil)
        guard addStatus == errSecSuccess
                || (addStatus == errSecDuplicateItem && loadIdentityIfPresent(label: label) != nil) else {
            throw DirectQuicIdentityImportError.keychainSaveFailed(addStatus)
        }
        setSelectedInstalledIdentityFingerprint(nil)
    }

    static func installedIdentityCount() -> Int {
        (try? installedIdentities().count) ?? 0
    }

    static func adoptInstalledIdentity(
        label: String,
        defaults: UserDefaults = .standard
    ) throws -> String {
        let identities = try installedIdentities()
        guard !identities.isEmpty else {
            throw DirectQuicInstalledIdentityAdoptionError.noInstalledIdentities
        }
        guard identities.count == 1 else {
            throw DirectQuicInstalledIdentityAdoptionError.multipleInstalledIdentities(identities.count)
        }
        let fingerprint = try Self.fingerprint(for: identities[0])
        setResolvedLabel(label, defaults: defaults)
        setSelectedInstalledIdentityFingerprint(fingerprint, defaults: defaults)
        return fingerprint
    }

    private static func launchArgumentValue(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func loadIdentityIfPresent(label: String) -> SecIdentity? {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        let identity = item as! SecIdentity
        return identity
    }

    static func loadIdentity(label: String) throws -> SecIdentity {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            if status == errSecItemNotFound {
                throw DirectQuicProbeError.identityNotFound(label)
            }
            throw DirectQuicProbeError.identityLookupFailed(label, status)
        }
        return item as! SecIdentity
    }

    private static func installedIdentities() throws -> [SecIdentity] {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let item else {
            throw DirectQuicInstalledIdentityAdoptionError.keychainQueryFailed(status)
        }
        let array = item as! [Any]
        return array.map { $0 as! SecIdentity }
    }

    static func loadInstalledIdentityMatchingFingerprint(_ fingerprint: String) -> SecIdentity? {
        guard let identities = try? installedIdentities() else { return nil }
        return identities.first { identity in
            (try? Self.fingerprint(for: identity)) == fingerprint
        }
    }

    private static func fingerprint(for identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DirectQuicProbeError.certificateMissing
        }
        return try fingerprint(for: certificate)
    }

    private static func fingerprint(for certificate: SecCertificate) throws -> String {
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard !certificateData.isEmpty else {
            throw DirectQuicProbeError.fingerprintEncodingFailed
        }
        let digest = SHA256.hash(data: certificateData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}

nonisolated enum DirectQuicProtocol {
    static let mediaAlpn = "turbo-ptt-v2"
}

nonisolated enum DirectQuicIdentityStatus: Equatable {
    case missingLabel
    case missingIdentity(String)
    case readyProduction(String, String)
    case readyDebug(String, String)
    case readyInstalled(String, String)

    var resolvedLabel: String? {
        switch self {
        case .missingLabel:
            return nil
        case .missingIdentity(let label),
             .readyProduction(let label, _),
             .readyDebug(let label, _),
             .readyInstalled(let label, _):
            return label
        }
    }

    var fingerprint: String? {
        switch self {
        case .missingLabel, .missingIdentity:
            return nil
        case .readyProduction(_, let fingerprint),
             .readyDebug(_, let fingerprint),
             .readyInstalled(_, let fingerprint):
            return fingerprint
        }
    }

    var source: DirectQuicIdentitySource {
        switch self {
        case .readyProduction:
            return .production
        case .readyDebug, .readyInstalled:
            return .debugP12
        case .missingLabel, .missingIdentity:
            return .missing
        }
    }

    var diagnosticsText: String {
        switch self {
        case .missingLabel:
            return "missing-label"
        case .missingIdentity(let label):
            return "missing-identity (\(label))"
        case .readyProduction(let label, _):
            return "ready-production (\(label))"
        case .readyDebug(let label, _):
            return "ready-debug-p12 (\(label))"
        case .readyInstalled(let label, _):
            return "ready-installed-debug-p12 (\(label))"
        }
    }
}

nonisolated enum DirectQuicIdentityImportError: Error, LocalizedError, Equatable {
    case pkcs12ImportFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case keychainSaveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .pkcs12ImportFailed(let status):
            return "Direct QUIC identity import failed: \(Self.describe(status))"
        case .keychainDeleteFailed(let status):
            return "Direct QUIC identity replacement failed: \(Self.describe(status))"
        case .keychainSaveFailed(let status):
            return "Direct QUIC identity save failed: \(Self.describe(status))"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}

nonisolated enum DirectQuicInstalledIdentityAdoptionError: Error, LocalizedError, Equatable {
    case noInstalledIdentities
    case multipleInstalledIdentities(Int)
    case keychainQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInstalledIdentities:
            return "No installed identities were found on this device"
        case .multipleInstalledIdentities(let count):
            return "Found \(count) installed identities; can’t auto-select one"
        case .keychainQueryFailed(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Installed identity lookup failed: \(message) (\(status))"
            }
            return "Installed identity lookup failed: OSStatus \(status)"
        }
    }
}

nonisolated enum DirectQuicProbeError: Error, LocalizedError, Equatable {
    case identityLabelMissing
    case identityNotFound(String)
    case identityLookupFailed(String, OSStatus)
    case certificateMissing
    case fingerprintEncodingFailed
    case listenerFailed(String)
    case listenerCancelled
    case noViableCandidate
    case localPortAllocationFailed(String)
    case connectionFailed(String)
    case proofFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityLabelMissing:
            return "Direct QUIC identity label is not configured"
        case .identityNotFound(let label):
            return "Direct QUIC identity '\(label)' was not found in the Keychain"
        case .identityLookupFailed(let label, let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Direct QUIC identity '\(label)' lookup failed: \(message) (\(status))"
            }
            return "Direct QUIC identity '\(label)' lookup failed: OSStatus \(status)"
        case .certificateMissing:
            return "Direct QUIC identity is missing its certificate"
        case .fingerprintEncodingFailed:
            return "Direct QUIC certificate fingerprint could not be encoded"
        case .listenerFailed(let message):
            return "Direct QUIC listener failed: \(message)"
        case .listenerCancelled:
            return "Direct QUIC listener was cancelled"
        case .noViableCandidate:
            return "Direct QUIC offer contained no viable direct candidate"
        case .localPortAllocationFailed(let message):
            return "Direct QUIC local port allocation failed: \(message)"
        case .connectionFailed(let message):
            return "Direct QUIC connection failed: \(message)"
        case .proofFailed(let message):
            return "Direct QUIC proof failed: \(message)"
        }
    }
}

nonisolated struct DirectQuicPreparedLocalOffer: Equatable {
    let attemptId: String
    let quicAlpn: String
    let localPort: UInt16
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated struct DirectQuicPreparedDialerConnection: Equatable {
    let attemptId: String
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
    let didEstablishPath: Bool
    let lastFailureReason: String?
}

nonisolated struct DirectQuicPreparedDialerAnswer: Equatable {
    let attemptId: String
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated private struct DirectQuicIdentityMaterial {
    let label: String
    let identity: SecIdentity
    let certificateFingerprint: String
    let source: DirectQuicIdentitySource
}

nonisolated private struct DirectQuicPreparedDialerAttempt: Equatable {
    let attemptId: String
    let quicAlpn: String
    let localPort: UInt16
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated enum DirectQuicCandidateProbeDisposition: String, Equatable {
    case alreadyConnected
    case pathEstablished
    case noViableCandidates
    case noNewCandidates
    case probeAlreadyInFlight
    case batchExhausted
}

nonisolated struct DirectQuicCandidateProbeOutcome: Equatable {
    let disposition: DirectQuicCandidateProbeDisposition
    let inputCandidateCount: Int
    let viableCandidateCount: Int
    let newlyAttemptedCandidateCount: Int
    let lastErrorDescription: String?

    var didEstablishPath: Bool {
        switch disposition {
        case .alreadyConnected, .pathEstablished:
            return true
        case .noViableCandidates, .noNewCandidates, .probeAlreadyInFlight, .batchExhausted:
            return false
        }
    }
}

nonisolated enum DirectQuicCandidateProbeSelection: Equatable {
    case immediate(DirectQuicCandidateProbeOutcome)
    case ready([TurboDirectQuicCandidate], viableCandidateCount: Int)
}

nonisolated enum DirectQuicWireMessageKind: String, Codable, Equatable {
    case probeHello = "probe-hello"
    case probeAck = "probe-ack"
    case consentPing = "consent-ping"
    case consentAck = "consent-ack"
    case receiverPrewarmRequest = "receiver-prewarm-request"
    case receiverPrewarmAck = "receiver-prewarm-ack"
    case pathClosing = "path-closing"
    case warmPing = "warm-ping"
    case warmPong = "warm-pong"
    case audioPlaybackStarted = "audio-playback-started"
}

nonisolated struct DirectQuicReceiverPrewarmPayload: Codable, Equatable, Sendable {
    let requestId: String
    let channelId: String
    let fromDeviceId: String
    let reason: String
    let directQuicAttemptId: String?
    let mediaCapabilities: VoiceMediaCapabilities?

    init(
        requestId: String,
        channelId: String,
        fromDeviceId: String,
        reason: String,
        directQuicAttemptId: String?,
        mediaCapabilities: VoiceMediaCapabilities? = .local
    ) {
        self.requestId = requestId
        self.channelId = channelId
        self.fromDeviceId = fromDeviceId
        self.reason = reason
        self.directQuicAttemptId = directQuicAttemptId
        self.mediaCapabilities = mediaCapabilities
    }
}

nonisolated enum DirectQuicReceiverPrewarmPayloadCodec {
    static func encode(_ payload: DirectQuicReceiverPrewarmPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DirectQuicProbeError.proofFailed("receiver prewarm payload encoding failed")
        }
        return encoded
    }

    static func decode(_ payload: String?) throws -> DirectQuicReceiverPrewarmPayload {
        guard let payload, let data = payload.data(using: .utf8) else {
            throw DirectQuicProbeError.proofFailed("receiver prewarm payload missing")
        }
        return try JSONDecoder().decode(DirectQuicReceiverPrewarmPayload.self, from: data)
    }
}

nonisolated struct DirectQuicPathClosingPayload: Codable, Equatable, Sendable {
    let attemptId: String
    let reason: String
}

nonisolated enum DirectQuicPathClosingPayloadCodec {
    static func encode(_ payload: DirectQuicPathClosingPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DirectQuicProbeError.proofFailed("path closing payload encoding failed")
        }
        return encoded
    }

    static func decode(_ payload: String?) throws -> DirectQuicPathClosingPayload {
        guard let payload, let data = payload.data(using: .utf8) else {
            throw DirectQuicProbeError.proofFailed("path closing payload missing")
        }
        return try JSONDecoder().decode(DirectQuicPathClosingPayload.self, from: data)
    }
}

nonisolated struct DirectQuicWireMessage: Codable, Equatable {
    let kind: DirectQuicWireMessageKind
    let payload: String?

    static let probeHello = DirectQuicWireMessage(kind: .probeHello, payload: nil)
    static let probeAck = DirectQuicWireMessage(kind: .probeAck, payload: nil)
    static func consentPing(_ id: String) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .consentPing, payload: id)
    }

    static func consentAck(_ id: String?) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .consentAck, payload: id)
    }

    static func receiverPrewarmRequest(_ payload: DirectQuicReceiverPrewarmPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .receiverPrewarmRequest,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func receiverPrewarmAck(_ payload: DirectQuicReceiverPrewarmPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .receiverPrewarmAck,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func pathClosing(_ payload: DirectQuicPathClosingPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .pathClosing,
            payload: try DirectQuicPathClosingPayloadCodec.encode(payload)
        )
    }

    static func warmPing(_ id: String) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .warmPing, payload: id)
    }

    static func warmPong(_ id: String?) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .warmPong, payload: id)
    }

    static func audioPlaybackStarted(_ payload: TurboAudioPlaybackStartedPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .audioPlaybackStarted,
            payload: try TurboAudioPlaybackStartedPayloadCodec.encode(payload)
        )
    }
}

nonisolated enum DirectQuicWireCodec {
    private static let newline = Data([0x0A])

    static func encode(_ message: DirectQuicWireMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(newline)
        return data
    }

    static func decodeAvailable(from buffer: inout Data) throws -> [DirectQuicWireMessage] {
        var decoded: [DirectQuicWireMessage] = []

        while let delimiterRange = buffer.firstRange(of: newline) {
            let frame = buffer.subdata(in: 0 ..< delimiterRange.lowerBound)
            buffer.removeSubrange(0 ..< delimiterRange.upperBound)
            guard !frame.isEmpty else { continue }
            decoded.append(try JSONDecoder().decode(DirectQuicWireMessage.self, from: frame))
        }

        return decoded
    }
}

nonisolated enum DirectQuicMediaDatagramFrame: Codable, Equatable, Sendable {
    case packetAudio(
        payload: String,
        sequenceNumber: UInt64? = nil,
        sentAtMilliseconds: Int64? = nil
    )
    case binaryPacketAudio(
        payload: Data,
        sequenceNumber: UInt64,
        sentAtMilliseconds: Int64
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
        case sequenceNumber = "sequence_number"
        case sentAtMilliseconds = "sent_at_ms"
    }

    private enum FrameType: String, Codable {
        case packetAudio = "packet-audio"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .packetAudio(let payload, let sequenceNumber, let sentAtMilliseconds):
            try container.encode(FrameType.packetAudio, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encodeIfPresent(sequenceNumber, forKey: .sequenceNumber)
            try container.encodeIfPresent(sentAtMilliseconds, forKey: .sentAtMilliseconds)
        case .binaryPacketAudio(let payload, let sequenceNumber, let sentAtMilliseconds):
            try container.encode(FrameType.packetAudio, forKey: .type)
            try container.encode(payload.base64EncodedString(), forKey: .payload)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)
            try container.encode(sentAtMilliseconds, forKey: .sentAtMilliseconds)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(FrameType.self, forKey: .type) {
        case .packetAudio:
            self = .packetAudio(
                payload: try container.decode(String.self, forKey: .payload),
                sequenceNumber: try container.decodeIfPresent(UInt64.self, forKey: .sequenceNumber),
                sentAtMilliseconds: try container.decodeIfPresent(Int64.self, forKey: .sentAtMilliseconds)
            )
        }
    }
}

nonisolated struct DirectQuicIncomingAudioPayload: Equatable, Sendable {
    let payload: String
    let datagramReceivedAtNanoseconds: UInt64
    let sequenceNumber: UInt64?
    let sentAtMilliseconds: Int64?

    init(
        payload: String,
        datagramReceivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sequenceNumber: UInt64? = nil,
        sentAtMilliseconds: Int64? = nil
    ) {
        self.payload = payload
        self.datagramReceivedAtNanoseconds = datagramReceivedAtNanoseconds
        self.sequenceNumber = sequenceNumber
        self.sentAtMilliseconds = sentAtMilliseconds
    }
}

nonisolated enum DirectQuicMediaDatagramCodec {
    static let maximumDatagramFrameSize = 4_096
    private static let binaryMagic = Data([0x54, 0x51, 0x44, 0x31])
    private static let binaryVersion: UInt8 = 1
    private static let binaryPacketAudioType: UInt8 = 1
    private static let binaryHeaderLength = 28

    static func encode(_ frame: DirectQuicMediaDatagramFrame) throws -> Data {
        if case .binaryPacketAudio(let payload, let sequenceNumber, let sentAtMilliseconds) = frame {
            return try encodeBinaryPacketAudio(
                payload: payload,
                sequenceNumber: sequenceNumber,
                sentAtMilliseconds: sentAtMilliseconds
            )
        }
        return try JSONEncoder().encode(frame)
    }

    static func decode(_ data: Data) throws -> DirectQuicMediaDatagramFrame {
        if data.prefix(binaryMagic.count) == binaryMagic {
            return try decodeBinaryPacketAudio(data)
        }
        return try JSONDecoder().decode(DirectQuicMediaDatagramFrame.self, from: data)
    }

    private static func encodeBinaryPacketAudio(
        payload: Data,
        sequenceNumber: UInt64,
        sentAtMilliseconds: Int64
    ) throws -> Data {
        guard payload.count <= UInt16.max else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC binary packet payload exceeded UInt16 length: \(payload.count)"
            )
        }
        var data = Data()
        data.reserveCapacity(binaryHeaderLength + payload.count)
        data.append(binaryMagic)
        data.append(binaryVersion)
        data.append(binaryPacketAudioType)
        data.appendDirectQuicBigEndian(UInt16(binaryHeaderLength))
        data.appendDirectQuicBigEndian(sequenceNumber)
        data.appendDirectQuicBigEndian(UInt64(bitPattern: sentAtMilliseconds))
        data.appendDirectQuicBigEndian(UInt16(payload.count))
        data.append(contentsOf: [0, 0])
        data.append(payload)
        return data
    }

    private static func decodeBinaryPacketAudio(_ data: Data) throws -> DirectQuicMediaDatagramFrame {
        guard data.count >= binaryHeaderLength else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC binary datagram too short: \(data.count)"
            )
        }
        let version = data[directQuicRelativeOffset: 4]
        guard version == binaryVersion else {
            throw DirectQuicProbeError.proofFailed(
                "unsupported direct QUIC binary datagram version: \(version)"
            )
        }
        let frameType = data[directQuicRelativeOffset: 5]
        guard frameType == binaryPacketAudioType else {
            throw DirectQuicProbeError.proofFailed(
                "unsupported direct QUIC binary datagram type: \(frameType)"
            )
        }
        let headerLength = Int(data.readDirectQuicUInt16BigEndian(at: 6))
        guard headerLength == binaryHeaderLength else {
            throw DirectQuicProbeError.proofFailed(
                "invalid direct QUIC binary datagram header length: \(headerLength)"
            )
        }
        let sequenceNumber = data.readDirectQuicUInt64BigEndian(at: 8)
        let sentAtMilliseconds = Int64(bitPattern: data.readDirectQuicUInt64BigEndian(at: 16))
        let payloadLength = Int(data.readDirectQuicUInt16BigEndian(at: 24))
        guard data[directQuicRelativeOffset: 26] == 0,
              data[directQuicRelativeOffset: 27] == 0 else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC binary datagram reserved bytes must be zero"
            )
        }
        let actualPayloadLength = data.count - binaryHeaderLength
        guard payloadLength == actualPayloadLength else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC binary datagram payload length mismatch: \(payloadLength) != \(actualPayloadLength)"
            )
        }
        return .binaryPacketAudio(
            payload: Data(data.suffix(actualPayloadLength)),
            sequenceNumber: sequenceNumber,
            sentAtMilliseconds: sentAtMilliseconds
        )
    }
}

private extension Data {
    nonisolated subscript(directQuicRelativeOffset relativeOffset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: relativeOffset)]
    }

    nonisolated mutating func appendDirectQuicBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    nonisolated mutating func appendDirectQuicBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }

    nonisolated func readDirectQuicUInt16BigEndian(at relativeOffset: Int) -> UInt16 {
        let high = UInt16(self[directQuicRelativeOffset: relativeOffset])
        let low = UInt16(self[directQuicRelativeOffset: relativeOffset + 1])
        return (high << 8) | low
    }

    nonisolated func readDirectQuicUInt64BigEndian(at relativeOffset: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in relativeOffset ..< relativeOffset + 8 {
            value = (value << 8) | UInt64(self[directQuicRelativeOffset: offset])
        }
        return value
    }
}

nonisolated enum DirectQuicMediaMessageDecodeResult: Equatable {
    case packet(DirectQuicMediaDatagramFrame)
    case control([DirectQuicWireMessage])
}

nonisolated enum DirectQuicMediaMessageCodec {
    static func decode(_ data: Data) throws -> DirectQuicMediaMessageDecodeResult {
        do {
            return .packet(try DirectQuicMediaDatagramCodec.decode(data))
        } catch {
            var buffer = data
            let controlMessages = try DirectQuicWireCodec.decodeAvailable(from: &buffer)
            guard !controlMessages.isEmpty else { throw error }
            return .control(controlMessages)
        }
    }
}

nonisolated struct TurboMediaRelayClientConfig: Codable, Equatable, Sendable {
    let host: String
    let quicPort: UInt16
    let tcpPort: UInt16
    let token: String

    var isConfigured: Bool {
        !host.isEmpty
    }
}

nonisolated enum TurboMediaRelayTransport: String, Codable, Equatable, Sendable {
    case quic
    case quicDatagram = "quic-datagram"
    case tcpTls = "tcp-tls"
}

nonisolated enum TurboMediaRelayMediaMode: String, Codable, Equatable, Sendable {
    case quicDatagram = "quic-datagram"
    case tcpOrdered = "tcp-ordered"
}

nonisolated struct TurboMediaRelayIncomingAudioPayload: Equatable, Sendable {
    let payload: String
    let mediaMode: TurboMediaRelayMediaMode
    let sequenceNumber: UInt64?
    let sentAtMilliseconds: Int64?
    let receivedAtNanoseconds: UInt64
}

nonisolated enum TurboMediaRelayControlKind: String, Codable, Equatable, Sendable {
    case receiverPrewarmRequest = "receiver-prewarm-request"
    case receiverPrewarmAck = "receiver-prewarm-ack"
    case audioPlaybackStarted = "audio-playback-started"
}

nonisolated struct TurboMediaRelayControlFrame: Codable, Equatable, Sendable {
    let kind: TurboMediaRelayControlKind
    let payload: String

    static func receiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload
    ) throws -> TurboMediaRelayControlFrame {
        TurboMediaRelayControlFrame(
            kind: .receiverPrewarmRequest,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func receiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload
    ) throws -> TurboMediaRelayControlFrame {
        TurboMediaRelayControlFrame(
            kind: .receiverPrewarmAck,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func audioPlaybackStarted(
        _ payload: TurboAudioPlaybackStartedPayload
    ) throws -> TurboMediaRelayControlFrame {
        TurboMediaRelayControlFrame(
            kind: .audioPlaybackStarted,
            payload: try TurboAudioPlaybackStartedPayloadCodec.encode(payload)
        )
    }
}

nonisolated enum TurboMediaRelayFrame: Codable, Equatable, Sendable {
    case join(
        sessionId: String,
        deviceId: String,
        peerDeviceId: String,
        token: String
    )
    case joinAck(
        sessionId: String,
        deviceId: String,
        transport: TurboMediaRelayTransport
    )
    case datagramJoin(
        sessionId: String,
        deviceId: String,
        peerDeviceId: String,
        token: String
    )
    case datagramJoinAck(
        sessionId: String,
        deviceId: String,
        transport: TurboMediaRelayTransport
    )
    case packetAudio(
        sessionId: String,
        senderDeviceId: String,
        sequenceNumber: UInt64,
        sentAtMs: Int64,
        payload: String
    )
    case binaryPacketAudio(
        sessionId: String,
        senderDeviceId: String,
        sequenceNumber: UInt64,
        sentAtMs: Int64,
        payload: Data
    )
    case tcpAudio(
        sessionId: String,
        senderDeviceId: String,
        sequenceNumber: UInt64,
        sentAtMs: Int64,
        payload: String
    )
    case control(
        sessionId: String,
        senderDeviceId: String,
        kind: TurboMediaRelayControlKind,
        payload: String
    )
    case peerUnavailable(sessionId: String, deviceId: String)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case deviceId = "device_id"
        case peerDeviceId = "peer_device_id"
        case senderDeviceId = "sender_device_id"
        case sequenceNumber = "sequence_number"
        case sentAtMs = "sent_at_ms"
        case payload
        case token
        case transport
        case message
        case kind
    }

    private enum FrameType: String, Codable {
        case join
        case joinAck = "join-ack"
        case datagramJoin = "datagram-join"
        case datagramJoinAck = "datagram-join-ack"
        case packetAudio = "packet-audio"
        case tcpAudio = "tcp-audio"
        case control
        case peerUnavailable = "peer-unavailable"
        case error
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .join(let sessionId, let deviceId, let peerDeviceId, let token):
            try container.encode(FrameType.join, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(peerDeviceId, forKey: .peerDeviceId)
            try container.encode(token, forKey: .token)
        case .joinAck(let sessionId, let deviceId, let transport):
            try container.encode(FrameType.joinAck, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(transport, forKey: .transport)
        case .datagramJoin(let sessionId, let deviceId, let peerDeviceId, let token):
            try container.encode(FrameType.datagramJoin, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(peerDeviceId, forKey: .peerDeviceId)
            try container.encode(token, forKey: .token)
        case .datagramJoinAck(let sessionId, let deviceId, let transport):
            try container.encode(FrameType.datagramJoinAck, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(transport, forKey: .transport)
        case .packetAudio(let sessionId, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload):
            try container.encode(FrameType.packetAudio, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(senderDeviceId, forKey: .senderDeviceId)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)
            try container.encode(sentAtMs, forKey: .sentAtMs)
            try container.encode(payload, forKey: .payload)
        case .binaryPacketAudio(let sessionId, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload):
            try container.encode(FrameType.packetAudio, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(senderDeviceId, forKey: .senderDeviceId)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)
            try container.encode(sentAtMs, forKey: .sentAtMs)
            try container.encode(payload.base64EncodedString(), forKey: .payload)
        case .tcpAudio(let sessionId, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload):
            try container.encode(FrameType.tcpAudio, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(senderDeviceId, forKey: .senderDeviceId)
            try container.encode(sequenceNumber, forKey: .sequenceNumber)
            try container.encode(sentAtMs, forKey: .sentAtMs)
            try container.encode(payload, forKey: .payload)
        case .control(let sessionId, let senderDeviceId, let kind, let payload):
            try container.encode(FrameType.control, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(senderDeviceId, forKey: .senderDeviceId)
            try container.encode(kind, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .peerUnavailable(let sessionId, let deviceId):
            try container.encode(FrameType.peerUnavailable, forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(deviceId, forKey: .deviceId)
        case .error(let message):
            try container.encode(FrameType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(FrameType.self, forKey: .type) {
        case .join:
            self = .join(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                deviceId: try container.decode(String.self, forKey: .deviceId),
                peerDeviceId: try container.decode(String.self, forKey: .peerDeviceId),
                token: try container.decode(String.self, forKey: .token)
            )
        case .joinAck:
            self = .joinAck(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                deviceId: try container.decode(String.self, forKey: .deviceId),
                transport: try container.decode(TurboMediaRelayTransport.self, forKey: .transport)
            )
        case .datagramJoin:
            self = .datagramJoin(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                deviceId: try container.decode(String.self, forKey: .deviceId),
                peerDeviceId: try container.decode(String.self, forKey: .peerDeviceId),
                token: try container.decode(String.self, forKey: .token)
            )
        case .datagramJoinAck:
            self = .datagramJoinAck(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                deviceId: try container.decode(String.self, forKey: .deviceId),
                transport: try container.decode(TurboMediaRelayTransport.self, forKey: .transport)
            )
        case .packetAudio:
            self = .packetAudio(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                senderDeviceId: try container.decode(String.self, forKey: .senderDeviceId),
                sequenceNumber: try container.decode(UInt64.self, forKey: .sequenceNumber),
                sentAtMs: try container.decode(Int64.self, forKey: .sentAtMs),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .tcpAudio:
            self = .tcpAudio(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                senderDeviceId: try container.decode(String.self, forKey: .senderDeviceId),
                sequenceNumber: try container.decode(UInt64.self, forKey: .sequenceNumber),
                sentAtMs: try container.decode(Int64.self, forKey: .sentAtMs),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .control:
            self = .control(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                senderDeviceId: try container.decode(String.self, forKey: .senderDeviceId),
                kind: try container.decode(TurboMediaRelayControlKind.self, forKey: .kind),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .peerUnavailable:
            self = .peerUnavailable(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                deviceId: try container.decode(String.self, forKey: .deviceId)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }
}

nonisolated enum TurboMediaRelayCodec {
    private static let newline = Data([0x0A])

    static func encode(_ frame: TurboMediaRelayFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(newline)
        return data
    }

    static func decodeAvailable(from buffer: inout Data) throws -> [TurboMediaRelayFrame] {
        var decoded: [TurboMediaRelayFrame] = []
        while let delimiterRange = buffer.firstRange(of: newline) {
            let frame = buffer.subdata(in: 0 ..< delimiterRange.lowerBound)
            buffer.removeSubrange(0 ..< delimiterRange.upperBound)
            guard !frame.isEmpty else { continue }
            decoded.append(try JSONDecoder().decode(TurboMediaRelayFrame.self, from: frame))
        }
        return decoded
    }
}

nonisolated enum TurboMediaRelayDatagramCodec {
    static let maximumDatagramFrameSize = 4_096
    private static let binaryMagic = Data([0x54, 0x52, 0x44, 0x31])
    private static let binaryVersion: UInt8 = 1
    private static let binaryPacketAudioType: UInt8 = 1
    private static let binaryHeaderLength = 32

    static func encode(_ frame: TurboMediaRelayFrame) throws -> Data {
        if case .binaryPacketAudio(
            let sessionId,
            let senderDeviceId,
            let sequenceNumber,
            let sentAtMs,
            let payload
        ) = frame {
            return try encodeBinaryPacketAudio(
                sessionId: sessionId,
                senderDeviceId: senderDeviceId,
                sequenceNumber: sequenceNumber,
                sentAtMs: sentAtMs,
                payload: payload
            )
        }
        return try JSONEncoder().encode(frame)
    }

    static func decode(_ data: Data) throws -> TurboMediaRelayFrame {
        if data.prefix(binaryMagic.count) == binaryMagic {
            return try decodeBinaryPacketAudio(data)
        }
        return try JSONDecoder().decode(TurboMediaRelayFrame.self, from: data)
    }

    private static func encodeBinaryPacketAudio(
        sessionId: String,
        senderDeviceId: String,
        sequenceNumber: UInt64,
        sentAtMs: Int64,
        payload: Data
    ) throws -> Data {
        guard let sessionData = sessionId.data(using: .utf8),
              let senderData = senderDeviceId.data(using: .utf8) else {
            throw DirectQuicProbeError.proofFailed("media relay binary packet identity was not UTF-8")
        }
        guard sessionData.count <= UInt16.max,
              senderData.count <= UInt16.max,
              payload.count <= UInt16.max else {
            throw DirectQuicProbeError.proofFailed(
                "media relay binary packet field exceeded UInt16 length"
            )
        }
        var data = Data()
        data.reserveCapacity(binaryHeaderLength + sessionData.count + senderData.count + payload.count)
        data.append(binaryMagic)
        data.append(binaryVersion)
        data.append(binaryPacketAudioType)
        data.appendDirectQuicBigEndian(UInt16(binaryHeaderLength))
        data.appendDirectQuicBigEndian(sequenceNumber)
        data.appendDirectQuicBigEndian(UInt64(bitPattern: sentAtMs))
        data.appendDirectQuicBigEndian(UInt16(sessionData.count))
        data.appendDirectQuicBigEndian(UInt16(senderData.count))
        data.appendDirectQuicBigEndian(UInt16(payload.count))
        data.append(contentsOf: [0, 0])
        data.append(sessionData)
        data.append(senderData)
        data.append(payload)
        return data
    }

    private static func decodeBinaryPacketAudio(_ data: Data) throws -> TurboMediaRelayFrame {
        guard data.count >= binaryHeaderLength else {
            throw DirectQuicProbeError.proofFailed(
                "media relay binary datagram too short: \(data.count)"
            )
        }
        let version = data[directQuicRelativeOffset: 4]
        guard version == binaryVersion else {
            throw DirectQuicProbeError.proofFailed(
                "unsupported media relay binary datagram version: \(version)"
            )
        }
        let frameType = data[directQuicRelativeOffset: 5]
        guard frameType == binaryPacketAudioType else {
            throw DirectQuicProbeError.proofFailed(
                "unsupported media relay binary datagram type: \(frameType)"
            )
        }
        let headerLength = Int(data.readDirectQuicUInt16BigEndian(at: 6))
        guard headerLength == binaryHeaderLength else {
            throw DirectQuicProbeError.proofFailed(
                "invalid media relay binary datagram header length: \(headerLength)"
            )
        }
        let sequenceNumber = data.readDirectQuicUInt64BigEndian(at: 8)
        let sentAtMs = Int64(bitPattern: data.readDirectQuicUInt64BigEndian(at: 16))
        let sessionLength = Int(data.readDirectQuicUInt16BigEndian(at: 24))
        let senderLength = Int(data.readDirectQuicUInt16BigEndian(at: 26))
        let payloadLength = Int(data.readDirectQuicUInt16BigEndian(at: 28))
        guard data[directQuicRelativeOffset: 30] == 0,
              data[directQuicRelativeOffset: 31] == 0 else {
            throw DirectQuicProbeError.proofFailed(
                "media relay binary datagram reserved bytes must be zero"
            )
        }
        let expectedLength = binaryHeaderLength + sessionLength + senderLength + payloadLength
        guard data.count == expectedLength else {
            throw DirectQuicProbeError.proofFailed(
                "media relay binary datagram length mismatch: \(data.count) != \(expectedLength)"
            )
        }
        var offset = binaryHeaderLength
        let sessionData = data.subdata(in: offset ..< offset + sessionLength)
        offset += sessionLength
        let senderData = data.subdata(in: offset ..< offset + senderLength)
        offset += senderLength
        let payload = data.subdata(in: offset ..< offset + payloadLength)
        guard let sessionId = String(data: sessionData, encoding: .utf8),
              let senderDeviceId = String(data: senderData, encoding: .utf8) else {
            throw DirectQuicProbeError.proofFailed("media relay binary packet identity was not UTF-8")
        }
        return .binaryPacketAudio(
            sessionId: sessionId,
            senderDeviceId: senderDeviceId,
            sequenceNumber: sequenceNumber,
            sentAtMs: sentAtMs,
            payload: payload
        )
    }
}

nonisolated private final class TurboMediaRelayTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.withLock {
            timedOut = true
        }
    }

    var didTimeOut: Bool {
        lock.withLock {
            timedOut
        }
    }
}

nonisolated final class TurboMediaRelayClient: @unchecked Sendable {
    static let quicIdleTimeoutMilliseconds = 120_000
    static let connectionHandshakeTimeoutNanoseconds: UInt64 = 1_500_000_000
    static let datagramHandshakeTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let datagramJoinRetryIntervalNanoseconds: UInt64 = 250_000_000
    static let streamConnectionAdvertisesDatagramReceive = true
    static let datagramJoinWaitsForProcessing = true
    static let datagramJoinArmsReceiveBeforeSend = true
    static let livePacketAudioWaitsForProcessing = false
    static let binaryPacketAudioDatagramsEnabled = true
    static let liveAudioMaxConcurrentIncomingHandlers = 16
    static let liveAudioMaxPendingIncomingHandlers = 96
    static let liveAudioIncomingHandlerExpirationNanoseconds: UInt64 = 2_000_000_000
    private static let maximumReceiveChunkLength = 65_536
    private let config: TurboMediaRelayClientConfig
    private let sessionId: String
    private let localDeviceId: String
    private let peerDeviceId: String
    private let onIncomingAudioPayload: @Sendable (TurboMediaRelayIncomingAudioPayload) async -> Void
    private let onExpiredIncomingAudioPayload:
        (@Sendable (TurboMediaRelayIncomingAudioPayload, UInt64, UInt64) async -> Void)?
    private let onIncomingControlFrame: (@Sendable (TurboMediaRelayControlFrame) async -> Void)?
    private let onDisconnected: (@Sendable (TurboMediaRelayClient) async -> Void)?
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    private let incomingAudioPayloadQueue: DirectQuicAudioPayloadAsyncQueue
    private let incomingOrderedAudioPayloadQueue: DirectQuicAudioPayloadAsyncQueue
    private let incomingAudioHandlerExpirationNanoseconds: UInt64
    private let queue = DispatchQueue(label: "turbo.media-relay-client")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var datagramConnection: NWConnection?
    private var receiveBuffer = Data()
    private var selectedTransport: TurboMediaRelayTransport?
    private var selectedMediaMode: TurboMediaRelayMediaMode = .quicDatagram
    private var sequenceNumber: UInt64 = 0
    private var peerUnavailableSince: Date?
    private let peerUnavailableFreshnessWindow: TimeInterval = 1.0
    private let outboundPacketAudioReportLimiter = MediaHotPathEventLimiter(
        minimumIntervalNanoseconds: 1_000_000_000
    )
    private let incomingPacketAudioReportLimiter = MediaHotPathEventLimiter(
        minimumIntervalNanoseconds: 1_000_000_000
    )

    init(
        config: TurboMediaRelayClientConfig,
        sessionId: String,
        localDeviceId: String,
        peerDeviceId: String,
        onIncomingAudioPayload: @escaping @Sendable (TurboMediaRelayIncomingAudioPayload) async -> Void,
        onExpiredIncomingAudioPayload:
            (@Sendable (TurboMediaRelayIncomingAudioPayload, UInt64, UInt64) async -> Void)? = nil,
        onIncomingControlFrame: (@Sendable (TurboMediaRelayControlFrame) async -> Void)? = nil,
        onDisconnected: (@Sendable (TurboMediaRelayClient) async -> Void)? = nil,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil,
        incomingAudioMaxConcurrentHandlers: Int = TurboMediaRelayClient
            .liveAudioMaxConcurrentIncomingHandlers,
        incomingAudioMaxPendingHandlers: Int = TurboMediaRelayClient
            .liveAudioMaxPendingIncomingHandlers,
        incomingAudioHandlerExpirationNanoseconds: UInt64 = TurboMediaRelayClient
            .liveAudioIncomingHandlerExpirationNanoseconds
    ) {
        self.config = config
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.peerDeviceId = peerDeviceId
        self.onIncomingAudioPayload = onIncomingAudioPayload
        self.onExpiredIncomingAudioPayload = onExpiredIncomingAudioPayload
        self.onIncomingControlFrame = onIncomingControlFrame
        self.onDisconnected = onDisconnected
        self.reportEvent = reportEvent
        self.incomingAudioHandlerExpirationNanoseconds = incomingAudioHandlerExpirationNanoseconds
        self.incomingAudioPayloadQueue = DirectQuicAudioPayloadAsyncQueue(
            maxConcurrentHandlers: incomingAudioMaxConcurrentHandlers,
            maxPendingHandlers: incomingAudioMaxPendingHandlers
        )
        self.incomingOrderedAudioPayloadQueue = DirectQuicAudioPayloadAsyncQueue(
            maxConcurrentHandlers: 1,
            maxPendingHandlers: incomingAudioMaxPendingHandlers
        )
    }

    func connect(preferredTransport: TurboMediaRelayTransport? = nil) async throws -> TurboMediaRelayTransport {
        if let preferredTransport {
            let transport = try await connect(using: preferredTransport)
            await report(
                preferredTransport == .tcpTls
                    ? "Media relay TCP ordered fallback connected"
                    : "Media relay QUIC packet connected",
                metadata: baseMetadata(transport: transport).merging(
                    ["preferredTransport": preferredTransport.rawValue],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return transport
        }
        do {
            let transport = try await connect(using: .quic)
            await report("Media relay QUIC packet connected", metadata: baseMetadata(transport: transport))
            return transport
        } catch {
            close()
            await report(
                "Media relay QUIC packet connect failed",
                metadata: baseMetadata(transport: .quic).merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                )
            )
            do {
                let transport = try await connect(using: .tcpTls)
                await report(
                    "Media relay TCP ordered fallback connected",
                    metadata: baseMetadata(transport: transport)
                )
                return transport
            } catch {
                close()
                await report(
                    "Media relay TCP ordered fallback connect failed",
                    metadata: baseMetadata(transport: .tcpTls).merging(
                        ["error": error.localizedDescription],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                throw error
            }
        }
    }

    func upgradeToDatagramMediaChannel() async throws -> TurboMediaRelayTransport {
        if currentMediaMode() == .quicDatagram {
            return .quicDatagram
        }
        guard lock.withLock({ self.connection != nil }) else {
            throw DirectQuicProbeError.connectionFailed("media relay is not connected")
        }
        try await connectDatagramMediaChannel()
        return .quicDatagram
    }

    @discardableResult
    func sendAudioPayload(
        _ payload: String,
        forcedMediaMode: TurboMediaRelayMediaMode? = nil
    ) async throws -> TurboMediaRelayMediaMode {
        let sequenceNumber = nextSequenceNumber()
        let sentAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let packetFrame: TurboMediaRelayFrame
        let packetFrameKind: String
        if Self.binaryPacketAudioDatagramsEnabled,
           let binaryPacketPayload = VoiceAudioFramePayloadCodec.singleBinaryOpusPacketData(payload) {
            packetFrame = .binaryPacketAudio(
                sessionId: sessionId,
                senderDeviceId: localDeviceId,
                sequenceNumber: sequenceNumber,
                sentAtMs: sentAtMs,
                payload: binaryPacketPayload
            )
            packetFrameKind = "binary-packet-audio"
        } else {
            packetFrame = .packetAudio(
                sessionId: sessionId,
                senderDeviceId: localDeviceId,
                sequenceNumber: sequenceNumber,
                sentAtMs: sentAtMs,
                payload: payload
            )
            packetFrameKind = "packet-audio"
        }
        let tcpFrame = TurboMediaRelayFrame.tcpAudio(
            sessionId: sessionId,
            senderDeviceId: localDeviceId,
            sequenceNumber: sequenceNumber,
            sentAtMs: sentAtMs,
            payload: payload
        )
        let connections = lock.withLock {
            (
                stream: self.connection,
                datagram: self.datagramConnection,
                transport: self.selectedTransport
            )
        }
        guard let stream = connections.stream else {
            throw DirectQuicProbeError.connectionFailed("media relay is not connected")
        }
        if hasFreshPeerUnavailable() {
            throw DirectQuicProbeError.connectionFailed("media relay peer is unavailable")
        }
        if forcedMediaMode == .tcpOrdered {
            guard connections.transport == .tcpTls else {
                throw DirectQuicProbeError.connectionFailed("media relay TCP/TLS path is unavailable")
            }
            do {
                try await send(tcpFrame, on: stream)
                return .tcpOrdered
            } catch {
                await report(
                    "Media relay TCP ordered audio send failed",
                    metadata: baseMetadata().merging(
                        [
                            "error": error.localizedDescription,
                            "sequenceNumber": String(sequenceNumber),
                            "forcedMediaMode": TurboMediaRelayMediaMode.tcpOrdered.rawValue,
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                throw error
            }
        }
        if let datagramConnection = connections.datagram {
            do {
                try await sendDatagram(
                    packetFrame,
                    on: datagramConnection,
                    waitsForProcessing: Self.livePacketAudioWaitsForProcessing
                )
                if outboundPacketAudioReportLimiter.take() {
                    await report(
                        "Media relay packet audio submitted",
                        metadata: baseMetadata().merging(
                            [
                                "sequenceNumber": String(sequenceNumber),
                                "frameKind": packetFrameKind,
                                "payloadLength": String(payload.count),
                            ],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                return .quicDatagram
            } catch {
                await report(
                    "Media relay packet send failed",
                    metadata: baseMetadata().merging(
                        [
                            "error": error.localizedDescription,
                            "preservedDatagramMediaPath": String(!Self.shouldClearDatagramMediaPath(afterPacketSendError: error)),
                            "sequenceNumber": String(sequenceNumber),
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                if Self.shouldClearDatagramMediaPath(afterPacketSendError: error) {
                    clearDatagramMediaPath(connection: datagramConnection)
                }
                if Self.shouldFallbackPacketOversizeToStream(afterPacketSendError: error) {
                    try await send(tcpFrame, on: stream)
                    await report(
                        "Media relay packet oversized; fell back to TCP ordered audio",
                        metadata: baseMetadata().merging(
                            [
                                "sequenceNumber": String(sequenceNumber),
                            ],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                    return .tcpOrdered
                }
                throw error
            }
        }
        if forcedMediaMode == .quicDatagram {
            throw DirectQuicProbeError.connectionFailed("media relay QUIC datagram path is unavailable")
        }
        guard connections.transport == .tcpTls else {
            throw DirectQuicProbeError.connectionFailed("media relay packet path is unavailable")
        }
        do {
            try await send(tcpFrame, on: stream)
            return .tcpOrdered
        } catch {
            await report(
                "Media relay TCP ordered audio send failed",
                metadata: baseMetadata().merging(
                    [
                        "error": error.localizedDescription,
                        "sequenceNumber": String(sequenceNumber),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            throw error
        }
    }

    func sendReceiverPrewarmRequest(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        try await sendControlFrame(.receiverPrewarmRequest(payload))
    }

    func sendReceiverPrewarmAck(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        try await sendControlFrame(.receiverPrewarmAck(payload))
    }

    func sendAudioPlaybackStarted(_ payload: TurboAudioPlaybackStartedPayload) async throws {
        try await sendControlFrame(.audioPlaybackStarted(payload))
    }

    private func sendControlFrame(_ frame: TurboMediaRelayControlFrame) async throws {
        let connection = lock.withLock { self.connection }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("media relay is not connected")
        }
        if hasFreshPeerUnavailable() {
            throw DirectQuicProbeError.connectionFailed("media relay peer is unavailable")
        }
        try await send(
            .control(
                sessionId: sessionId,
                senderDeviceId: localDeviceId,
                kind: frame.kind,
                payload: frame.payload
            ),
            on: connection
        )
    }

    func close() {
        let connections = lock.withLock { () -> (stream: NWConnection?, datagram: NWConnection?) in
            let connection = self.connection
            let datagramConnection = self.datagramConnection
            self.connection = nil
            self.datagramConnection = nil
            self.receiveBuffer.removeAll(keepingCapacity: false)
            self.selectedTransport = nil
            self.selectedMediaMode = .quicDatagram
            self.peerUnavailableSince = nil
            return (connection, datagramConnection)
        }
        incomingAudioPayloadQueue.reset()
        incomingOrderedAudioPayloadQueue.reset()
        connections.stream?.cancel()
        connections.datagram?.cancel()
    }

#if DEBUG
    func injectIncomingAudioPayloadForTesting(_ incomingPayload: TurboMediaRelayIncomingAudioPayload) {
        enqueueIncomingAudioPayload(incomingPayload)
    }
#endif

    private func connect(using transport: TurboMediaRelayTransport) async throws -> TurboMediaRelayTransport {
        close()
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: port(for: transport)) ?? .https,
            using: parameters(for: transport)
        )
        let ackTransport: TurboMediaRelayTransport
        do {
            ackTransport = try await withConnectionHandshakeTimeout(
                transport: transport,
                connection: connection
            ) {
                try await self.startConnection(connection, transport: transport)
                try await self.send(
                    .join(
                        sessionId: self.sessionId,
                        deviceId: self.localDeviceId,
                        peerDeviceId: self.peerDeviceId,
                        token: self.config.token
                    ),
                    on: connection
                )
                let ack = try await self.receiveNextFrame(on: connection)
                guard case .joinAck(let sessionId, let deviceId, let ackTransport) = ack,
                      sessionId == self.sessionId,
                      deviceId == self.localDeviceId else {
                    throw DirectQuicProbeError.proofFailed("media relay join acknowledgement was invalid")
                }
                guard ackTransport == transport else {
                    throw DirectQuicProbeError.proofFailed(
                        "media relay acknowledged \(ackTransport.rawValue) for \(transport.rawValue) connection"
                    )
                }
                return ackTransport
            }
        } catch {
            connection.cancel()
            throw error
        }
        lock.withLock {
            self.connection = connection
            self.selectedTransport = ackTransport
            self.receiveBuffer.removeAll(keepingCapacity: false)
            if ackTransport == .tcpTls {
                self.selectedMediaMode = .tcpOrdered
            }
            self.peerUnavailableSince = nil
        }
        receiveFrames(on: connection)
        if ackTransport == .quic {
            try await connectDatagramMediaChannel()
            guard lock.withLock({ self.datagramConnection != nil }) else {
                throw DirectQuicProbeError.connectionFailed("media relay packet path is unavailable")
            }
        } else if ackTransport == .tcpTls {
            lock.withLock {
                self.selectedMediaMode = .tcpOrdered
            }
        } else {
            throw DirectQuicProbeError.connectionFailed(
                "media relay stream acknowledged unsupported transport \(ackTransport.rawValue)"
            )
        }
        return ackTransport
    }

    private func withConnectionHandshakeTimeout<T: Sendable>(
        transport: TurboMediaRelayTransport,
        connection: NWConnection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = TurboMediaRelayTimeoutFlag()
        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.connectionHandshakeTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            timeout.markTimedOut()
            connection.cancel()
            operationTask.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            return try await operationTask.value
        } catch {
            if timeout.didTimeOut {
                throw DirectQuicProbeError.connectionFailed(
                    "media relay \(transport.rawValue) handshake timed out"
                )
            }
            throw error
        }
    }

    private func parameters(for transport: TurboMediaRelayTransport) -> NWParameters {
        switch transport {
        case .quic, .quicDatagram:
            let quicOptions = NWProtocolQUIC.Options(alpn: ["turbo-relay-v2"])
            sec_protocol_options_set_min_tls_protocol_version(
                quicOptions.securityProtocolOptions,
                .TLSv13
            )
            quicOptions.idleTimeout = Self.quicIdleTimeoutMilliseconds
            if Self.streamConnectionAdvertisesDatagramReceive {
                quicOptions.maxDatagramFrameSize = TurboMediaRelayDatagramCodec.maximumDatagramFrameSize
            }
            return NWParameters(quic: quicOptions)
        case .tcpTls:
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv13
            )
            return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        }
    }

    private func port(for transport: TurboMediaRelayTransport) -> UInt16 {
        switch transport {
        case .quic, .quicDatagram:
            return config.quicPort
        case .tcpTls:
            return config.tcpPort
        }
    }

    private func datagramParameters() -> NWParameters {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["turbo-relay-v2"])
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv13
        )
        quicOptions.idleTimeout = Self.quicIdleTimeoutMilliseconds
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = TurboMediaRelayDatagramCodec.maximumDatagramFrameSize
        return NWParameters(quic: quicOptions)
    }

    private func connectDatagramMediaChannel() async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.quicPort) ?? .https,
            using: datagramParameters()
        )
        let handshakeStartedAt = DispatchTime.now().uptimeNanoseconds
        @Sendable func elapsedHandshakeMilliseconds() -> String {
            String((DispatchTime.now().uptimeNanoseconds - handshakeStartedAt) / 1_000_000)
        }
        do {
            await report(
                "Media relay QUIC datagram handshake stage",
                metadata: baseMetadata().merging(
                    ["stage": "starting", "elapsedMs": elapsedHandshakeMilliseconds()],
                    uniquingKeysWith: { _, new in new }
                )
            )
            let ack = try await withDatagramHandshakeTimeout(connection: connection) {
                try await self.startConnection(connection, transport: .quicDatagram)
                await self.report(
                    "Media relay QUIC datagram handshake stage",
                    metadata: self.baseMetadata().merging(
                        [
                            "stage": "ready",
                            "elapsedMs": elapsedHandshakeMilliseconds(),
                            "datagramMaximumSize": String(connection.maximumDatagramSize)
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                var ackIterator = self
                    .armNextDatagramFrameReceive(on: connection)
                    .makeAsyncIterator()
                await self.report(
                    "Media relay QUIC datagram handshake stage",
                    metadata: self.baseMetadata().merging(
                        ["stage": "receive-armed", "elapsedMs": elapsedHandshakeMilliseconds()],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                let joinFrame = TurboMediaRelayFrame.datagramJoin(
                    sessionId: self.sessionId,
                    deviceId: self.localDeviceId,
                    peerDeviceId: self.peerDeviceId,
                    token: self.config.token
                )
                let joinSendTask = Task {
                    try await self.sendDatagramJoinUntilAck(
                        joinFrame,
                        on: connection,
                        elapsedMilliseconds: elapsedHandshakeMilliseconds
                    )
                }
                defer { joinSendTask.cancel() }
                guard let ack = try await ackIterator.next() else {
                    throw DirectQuicProbeError.proofFailed("media relay datagram receive ended before response")
                }
                await self.report(
                    "Media relay QUIC datagram handshake stage",
                    metadata: self.baseMetadata().merging(
                        ["stage": "ack-received", "elapsedMs": elapsedHandshakeMilliseconds()],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                return ack
            }
            guard case .datagramJoinAck(let sessionId, let deviceId, let transport) = ack,
                  sessionId == self.sessionId,
                  deviceId == localDeviceId,
                  transport == .quicDatagram else {
                throw DirectQuicProbeError.proofFailed("media relay datagram join acknowledgement was invalid")
            }
            let shouldInstall = lock.withLock { () -> Bool in
                guard self.connection != nil else { return false }
                self.datagramConnection = connection
                self.selectedMediaMode = .quicDatagram
                return true
            }
            guard shouldInstall else {
                connection.cancel()
                return
            }
            receiveDatagrams(on: connection)
            await report(
                "Media relay QUIC datagram connected",
                metadata: baseMetadata().merging(
                    ["datagramMaximumSize": String(connection.maximumDatagramSize)],
                    uniquingKeysWith: { _, new in new }
                )
            )
        } catch {
            connection.cancel()
            lock.withLock {
                if self.datagramConnection === connection {
                    self.datagramConnection = nil
                }
            }
            await report(
                "Media relay QUIC datagram unavailable",
                metadata: baseMetadata().merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                )
            )
            throw error
        }
    }

    private func withDatagramHandshakeTimeout<T: Sendable>(
        connection: NWConnection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = TurboMediaRelayTimeoutFlag()
        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.datagramHandshakeTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            timeout.markTimedOut()
            connection.cancel()
            operationTask.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            return try await operationTask.value
        } catch {
            if timeout.didTimeOut {
                throw DirectQuicProbeError.connectionFailed("media relay datagram handshake timed out")
            }
            throw error
        }
    }

    private func startConnection(
        _ connection: NWConnection,
        transport: TurboMediaRelayTransport
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    gate.resume { continuation.resume() }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed(error.localizedDescription)
                        )
                    }
                case .cancelled:
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed("cancelled")
                        )
                    }
                case .waiting(let error):
                    Task {
                        await self?.report(
                            "Media relay connection waiting",
                            metadata: self?.baseMetadata(transport: transport).merging(
                                ["error": error.localizedDescription],
                                uniquingKeysWith: { _, new in new }
                            ) ?? [:]
                        )
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ frame: TurboMediaRelayFrame, on connection: NWConnection) async throws {
        let content = try TurboMediaRelayCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func sendDatagram(
        _ frame: TurboMediaRelayFrame,
        on connection: NWConnection,
        waitsForProcessing: Bool = true
    ) async throws {
        let content = try TurboMediaRelayDatagramCodec.encode(frame)
        let maximumSize = connection.maximumDatagramSize
        guard maximumSize <= 0 || content.count <= maximumSize else {
            throw DirectQuicProbeError.proofFailed(
                "media relay datagram exceeded path maximum: \(content.count) > \(maximumSize)"
            )
        }
        guard waitsForProcessing else {
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .idempotent
            )
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    nonisolated static func shouldClearDatagramMediaPath(afterPacketSendError error: Error) -> Bool {
        guard case DirectQuicProbeError.proofFailed(let message) = error else {
            return true
        }
        return !message.hasPrefix("media relay datagram exceeded path maximum:")
    }

    nonisolated static func shouldFallbackPacketOversizeToStream(afterPacketSendError error: Error) -> Bool {
        false
    }

    private func sendDatagramJoinUntilAck(
        _ frame: TurboMediaRelayFrame,
        on connection: NWConnection,
        elapsedMilliseconds: @escaping @Sendable () -> String
    ) async throws {
        let contentLength = try TurboMediaRelayDatagramCodec.encode(frame).count
        var attempt = 1
        while !Task.isCancelled {
            try await sendDatagram(
                frame,
                on: connection,
                waitsForProcessing: Self.datagramJoinWaitsForProcessing
            )
            await report(
                "Media relay QUIC datagram join sent",
                metadata: baseMetadata().merging(
                    [
                        "attempt": String(attempt),
                        "contentLength": String(contentLength),
                        "elapsedMs": elapsedMilliseconds(),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            attempt += 1
            try await Task.sleep(nanoseconds: Self.datagramJoinRetryIntervalNanoseconds)
        }
    }

    private func receiveNextFrame(on connection: NWConnection) async throws -> TurboMediaRelayFrame {
        var buffer = Data()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TurboMediaRelayFrame, Error>) in
            func receiveNextChunk() {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: Self.maximumReceiveChunkLength
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                        return
                    }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        do {
                            if let decoded = try TurboMediaRelayCodec.decodeAvailable(from: &buffer).first {
                                continuation.resume(returning: decoded)
                                return
                            }
                        } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                    }
                    if isComplete {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed("media relay closed before response")
                        )
                        return
                    }
                    receiveNextChunk()
                }
            }
            receiveNextChunk()
        }
    }

    private func receiveNextDatagramFrame(on connection: NWConnection) async throws -> TurboMediaRelayFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TurboMediaRelayFrame, Error>) in
            func receiveNextMessage() {
                connection.receiveMessage { data, _, _, error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                        return
                    }
                    guard let data, !data.isEmpty else {
                        receiveNextMessage()
                        return
                    }
                    do {
                        continuation.resume(returning: try TurboMediaRelayDatagramCodec.decode(data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            receiveNextMessage()
        }
    }

    private func armNextDatagramFrameReceive(
        on connection: NWConnection
    ) -> AsyncThrowingStream<TurboMediaRelayFrame, Error> {
        AsyncThrowingStream(
            TurboMediaRelayFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            func receiveNextMessage() {
                connection.receiveMessage { data, _, _, error in
                    if let error {
                        continuation.finish(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                        return
                    }
                    guard let data, !data.isEmpty else {
                        receiveNextMessage()
                        return
                    }
                    do {
                        continuation.yield(try TurboMediaRelayDatagramCodec.decode(data))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            receiveNextMessage()
        }
    }

    private func receiveFrames(on connection: NWConnection) {
        guard lock.withLock({ self.connection === connection }) else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumReceiveChunkLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task {
                    await self.report(
                        "Media relay receive failed",
                        metadata: self.baseMetadata().merging(
                            ["error": error.localizedDescription],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                    await self.onDisconnected?(self)
                }
                return
            }
            if let data, !data.isEmpty {
                let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                let result = self.lock.withLock { () -> Result<[TurboMediaRelayFrame], Error> in
                    self.receiveBuffer.append(data)
                    do {
                        return .success(try TurboMediaRelayCodec.decodeAvailable(from: &self.receiveBuffer))
                    } catch {
                        return .failure(error)
                    }
                }
                switch result {
                case .success(let frames):
                    for frame in frames {
                        if case .tcpAudio(_, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload) = frame {
                            guard senderDeviceId == self.peerDeviceId else {
                                Task {
                                    await self.report(
                                        "Ignored media relay TCP audio from unexpected peer",
                                        metadata: self.baseMetadata().merging(
                                            [
                                                "senderDeviceId": senderDeviceId,
                                                "sequenceNumber": String(sequenceNumber),
                                            ],
                                            uniquingKeysWith: { _, new in new }
                                        )
                                    )
                                }
                                continue
                            }
                            self.clearPeerUnavailable()
                            self.enqueueIncomingAudioPayload(
                                TurboMediaRelayIncomingAudioPayload(
                                    payload: payload,
                                    mediaMode: .tcpOrdered,
                                    sequenceNumber: sequenceNumber,
                                    sentAtMilliseconds: sentAtMs,
                                    receivedAtNanoseconds: receivedAtNanoseconds
                                )
                            )
                        } else if case .control(_, let senderDeviceId, let kind, let payload) = frame {
                            guard senderDeviceId == self.peerDeviceId else {
                                Task {
                                    await self.report(
                                        "Ignored media relay control frame from unexpected peer",
                                        metadata: self.baseMetadata().merging(
                                            [
                                                "senderDeviceId": senderDeviceId,
                                                "kind": kind.rawValue,
                                            ],
                                            uniquingKeysWith: { _, new in new }
                                        )
                                    )
                                }
                                continue
                            }
                            self.clearPeerUnavailable()
                            Task {
                                await self.onIncomingControlFrame?(
                                    TurboMediaRelayControlFrame(kind: kind, payload: payload)
                                )
                            }
                        } else if case .peerUnavailable = frame {
                            self.markPeerUnavailable()
                            Task {
                                await self.report(
                                    "Media relay peer unavailable",
                                    metadata: self.baseMetadata()
                                )
                            }
                        }
                    }
                case .failure(let error):
                    Task {
                        await self.report(
                            "Media relay frame decode failed",
                            metadata: self.baseMetadata().merging(
                                ["error": error.localizedDescription],
                                uniquingKeysWith: { _, new in new }
                            )
                        )
                    }
                    return
                }
            }
            guard !isComplete else {
                Task {
                    await self.onDisconnected?(self)
                }
                return
            }
            self.receiveFrames(on: connection)
        }
    }

    private func receiveDatagrams(on connection: NWConnection) {
        guard lock.withLock({ self.datagramConnection === connection }) else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                Task {
                    await self.report(
                        "Media relay datagram receive failed",
                        metadata: self.baseMetadata().merging(
                            ["error": error.localizedDescription],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                self.clearDatagramMediaPath(connection: connection)
                return
            }
            if let data, !data.isEmpty {
                let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                do {
                    let frame = try TurboMediaRelayDatagramCodec.decode(data)
                    switch frame {
                    case .packetAudio(_, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload):
                        guard senderDeviceId == self.peerDeviceId else {
                            Task {
                                await self.report(
                                    "Ignored media relay packet audio from unexpected peer",
                                    metadata: self.baseMetadata().merging(
                                        [
                                            "senderDeviceId": senderDeviceId,
                                            "sequenceNumber": String(sequenceNumber),
                                        ],
                                        uniquingKeysWith: { _, new in new }
                                    )
                                )
                            }
                            break
                        }
                        self.clearPeerUnavailable()
                        if self.incomingPacketAudioReportLimiter.take() {
                            Task {
                                await self.report(
                                    "Media relay packet audio received",
                                    metadata: self.baseMetadata().merging(
                                        [
                                            "sequenceNumber": String(sequenceNumber),
                                            "frameKind": "packet-audio",
                                            "payloadLength": String(payload.count),
                                        ],
                                        uniquingKeysWith: { _, new in new }
                                    )
                                )
                            }
                        }
                        self.enqueueIncomingAudioPayload(
                            TurboMediaRelayIncomingAudioPayload(
                                payload: payload,
                                mediaMode: .quicDatagram,
                                sequenceNumber: sequenceNumber,
                                sentAtMilliseconds: sentAtMs,
                                receivedAtNanoseconds: receivedAtNanoseconds
                            )
                        )
                    case .binaryPacketAudio(_, let senderDeviceId, let sequenceNumber, let sentAtMs, let payload):
                        guard senderDeviceId == self.peerDeviceId else {
                            Task {
                                await self.report(
                                    "Ignored media relay binary packet audio from unexpected peer",
                                    metadata: self.baseMetadata().merging(
                                        [
                                            "senderDeviceId": senderDeviceId,
                                            "sequenceNumber": String(sequenceNumber),
                                        ],
                                        uniquingKeysWith: { _, new in new }
                                    )
                                )
                            }
                            break
                        }
                        self.clearPeerUnavailable()
                        if self.incomingPacketAudioReportLimiter.take() {
                            Task {
                                await self.report(
                                    "Media relay packet audio received",
                                    metadata: self.baseMetadata().merging(
                                        [
                                            "sequenceNumber": String(sequenceNumber),
                                            "frameKind": "binary-packet-audio",
                                            "payloadLength": String(payload.count),
                                        ],
                                        uniquingKeysWith: { _, new in new }
                                    )
                                )
                            }
                        }
                        self.enqueueIncomingAudioPayload(
                            TurboMediaRelayIncomingAudioPayload(
                                payload: VoiceAudioFramePayloadCodec.encodeBinaryOpusData(payload),
                                mediaMode: .quicDatagram,
                                sequenceNumber: sequenceNumber,
                                sentAtMilliseconds: sentAtMs,
                                receivedAtNanoseconds: receivedAtNanoseconds
                            )
                        )
                    case .peerUnavailable:
                        self.markPeerUnavailable()
                        Task {
                            await self.report(
                                "Media relay peer unavailable",
                                metadata: self.baseMetadata()
                            )
                        }
                    case .error(let message):
                        Task {
                            await self.report(
                                "Media relay datagram error",
                                metadata: self.baseMetadata().merging(
                                    ["error": message],
                                    uniquingKeysWith: { _, new in new }
                                )
                            )
                        }
                    default:
                        break
                    }
                } catch {
                    Task {
                        await self.report(
                            "Media relay datagram decode failed",
                            metadata: self.baseMetadata().merging(
                                ["error": error.localizedDescription],
                                uniquingKeysWith: { _, new in new }
                            )
                        )
                    }
                }
            }
            self.receiveDatagrams(on: connection)
        }
    }

    private func enqueueIncomingAudioPayload(
        _ incomingPayload: TurboMediaRelayIncomingAudioPayload
    ) {
        let expirationNanoseconds = Self.liveAudioHandlerExpirationDeadline(
            receivedAtNanoseconds: incomingPayload.receivedAtNanoseconds,
            intervalNanoseconds: incomingAudioHandlerExpirationNanoseconds
        )
        let isPacketMedia = incomingPayload.mediaMode == .quicDatagram
        let queue = isPacketMedia
            ? incomingAudioPayloadQueue
            : incomingOrderedAudioPayloadQueue
        queue.enqueue(
            expiringAtNanoseconds: expirationNanoseconds,
            expiresRunningHandler: false,
            onExpired: { [weak self] in
                guard let self else { return }
                let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                let localQueueDelayNanoseconds =
                    nowNanoseconds >= incomingPayload.receivedAtNanoseconds
                    ? nowNanoseconds - incomingPayload.receivedAtNanoseconds
                    : 0
                if let onExpiredIncomingAudioPayload = self.onExpiredIncomingAudioPayload {
                    await onExpiredIncomingAudioPayload(
                        incomingPayload,
                        localQueueDelayNanoseconds,
                        self.incomingAudioHandlerExpirationNanoseconds
                    )
                    return
                }
                await self.report(
                    "Dropped expired media relay incoming audio payload before app handler",
                    metadata: self.baseMetadata().merging(
                        [
                            "mediaMode": incomingPayload.mediaMode.rawValue,
                            "sequenceNumber": incomingPayload.sequenceNumber.map(String.init) ?? "none",
                            "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                            "thresholdMs": String(self.incomingAudioHandlerExpirationNanoseconds / 1_000_000),
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            }
        ) { [onIncomingAudioPayload] in
            await onIncomingAudioPayload(incomingPayload)
        }
    }

    private static func liveAudioHandlerExpirationDeadline(
        receivedAtNanoseconds: UInt64,
        intervalNanoseconds: UInt64
    ) -> UInt64? {
        guard intervalNanoseconds > 0 else { return nil }
        let (deadline, overflow) = receivedAtNanoseconds.addingReportingOverflow(intervalNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private func nextSequenceNumber() -> UInt64 {
        lock.withLock {
            sequenceNumber += 1
            return sequenceNumber
        }
    }

    func markPeerUnavailable() {
        lock.withLock {
            peerUnavailableSince = Date()
        }
    }

    func resetIncomingAudioPayloadQueue(reason: String) {
        incomingAudioPayloadQueue.reset()
        incomingOrderedAudioPayloadQueue.reset()
        Task {
            await report(
                "Reset media relay incoming audio payload queue",
                metadata: baseMetadata().merging(
                    ["reason": reason],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    func clearPeerUnavailable() {
        lock.withLock {
            peerUnavailableSince = nil
        }
    }

    func hasFreshPeerUnavailable(now: Date = Date()) -> Bool {
        lock.withLock {
            guard let peerUnavailableSince else { return false }
            if now.timeIntervalSince(peerUnavailableSince) <= peerUnavailableFreshnessWindow {
                return true
            }
            self.peerUnavailableSince = nil
            return false
        }
    }

    func currentMediaTransportLabel() -> String {
        let mediaMode = lock.withLock { selectedMediaMode }
        return IncomingAudioPayloadTransport(mediaRelayMediaMode: mediaMode).diagnosticsValue
    }

    func currentMediaMode() -> TurboMediaRelayMediaMode {
        lock.withLock { selectedMediaMode }
    }

    private func clearDatagramMediaPath(connection: NWConnection) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard self.datagramConnection === connection else { return false }
            self.datagramConnection = nil
            return true
        }
        if shouldCancel {
            connection.cancel()
        }
    }

    private func baseMetadata(transport: TurboMediaRelayTransport? = nil) -> [String: String] {
        let relayState = lock.withLock {
            (
                selectedTransport: self.selectedTransport,
                selectedMediaMode: self.selectedMediaMode,
                datagramMaximumSize: self.datagramConnection?.maximumDatagramSize
            )
        }
        let selected = transport ?? relayState.selectedTransport
        return [
            "sessionId": sessionId,
            "localDeviceId": localDeviceId,
            "peerDeviceId": peerDeviceId,
            "host": config.host,
            "transport": selected?.rawValue ?? "none",
            "mediaMode": relayState.selectedMediaMode.rawValue,
            "datagramMaximumSize": relayState.datagramMaximumSize.map(String.init) ?? "none",
            "quicPort": String(config.quicPort),
            "tcpPort": String(config.tcpPort),
            "quicIdleTimeoutMs": String(Self.quicIdleTimeoutMilliseconds),
            "datagramHandshakeTimeoutMs": String(Self.datagramHandshakeTimeoutNanoseconds / 1_000_000),
            "datagramJoinWaitsForProcessing": String(describing: Self.datagramJoinWaitsForProcessing),
            "datagramJoinArmsReceiveBeforeSend": String(describing: Self.datagramJoinArmsReceiveBeforeSend),
        ]
    }

    private func report(_ message: String, metadata: [String: String]) async {
        await reportEvent?(message, metadata)
    }
}

nonisolated enum DirectQuicHostCandidateGatherer {
    static func gatherCandidates(
        port: UInt16,
        includeLoopbackFallback: Bool = true
    ) -> [TurboDirectQuicCandidate] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard let address = interface.pointee.ifa_addr else { continue }

            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let host = String(cString: hostBuffer)
            guard !host.isEmpty else { continue }
            guard !host.hasPrefix("fe80:") else { continue }
            guard host != "::1" else { continue }
            if host == "127.0.0.1" && !includeLoopbackFallback {
                continue
            }
            addresses.append(host)
        }

        let nonLoopback = addresses.filter { $0 != "127.0.0.1" }
        let selectedAddresses = nonLoopback.isEmpty && includeLoopbackFallback ? addresses : nonLoopback

        return selectedAddresses.enumerated().map { index, host in
            let foundation = "host-\(index)"
            return TurboDirectQuicCandidate(
                foundation: foundation,
                component: "media",
                transport: "udp",
                priority: max(1_000_000 - index, 1),
                kind: .host,
                address: host,
                port: Int(port),
                relatedAddress: nil,
                relatedPort: nil
            )
        }
    }
}

nonisolated private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        operation()
    }
}

nonisolated final class DirectQuicSerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var tailTask: Task<Void, Never>?

    func reset() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            let task = tailTask
            tailTask = nil
            return task
        }
        task?.cancel()
    }

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let task = lock.withLock { () -> Task<Void, Never> in
            let generation = self.generation
            let previousTask = tailTask
            let task = Task {
                await previousTask?.value
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }
                await operation()
            }
            tailTask = task
            return task
        }
        _ = task
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }
}

nonisolated enum DirectQuicAudioPayloadWorkClass: Int, CaseIterable, Sendable {
    case audioRealtime = 0
    case appleBoundary = 1
    case controlPlane = 2
    case observability = 3
    case maintenance = 4
}

nonisolated enum DirectQuicAudioPayloadDropPolicy: Sendable, Equatable {
    case mustRun
    case cancelOnReset
    case expireAtDeadline
    case replaceByKey(String)
    case aggregateByKey(String)
}

nonisolated final class DirectQuicAudioPayloadAsyncQueue: @unchecked Sendable {
    // The default is serial for explicit ordering tests and ordered fallback-style
    // use. Direct/Fast packet media controllers opt into bounded concurrency
    // because Opus playout is keyed by frame index and can absorb packet
    // reordering. Ordered fallback lanes keep their own serial queue.
    static let defaultMaxConcurrentHandlers = 1
    static let defaultMaxPendingHandlers = 64

    private struct PendingEntry: Sendable {
        let id: UUID
        let generation: Int
        let sequence: UInt64
        let workClass: DirectQuicAudioPayloadWorkClass
        let expirationNanoseconds: UInt64?
        let expiresRunningHandler: Bool
        let dropPolicy: DirectQuicAudioPayloadDropPolicy
        let onExpired: (@Sendable () async -> Void)?
        let operation: @Sendable () async -> Void

        var sortDeadlineNanoseconds: UInt64 {
            expirationNanoseconds ?? UInt64.max
        }
    }

    private let lock = NSLock()
    private let priority: TaskPriority
    private let maxConcurrentHandlers: Int
    private let maxPendingHandlers: Int
    private var generation = 0
    private var nextSequence: UInt64 = 0
    private var pendingByClass: [DirectQuicAudioPayloadWorkClass: [PendingEntry]] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]

    init(
        priority: TaskPriority = .userInitiated,
        maxConcurrentHandlers: Int = DirectQuicAudioPayloadAsyncQueue.defaultMaxConcurrentHandlers,
        maxPendingHandlers: Int = DirectQuicAudioPayloadAsyncQueue.defaultMaxPendingHandlers
    ) {
        self.priority = priority
        self.maxConcurrentHandlers = max(1, maxConcurrentHandlers)
        self.maxPendingHandlers = max(1, maxPendingHandlers)
    }

    func reset() {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            generation += 1
            pendingByClass.removeAll()
            let tasks = Array(self.running.values)
            self.running.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    func enqueue(
        workClass: DirectQuicAudioPayloadWorkClass = .audioRealtime,
        dropPolicy: DirectQuicAudioPayloadDropPolicy = .cancelOnReset,
        expiringAtNanoseconds expirationNanoseconds: UInt64? = nil,
        expiresRunningHandler: Bool = false,
        onExpired: (@Sendable () async -> Void)? = nil,
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let expiredCallbacks = lock.withLock { () -> [@Sendable () async -> Void] in
            var expiredCallbacks: [@Sendable () async -> Void] = []
            let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
            guard !Self.isExpired(
                expirationNanoseconds,
                nowNanoseconds: nowNanoseconds
            ) else {
                if let onExpired {
                    expiredCallbacks.append(onExpired)
                }
                return expiredCallbacks
            }
            expirePendingLocked(nowNanoseconds: nowNanoseconds, expiredCallbacks: &expiredCallbacks)
            removeReplaceablePendingLocked(
                workClass: workClass,
                dropPolicy: dropPolicy
            )
            nextSequence &+= 1
            pushPendingLocked(
                PendingEntry(
                    id: UUID(),
                    generation: generation,
                    sequence: nextSequence,
                    workClass: workClass,
                    expirationNanoseconds: expirationNanoseconds,
                    expiresRunningHandler: expiresRunningHandler,
                    dropPolicy: dropPolicy,
                    onExpired: onExpired,
                    operation: operation
                )
            )
            removeOverflowPendingLocked()
            return expiredCallbacks
        }
        expiredCallbacks.forEach(runExpirationCallback)
        startAvailableHandlers()
    }

    private func startAvailableHandlers() {
        while true {
            let result = lock.withLock { () -> (task: Task<Void, Never>?, expiredCallbacks: [@Sendable () async -> Void]) in
                var expiredCallbacks: [@Sendable () async -> Void] = []
                while running.count < maxConcurrentHandlers,
                      let entry = popNextPendingLocked() {
                    let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                    guard !Self.isExpired(
                        entry.expirationNanoseconds,
                        nowNanoseconds: nowNanoseconds
                    ) else {
                        if let onExpired = entry.onExpired {
                            expiredCallbacks.append(onExpired)
                        }
                        continue
                    }
                    let task = Task.detached(priority: priority) { [weak self] in
                        guard let self,
                              !Task.isCancelled,
                              self.isCurrentGeneration(entry.generation)
                        else {
                            return
                        }
                        guard !Self.isExpired(
                                entry.expirationNanoseconds,
                                nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                              )
                        else {
                            if let onExpired = entry.onExpired {
                                await onExpired()
                            }
                            self.finish(entry.id)
                            return
                        }
                        let expirationTask = self.startRunningExpirationTask(for: entry)
                        await entry.operation()
                        expirationTask?.cancel()
                        self.finish(entry.id)
                    }
                    running[entry.id] = task
                    return (task, expiredCallbacks)
                }
                return (nil, expiredCallbacks)
            }
            result.expiredCallbacks.forEach(runExpirationCallback)
            guard result.task != nil else { return }
        }
    }

    private func startRunningExpirationTask(for entry: PendingEntry) -> Task<Void, Never>? {
        guard entry.expiresRunningHandler else { return nil }
        guard let expirationNanoseconds = entry.expirationNanoseconds else { return nil }
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard expirationNanoseconds > nowNanoseconds else { return nil }
        return Task.detached(priority: priority) { [weak self] in
            try? await Task.sleep(nanoseconds: expirationNanoseconds - nowNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.expireRunning(entry.id, generation: entry.generation)
            else { return }
            if let onExpired = entry.onExpired {
                await onExpired()
            }
        }
    }

    private func runExpirationCallback(_ callback: @escaping @Sendable () async -> Void) {
        Task.detached(priority: priority) {
            await callback()
        }
    }

    private static func isExpired(
        _ expirationNanoseconds: UInt64?,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard let expirationNanoseconds else { return false }
        return nowNanoseconds >= expirationNanoseconds
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }

    private func finish(_ id: UUID) {
        let shouldStartMore = lock.withLock { () -> Bool in
            running[id] = nil
            return pendingCountLocked() > 0
        }
        if shouldStartMore {
            startAvailableHandlers()
        }
    }

    @discardableResult
    private func expireRunning(_ id: UUID, generation: Int) -> Bool {
        let result = lock.withLock { () -> (task: Task<Void, Never>?, shouldStartMore: Bool) in
            guard self.generation == generation,
                  let task = running[id]
            else {
                return (nil, false)
            }
            running[id] = nil
            return (task, pendingCountLocked() > 0)
        }
        guard let task = result.task else { return false }
        task.cancel()
        if result.shouldStartMore {
            startAvailableHandlers()
        }
        return true
    }

    private func pendingCountLocked() -> Int {
        pendingByClass.values.reduce(0) { $0 + $1.count }
    }

    private func removeReplaceablePendingLocked(
        workClass: DirectQuicAudioPayloadWorkClass,
        dropPolicy: DirectQuicAudioPayloadDropPolicy
    ) {
        let replacementKey: String?
        switch dropPolicy {
        case .replaceByKey(let key), .aggregateByKey(let key):
            replacementKey = key
        case .mustRun, .cancelOnReset, .expireAtDeadline:
            replacementKey = nil
        }
        guard let replacementKey else { return }
        var heap = pendingByClass[workClass] ?? []
        heap.removeAll { entry in
            switch entry.dropPolicy {
            case .replaceByKey(let key), .aggregateByKey(let key):
                return key == replacementKey
            case .mustRun, .cancelOnReset, .expireAtDeadline:
                return false
            }
        }
        heapify(&heap)
        pendingByClass[workClass] = heap
    }

    private func expirePendingLocked(
        nowNanoseconds: UInt64,
        expiredCallbacks: inout [@Sendable () async -> Void]
    ) {
        for workClass in DirectQuicAudioPayloadWorkClass.allCases {
            var heap = pendingByClass[workClass] ?? []
            heap.removeAll { entry in
                let isExpired = Self.isExpired(entry.expirationNanoseconds, nowNanoseconds: nowNanoseconds)
                if isExpired,
                   let onExpired = entry.onExpired {
                    expiredCallbacks.append(onExpired)
                }
                return isExpired
            }
            heapify(&heap)
            pendingByClass[workClass] = heap
        }
    }

    private func removeOverflowPendingLocked() {
        while pendingCountLocked() > maxPendingHandlers {
            var removedOverflowEntry = false
            for workClass in DirectQuicAudioPayloadWorkClass.allCases.reversed() {
                guard var heap = pendingByClass[workClass], !heap.isEmpty else { continue }
                guard let oldestDroppableIndex = oldestOverflowIndex(in: heap, allowingMustRun: false) else {
                    continue
                }
                heap.remove(at: oldestDroppableIndex)
                heapify(&heap)
                pendingByClass[workClass] = heap
                removedOverflowEntry = true
                break
            }
            if removedOverflowEntry {
                continue
            }
            for workClass in DirectQuicAudioPayloadWorkClass.allCases.reversed() {
                guard var heap = pendingByClass[workClass], !heap.isEmpty else { continue }
                let oldestIndex = oldestOverflowIndex(in: heap, allowingMustRun: true)!
                heap.remove(at: oldestIndex)
                heapify(&heap)
                pendingByClass[workClass] = heap
                removedOverflowEntry = true
                break
            }
            guard removedOverflowEntry else { return }
        }
    }

    private func oldestOverflowIndex(
        in heap: [PendingEntry],
        allowingMustRun: Bool
    ) -> Array<PendingEntry>.Index? {
        heap.indices
            .filter { allowingMustRun || heap[$0].dropPolicy != .mustRun }
            .min { lhs, rhs in heap[lhs].sequence < heap[rhs].sequence }
    }

    private func popNextPendingLocked() -> PendingEntry? {
        for workClass in DirectQuicAudioPayloadWorkClass.allCases {
            guard var heap = pendingByClass[workClass], !heap.isEmpty else { continue }
            let entry = popMin(&heap)
            pendingByClass[workClass] = heap
            return entry
        }
        return nil
    }

    private func pushPendingLocked(_ entry: PendingEntry) {
        var heap = pendingByClass[entry.workClass] ?? []
        push(entry, into: &heap)
        pendingByClass[entry.workClass] = heap
    }

    private static func hasHigherPriority(_ lhs: PendingEntry, than rhs: PendingEntry) -> Bool {
        if lhs.sortDeadlineNanoseconds != rhs.sortDeadlineNanoseconds {
            return lhs.sortDeadlineNanoseconds < rhs.sortDeadlineNanoseconds
        }
        return lhs.sequence < rhs.sequence
    }

    private func push(_ entry: PendingEntry, into heap: inout [PendingEntry]) {
        heap.append(entry)
        siftUp(&heap, from: heap.count - 1)
    }

    private func popMin(_ heap: inout [PendingEntry]) -> PendingEntry {
        precondition(!heap.isEmpty)
        guard heap.count > 1 else { return heap.removeLast() }
        let result = heap[0]
        heap[0] = heap.removeLast()
        siftDown(&heap, from: 0)
        return result
    }

    private func heapify(_ heap: inout [PendingEntry]) {
        guard heap.count > 1 else { return }
        for index in stride(from: heap.count / 2 - 1, through: 0, by: -1) {
            siftDown(&heap, from: index)
        }
    }

    private func siftUp(_ heap: inout [PendingEntry], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.hasHigherPriority(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private func siftDown(_ heap: inout [PendingEntry], from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < heap.count,
               Self.hasHigherPriority(heap[left], than: heap[candidate]) {
                candidate = left
            }
            if right < heap.count,
               Self.hasHigherPriority(heap[right], than: heap[candidate]) {
                candidate = right
            }
            guard candidate != parent else { return }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

enum DirectQuicActivationConnectionSlot: String, Equatable {
    case outboundConnection
    case inboundConnection
}

nonisolated final class DirectQuicProbeController: @unchecked Sendable {
    private static let consentIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let liveAudioMaxConcurrentIncomingHandlers = 16
    static let liveAudioDatagramWaitsForProcessing = false
    private static let liveAudioIncomingHandlerExpirationNanoseconds: UInt64 = 2_000_000_000
    // Apple PTT activation can hold the first transmit/receive path for several
    // seconds. Keep the app-level consent watchdog longer than that activation
    // window so a warm Direct QUIC path is not torn down just before audio starts.
    private static let consentTimeoutSeconds: TimeInterval = 10

    private let queue = DispatchQueue(label: "Turbo.DirectQuicProbe")
    private let stateLock = NSLock()
    private let incomingAudioPayloadQueue: DirectQuicAudioPayloadAsyncQueue
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?

    private var listener: NWListener?
    private var inboundConnection: NWConnection?
    private var outboundConnection: NWConnection?
    private var activeMediaConnection: NWConnection?
    private var preparedOffer: DirectQuicPreparedLocalOffer?
    private var preparedDialerAttempt: DirectQuicPreparedDialerAttempt?
    private var activeReceiveBuffer = Data()
    private var verifiedPeerCertificateFingerprint: String?
    private var nominatedPath: DirectQuicNominatedPath?
    private var onIncomingAudioPayload: (@Sendable (DirectQuicIncomingAudioPayload) async -> Void)?
    private var onExpiredIncomingAudioPayload:
        (@Sendable (DirectQuicIncomingAudioPayload, UInt64, UInt64) async -> Void)?
    private var onReceiverPrewarmRequest: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)?
    private var onReceiverPrewarmAck: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)?
    private var onPathClosing: (@Sendable (DirectQuicPathClosingPayload) async -> Void)?
    private var onWarmPong: (@Sendable (String?) async -> Void)?
    private var onAudioPlaybackStarted: (@Sendable (TurboAudioPlaybackStartedPayload) async -> Void)?
    private var onLivenessConfirmed: (@Sendable (String) async -> Void)?
    private var onPathLost: (@Sendable (String) async -> Void)?
    private var suppressPathLostCallback = false
    private var remoteCandidateKeysAttempted: Set<String> = []
    private var remoteCandidateProbeInFlight = false
    private var consentTask: Task<Void, Never>?
    private var outstandingConsentID: String?
    private var outstandingConsentSentAt: Date?
    private var nextAudioSequenceNumber: UInt64 = 0
#if DEBUG
    private var testActivationOverride: (@Sendable () async throws -> Void)?
    private var testMediaTransportActivated = false
#endif

    init(
        incomingAudioMaxConcurrentHandlers: Int = DirectQuicProbeController
            .liveAudioMaxConcurrentIncomingHandlers,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.incomingAudioPayloadQueue = DirectQuicAudioPayloadAsyncQueue(
            maxConcurrentHandlers: incomingAudioMaxConcurrentHandlers
        )
        self.reportEvent = reportEvent
    }

    func prepareListenerOffer(
        attemptId: String,
        alpn: String = DirectQuicProtocol.mediaAlpn,
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedLocalOffer {
        let existingPreparedOffer: DirectQuicPreparedLocalOffer? = withLockedState { self.preparedOffer }
        if let existingPreparedOffer = existingPreparedOffer,
           existingPreparedOffer.attemptId == attemptId {
            return existingPreparedOffer
        }

        cancel(reason: "replacing-listener")

        let identityMaterial = try resolvedIdentityMaterial()
        let quicOptions = NWProtocolQUIC.Options(alpn: [alpn])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = DirectQuicMediaDatagramCodec.maximumDatagramFrameSize
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions,
            true
        )
        installPeerVerification(
            on: quicOptions.securityProtocolOptions,
            expectedPeerCertificateFingerprint: nil,
            role: "listener"
        )
        if let localIdentity = sec_identity_create(identityMaterial.identity) {
            sec_protocol_options_set_local_identity(
                quicOptions.securityProtocolOptions,
                localIdentity
            )
        }

        let parameters = NWParameters(quic: quicOptions)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleInboundConnection(connection)
        }

        let port = try await startListener(listener)
        let candidates = await localCandidates(
            localPort: port,
            stunServers: stunServers
        )
        let preparedOffer = DirectQuicPreparedLocalOffer(
            attemptId: attemptId,
            quicAlpn: alpn,
            localPort: port,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: candidates
        )

        withLockedState {
            self.listener = listener
            self.preparedOffer = preparedOffer
            self.verifiedPeerCertificateFingerprint = nil
            self.nominatedPath = nil
        }
        await report(
            "Prepared direct QUIC listener offer",
            metadata: [
                "attemptId": attemptId,
                "candidateCount": String(candidates.count),
                "port": String(port),
                "identityLabel": identityMaterial.label,
            ]
        )
        return preparedOffer
    }

    func connect(
        using offer: TurboDirectQuicOfferPayload,
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedDialerConnection {
        let viableCandidates = viableCandidates(from: offer.candidates)
        let identityMaterial = try resolvedIdentityMaterial()
        let localPort = try allocateLocalUDPPort()
        let localCandidates = await localCandidates(
            localPort: localPort,
            stunServers: stunServers
        )

        let previousOutboundConnection = withLockedState { () -> NWConnection? in
            let existing = outboundConnection
            outboundConnection = nil
            return existing
        }
        previousOutboundConnection?.cancel()
        withLockedState {
            preparedDialerAttempt = DirectQuicPreparedDialerAttempt(
                attemptId: offer.attemptId,
                quicAlpn: offer.quicAlpn,
                localPort: localPort,
                candidates: localCandidates
            )
            nominatedPath = nil
        }

        guard offer.quicAlpn == DirectQuicProtocol.mediaAlpn else {
            let reason = "unsupported direct QUIC media ALPN: \(offer.quicAlpn)"
            await report(
                "Rejected direct QUIC offer with unsupported media ALPN",
                metadata: [
                    "attemptId": offer.attemptId,
                    "quicAlpn": offer.quicAlpn,
                    "requiredAlpn": DirectQuicProtocol.mediaAlpn,
                ]
            )
            return DirectQuicPreparedDialerConnection(
                attemptId: offer.attemptId,
                certificateFingerprint: identityMaterial.certificateFingerprint,
                candidates: localCandidates,
                didEstablishPath: false,
                lastFailureReason: reason
            )
        }

        guard !viableCandidates.isEmpty else {
            await report(
                "Direct QUIC offer contained no viable initial candidate",
                metadata: [
                    "attemptId": offer.attemptId,
                    "localPort": String(localPort),
                    "localCandidateCount": String(localCandidates.count),
                ]
            )
            return DirectQuicPreparedDialerConnection(
                attemptId: offer.attemptId,
                certificateFingerprint: identityMaterial.certificateFingerprint,
                candidates: localCandidates,
                didEstablishPath: false,
                lastFailureReason: DirectQuicProbeError.noViableCandidate.localizedDescription
            )
        }

        var lastError: Error?
        for candidate in viableCandidates {
            let parameters = makeOutboundParameters(
                quicAlpn: offer.quicAlpn,
                expectedPeerCertificateFingerprint: offer.certificateFingerprint,
                identityMaterial: identityMaterial,
                localPort: localPort,
                remoteAddress: candidate.address
            )
            do {
                try await attemptOutboundProof(
                    to: candidate,
                    using: parameters,
                    attemptId: offer.attemptId,
                    role: "dialer",
                    localPort: localPort
                )
                await report(
                    "Direct QUIC probe connection established",
                    metadata: [
                        "attemptId": offer.attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "peerCertificateFingerprint": offer.certificateFingerprint,
                        "localPort": String(localPort),
                        "localCandidateCount": String(localCandidates.count),
                    ]
                )
                return DirectQuicPreparedDialerConnection(
                    attemptId: offer.attemptId,
                    certificateFingerprint: identityMaterial.certificateFingerprint,
                    candidates: localCandidates,
                    didEstablishPath: true,
                    lastFailureReason: nil
                )
            } catch {
                lastError = error
                await report(
                    "Direct QUIC probe candidate failed",
                    metadata: [
                        "attemptId": offer.attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        return DirectQuicPreparedDialerConnection(
            attemptId: offer.attemptId,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: localCandidates,
            didEstablishPath: false,
            lastFailureReason: lastError?.localizedDescription
                ?? DirectQuicProbeError.noViableCandidate.localizedDescription
        )
    }

    func prepareDialerAnswer(
        using offer: TurboDirectQuicOfferPayload,
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedDialerAnswer {
        let identityMaterial = try resolvedIdentityMaterial()
        guard offer.quicAlpn == DirectQuicProtocol.mediaAlpn else {
            throw DirectQuicProbeError.proofFailed("unsupported direct QUIC media ALPN: \(offer.quicAlpn)")
        }
        let localPort = try allocateLocalUDPPort()
        let localCandidates = await localCandidates(
            localPort: localPort,
            stunServers: stunServers
        )

        let previousOutboundConnection = withLockedState { () -> NWConnection? in
            let existing = outboundConnection
            outboundConnection = nil
            return existing
        }
        previousOutboundConnection?.cancel()
        withLockedState {
            preparedDialerAttempt = DirectQuicPreparedDialerAttempt(
                attemptId: offer.attemptId,
                quicAlpn: offer.quicAlpn,
                localPort: localPort,
                candidates: localCandidates
            )
            nominatedPath = nil
        }

        await report(
            "Prepared direct QUIC dialer answer",
            metadata: [
                "attemptId": offer.attemptId,
                "candidateCount": String(localCandidates.count),
                "localPort": String(localPort),
                "identityLabel": identityMaterial.label,
            ]
        )

        return DirectQuicPreparedDialerAnswer(
            attemptId: offer.attemptId,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: localCandidates
        )
    }

    func activateMediaTransport(
        onIncomingAudioPayload: @escaping @Sendable (DirectQuicIncomingAudioPayload) async -> Void,
        onExpiredIncomingAudioPayload:
            (@Sendable (DirectQuicIncomingAudioPayload, UInt64, UInt64) async -> Void)? = nil,
        onReceiverPrewarmRequest: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)? = nil,
        onReceiverPrewarmAck: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)? = nil,
        onPathClosing: (@Sendable (DirectQuicPathClosingPayload) async -> Void)? = nil,
        onWarmPong: (@Sendable (String?) async -> Void)? = nil,
        onAudioPlaybackStarted: (@Sendable (TurboAudioPlaybackStartedPayload) async -> Void)? = nil,
        onLivenessConfirmed: (@Sendable (String) async -> Void)? = nil,
        onPathLost: @escaping @Sendable (String) async -> Void
    ) async throws {
#if DEBUG
        let testActivationOverride = withLockedState { self.testActivationOverride }
        if let testActivationOverride {
            let reusedActiveTransport = withLockedState {
                guard testMediaTransportActivated else { return false }
                self.onIncomingAudioPayload = onIncomingAudioPayload
                self.onExpiredIncomingAudioPayload = onExpiredIncomingAudioPayload
                self.onReceiverPrewarmRequest = onReceiverPrewarmRequest
                self.onReceiverPrewarmAck = onReceiverPrewarmAck
                self.onPathClosing = onPathClosing
                self.onWarmPong = onWarmPong
                self.onAudioPlaybackStarted = onAudioPlaybackStarted
                self.onLivenessConfirmed = onLivenessConfirmed
                self.onPathLost = onPathLost
                return true
            }
            if reusedActiveTransport {
                await report(
                    "Reused active Direct QUIC media transport",
                    metadata: ["mode": "test"]
                )
                return
            }
            try await testActivationOverride()
            withLockedState {
                suppressPathLostCallback = false
                self.onIncomingAudioPayload = onIncomingAudioPayload
                self.onExpiredIncomingAudioPayload = onExpiredIncomingAudioPayload
                self.onReceiverPrewarmRequest = onReceiverPrewarmRequest
                self.onReceiverPrewarmAck = onReceiverPrewarmAck
                self.onPathClosing = onPathClosing
                self.onWarmPong = onWarmPong
                self.onAudioPlaybackStarted = onAudioPlaybackStarted
                self.onLivenessConfirmed = onLivenessConfirmed
                self.onPathLost = onPathLost
                activeReceiveBuffer.removeAll(keepingCapacity: false)
                outstandingConsentID = nil
                outstandingConsentSentAt = nil
                testMediaTransportActivated = true
            }
            incomingAudioPayloadQueue.reset()
            await report(
                "Activated direct QUIC media transport",
                metadata: ["mode": "test"]
            )
            return
        }
#endif
        let selectedConnection = withLockedState { () -> (
            connection: NWConnection?,
            slot: DirectQuicActivationConnectionSlot?,
            nominatedPathSource: DirectQuicNominatedPathSource?
        ) in
            let nominatedPathSource = nominatedPath?.source
            let slot = Self.activationConnectionSlot(
                nominatedPathSource: nominatedPathSource,
                outboundAvailable: outboundConnection != nil,
                inboundAvailable: inboundConnection != nil
            )
            switch slot {
            case .outboundConnection:
                return (outboundConnection, slot, nominatedPathSource)
            case .inboundConnection:
                return (inboundConnection, slot, nominatedPathSource)
            case nil:
                return (nil, nil, nominatedPathSource)
            }
        }
        guard let connection = selectedConnection.connection else {
            let source = selectedConnection.nominatedPathSource?.rawValue ?? "none"
            throw DirectQuicProbeError.connectionFailed(
                "no verified direct QUIC connection for nominated path source \(source)"
            )
        }

        let reusedActiveConnection = withLockedState {
            guard activeMediaConnection !== connection else {
                self.onIncomingAudioPayload = onIncomingAudioPayload
                self.onExpiredIncomingAudioPayload = onExpiredIncomingAudioPayload
                self.onReceiverPrewarmRequest = onReceiverPrewarmRequest
                self.onReceiverPrewarmAck = onReceiverPrewarmAck
                self.onPathClosing = onPathClosing
                self.onWarmPong = onWarmPong
                self.onAudioPlaybackStarted = onAudioPlaybackStarted
                self.onLivenessConfirmed = onLivenessConfirmed
                self.onPathLost = onPathLost
                return true
            }
            suppressPathLostCallback = false
            self.onIncomingAudioPayload = onIncomingAudioPayload
            self.onExpiredIncomingAudioPayload = onExpiredIncomingAudioPayload
            self.onReceiverPrewarmRequest = onReceiverPrewarmRequest
            self.onReceiverPrewarmAck = onReceiverPrewarmAck
            self.onPathClosing = onPathClosing
            self.onWarmPong = onWarmPong
            self.onAudioPlaybackStarted = onAudioPlaybackStarted
            self.onLivenessConfirmed = onLivenessConfirmed
            self.onPathLost = onPathLost
            activeMediaConnection = connection
            activeReceiveBuffer.removeAll(keepingCapacity: false)
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            return false
        }
        if reusedActiveConnection {
            await report(
                "Reused active Direct QUIC media transport",
                metadata: [
                    "connectionSlot": selectedConnection.slot?.rawValue ?? "none",
                    "nominatedPathSource": selectedConnection.nominatedPathSource?.rawValue ?? "none",
                ]
            )
            return
        }
        incomingAudioPayloadQueue.reset()
        receiveMediaMessages(on: connection)
        receiveMediaDatagrams(on: connection)
        startConsentLoop(on: connection)

        await report(
            "Activated direct QUIC media transport",
            metadata: [
                "connectionSlot": selectedConnection.slot?.rawValue ?? "none",
                "nominatedPathSource": selectedConnection.nominatedPathSource?.rawValue ?? "none",
            ]
        )
    }

    static func activationConnectionSlot(
        nominatedPathSource: DirectQuicNominatedPathSource?,
        outboundAvailable: Bool,
        inboundAvailable: Bool
    ) -> DirectQuicActivationConnectionSlot? {
        switch nominatedPathSource {
        case .outboundProbe:
            return outboundAvailable ? .outboundConnection : nil
        case .inboundConnection:
            return inboundAvailable ? .inboundConnection : nil
        case nil:
            if outboundAvailable { return .outboundConnection }
            if inboundAvailable { return .inboundConnection }
            return nil
        }
    }

    func sendAudioPayload(_ payload: String) async throws {
        let connection = withLockedState {
            activeMediaConnection ?? outboundConnection ?? inboundConnection
        }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("direct QUIC media path is unavailable")
        }
        let sequenceNumber = nextDirectAudioSequenceNumber()
        let sentAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let frame: DirectQuicMediaDatagramFrame
        if let binaryPacketPayload = VoiceAudioFramePayloadCodec.singleBinaryOpusPacketData(payload) {
            frame = .binaryPacketAudio(
                payload: binaryPacketPayload,
                sequenceNumber: sequenceNumber,
                sentAtMilliseconds: sentAtMilliseconds
            )
        } else {
            frame = .packetAudio(
                payload: payload,
                sequenceNumber: sequenceNumber,
                sentAtMilliseconds: sentAtMilliseconds
            )
        }
        try await sendLiveAudioDatagram(
            frame,
            on: connection,
            waitsForProcessing: Self.liveAudioDatagramWaitsForProcessing
        )
    }

    func sendReceiverPrewarmRequest(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .receiverPrewarmRequest(payload), on: connection)
    }

    func sendReceiverPrewarmAck(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .receiverPrewarmAck(payload), on: connection)
    }

    func sendAudioPlaybackStarted(_ payload: TurboAudioPlaybackStartedPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .audioPlaybackStarted(payload), on: connection)
    }

    func sendPathClosing(_ payload: DirectQuicPathClosingPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .pathClosing(payload), on: connection)
    }

    func beginIntentionalPathClose(
        _ payload: DirectQuicPathClosingPayload,
        metadata: [String: String],
        cancelReason: String
    ) {
        suppressPathLostForIntentionalClose()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendPathClosing(payload)
                await self.report(
                    "Direct QUIC path closing sent",
                    metadata: metadata
                )
            } catch {
                var failureMetadata = metadata
                failureMetadata["error"] = error.localizedDescription
                await self.report(
                    "Direct QUIC path closing send failed",
                    metadata: failureMetadata
                )
            }
            self.cancel(reason: cancelReason)
        }
    }

    func sendWarmPing(id: String) async throws {
        let connection = try activeControlConnection()
        try await send(message: .warmPing(id), on: connection)
    }

    func preparedLocalCandidates(matching attemptId: String) -> [TurboDirectQuicCandidate] {
        withLockedState {
            if let preparedOffer, preparedOffer.attemptId == attemptId {
                return preparedOffer.candidates
            }
            if let preparedDialerAttempt, preparedDialerAttempt.attemptId == attemptId {
                return preparedDialerAttempt.candidates
            }
            return []
        }
    }

    func nominatedPath(matching attemptId: String) -> DirectQuicNominatedPath? {
        withLockedState {
            guard let nominatedPath, nominatedPath.attemptId == attemptId else {
                return nil
            }
            return nominatedPath
        }
    }

#if DEBUG
    func installVerifiedNominatedPathForTesting(
        _ nominatedPath: DirectQuicNominatedPath,
        peerCertificateFingerprint: String,
        activationSucceeds: Bool = true
    ) {
        let normalizedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(peerCertificateFingerprint)
        withLockedState {
            self.nominatedPath = nominatedPath
            self.verifiedPeerCertificateFingerprint = normalizedPeerCertificateFingerprint
            self.testActivationOverride = {
                guard activationSucceeds else {
                    throw DirectQuicProbeError.connectionFailed("test activation failed")
                }
            }
        }
    }

    func injectIncomingAudioPayloadForTesting(_ incomingPayload: DirectQuicIncomingAudioPayload) {
        enqueueIncomingAudioPayload(incomingPayload)
    }
#endif

    private func enqueueIncomingAudioPayload(_ incomingPayload: DirectQuicIncomingAudioPayload) {
        let expirationNanoseconds = Self.liveAudioHandlerExpirationDeadline(
            receivedAtNanoseconds: incomingPayload.datagramReceivedAtNanoseconds,
            intervalNanoseconds: Self.liveAudioIncomingHandlerExpirationNanoseconds
        )
        let callbacks = withLockedState {
            (
                onIncomingAudioPayload: self.onIncomingAudioPayload,
                onExpiredIncomingAudioPayload: self.onExpiredIncomingAudioPayload
            )
        }
        incomingAudioPayloadQueue.enqueue(
            expiringAtNanoseconds: expirationNanoseconds,
            expiresRunningHandler: false,
            onExpired: { [weak self] in
                guard let self else { return }
                let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                let localQueueDelayNanoseconds =
                    nowNanoseconds >= incomingPayload.datagramReceivedAtNanoseconds
                    ? nowNanoseconds - incomingPayload.datagramReceivedAtNanoseconds
                    : 0
                if let onExpiredIncomingAudioPayload = callbacks.onExpiredIncomingAudioPayload {
                    await onExpiredIncomingAudioPayload(
                        incomingPayload,
                        localQueueDelayNanoseconds,
                        Self.liveAudioIncomingHandlerExpirationNanoseconds
                    )
                    return
                }
                await self.report(
                    "Dropped expired Direct QUIC incoming audio payload before app handler",
                    metadata: [
                        "directQuicSequenceNumber": incomingPayload.sequenceNumber.map(String.init) ?? "none",
                        "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                        "thresholdMs": String(Self.liveAudioIncomingHandlerExpirationNanoseconds / 1_000_000),
                    ]
                )
            }
        ) {
            await callbacks.onIncomingAudioPayload?(incomingPayload)
        }
    }

    private static func liveAudioHandlerExpirationDeadline(
        receivedAtNanoseconds: UInt64,
        intervalNanoseconds: UInt64
    ) -> UInt64? {
        guard intervalNanoseconds > 0 else { return nil }
        let (deadline, overflow) = receivedAtNanoseconds.addingReportingOverflow(intervalNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    func cancel(reason: String) {
        let resources = withLockedState { () -> (NWListener?, NWConnection?, NWConnection?, Task<Void, Never>?) in
            suppressPathLostCallback = true
            onIncomingAudioPayload = nil
            onExpiredIncomingAudioPayload = nil
            onReceiverPrewarmRequest = nil
            onReceiverPrewarmAck = nil
            onPathClosing = nil
            onWarmPong = nil
            onAudioPlaybackStarted = nil
            onLivenessConfirmed = nil
            onPathLost = nil
            activeMediaConnection = nil
            activeReceiveBuffer.removeAll(keepingCapacity: false)
            verifiedPeerCertificateFingerprint = nil
            nominatedPath = nil
            remoteCandidateKeysAttempted = []
            remoteCandidateProbeInFlight = false
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
#if DEBUG
            testActivationOverride = nil
            testMediaTransportActivated = false
#endif
            let resources = (listener, inboundConnection, outboundConnection, consentTask)
            listener = nil
            inboundConnection = nil
            outboundConnection = nil
            preparedOffer = nil
            preparedDialerAttempt = nil
            consentTask = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.cancel()
        resources.2?.cancel()
        resources.3?.cancel()
        incomingAudioPayloadQueue.reset()
        Task {
            await report("Cancelled direct QUIC probe resources", metadata: ["reason": reason])
        }
    }

    func resetIncomingAudioPayloadQueue(reason: String) {
        incomingAudioPayloadQueue.reset()
        Task {
            await report(
                "Reset Direct QUIC incoming audio payload queue",
                metadata: ["reason": reason]
            )
        }
    }

    private func suppressPathLostForIntentionalClose() {
        let consentTask = withLockedState { () -> Task<Void, Never>? in
            suppressPathLostCallback = true
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            let task = self.consentTask
            self.consentTask = nil
            return task
        }
        consentTask?.cancel()
    }

    func verifyConnectedPeerCertificateFingerprint(
        _ expectedPeerCertificateFingerprint: String
    ) throws {
        let normalizedExpectedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
        let verifiedPeerCertificateFingerprint = withLockedState {
            self.verifiedPeerCertificateFingerprint
        }
        guard let verifiedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint was unavailable"
            )
        }
        let normalizedVerifiedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(verifiedPeerCertificateFingerprint)
        guard normalizedVerifiedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint mismatch"
            )
        }
    }

    func verifyConnectedPeerCertificateFingerprintIfAvailable(
        _ expectedPeerCertificateFingerprint: String
    ) throws -> Bool {
        let normalizedExpectedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
        let verifiedPeerCertificateFingerprint = withLockedState {
            self.verifiedPeerCertificateFingerprint
        }
        guard let verifiedPeerCertificateFingerprint else {
            return false
        }
        let normalizedVerifiedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(verifiedPeerCertificateFingerprint)
        guard normalizedVerifiedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint mismatch"
            )
        }
        return true
    }

    func probeRemoteCandidatesIfNeeded(
        attemptId: String,
        expectedPeerCertificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate]
    ) async throws -> DirectQuicCandidateProbeOutcome {
        let viableCandidates = viableCandidates(from: candidates)
        if try verifyConnectedPeerCertificateFingerprintIfAvailable(
            expectedPeerCertificateFingerprint
        ) {
            return DirectQuicCandidateProbeOutcome(
                disposition: .alreadyConnected,
                inputCandidateCount: candidates.count,
                viableCandidateCount: viableCandidates.count,
                newlyAttemptedCandidateCount: 0,
                lastErrorDescription: nil
            )
        }

        enum LocalProbeContext {
            case listener(DirectQuicPreparedLocalOffer)
            case dialer(DirectQuicPreparedDialerAttempt)

            var quicAlpn: String {
                switch self {
                case .listener(let offer):
                    return offer.quicAlpn
                case .dialer(let attempt):
                    return attempt.quicAlpn
                }
            }

            var localPort: UInt16 {
                switch self {
                case .listener(let offer):
                    return offer.localPort
                case .dialer(let attempt):
                    return attempt.localPort
                }
            }
        }

        let localProbeContext = withLockedState { () -> LocalProbeContext? in
            if let preparedOffer, preparedOffer.attemptId == attemptId {
                return .listener(preparedOffer)
            }
            if let preparedDialerAttempt, preparedDialerAttempt.attemptId == attemptId {
                return .dialer(preparedDialerAttempt)
            }
            return nil
        }
        guard let localProbeContext else {
            throw DirectQuicProbeError.connectionFailed(
                "direct QUIC local probe context is unavailable for candidate probing"
            )
        }

        let selection = withLockedState { () -> DirectQuicCandidateProbeSelection in
            let attemptedCandidateKeys = remoteCandidateKeysAttempted
            let selection = Self.selectCandidatesForProbeBatch(
                inputCandidates: candidates,
                attemptedCandidateKeys: attemptedCandidateKeys,
                probeInFlight: remoteCandidateProbeInFlight
            )
            if case .ready(let filteredCandidates, _) = selection {
                remoteCandidateProbeInFlight = true
                for candidate in filteredCandidates {
                    remoteCandidateKeysAttempted.insert(Self.candidateKey(candidate))
                }
            }
            return selection
        }
        let candidatesToProbe: [TurboDirectQuicCandidate]
        let viableCandidateCount: Int
        switch selection {
        case .immediate(let outcome):
            return outcome
        case .ready(let filteredCandidates, let selectionViableCandidateCount):
            candidatesToProbe = filteredCandidates
            viableCandidateCount = selectionViableCandidateCount
        }

        defer {
            withLockedState {
                remoteCandidateProbeInFlight = false
            }
        }

        let identityMaterial = try resolvedIdentityMaterial()
        var lastError: Error?
        for candidate in candidatesToProbe {
            if try verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) {
                return DirectQuicCandidateProbeOutcome(
                    disposition: .alreadyConnected,
                    inputCandidateCount: candidates.count,
                    viableCandidateCount: viableCandidateCount,
                    newlyAttemptedCandidateCount: candidatesToProbe.count,
                    lastErrorDescription: nil
                )
            }

            let parameters = makeOutboundParameters(
                quicAlpn: localProbeContext.quicAlpn,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                identityMaterial: identityMaterial,
                localPort: localProbeContext.localPort,
                remoteAddress: candidate.address
            )
            do {
                try await attemptOutboundProof(
                    to: candidate,
                    using: parameters,
                    attemptId: attemptId,
                    role: "listener-probe",
                    localPort: localProbeContext.localPort
                )
                await report(
                    "Direct QUIC candidate probe connection established",
                    metadata: [
                        "attemptId": attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                        "localPort": String(localProbeContext.localPort),
                    ]
                )
                return DirectQuicCandidateProbeOutcome(
                    disposition: .pathEstablished,
                    inputCandidateCount: candidates.count,
                    viableCandidateCount: viableCandidateCount,
                    newlyAttemptedCandidateCount: candidatesToProbe.count,
                    lastErrorDescription: nil
                )
            } catch {
                lastError = error
                await report(
                    "Direct QUIC candidate probe failed",
                    metadata: [
                        "attemptId": attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        if let lastError {
            await report(
                "Direct QUIC candidate probe batch exhausted",
                metadata: [
                    "attemptId": attemptId,
                    "candidateCount": String(candidatesToProbe.count),
                    "error": lastError.localizedDescription,
                ]
            )
        }
        return DirectQuicCandidateProbeOutcome(
            disposition: .batchExhausted,
            inputCandidateCount: candidates.count,
            viableCandidateCount: viableCandidateCount,
            newlyAttemptedCandidateCount: candidatesToProbe.count,
            lastErrorDescription: lastError?.localizedDescription
        )
    }

    private func viableCandidates(
        from candidates: [TurboDirectQuicCandidate]
    ) -> [TurboDirectQuicCandidate] {
        Self.viableProbeCandidates(from: candidates)
    }

    private func localCandidates(
        localPort: UInt16,
        stunServers: [TurboDirectQuicStunServer]
    ) async -> [TurboDirectQuicCandidate] {
        let hostCandidates = DirectQuicHostCandidateGatherer.gatherCandidates(port: localPort)
        let stunCandidates = await DirectQuicStunClient().gatherServerReflexiveCandidates(
            localPort: localPort,
            servers: stunServers
        )
        return hostCandidates + stunCandidates
    }

    private func allocateLocalUDPPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("socket() returned \(errno)")
        }
        defer { close(descriptor) }

        var value: Int32 = 1
        if setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            throw DirectQuicProbeError.localPortAllocationFailed("setsockopt() returned \(errno)")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(
                    descriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.stride)
                )
            }
        }
        guard bindResult == 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("bind() returned \(errno)")
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("getsockname() returned \(errno)")
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func attemptOutboundProof(
        to candidate: TurboDirectQuicCandidate,
        using parameters: NWParameters,
        attemptId: String,
        role: String,
        localPort: UInt16
    ) async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(candidate.port)) else {
            throw DirectQuicProbeError.noViableCandidate
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(candidate.address),
            port: port,
            using: parameters
        )
        withLockedState {
            outboundConnection = connection
            verifiedPeerCertificateFingerprint = nil
        }

        do {
            try await startConnection(
                connection,
                metadata: [
                    "attemptId": attemptId,
                    "address": candidate.address,
                    "port": String(candidate.port),
                    "kind": candidate.kind.rawValue,
                    "role": role,
                ]
            )
            try await send(message: .probeHello, on: connection)
            let acknowledgement = try await receiveNextMessage(
                on: connection,
                errorPrefix: "expected direct QUIC probe acknowledgement"
            )
            guard acknowledgement.kind == .probeAck else {
                throw DirectQuicProbeError.proofFailed(
                    "expected direct QUIC probe acknowledgement: received \(acknowledgement.kind.rawValue)"
                )
            }
            withLockedState {
                nominatedPath = DirectQuicNominatedPath(
                    attemptId: attemptId,
                    source: .outboundProbe,
                    localPort: localPort,
                    remoteAddress: candidate.address,
                    remotePort: candidate.port,
                    remoteCandidateKind: candidate.kind
                )
            }
        } catch {
            withLockedState {
                if outboundConnection === connection {
                    outboundConnection = nil
                }
            }
            connection.cancel()
            throw error
        }
    }

    private func handleInboundConnection(_ connection: NWConnection) {
        let previousConnection = withLockedState { () -> NWConnection? in
            let previousConnection = inboundConnection
            inboundConnection = connection
            return previousConnection
        }
        previousConnection?.cancel()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task {
                    await self.report("Accepted direct QUIC inbound connection", metadata: [:])
                }
                self.receiveInboundProbe(on: connection)
            case .failed(let error):
                self.reportConnectionFailure(
                    connection: connection,
                    role: "inbound",
                    message: error.localizedDescription
                )
            case .cancelled:
                self.reportConnectionFailure(
                    connection: connection,
                    role: "inbound",
                    message: "cancelled"
                )
            case .waiting, .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveInboundProbe(on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.receiveNextMessage(
                    on: connection,
                    errorPrefix: "expected direct QUIC probe hello"
                )
                guard message.kind == .probeHello else {
                    await self.report(
                        "Ignored unexpected direct QUIC inbound proof payload",
                        metadata: ["kind": message.kind.rawValue]
                    )
                    return
                }

                try await self.send(message: .probeAck, on: connection)
                self.recordInboundNominationIfPossible(on: connection)
                await self.report(
                    "Direct QUIC inbound proof acknowledged",
                    metadata: [:]
                )
            } catch {
                await self.report(
                    "Direct QUIC inbound proof receive failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func startListener(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let gate = ContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        gate.resume {
                            continuation.resume(
                                throwing: DirectQuicProbeError.listenerFailed("listener started without a port")
                            )
                        }
                        return
                    }
                    gate.resume {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.listenerFailed(error.localizedDescription)
                        )
                    }
                case .cancelled:
                    gate.resume {
                        continuation.resume(throwing: DirectQuicProbeError.listenerCancelled)
                    }
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func startConnection(
        _ connection: NWConnection,
        metadata: [String: String]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    gate.resume {
                        continuation.resume()
                    }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed(error.localizedDescription)
                        )
                    }
                    self?.reportConnectionFailure(
                        connection: connection,
                        role: metadata["role"] ?? "outbound",
                        message: error.localizedDescription
                    )
                case .cancelled:
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed("cancelled")
                        )
                    }
                    self?.reportConnectionFailure(
                        connection: connection,
                        role: metadata["role"] ?? "outbound",
                        message: "cancelled"
                    )
                case .waiting(let error):
                    Task {
                        await self?.report(
                            "Direct QUIC outbound connection waiting",
                            metadata: metadata.merging(
                                ["error": error.localizedDescription],
                                uniquingKeysWith: { _, new in new }
                            )
                        )
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(
        message: DirectQuicWireMessage,
        on connection: NWConnection
    ) async throws {
        let content = try DirectQuicWireCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func sendLiveAudioDatagram(
        _ frame: DirectQuicMediaDatagramFrame,
        on connection: NWConnection,
        waitsForProcessing: Bool
    ) async throws {
        let content = try DirectQuicMediaDatagramCodec.encode(frame)
        let maximumSize = connection.maximumDatagramSize
        guard maximumSize <= 0 || content.count <= maximumSize else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC datagram exceeded path maximum: \(content.count) > \(maximumSize)"
            )
        }
        guard waitsForProcessing else {
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .idempotent
            )
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func activeControlConnection() throws -> NWConnection {
        let connection = withLockedState {
            activeMediaConnection ?? outboundConnection ?? inboundConnection
        }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("direct QUIC control path is unavailable")
        }
        return connection
    }

    private func receiveNextMessage(
        on connection: NWConnection,
        errorPrefix: String
    ) async throws -> DirectQuicWireMessage {
        var buffer = Data()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DirectQuicWireMessage, Error>) in
            func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                        return
                    }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        do {
                            let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)
                            if let decoded = decoded.first {
                                continuation.resume(returning: decoded)
                                return
                            }
                        } catch {
                            continuation.resume(
                                throwing: DirectQuicProbeError.proofFailed("\(errorPrefix): \(error.localizedDescription)")
                            )
                            return
                        }
                    }
                    if isComplete {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed("\(errorPrefix): empty response")
                        )
                        return
                    }
                    receiveNextChunk()
                }
            }
            receiveNextChunk()
        }
    }

    private func receiveMediaMessages(on connection: NWConnection) {
        guard withLockedState({ activeMediaConnection === connection }) else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                Task {
                    await self.report(
                        "Direct QUIC control receive failed; keeping packet media path active",
                        metadata: ["error": error.localizedDescription]
                    )
                }
                return
            }

            if let data, !data.isEmpty {
                let decodeResult = withLockedState { () -> Result<[DirectQuicWireMessage], Error> in
                    self.activeReceiveBuffer.append(data)
                    do {
                        return .success(
                            try DirectQuicWireCodec.decodeAvailable(from: &self.activeReceiveBuffer)
                        )
                    } catch {
                        return .failure(error)
                    }
                }
                switch decodeResult {
                case .success(let decodedMessages):
                    self.handleMediaControlMessages(decodedMessages, on: connection)
                case .failure(let error):
                    Task {
                        await self.report(
                            "Direct QUIC media framing decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                    self.notifyPathLostIfNeeded(
                        for: connection,
                        reason: "invalid-media-frame"
                    )
                    return
                }
            }

            if isComplete {
                Task {
                    await self.report(
                        "Direct QUIC control stream completed; keeping packet media path active",
                        metadata: [:]
                    )
                }
                return
            }

            self.receiveMediaMessages(on: connection)
        }
    }

    private func receiveMediaDatagrams(on connection: NWConnection) {
        guard withLockedState({ activeMediaConnection === connection }) else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            let datagramReceivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

            if let error {
                Task {
                    await self.report(
                        "Direct QUIC datagram receive failed",
                        metadata: ["error": error.localizedDescription]
                    )
                }
                self.notifyPathLostIfNeeded(
                    for: connection,
                    reason: error.localizedDescription
                )
                return
            }

            if let data, !data.isEmpty {
                do {
                    let decoded = try DirectQuicMediaMessageCodec.decode(data)
                    switch decoded {
                    case .packet(.packetAudio(let payload, let sequenceNumber, let sentAtMilliseconds)):
                        self.notifyLivenessConfirmed("packet-audio-received")
                        let incomingPayload = DirectQuicIncomingAudioPayload(
                            payload: payload,
                            datagramReceivedAtNanoseconds: datagramReceivedAtNanoseconds,
                            sequenceNumber: sequenceNumber,
                            sentAtMilliseconds: sentAtMilliseconds
                        )
                        self.enqueueIncomingAudioPayload(incomingPayload)
                    case .packet(.binaryPacketAudio(let payload, let sequenceNumber, let sentAtMilliseconds)):
                        self.notifyLivenessConfirmed("binary-packet-audio-received")
                        let incomingPayload = DirectQuicIncomingAudioPayload(
                            payload: VoiceAudioFramePayloadCodec.encodeBinaryOpusData(payload),
                            datagramReceivedAtNanoseconds: datagramReceivedAtNanoseconds,
                            sequenceNumber: sequenceNumber,
                            sentAtMilliseconds: sentAtMilliseconds
                        )
                        self.enqueueIncomingAudioPayload(incomingPayload)
                    case .control(let messages):
                        Task {
                            await self.report(
                                "Direct QUIC control payload received on message path",
                                metadata: ["messageCount": String(messages.count)]
                            )
                        }
                        self.handleMediaControlMessages(messages, on: connection)
                    }
                } catch {
                    Task {
                        await self.report(
                            "Direct QUIC datagram decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }

            self.receiveMediaDatagrams(on: connection)
        }
    }

    private func handleMediaControlMessages(
        _ decodedMessages: [DirectQuicWireMessage],
        on connection: NWConnection
    ) {
        for decodedMessage in decodedMessages {
            switch decodedMessage.kind {
            case .probeHello:
                Task {
                    do {
                        try await self.send(message: .probeAck, on: connection)
                    } catch {
                        await self.report(
                            "Direct QUIC media probe acknowledgement failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .probeAck:
                Task {
                    await self.report(
                        "Ignored unexpected direct QUIC media control payload",
                        metadata: ["kind": decodedMessage.kind.rawValue]
                    )
                }
            case .consentPing:
                let consentID = decodedMessage.payload
                Task {
                    do {
                        try await self.send(message: .consentAck(consentID), on: connection)
                    } catch {
                        await self.report(
                            "Direct QUIC consent acknowledgement failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .consentAck:
                self.withLockedState {
                    guard self.outstandingConsentID == decodedMessage.payload else { return }
                    self.outstandingConsentID = nil
                    self.outstandingConsentSentAt = nil
                }
                notifyLivenessConfirmed("consent-ack")
            case .receiverPrewarmRequest:
                do {
                    let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(decodedMessage.payload)
                    let onReceiverPrewarmRequest = self.withLockedState { self.onReceiverPrewarmRequest }
                    Task {
                        await onReceiverPrewarmRequest?(payload)
                    }
                } catch {
                    Task {
                        await self.report(
                            "Direct QUIC receiver prewarm request decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .receiverPrewarmAck:
                do {
                    let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(decodedMessage.payload)
                    let onReceiverPrewarmAck = self.withLockedState { self.onReceiverPrewarmAck }
                    Task {
                        await onReceiverPrewarmAck?(payload)
                    }
                } catch {
                    Task {
                        await self.report(
                            "Direct QUIC receiver prewarm ack decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .pathClosing:
                do {
                    let payload = try DirectQuicPathClosingPayloadCodec.decode(decodedMessage.payload)
                    let onPathClosing = self.withLockedState {
                        self.suppressPathLostCallback = true
                        self.outstandingConsentID = nil
                        self.outstandingConsentSentAt = nil
                        let task = self.consentTask
                        self.consentTask = nil
                        task?.cancel()
                        return self.onPathClosing
                    }
                    Task {
                        await onPathClosing?(payload)
                    }
                } catch {
                    Task {
                        await self.report(
                            "Direct QUIC path closing decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .warmPing:
                let pingID = decodedMessage.payload
                Task {
                    do {
                        try await self.send(message: .warmPong(pingID), on: connection)
                    } catch {
                        await self.report(
                            "Direct QUIC warm pong failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            case .warmPong:
                let onWarmPong = self.withLockedState { self.onWarmPong }
                notifyLivenessConfirmed("warm-pong")
                Task {
                    await onWarmPong?(decodedMessage.payload)
                }
            case .audioPlaybackStarted:
                do {
                    guard let encodedPayload = decodedMessage.payload else {
                        throw TurboAudioPlaybackStartedPayloadError.invalidJSON("missing payload")
                    }
                    let payload = try TurboAudioPlaybackStartedPayloadCodec.decode(encodedPayload)
                    let onAudioPlaybackStarted = self.withLockedState { self.onAudioPlaybackStarted }
                    Task {
                        await onAudioPlaybackStarted?(payload)
                    }
                } catch {
                    Task {
                        await self.report(
                            "Direct QUIC audio playback ACK decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }
        }
    }

    private func notifyLivenessConfirmed(_ reason: String) {
        let handler = withLockedState { onLivenessConfirmed }
        guard let handler else { return }
        Task {
            await handler(reason)
        }
    }

    private func nextDirectAudioSequenceNumber() -> UInt64 {
        withLockedState {
            let sequenceNumber = nextAudioSequenceNumber
            nextAudioSequenceNumber &+= 1
            return sequenceNumber
        }
    }

    private func notifyPathLostIfNeeded(
        for connection: NWConnection,
        reason: String
    ) {
        let pathLostHandler = withLockedState { () -> (((@Sendable (String) async -> Void)?, Task<Void, Never>?)?) in
            guard !suppressPathLostCallback else { return nil }
            guard activeMediaConnection === connection else { return nil }
            suppressPathLostCallback = true
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            let task = consentTask
            consentTask = nil
            return (onPathLost, task)
        }
        guard let (handler, task) = pathLostHandler else { return }
        task?.cancel()
        guard let handler else { return }
        Task {
            await handler(reason)
        }
    }

    private func reportConnectionFailure(
        connection: NWConnection,
        role: String,
        message: String
    ) {
        Task {
            await report(
                "Direct QUIC \(role) connection failed",
                metadata: ["error": message]
            )
        }
        notifyPathLostIfNeeded(for: connection, reason: message)
    }

    private func resolvedIdentityLabel() throws -> String {
        guard let label = DirectQuicIdentityConfiguration.resolvedLabel(), !label.isEmpty else {
            throw DirectQuicProbeError.identityLabelMissing
        }
        return label
    }

    private func resolvedIdentityMaterial() throws -> DirectQuicIdentityMaterial {
        let label = try resolvedIdentityLabel()
        if let productionIdentity = DirectQuicProductionIdentityManager.existingIdentity(label: label) {
            return DirectQuicIdentityMaterial(
                label: label,
                identity: productionIdentity.identity,
                certificateFingerprint: productionIdentity.certificateFingerprint,
                source: .production
            )
        }
        let identity = try Self.loadDebugIdentity(label: label)
        let certificateFingerprint = try Self.fingerprint(for: identity)
        return DirectQuicIdentityMaterial(
            label: label,
            identity: identity,
            certificateFingerprint: certificateFingerprint,
            source: .debugP12
        )
    }

    private static func loadDebugIdentity(label: String) throws -> SecIdentity {
        do {
            return try DirectQuicIdentityConfiguration.loadIdentity(label: label)
        } catch DirectQuicProbeError.identityNotFound {
            if let fingerprint = DirectQuicIdentityConfiguration.selectedInstalledIdentityFingerprint(),
               let installedIdentity = DirectQuicIdentityConfiguration.loadInstalledIdentityMatchingFingerprint(
                    fingerprint
               ) {
                return installedIdentity
            }
            throw DirectQuicProbeError.identityNotFound(label)
        } catch {
            throw error
        }
    }

    private static func fingerprint(for identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DirectQuicProbeError.certificateMissing
        }
        return try fingerprint(for: certificate)
    }

    private static func fingerprint(for certificate: SecCertificate) throws -> String {
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard !certificateData.isEmpty else {
            throw DirectQuicProbeError.fingerprintEncodingFailed
        }
        let digest = SHA256.hash(data: certificateData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    private static func normalizedCertificateFingerprint(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func peerCertificateFingerprint(
        metadata: sec_protocol_metadata_t
    ) -> String? {
        var leafCertificate: SecCertificate?
        let didAccessCertificates = sec_protocol_metadata_access_peer_certificate_chain(metadata) {
            certificate in
            guard leafCertificate == nil else { return }
            leafCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
        }
        guard didAccessCertificates, let leafCertificate else { return nil }
        return try? fingerprint(for: leafCertificate)
    }

    private func installPeerVerification(
        on options: sec_protocol_options_t,
        expectedPeerCertificateFingerprint: String?,
        role: String
    ) {
        sec_protocol_options_set_verify_block(
            options,
            { [weak self] metadata, _, complete in
                guard let self else {
                    complete(false)
                    return
                }
                guard let peerCertificateFingerprint = Self.peerCertificateFingerprint(metadata: metadata) else {
                    Task {
                        await self.report(
                            "Direct QUIC peer certificate fingerprint unavailable",
                            metadata: ["role": role]
                        )
                    }
                    complete(false)
                    return
                }
                let normalizedPeerCertificateFingerprint =
                    Self.normalizedCertificateFingerprint(peerCertificateFingerprint)
                self.withLockedState {
                    self.verifiedPeerCertificateFingerprint = normalizedPeerCertificateFingerprint
                }

                if let expectedPeerCertificateFingerprint {
                    let normalizedExpectedPeerCertificateFingerprint =
                        Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
                    guard normalizedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
                        Task {
                            await self.report(
                                "Direct QUIC peer certificate fingerprint mismatch",
                                metadata: [
                                    "role": role,
                                    "expectedPeerCertificateFingerprint": normalizedExpectedPeerCertificateFingerprint,
                                    "actualPeerCertificateFingerprint": normalizedPeerCertificateFingerprint,
                                ]
                            )
                        }
                        complete(false)
                        return
                    }
                }

                Task {
                    await self.report(
                        "Direct QUIC peer certificate verified",
                        metadata: [
                            "role": role,
                            "peerCertificateFingerprint": normalizedPeerCertificateFingerprint,
                        ]
                    )
                }
                complete(true)
            },
            queue
        )
    }

    private func report(
        _ message: String,
        metadata: [String: String]
    ) async {
        await reportEvent?(message, metadata)
    }

    private func makeOutboundParameters(
        quicAlpn: String,
        expectedPeerCertificateFingerprint: String,
        identityMaterial: DirectQuicIdentityMaterial,
        localPort: UInt16,
        remoteAddress: String? = nil
    ) -> NWParameters {
        let quicOptions = NWProtocolQUIC.Options(alpn: [quicAlpn])
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = DirectQuicMediaDatagramCodec.maximumDatagramFrameSize
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv13
        )
        installPeerVerification(
            on: quicOptions.securityProtocolOptions,
            expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
            role: "dialer"
        )
        if let localIdentity = sec_identity_create(identityMaterial.identity) {
            sec_protocol_options_set_local_identity(
                quicOptions.securityProtocolOptions,
                localIdentity
            )
        }

        let parameters = NWParameters(quic: quicOptions)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        let localHost = remoteAddress.map(Self.isIPv6Address) == true ? "::" : "0.0.0.0"
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(localHost),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any
        )
        return parameters
    }

    static func candidateKey(_ candidate: TurboDirectQuicCandidate) -> String {
        [
            candidate.kind.rawValue,
            candidate.transport.lowercased(),
            candidate.address.lowercased(),
            String(candidate.port),
            candidate.relatedAddress?.lowercased() ?? "",
            candidate.relatedPort.map(String.init) ?? "",
            candidate.foundation,
        ].joined(separator: "|")
    }

    static func selectCandidatesForProbeBatch(
        inputCandidates: [TurboDirectQuicCandidate],
        attemptedCandidateKeys: Set<String>,
        probeInFlight: Bool
    ) -> DirectQuicCandidateProbeSelection {
        let viableCandidates = viableProbeCandidates(from: inputCandidates)

        if probeInFlight {
            return .immediate(
                DirectQuicCandidateProbeOutcome(
                    disposition: .probeAlreadyInFlight,
                    inputCandidateCount: inputCandidates.count,
                    viableCandidateCount: viableCandidates.count,
                    newlyAttemptedCandidateCount: 0,
                    lastErrorDescription: nil
                )
            )
        }

        let filteredCandidates = viableCandidates.filter {
            !attemptedCandidateKeys.contains(candidateKey($0))
        }
        if filteredCandidates.isEmpty {
            return .immediate(
                DirectQuicCandidateProbeOutcome(
                    disposition: viableCandidates.isEmpty ? .noViableCandidates : .noNewCandidates,
                    inputCandidateCount: inputCandidates.count,
                    viableCandidateCount: viableCandidates.count,
                    newlyAttemptedCandidateCount: 0,
                    lastErrorDescription: nil
                )
            )
        }

        return .ready(filteredCandidates, viableCandidateCount: viableCandidates.count)
    }

    private static func viableProbeCandidates(
        from candidates: [TurboDirectQuicCandidate]
    ) -> [TurboDirectQuicCandidate] {
        candidates
            .filter {
                ($0.kind == .host || $0.kind == .serverReflexive)
                    && $0.transport.caseInsensitiveCompare("udp") == .orderedSame
                    && $0.port > 0
                    && $0.port <= Int(UInt16.max)
                    && !isIPv6LoopbackOrLinkLocal($0.address)
            }
            .sorted { lhs, rhs in
                let lhsRank = candidateSortRank(lhs)
                let rhsRank = candidateSortRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.priority > rhs.priority
            }
    }

    private static func candidateSortRank(_ candidate: TurboDirectQuicCandidate) -> Int {
        switch candidate.kind {
        case .host where isPrivateOrLoopbackIPv4Address(candidate.address):
            return 0
        case .host where isGlobalIPv6Address(candidate.address):
            return 1
        case .host:
            return 2
        case .serverReflexive where isIPv6Address(candidate.address):
            return 3
        case .serverReflexive:
            return 4
        case .relay:
            return 5
        }
    }

    private static func isIPv6Address(_ address: String) -> Bool {
        address.contains(":")
    }

    private static func isGlobalIPv6Address(_ address: String) -> Bool {
        isIPv6Address(address) && !isIPv6LoopbackOrLinkLocal(address)
    }

    private static func isIPv6LoopbackOrLinkLocal(_ address: String) -> Bool {
        let normalized = address.lowercased()
        return normalized == "::1"
            || normalized.hasPrefix("fe80:")
            || normalized.hasPrefix("fe80::")
    }

    private static func isPrivateOrLoopbackIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let first = parts[0]
        let second = parts[1]
        return first == 10
            || first == 127
            || (first == 172 && (16 ... 31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    private func startConsentLoop(on connection: NWConnection) {
        let task = Task { [weak self] in
            guard let self else { return }

            enum ConsentAction {
                case send(String)
                case wait
                case fail(String)
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.consentIntervalNanoseconds)
                guard !Task.isCancelled else { return }

                let action = self.withLockedState { () -> ConsentAction in
                    guard !self.suppressPathLostCallback, self.activeMediaConnection === connection else {
                        return .wait
                    }
                    if self.outstandingConsentID != nil,
                       let outstandingConsentSentAt = self.outstandingConsentSentAt,
                       Date().timeIntervalSince(outstandingConsentSentAt) > Self.consentTimeoutSeconds {
                        self.outstandingConsentID = nil
                        self.outstandingConsentSentAt = nil
                        return .fail("consent-timeout")
                    }
                    guard self.outstandingConsentID == nil else {
                        return .wait
                    }
                    let consentID = UUID().uuidString.lowercased()
                    self.outstandingConsentID = consentID
                    self.outstandingConsentSentAt = Date()
                    return .send(consentID)
                }

                switch action {
                case .wait:
                    continue
                case .send(let consentID):
                    do {
                        try await self.send(message: .consentPing(consentID), on: connection)
                    } catch {
                        await self.report(
                            "Direct QUIC consent ping failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        self.notifyPathLostIfNeeded(
                            for: connection,
                            reason: "consent-send-failed"
                        )
                        return
                    }
                case .fail(let reason):
                    await self.report(
                        "Direct QUIC consent timed out",
                        metadata: ["reason": reason]
                    )
                    self.notifyPathLostIfNeeded(for: connection, reason: reason)
                    return
                }
            }
        }

        let previousTask = withLockedState { () -> Task<Void, Never>? in
            let previousTask = consentTask
            consentTask = task
            return previousTask
        }
        previousTask?.cancel()
    }

    private func recordInboundNominationIfPossible(on connection: NWConnection) {
        guard let endpoint = Self.endpointAddressAndPort(for: connection.endpoint) else {
            return
        }
        withLockedState {
            guard let preparedOffer else { return }
            nominatedPath = DirectQuicNominatedPath(
                attemptId: preparedOffer.attemptId,
                source: .inboundConnection,
                localPort: preparedOffer.localPort,
                remoteAddress: endpoint.address,
                remotePort: endpoint.port,
                remoteCandidateKind: nil
            )
        }
    }

    private static func endpointAddressAndPort(
        for endpoint: NWEndpoint
    ) -> (address: String, port: Int)? {
        guard case .hostPort(let host, let port) = endpoint else {
            return nil
        }
        return (String(describing: host), Int(port.rawValue))
    }

    private func withLockedState<T>(
        _ operation: () -> T
    ) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}
