import Darwin
import Dispatch
import Foundation
import TurboOpus

nonisolated enum VoiceMediaPayloadFormat: String, Equatable, Sendable {
    case legacyPCM = "legacy-pcm"
    case opusV2 = "opus-v2"
    case binaryOpusV1 = "binary-opus-v1"
}

nonisolated struct VoiceMediaCapabilities: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let opusCodec = "opus"
    static let opusFrameV2Feature = "turbo-audio-frame-v2"
    static let binaryVoicePacketV1Feature = "turbo-voice-packet-v1"
    static let plcFeature = "plc"
    static let fecFeature = "in-band-fec"

    let version: Int
    let codecs: [String]
    let features: [String]

    init(
        version: Int = Self.currentVersion,
        codecs: [String],
        features: [String]
    ) {
        self.version = version
        self.codecs = codecs
        self.features = features
    }

    static var local: VoiceMediaCapabilities {
        guard OpusVoiceCodec.isAvailable() else {
            return VoiceMediaCapabilities(codecs: [], features: [])
        }
        return VoiceMediaCapabilities(
            codecs: [opusCodec],
            features: [opusFrameV2Feature, binaryVoicePacketV1Feature, plcFeature, fecFeature]
        )
    }

    var supportsOpusV2: Bool {
        codecs.contains(Self.opusCodec)
            && features.contains(Self.opusFrameV2Feature)
    }

    var supportsBinaryVoicePacketV1: Bool {
        codecs.contains(Self.opusCodec)
            && features.contains(Self.binaryVoicePacketV1Feature)
    }

    var diagnosticsValue: String {
        let codecList = codecs.isEmpty ? "none" : codecs.joined(separator: ",")
        let featureList = features.isEmpty ? "none" : features.joined(separator: ",")
        return "v\(version);codecs=\(codecList);features=\(featureList)"
    }
}

nonisolated struct VoiceMediaPeerCapabilityEvidence: Equatable, Sendable {
    let capabilities: VoiceMediaCapabilities
    let observedAt: Date
    let source: String
    let peerDeviceID: String
}

nonisolated enum VoiceMediaNegotiator {
    static func outboundPayloadFormat(
        localCapabilities: VoiceMediaCapabilities = .local,
        peerCapabilities: VoiceMediaCapabilities? = nil,
        codecAvailable: Bool = OpusVoiceCodec.isAvailable()
    ) -> VoiceMediaPayloadFormat {
        guard codecAvailable,
              localCapabilities.supportsOpusV2 else {
            return .legacyPCM
        }
        if localCapabilities.supportsBinaryVoicePacketV1,
           peerCapabilities?.supportsBinaryVoicePacketV1 == true {
            return .binaryOpusV1
        }
        return .opusV2
    }
}

nonisolated struct VoicePCMFrame: Equatable, Sendable {
    let frameIndex: UInt64
    let pcmData: Data
}

nonisolated struct VoiceFrameAccumulator: Equatable, Sendable {
    static let sampleRate = 48_000
    static let channelCount = 1
    static let frameDurationMilliseconds = 20
    static let frameDurationNanoseconds: UInt64 = 20_000_000
    static let samplesPerFrame = sampleRate * frameDurationMilliseconds / 1_000
    static let bytesPerSample = MemoryLayout<Int16>.size
    static let bytesPerFrame = samplesPerFrame * bytesPerSample * channelCount

    private var pending = Data()
    private(set) var nextFrameIndex: UInt64 = 0

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        nextFrameIndex = 0
    }

    mutating func append(_ pcmData: Data) -> [VoicePCMFrame] {
        guard !pcmData.isEmpty else { return [] }
        pending.append(pcmData)

        var frames: [VoicePCMFrame] = []
        while pending.count >= Self.bytesPerFrame {
            let frameData = pending.prefix(Self.bytesPerFrame)
            frames.append(
                VoicePCMFrame(
                    frameIndex: nextFrameIndex,
                    pcmData: Data(frameData)
                )
            )
            pending.removeFirst(Self.bytesPerFrame)
            nextFrameIndex &+= 1
        }
        return frames
    }
}

nonisolated struct VoiceOpusFramePayload: Equatable, Sendable {
    let frameIndex: UInt64
    let sampleRate: Int
    let channels: Int
    let frameDurationMilliseconds: Int
    let features: [String]
    let packet: Data
}

nonisolated enum VoiceAudioTransportFrame: Equatable, Sendable {
    case legacyPCM(Data)
    case opus(VoiceOpusFramePayload)
    case binaryOpusV1(VoicePacketV1)
}

nonisolated struct VoicePacketV1: Equatable, Sendable {
    static let codecOpus: UInt8 = 1
    static let maximumOpusPayloadBytes = 1_275
    static let samplesPerFrame = UInt64(VoiceFrameAccumulator.samplesPerFrame)

    let frameIndex: UInt64
    let sampleTimestamp48k: UInt64
    let flags: UInt16
    let opusPayload: Data

    init(
        frameIndex: UInt64,
        sampleTimestamp48k: UInt64? = nil,
        flags: UInt16 = 0,
        opusPayload: Data
    ) throws {
        guard !opusPayload.isEmpty else {
            throw VoicePacketV1CodecError.emptyPayload
        }
        guard opusPayload.count <= Self.maximumOpusPayloadBytes else {
            throw VoicePacketV1CodecError.payloadTooLarge(opusPayload.count)
        }
        self.frameIndex = frameIndex
        self.sampleTimestamp48k = sampleTimestamp48k ?? frameIndex &* Self.samplesPerFrame
        self.flags = flags
        self.opusPayload = opusPayload
    }

    var opusFramePayload: VoiceOpusFramePayload {
        VoiceOpusFramePayload(
            frameIndex: frameIndex,
            sampleRate: VoiceFrameAccumulator.sampleRate,
            channels: VoiceFrameAccumulator.channelCount,
            frameDurationMilliseconds: VoiceFrameAccumulator.frameDurationMilliseconds,
            features: features,
            packet: opusPayload
        )
    }

    private var features: [String] {
        var result = [VoiceMediaCapabilities.plcFeature]
        if flags & VoicePacketV1Codec.Flag.inBandFEC.rawValue != 0 {
            result.append(VoiceMediaCapabilities.fecFeature)
        }
        return result
    }
}

nonisolated enum VoicePacketV1CodecError: Error, Equatable, LocalizedError {
    case tooShort(Int)
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unsupportedCodec(UInt8)
    case invalidHeaderLength(UInt16)
    case nonzeroReservedBytes
    case emptyPayload
    case payloadTooLarge(Int)
    case payloadLengthMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .tooShort(let size):
            return "Voice packet v1 is too short: \(size) bytes"
        case .invalidMagic:
            return "Voice packet v1 magic did not match TVP1"
        case .unsupportedVersion(let version):
            return "Unsupported voice packet version \(version)"
        case .unsupportedCodec(let codec):
            return "Unsupported voice packet codec \(codec)"
        case .invalidHeaderLength(let length):
            return "Invalid voice packet v1 header length \(length)"
        case .nonzeroReservedBytes:
            return "Voice packet v1 reserved bytes must be zero"
        case .emptyPayload:
            return "Voice packet v1 payload is empty"
        case .payloadTooLarge(let size):
            return "Voice packet v1 payload is too large: \(size) bytes"
        case .payloadLengthMismatch(let expected, let actual):
            return "Voice packet v1 payload length mismatch expected \(expected) actual \(actual)"
        }
    }
}

nonisolated enum VoicePacketV1Codec {
    enum Flag: UInt16, Sendable {
        case inBandFEC = 1
    }

    static let magic = Data([0x54, 0x56, 0x50, 0x31])
    static let version: UInt8 = 1
    static let headerLength = 32

    static func encode(_ packet: VoicePacketV1) -> Data {
        var data = Data()
        data.reserveCapacity(headerLength + packet.opusPayload.count)
        data.append(magic)
        data.append(version)
        data.append(VoicePacketV1.codecOpus)
        data.appendBigEndian(packet.flags)
        data.appendBigEndian(UInt16(headerLength))
        data.appendBigEndian(packet.frameIndex)
        data.appendBigEndian(packet.sampleTimestamp48k)
        data.appendBigEndian(UInt16(packet.opusPayload.count))
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(packet.opusPayload)
        return data
    }

    static func decode(_ data: Data) throws -> VoicePacketV1 {
        guard data.count >= headerLength else {
            throw VoicePacketV1CodecError.tooShort(data.count)
        }
        guard data.prefix(4) == magic else {
            throw VoicePacketV1CodecError.invalidMagic
        }
        let version = data[data.index(data.startIndex, offsetBy: 4)]
        guard version == Self.version else {
            throw VoicePacketV1CodecError.unsupportedVersion(version)
        }
        let codec = data[data.index(data.startIndex, offsetBy: 5)]
        guard codec == VoicePacketV1.codecOpus else {
            throw VoicePacketV1CodecError.unsupportedCodec(codec)
        }
        let flags = data.readUInt16BigEndian(at: 6)
        let headerLength = data.readUInt16BigEndian(at: 8)
        guard headerLength == UInt16(Self.headerLength) else {
            throw VoicePacketV1CodecError.invalidHeaderLength(headerLength)
        }
        let frameIndex = data.readUInt64BigEndian(at: 10)
        let sampleTimestamp48k = data.readUInt64BigEndian(at: 18)
        let payloadLength = Int(data.readUInt16BigEndian(at: 26))
        guard data[relativeOffset: 28] == 0,
              data[relativeOffset: 29] == 0,
              data[relativeOffset: 30] == 0,
              data[relativeOffset: 31] == 0 else {
            throw VoicePacketV1CodecError.nonzeroReservedBytes
        }
        let actualPayloadLength = data.count - Self.headerLength
        guard payloadLength == actualPayloadLength else {
            throw VoicePacketV1CodecError.payloadLengthMismatch(
                expected: payloadLength,
                actual: actualPayloadLength
            )
        }
        let payload = data.suffix(actualPayloadLength)
        return try VoicePacketV1(
            frameIndex: frameIndex,
            sampleTimestamp48k: sampleTimestamp48k,
            flags: flags,
            opusPayload: Data(payload)
        )
    }
}

private extension Data {
    nonisolated subscript(relativeOffset relativeOffset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: relativeOffset)]
    }

    nonisolated mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    nonisolated mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }

    nonisolated func readUInt16BigEndian(at relativeOffset: Int) -> UInt16 {
        let high = UInt16(self[relativeOffset: relativeOffset])
        let low = UInt16(self[relativeOffset: relativeOffset + 1])
        return (high << 8) | low
    }

    nonisolated func readUInt64BigEndian(at relativeOffset: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in relativeOffset ..< relativeOffset + 8 {
            value = (value << 8) | UInt64(self[relativeOffset: offset])
        }
        return value
    }
}

nonisolated enum VoiceAudioFramePayloadCodec {
    static let kind = "turbo-audio-frame-v2"

    private struct Envelope: Codable {
        let kind: String
        let codec: String
        let frameIndex: UInt64
        let sampleRate: Int
        let channels: Int
        let frameDurationMs: Int
        let features: [String]
        let payload: String
    }

    static func encodeOpus(
        packet: Data,
        frameIndex: UInt64,
        features: [String] = [VoiceMediaCapabilities.plcFeature, VoiceMediaCapabilities.fecFeature]
    ) -> String? {
        let envelope = Envelope(
            kind: kind,
            codec: VoiceMediaCapabilities.opusCodec,
            frameIndex: frameIndex,
            sampleRate: VoiceFrameAccumulator.sampleRate,
            channels: VoiceFrameAccumulator.channelCount,
            frameDurationMs: VoiceFrameAccumulator.frameDurationMilliseconds,
            features: features,
            payload: packet.base64EncodedString()
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ payload: String) -> VoiceOpusFramePayload? {
        guard payload.first == "{",
              let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kind == kind,
              envelope.codec == VoiceMediaCapabilities.opusCodec,
              envelope.sampleRate == VoiceFrameAccumulator.sampleRate,
              envelope.channels == VoiceFrameAccumulator.channelCount,
              envelope.frameDurationMs == VoiceFrameAccumulator.frameDurationMilliseconds,
              let packet = Data(base64Encoded: envelope.payload) else {
            return nil
        }
        return VoiceOpusFramePayload(
            frameIndex: envelope.frameIndex,
            sampleRate: envelope.sampleRate,
            channels: envelope.channels,
            frameDurationMilliseconds: envelope.frameDurationMs,
            features: envelope.features,
            packet: packet
        )
    }

    static func mayContainOpusFrame(_ payload: String) -> Bool {
        payload.contains(kind) && payload.contains(VoiceMediaCapabilities.opusCodec)
    }

    static func decodeTransportFrames(_ payload: String) -> [VoiceAudioTransportFrame]? {
        let chunks = AudioChunkPayloadCodec.decode(payload)
        guard !chunks.isEmpty else { return [] }

        var frames: [VoiceAudioTransportFrame] = []
        frames.reserveCapacity(chunks.count)
        for chunk in chunks {
            if let opusFrame = decode(chunk) {
                frames.append(.opus(opusFrame))
                continue
            }
            guard let pcmData = Data(base64Encoded: chunk) else {
                return nil
            }
            frames.append(.legacyPCM(pcmData))
        }
        return frames
    }
}

nonisolated enum OpusVoiceCodecError: Error, LocalizedError, Equatable {
    case unavailable
    case invalidFrameSize(Int)
    case encodeFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Opus codec is unavailable"
        case .invalidFrameSize(let size):
            return "Expected 20 ms PCM frame but received \(size) bytes"
        case .encodeFailed(let message):
            return "Opus encode failed: \(message)"
        case .decodeFailed(let message):
            return "Opus decode failed: \(message)"
        }
    }
}

nonisolated struct OpusVoiceEncodingPolicy: Equatable, Sendable {
    static let minimumBitrate = 6_000
    static let maximumBitrate = 510_000
    static let maximumPacketLossPercent = 20

    let bitrate: Int
    let complexity: Int
    let expectedPacketLossPercent: Int
    let inBandFECEnabled: Bool
    let vbrEnabled: Bool
    let constrainedVBREnabled: Bool
    let dtxEnabled: Bool
    let fullbandEnabled: Bool

    init(
        bitrate: Int,
        complexity: Int = 10,
        expectedPacketLossPercent: Int,
        inBandFECEnabled: Bool,
        vbrEnabled: Bool = true,
        constrainedVBREnabled: Bool = true,
        dtxEnabled: Bool = false,
        fullbandEnabled: Bool = true
    ) {
        self.bitrate = min(Self.maximumBitrate, max(Self.minimumBitrate, bitrate))
        self.complexity = min(10, max(0, complexity))
        self.expectedPacketLossPercent = min(
            Self.maximumPacketLossPercent,
            max(0, expectedPacketLossPercent)
        )
        self.inBandFECEnabled = inBandFECEnabled
        self.vbrEnabled = vbrEnabled
        self.constrainedVBREnabled = constrainedVBREnabled
        self.dtxEnabled = dtxEnabled
        self.fullbandEnabled = fullbandEnabled
    }

    static let reliableFallback = OpusVoiceEncodingPolicy(
        bitrate: 32_000,
        expectedPacketLossPercent: 0,
        inBandFECEnabled: false
    )

    static func packetLane(
        bitrate: Int = 40_000,
        observedPacketLossPercent: Int
    ) -> OpusVoiceEncodingPolicy {
        let lossPercent = min(max(0, observedPacketLossPercent), maximumPacketLossPercent)
        return OpusVoiceEncodingPolicy(
            bitrate: bitrate,
            expectedPacketLossPercent: lossPercent,
            inBandFECEnabled: lossPercent >= 3
        )
    }

    var payloadFeatures: [String] {
        var features = [VoiceMediaCapabilities.plcFeature]
        if inBandFECEnabled {
            features.append(VoiceMediaCapabilities.fecFeature)
        }
        return features
    }

    var diagnosticsMetadata: [String: String] {
        [
            "opusBitrate": String(bitrate),
            "opusComplexity": String(complexity),
            "opusExpectedPacketLossPercent": String(expectedPacketLossPercent),
            "opusInBandFEC": String(inBandFECEnabled),
            "opusVBR": String(vbrEnabled),
            "opusConstrainedVBR": String(constrainedVBREnabled),
            "opusDTX": String(dtxEnabled),
            "opusBandwidth": fullbandEnabled ? "fullband" : "auto",
        ]
    }
}

nonisolated final class OpusVoiceCodec {
    static let maximumPacketBytes = 4_000
    private static let selfTestAmplitude: Double = 8_000
    private static let selfTestFrequency: Double = 440

    private let encoder: OpaquePointer
    private let decoder: OpaquePointer
    private let codecLock = NSLock()
    private(set) var encodingPolicy: OpusVoiceEncodingPolicy

    convenience init(
        encodingPolicy: OpusVoiceEncodingPolicy = .reliableFallback
    ) throws {
        guard Self.isAvailable() else {
            throw OpusVoiceCodecError.unavailable
        }
        try self.init(
            encodingPolicy: encodingPolicy,
            skipAvailabilityCheck: true
        )
    }

    private init(
        encodingPolicy: OpusVoiceEncodingPolicy = .reliableFallback,
        skipAvailabilityCheck _: Bool
    ) throws {
        var encoderError: Int32 = OPUS_OK
        guard let encoder = opus_encoder_create(
            Int32(VoiceFrameAccumulator.sampleRate),
            Int32(VoiceFrameAccumulator.channelCount),
            OPUS_APPLICATION_VOIP,
            &encoderError
        ), encoderError == OPUS_OK else {
            throw OpusVoiceCodecError.encodeFailed(Self.errorDescription(encoderError))
        }

        var decoderError: Int32 = OPUS_OK
        guard let decoder = opus_decoder_create(
            Int32(VoiceFrameAccumulator.sampleRate),
            Int32(VoiceFrameAccumulator.channelCount),
            &decoderError
        ), decoderError == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw OpusVoiceCodecError.decodeFailed(Self.errorDescription(decoderError))
        }

        let controlResults = Self.encoderControlResults(
            for: encoder,
            policy: encodingPolicy
        )
        guard let failedControl = controlResults.first(where: { $0 != OPUS_OK }) else {
            self.encoder = encoder
            self.decoder = decoder
            self.encodingPolicy = encodingPolicy
            return
        }
        opus_encoder_destroy(encoder)
        opus_decoder_destroy(decoder)
        throw OpusVoiceCodecError.encodeFailed(Self.errorDescription(failedControl))
    }

    deinit {
        opus_encoder_destroy(encoder)
        opus_decoder_destroy(decoder)
    }

    private static func encoderControlResults(
        for encoder: OpaquePointer,
        policy: OpusVoiceEncodingPolicy
    ) -> [Int32] {
        var results = [
            TurboOpusEncoderSetBitrate(encoder, Int32(policy.bitrate)),
            TurboOpusEncoderSetComplexity(encoder, Int32(policy.complexity)),
            TurboOpusEncoderSetInBandFEC(encoder, policy.inBandFECEnabled ? 1 : 0),
            TurboOpusEncoderSetLSBDepth(encoder, 16),
            TurboOpusEncoderSetPacketLossPercent(encoder, Int32(policy.expectedPacketLossPercent)),
            TurboOpusEncoderSetSignalVoice(encoder),
            TurboOpusEncoderSetVBR(encoder, policy.vbrEnabled ? 1 : 0),
            TurboOpusEncoderSetVBRConstraint(encoder, policy.constrainedVBREnabled ? 1 : 0),
            TurboOpusEncoderSetDTX(encoder, policy.dtxEnabled ? 1 : 0),
        ]
        if policy.fullbandEnabled {
            results.append(TurboOpusEncoderSetBandwidthFullband(encoder))
            results.append(TurboOpusEncoderSetMaxBandwidthFullband(encoder))
        }
        return results
    }

    func updateEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) throws {
        codecLock.lock()
        defer { codecLock.unlock() }
        let controlResults = Self.encoderControlResults(
            for: encoder,
            policy: policy
        )
        guard let failedControl = controlResults.first(where: { $0 != OPUS_OK }) else {
            encodingPolicy = policy
            return
        }
        throw OpusVoiceCodecError.encodeFailed(Self.errorDescription(failedControl))
    }

    func setExpectedPacketLossPercent(_ percent: Int) throws {
        let lossPercent = min(max(0, percent), OpusVoiceEncodingPolicy.maximumPacketLossPercent)
        try updateEncodingPolicy(
            OpusVoiceEncodingPolicy(
                bitrate: encodingPolicy.bitrate,
                complexity: encodingPolicy.complexity,
                expectedPacketLossPercent: lossPercent,
                inBandFECEnabled: lossPercent >= 3,
                vbrEnabled: encodingPolicy.vbrEnabled,
                constrainedVBREnabled: encodingPolicy.constrainedVBREnabled,
                dtxEnabled: encodingPolicy.dtxEnabled,
                fullbandEnabled: encodingPolicy.fullbandEnabled
            )
        )
    }

    static func versionString() -> String {
        guard let version = TurboOpusVersionString() else {
            return "unknown"
        }
        return String(cString: version)
    }

    private static func errorDescription(_ code: Int32) -> String {
        guard let message = TurboOpusErrorString(code) else {
            return "libopus error \(code)"
        }
        return String(cString: message)
    }

    static func isAvailable() -> Bool {
        availability
    }

    private static let availability: Bool = {
        guard let codec = try? OpusVoiceCodec(skipAvailabilityCheck: true) else {
            return false
        }
        return codec.roundTripPreservesSignal()
    }()

    private func roundTripPreservesSignal() -> Bool {
        guard let packet = try? encode(Self.selfTestPCMData()),
              let decoded = try? decode(packet) else {
            return false
        }
        return decoded.contains { $0 != 0 }
    }

    private static func selfTestPCMData() -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(VoiceFrameAccumulator.samplesPerFrame)
        for index in 0 ..< VoiceFrameAccumulator.samplesPerFrame {
            let value = sin(
                Double(index) * 2 * Double.pi * selfTestFrequency
                    / Double(VoiceFrameAccumulator.sampleRate)
            )
            samples.append(Int16(value * selfTestAmplitude))
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    func encode(_ pcmData: Data) throws -> Data {
        guard pcmData.count == VoiceFrameAccumulator.bytesPerFrame else {
            throw OpusVoiceCodecError.invalidFrameSize(pcmData.count)
        }
        codecLock.lock()
        defer { codecLock.unlock() }

        var packet = [UInt8](repeating: 0, count: Self.maximumPacketBytes)
        let maximumPacketBytes = Int32(Self.maximumPacketBytes)
        let encodedBytes = try pcmData.withUnsafeBytes { rawBuffer -> Int32 in
            guard let input = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                throw OpusVoiceCodecError.encodeFailed("missing PCM input")
            }
            return packet.withUnsafeMutableBufferPointer { output in
                guard let outputBaseAddress = output.baseAddress else {
                    return OPUS_ALLOC_FAIL
                }
                return opus_encode(
                    encoder,
                    input,
                    Int32(VoiceFrameAccumulator.samplesPerFrame),
                    outputBaseAddress,
                    maximumPacketBytes
                )
            }
        }
        guard encodedBytes > 0 else {
            throw OpusVoiceCodecError.encodeFailed(Self.errorDescription(encodedBytes))
        }
        return Data(packet.prefix(Int(encodedBytes)))
    }

    func decode(_ packet: Data) throws -> Data {
        try decode(packet, useForwardErrorCorrection: false)
    }

    func decodeFEC(from packet: Data) throws -> Data {
        try decode(packet, useForwardErrorCorrection: true)
    }

    private func decode(_ packet: Data, useForwardErrorCorrection: Bool) throws -> Data {
        guard !packet.isEmpty else {
            throw OpusVoiceCodecError.decodeFailed("empty packet")
        }
        codecLock.lock()
        defer { codecLock.unlock() }

        var samples = [Int16](repeating: 0, count: VoiceFrameAccumulator.samplesPerFrame)
        let decodedSamples = packet.withUnsafeBytes { rawBuffer -> Int32 in
            let input = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return samples.withUnsafeMutableBufferPointer { output in
                guard let outputBaseAddress = output.baseAddress else {
                    return OPUS_ALLOC_FAIL
                }
                return opus_decode(
                    decoder,
                    input,
                    Int32(packet.count),
                    outputBaseAddress,
                    Int32(VoiceFrameAccumulator.samplesPerFrame),
                    useForwardErrorCorrection ? 1 : 0
                )
            }
        }
        guard decodedSamples == Int32(VoiceFrameAccumulator.samplesPerFrame) else {
            if decodedSamples < 0 {
                throw OpusVoiceCodecError.decodeFailed(Self.errorDescription(decodedSamples))
            }
            throw OpusVoiceCodecError.decodeFailed("decoded \(decodedSamples) samples")
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    func decodePLC() -> Data {
        codecLock.lock()
        defer { codecLock.unlock() }

        var samples = [Int16](repeating: 0, count: VoiceFrameAccumulator.samplesPerFrame)
        let decodedSamples = samples.withUnsafeMutableBufferPointer { output in
            guard let outputBaseAddress = output.baseAddress else {
                return OPUS_ALLOC_FAIL
            }
            return opus_decode(
                decoder,
                nil,
                0,
                outputBaseAddress,
                Int32(VoiceFrameAccumulator.samplesPerFrame),
                0
            )
        }
        guard decodedSamples == Int32(VoiceFrameAccumulator.samplesPerFrame) else {
            return Data(repeating: 0, count: VoiceFrameAccumulator.bytesPerFrame)
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}

nonisolated enum PCMInt16SampleRateConverter {
    static func convert(
        _ data: Data,
        fromSampleRate: Int,
        toSampleRate: Int
    ) -> Data {
        guard fromSampleRate != toSampleRate else { return data }
        guard fromSampleRate > 0, toSampleRate > 0 else { return data }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return data }

        let outputSampleCount = max(1, sampleCount * toSampleRate / fromSampleRate)
        return data.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return Data()
            }
            var output = [Int16](repeating: 0, count: outputSampleCount)
            for outputIndex in 0 ..< outputSampleCount {
                let sourcePosition = Double(outputIndex) * Double(fromSampleRate) / Double(toSampleRate)
                let lowerIndex = min(sampleCount - 1, Int(sourcePosition.rounded(.down)))
                let upperIndex = min(sampleCount - 1, lowerIndex + 1)
                let fraction = sourcePosition - Double(lowerIndex)
                let lower = Double(input[lowerIndex])
                let upper = Double(input[upperIndex])
                output[outputIndex] = Int16(
                    max(
                        Double(Int16.min),
                        min(Double(Int16.max), lower + ((upper - lower) * fraction))
                    ).rounded()
                )
            }
            return output.withUnsafeBytes { Data($0) }
        }
    }
}

nonisolated enum VoicePlayoutRecovery: Equatable, Sendable {
    case received
    case fec
    case plc
}

nonisolated struct VoicePlayoutFrame: Equatable, Sendable {
    let frameIndex: UInt64
    let pcmData: Data
    let recovery: VoicePlayoutRecovery
    let packetSizeBytes: Int
}

nonisolated struct VoicePlayoutInsertResult: Equatable, Sendable {
    let framesToPlay: [VoicePlayoutFrame]
    let duplicateDropCount: Int
    let lateDropCount: Int
    let missingFrameCount: Int
    let plcRecoveryCount: Int
    let fecRecoveryCount: Int
    let resynchronizedGapFrameCount: Int
    let bufferDepthFrames: Int
    let targetCushionFrames: Int
    let interArrivalGapNanoseconds: UInt64?
    let largestScheduledGapFrames: UInt64
    let adaptiveCushionIncreased: Bool
}

nonisolated struct VoiceReceiveEpochID: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

nonisolated enum VoicePlayoutPhase: Equatable, Sendable {
    case idle
    case buffering(epoch: VoiceReceiveEpochID)
    case playing(epoch: VoiceReceiveEpochID)
    case draining(epoch: VoiceReceiveEpochID)
}

nonisolated enum VoicePacketAdmission: Equatable, Sendable {
    case accepted(frameIndex: UInt64)
    case duplicate(frameIndex: UInt64)
    case late(frameIndex: UInt64)
    case wrongEpoch(expected: VoiceReceiveEpochID, actual: VoiceReceiveEpochID)
    case malformed(String)
}

nonisolated enum VoicePlayoutDecision: Equatable, Sendable {
    case hold
    case playReceived(frameIndex: UInt64)
    case playFEC(frameIndex: UInt64)
    case playPLC(frameIndex: UInt64)
    case expand(frameIndex: UInt64)
    case preemptiveExpand(frameIndex: UInt64)
    case accelerate(frameIndex: UInt64)
    case resync(fromFrameIndex: UInt64, toFrameIndex: UInt64)
}

nonisolated struct VoicePlayoutEngineMetrics: Equatable, Sendable {
    var phase: VoicePlayoutPhase
    var acceptedPacketCount: Int
    var duplicatePacketCount: Int
    var latePacketCount: Int
    var malformedPacketCount: Int
    var targetDelayMilliseconds: Int
    var bufferedFrameCount: Int
    var concealmentCount: Int
    var fecRecoveryCount: Int
    var resyncCount: Int
}

nonisolated struct VoiceMediaEventLog: Codable, Equatable, Sendable {
    static let defaultMaximumEventCount = 240

    var schemaVersion: Int
    var sessionID: String
    var engineMode: String
    private(set) var events: [VoiceMediaEvent]
    let maximumEventCount: Int

    init(
        schemaVersion: Int = 1,
        sessionID: String,
        engineMode: String,
        events: [VoiceMediaEvent] = [],
        maximumEventCount: Int = Self.defaultMaximumEventCount
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.engineMode = engineMode
        self.events = Array(events.suffix(max(1, maximumEventCount)))
        self.maximumEventCount = max(1, maximumEventCount)
    }

    mutating func record(_ event: VoiceMediaEvent) {
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
    }
}

nonisolated enum VoiceMediaEvent: Codable, Equatable, Sendable {
    case packetArrived(VoiceMediaPacketArrivalEvent)
    case packetAdmitted(VoiceMediaPacketAdmissionEvent)
    case playoutTick(VoiceMediaPlayoutTickEvent)
    case playoutDecision(VoiceMediaPlayoutDecisionEvent)
    case decodeOutcome(VoiceMediaDecodeOutcomeEvent)
    case routeChanged(VoiceMediaRouteChangeEvent)
    case schedulerLate(VoiceMediaSchedulerLateEvent)

    private enum CodingKeys: String, CodingKey {
        case packetArrived
        case packetAdmitted
        case playoutTick
        case playoutDecision
        case decodeOutcome
        case routeChanged
        case schedulerLate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(VoiceMediaPacketArrivalEvent.self, forKey: .packetArrived) {
            self = .packetArrived(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaPacketAdmissionEvent.self, forKey: .packetAdmitted) {
            self = .packetAdmitted(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaPlayoutTickEvent.self, forKey: .playoutTick) {
            self = .playoutTick(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaPlayoutDecisionEvent.self, forKey: .playoutDecision) {
            self = .playoutDecision(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaDecodeOutcomeEvent.self, forKey: .decodeOutcome) {
            self = .decodeOutcome(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaRouteChangeEvent.self, forKey: .routeChanged) {
            self = .routeChanged(value)
            return
        }
        if let value = try container.decodeIfPresent(VoiceMediaSchedulerLateEvent.self, forKey: .schedulerLate) {
            self = .schedulerLate(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "VoiceMediaEvent must contain exactly one known event key"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .packetArrived(let value):
            try container.encode(value, forKey: .packetArrived)
        case .packetAdmitted(let value):
            try container.encode(value, forKey: .packetAdmitted)
        case .playoutTick(let value):
            try container.encode(value, forKey: .playoutTick)
        case .playoutDecision(let value):
            try container.encode(value, forKey: .playoutDecision)
        case .decodeOutcome(let value):
            try container.encode(value, forKey: .decodeOutcome)
        case .routeChanged(let value):
            try container.encode(value, forKey: .routeChanged)
        case .schedulerLate(let value):
            try container.encode(value, forKey: .schedulerLate)
        }
    }
}

nonisolated struct VoiceMediaPacketArrivalEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let frameIndex: UInt64
    let sequenceNumber: UInt64?
    let sentAtMilliseconds: Int64?
    let receivedAtNanoseconds: UInt64
    let packetSizeBytes: Int
}

nonisolated struct VoiceMediaPacketAdmissionEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let frameIndex: UInt64
    let admission: String
    let bufferDepthFrames: Int
}

nonisolated struct VoiceMediaPlayoutTickEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let tickIndex: UInt64
    let playoutAtNanoseconds: UInt64
    let desiredSampleTimestamp48k: UInt64
}

nonisolated struct VoiceMediaPlayoutDecisionEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let tickIndex: UInt64
    let decision: String
    let frameIndex: UInt64?
    let targetDelayMilliseconds: Int
    let bufferedFrameCount: Int
}

nonisolated struct VoiceMediaDecodeOutcomeEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let frameIndex: UInt64
    let outcome: String
    let pcmByteCount: Int
}

nonisolated struct VoiceMediaRouteChangeEvent: Codable, Equatable, Sendable {
    let oldRoute: String
    let newRoute: String
    let changedAtNanoseconds: UInt64
}

nonisolated struct VoiceMediaSchedulerLateEvent: Codable, Equatable, Sendable {
    let epoch: UInt64
    let tickIndex: UInt64
    let lateByNanoseconds: UInt64
}

nonisolated protocol VoicePlayoutEngine: AnyObject {
    var phase: VoicePlayoutPhase { get }

    func reset(epoch: VoiceReceiveEpochID, nowNanoseconds: UInt64)

    func insert(
        packet: VoicePacketV1,
        epoch: VoiceReceiveEpochID,
        playbackProfile: MediaSessionPlaybackProfile,
        decode: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC: (VoiceOpusFramePayload) throws -> Data,
        plc: () -> Data,
        nowNanoseconds: UInt64
    ) throws -> VoicePlayoutInsertResult

    func metrics() -> VoicePlayoutEngineMetrics
}

nonisolated final class LegacyAdaptivePlayoutEngine: VoicePlayoutEngine {
    private let buffer = AdaptiveVoicePlayoutBuffer()
    private var currentEpoch = VoiceReceiveEpochID(rawValue: 0)
    private(set) var phase: VoicePlayoutPhase = .idle
    private var metricsSnapshot = VoicePlayoutEngineMetrics(
        phase: .idle,
        acceptedPacketCount: 0,
        duplicatePacketCount: 0,
        latePacketCount: 0,
        malformedPacketCount: 0,
        targetDelayMilliseconds: 0,
        bufferedFrameCount: 0,
        concealmentCount: 0,
        fecRecoveryCount: 0,
        resyncCount: 0
    )

    func reset(epoch: VoiceReceiveEpochID, nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        currentEpoch = epoch
        buffer.resetForNewReceiveEpoch(nowNanoseconds: nowNanoseconds)
        phase = .buffering(epoch: epoch)
        metricsSnapshot.phase = phase
        metricsSnapshot.bufferedFrameCount = 0
    }

    func insert(
        packet: VoicePacketV1,
        epoch: VoiceReceiveEpochID,
        playbackProfile: MediaSessionPlaybackProfile,
        decode: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC: (VoiceOpusFramePayload) throws -> Data,
        plc: () -> Data,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> VoicePlayoutInsertResult {
        if phase == .idle {
            reset(epoch: epoch, nowNanoseconds: nowNanoseconds)
        }
        guard epoch == currentEpoch else {
            metricsSnapshot.malformedPacketCount += 1
            return emptyResult(playbackProfile: playbackProfile)
        }
        let result = try buffer.insert(
            frame: packet.opusFramePayload,
            playbackProfile: playbackProfile,
            decode: decode,
            decodeFEC: decodeFEC,
            plc: plc,
            nowNanoseconds: nowNanoseconds
        )
        apply(result, epoch: epoch)
        return result
    }

    func metrics() -> VoicePlayoutEngineMetrics {
        metricsSnapshot
    }

    private func apply(_ result: VoicePlayoutInsertResult, epoch: VoiceReceiveEpochID) {
        metricsSnapshot.acceptedPacketCount += result.duplicateDropCount == 0 && result.lateDropCount == 0 ? 1 : 0
        metricsSnapshot.duplicatePacketCount += result.duplicateDropCount
        metricsSnapshot.latePacketCount += result.lateDropCount
        metricsSnapshot.targetDelayMilliseconds =
            result.targetCushionFrames * VoiceFrameAccumulator.frameDurationMilliseconds
        metricsSnapshot.bufferedFrameCount = result.bufferDepthFrames
        metricsSnapshot.concealmentCount += result.plcRecoveryCount
        metricsSnapshot.fecRecoveryCount += result.fecRecoveryCount
        metricsSnapshot.resyncCount += result.resynchronizedGapFrameCount > 0 ? 1 : 0
        if !result.framesToPlay.isEmpty {
            phase = .playing(epoch: epoch)
        } else if result.bufferDepthFrames > 0 {
            phase = .buffering(epoch: epoch)
        }
        metricsSnapshot.phase = phase
    }

    private func emptyResult(playbackProfile: MediaSessionPlaybackProfile) -> VoicePlayoutInsertResult {
        let target: Int
        switch playbackProfile {
        case .lowLatency:
            target = 4
        case .fastRelayBalanced:
            target = 5
        case .relayJitterBuffered:
            target = 7
        case .wakeBackgroundContinuity:
            target = 8
        }
        return VoicePlayoutInsertResult(
            framesToPlay: [],
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: 0,
            plcRecoveryCount: 0,
            fecRecoveryCount: 0,
            resynchronizedGapFrameCount: 0,
            bufferDepthFrames: 0,
            targetCushionFrames: target,
            interArrivalGapNanoseconds: nil,
            largestScheduledGapFrames: 0,
            adaptiveCushionIncreased: false
        )
    }
}

nonisolated final class SwiftNetEqPlayoutEngine: VoicePlayoutEngine {
    private static let maximumBufferedPackets = 96
    private static let startupTimeoutNanoseconds: UInt64 = 80_000_000
    private static let jitterSmoothingNumerator: UInt64 = 7
    private static let jitterSmoothingDenominator: UInt64 = 8
    private static let maximumJitterExtraFrames = 5

    private var bufferedPackets: [UInt64: VoicePacketV1] = [:]
    private var currentEpoch = VoiceReceiveEpochID(rawValue: 0)
    private var expectedFrameIndex: UInt64?
    private var startupBufferedSinceNanoseconds: UInt64?
    private var lastArrivalNanoseconds: UInt64?
    private var smoothedExcessJitterNanoseconds: UInt64 = 0
    private(set) var phase: VoicePlayoutPhase = .idle
    private var metricsSnapshot = VoicePlayoutEngineMetrics(
        phase: .idle,
        acceptedPacketCount: 0,
        duplicatePacketCount: 0,
        latePacketCount: 0,
        malformedPacketCount: 0,
        targetDelayMilliseconds: 0,
        bufferedFrameCount: 0,
        concealmentCount: 0,
        fecRecoveryCount: 0,
        resyncCount: 0
    )

    func reset(epoch: VoiceReceiveEpochID, nowNanoseconds _: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        bufferedPackets.removeAll(keepingCapacity: false)
        currentEpoch = epoch
        expectedFrameIndex = nil
        startupBufferedSinceNanoseconds = nil
        lastArrivalNanoseconds = nil
        phase = .buffering(epoch: epoch)
        metricsSnapshot.phase = phase
        metricsSnapshot.bufferedFrameCount = 0
    }

    func insert(
        packet: VoicePacketV1,
        epoch: VoiceReceiveEpochID,
        playbackProfile: MediaSessionPlaybackProfile,
        decode: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC: (VoiceOpusFramePayload) throws -> Data,
        plc: () -> Data,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> VoicePlayoutInsertResult {
        if phase == .idle {
            reset(epoch: epoch, nowNanoseconds: nowNanoseconds)
        }
        guard epoch == currentEpoch else {
            metricsSnapshot.malformedPacketCount += 1
            return emptyResult(playbackProfile: playbackProfile, interArrivalGapNanoseconds: nil)
        }

        let interArrivalGap = lastArrivalNanoseconds.map {
            nowNanoseconds >= $0 ? nowNanoseconds - $0 : 0
        }
        lastArrivalNanoseconds = nowNanoseconds
        updateJitterEstimate(
            interArrivalGapNanoseconds: interArrivalGap,
            playbackProfile: playbackProfile
        )

        if let expectedFrameIndex, phase != .buffering(epoch: epoch), packet.frameIndex < expectedFrameIndex {
            metricsSnapshot.latePacketCount += 1
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 0,
                lateDropCount: 1,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedPackets.count,
                targetCushionFrames: targetCushionFrames(for: playbackProfile),
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }
        if bufferedPackets[packet.frameIndex] != nil {
            metricsSnapshot.duplicatePacketCount += 1
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 1,
                lateDropCount: 0,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedPackets.count,
                targetCushionFrames: targetCushionFrames(for: playbackProfile),
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }

        admit(packet)
        metricsSnapshot.acceptedPacketCount += 1
        if startupBufferedSinceNanoseconds == nil {
            startupBufferedSinceNanoseconds = nowNanoseconds
        }
        if expectedFrameIndex == nil || phase == .buffering(epoch: epoch),
           let lowestBufferedFrameIndex = bufferedPackets.keys.min(),
           expectedFrameIndex.map({ lowestBufferedFrameIndex < $0 }) ?? true {
            expectedFrameIndex = lowestBufferedFrameIndex
        }

        let targetCushion = targetCushionFrames(for: playbackProfile)
        if phase == .buffering(epoch: epoch),
           bufferedPackets.count < targetCushion,
           !startupWaitElapsed(nowNanoseconds: nowNanoseconds) {
            metricsSnapshot.targetDelayMilliseconds =
                targetCushion * VoiceFrameAccumulator.frameDurationMilliseconds
            metricsSnapshot.bufferedFrameCount = bufferedPackets.count
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 0,
                lateDropCount: 0,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedPackets.count,
                targetCushionFrames: targetCushion,
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }

        phase = .playing(epoch: epoch)
        startupBufferedSinceNanoseconds = nil
        let result = try makePlayout(
            playbackProfile: playbackProfile,
            decode: decode,
            decodeFEC: decodeFEC,
            plc: plc,
            targetCushion: targetCushion,
            interArrivalGapNanoseconds: interArrivalGap
        )
        apply(result, targetCushion: targetCushion, epoch: epoch)
        return result
    }

    func metrics() -> VoicePlayoutEngineMetrics {
        metricsSnapshot
    }

    private func admit(_ packet: VoicePacketV1) {
        bufferedPackets[packet.frameIndex] = packet
        guard bufferedPackets.count > Self.maximumBufferedPackets else { return }
        let overflowCount = bufferedPackets.count - Self.maximumBufferedPackets
        for key in bufferedPackets.keys.sorted().prefix(overflowCount) {
            bufferedPackets[key] = nil
        }
    }

    private func makePlayout(
        playbackProfile: MediaSessionPlaybackProfile,
        decode: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC: (VoiceOpusFramePayload) throws -> Data,
        plc: () -> Data,
        targetCushion: Int,
        interArrivalGapNanoseconds: UInt64?
    ) throws -> VoicePlayoutInsertResult {
        var framesToPlay: [VoicePlayoutFrame] = []
        var missingFrameCount = 0
        var plcRecoveryCount = 0
        var fecRecoveryCount = 0
        var resynchronizedGapFrameCount = 0
        var largestScheduledGapFrames: UInt64 = 0

        while let expected = expectedFrameIndex {
            if let packet = bufferedPackets.removeValue(forKey: expected) {
                let pcm = try decode(packet.opusFramePayload)
                framesToPlay.append(
                    VoicePlayoutFrame(
                        frameIndex: expected,
                        pcmData: pcm,
                        recovery: .received,
                        packetSizeBytes: packet.opusPayload.count
                    )
                )
                expectedFrameIndex = expected &+ 1
                continue
            }

            guard let nextBufferedIndex = bufferedPackets.keys.min(),
                  nextBufferedIndex > expected else {
                break
            }
            guard bufferedPackets.count >= targetCushion else {
                break
            }

            let gap = nextBufferedIndex - expected
            largestScheduledGapFrames = max(largestScheduledGapFrames, gap)
            if shouldResync(gap: gap, targetCushion: targetCushion) {
                resynchronizedGapFrameCount += Int(min(gap, UInt64(Int.max)))
                expectedFrameIndex = nextBufferedIndex
                continue
            }

            let nextPacket = bufferedPackets[nextBufferedIndex]
            for missingIndex in expected ..< nextBufferedIndex {
                let recoveredWithFEC = missingIndex == (nextBufferedIndex &- 1)
                    && nextPacket?.opusFramePayload.features.contains(VoiceMediaCapabilities.fecFeature) == true
                let fecPCM: Data?
                if recoveredWithFEC, let nextPacket {
                    fecPCM = try? decodeFEC(nextPacket.opusFramePayload)
                } else {
                    fecPCM = nil
                }
                if let fecPCM {
                    framesToPlay.append(
                        VoicePlayoutFrame(
                            frameIndex: missingIndex,
                            pcmData: fecPCM,
                            recovery: .fec,
                            packetSizeBytes: 0
                        )
                    )
                    fecRecoveryCount += 1
                } else {
                    framesToPlay.append(
                        VoicePlayoutFrame(
                            frameIndex: missingIndex,
                            pcmData: plc(),
                            recovery: .plc,
                            packetSizeBytes: 0
                        )
                    )
                    plcRecoveryCount += 1
                }
                missingFrameCount += 1
            }
            expectedFrameIndex = nextBufferedIndex
        }

        return VoicePlayoutInsertResult(
            framesToPlay: framesToPlay,
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: missingFrameCount,
            plcRecoveryCount: plcRecoveryCount,
            fecRecoveryCount: fecRecoveryCount,
            resynchronizedGapFrameCount: resynchronizedGapFrameCount,
            bufferDepthFrames: bufferedPackets.count,
            targetCushionFrames: targetCushion,
            interArrivalGapNanoseconds: interArrivalGapNanoseconds,
            largestScheduledGapFrames: largestScheduledGapFrames,
            adaptiveCushionIncreased: jitterExtraFrames() > 0
        )
    }

    private func apply(
        _ result: VoicePlayoutInsertResult,
        targetCushion: Int,
        epoch: VoiceReceiveEpochID
    ) {
        metricsSnapshot.targetDelayMilliseconds =
            targetCushion * VoiceFrameAccumulator.frameDurationMilliseconds
        metricsSnapshot.bufferedFrameCount = result.bufferDepthFrames
        metricsSnapshot.concealmentCount += result.plcRecoveryCount
        metricsSnapshot.fecRecoveryCount += result.fecRecoveryCount
        metricsSnapshot.resyncCount += result.resynchronizedGapFrameCount > 0 ? 1 : 0
        metricsSnapshot.phase = result.framesToPlay.isEmpty ? phase : .playing(epoch: epoch)
        phase = metricsSnapshot.phase
    }

    private func emptyResult(
        playbackProfile: MediaSessionPlaybackProfile,
        interArrivalGapNanoseconds: UInt64?
    ) -> VoicePlayoutInsertResult {
        let target = targetCushionFrames(for: playbackProfile)
        return VoicePlayoutInsertResult(
            framesToPlay: [],
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: 0,
            plcRecoveryCount: 0,
            fecRecoveryCount: 0,
            resynchronizedGapFrameCount: 0,
            bufferDepthFrames: bufferedPackets.count,
            targetCushionFrames: target,
            interArrivalGapNanoseconds: interArrivalGapNanoseconds,
            largestScheduledGapFrames: 0,
            adaptiveCushionIncreased: false
        )
    }

    private func targetCushionFrames(for playbackProfile: MediaSessionPlaybackProfile) -> Int {
        let base: Int
        switch playbackProfile {
        case .lowLatency:
            base = 4
        case .fastRelayBalanced:
            base = 5
        case .relayJitterBuffered:
            base = 7
        case .wakeBackgroundContinuity:
            base = 8
        }
        return base + jitterExtraFrames()
    }

    private func updateJitterEstimate(
        interArrivalGapNanoseconds: UInt64?,
        playbackProfile: MediaSessionPlaybackProfile
    ) {
        guard let interArrivalGapNanoseconds else { return }
        let nominalGap = VoiceFrameAccumulator.frameDurationNanoseconds
        let excess = interArrivalGapNanoseconds > nominalGap
            ? interArrivalGapNanoseconds - nominalGap
            : 0
        let weighted = (smoothedExcessJitterNanoseconds * Self.jitterSmoothingNumerator + excess)
            / Self.jitterSmoothingDenominator
        switch playbackProfile {
        case .lowLatency:
            smoothedExcessJitterNanoseconds = min(weighted, VoiceFrameAccumulator.frameDurationNanoseconds)
        case .fastRelayBalanced, .relayJitterBuffered, .wakeBackgroundContinuity:
            smoothedExcessJitterNanoseconds = weighted
        }
    }

    private func jitterExtraFrames() -> Int {
        guard smoothedExcessJitterNanoseconds > 0 else { return 0 }
        return min(
            Self.maximumJitterExtraFrames,
            Int((smoothedExcessJitterNanoseconds + VoiceFrameAccumulator.frameDurationNanoseconds - 1)
                / VoiceFrameAccumulator.frameDurationNanoseconds)
        )
    }

    private func startupWaitElapsed(nowNanoseconds: UInt64) -> Bool {
        guard let startupBufferedSinceNanoseconds else { return false }
        return nowNanoseconds >= startupBufferedSinceNanoseconds
            && nowNanoseconds - startupBufferedSinceNanoseconds >= Self.startupTimeoutNanoseconds
    }

    private func shouldResync(gap: UInt64, targetCushion: Int) -> Bool {
        gap >= max(UInt64(targetCushion * 2), 8)
    }
}

nonisolated final class ScriptedPlayoutEngine: VoicePlayoutEngine {
    private(set) var phase: VoicePlayoutPhase = .idle
    var scriptedResults: [VoicePlayoutInsertResult]

    init(scriptedResults: [VoicePlayoutInsertResult]) {
        self.scriptedResults = scriptedResults
    }

    func reset(epoch: VoiceReceiveEpochID, nowNanoseconds _: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        phase = .buffering(epoch: epoch)
    }

    func insert(
        packet _: VoicePacketV1,
        epoch: VoiceReceiveEpochID,
        playbackProfile: MediaSessionPlaybackProfile,
        decode _: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC _: (VoiceOpusFramePayload) throws -> Data,
        plc _: () -> Data,
        nowNanoseconds _: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> VoicePlayoutInsertResult {
        if phase == .idle {
            reset(epoch: epoch)
        }
        let result = scriptedResults.isEmpty
            ? emptyResult(playbackProfile: playbackProfile)
            : scriptedResults.removeFirst()
        if !result.framesToPlay.isEmpty {
            phase = .playing(epoch: epoch)
        }
        return result
    }

    func metrics() -> VoicePlayoutEngineMetrics {
        VoicePlayoutEngineMetrics(
            phase: phase,
            acceptedPacketCount: 0,
            duplicatePacketCount: 0,
            latePacketCount: 0,
            malformedPacketCount: 0,
            targetDelayMilliseconds: 0,
            bufferedFrameCount: 0,
            concealmentCount: 0,
            fecRecoveryCount: 0,
            resyncCount: 0
        )
    }

    private func emptyResult(playbackProfile: MediaSessionPlaybackProfile) -> VoicePlayoutInsertResult {
        let target: Int
        switch playbackProfile {
        case .lowLatency:
            target = 4
        case .fastRelayBalanced:
            target = 5
        case .relayJitterBuffered:
            target = 7
        case .wakeBackgroundContinuity:
            target = 8
        }
        return VoicePlayoutInsertResult(
            framesToPlay: [],
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: 0,
            plcRecoveryCount: 0,
            fecRecoveryCount: 0,
            resynchronizedGapFrameCount: 0,
            bufferDepthFrames: 0,
            targetCushionFrames: target,
            interArrivalGapNanoseconds: nil,
            largestScheduledGapFrames: 0,
            adaptiveCushionIncreased: false
        )
    }
}

nonisolated enum VoicePlayoutEngineFactory {
    static func make(mode: VoiceMediaCoreMode) -> VoicePlayoutEngine {
        switch mode {
        case .legacyAdaptive, .shadowLegacyScheduled:
            return LegacyAdaptivePlayoutEngine()
        case .swiftNetEqV1:
            return SwiftNetEqPlayoutEngine()
        }
    }
}

nonisolated private struct BufferedVoiceFrame {
    let frame: VoiceOpusFramePayload
}

nonisolated final class AdaptiveVoicePlayoutBuffer {
    private static let rapidTurnJitterMemoryNanoseconds: UInt64 = 8_000_000_000
    private static let maximumEpochExtraCushionFrames = 3
    private static let maximumCarryoverExtraCushionFrames = 5

    private var bufferedFrames: [UInt64: BufferedVoiceFrame] = [:]
    private var expectedFrameIndex: UInt64?
    private var hasStarted = false
    private var lastArrivalNanoseconds: UInt64?
    private var startupBufferedSinceNanoseconds: UInt64?
    private var epochExtraCushionFrames = 0
    private var carryoverExtraCushionFrames = 0
    private var carryoverExtraCushionExpiresAtNanoseconds: UInt64?

    func reset() {
        resetEpochState()
        epochExtraCushionFrames = 0
        carryoverExtraCushionFrames = 0
        carryoverExtraCushionExpiresAtNanoseconds = nil
    }

    func resetForNewReceiveEpoch(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        resetEpochState()
        epochExtraCushionFrames = 0
        expireCarryoverCushionIfNeeded(nowNanoseconds: nowNanoseconds)
    }

    private func resetEpochState() {
        bufferedFrames.removeAll(keepingCapacity: false)
        expectedFrameIndex = nil
        hasStarted = false
        lastArrivalNanoseconds = nil
        startupBufferedSinceNanoseconds = nil
    }

    func insert(
        frame: VoiceOpusFramePayload,
        playbackProfile: MediaSessionPlaybackProfile,
        decode: (VoiceOpusFramePayload) throws -> Data,
        decodeFEC: (VoiceOpusFramePayload) throws -> Data,
        plc: () -> Data,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> VoicePlayoutInsertResult {
        let interArrivalGap = lastArrivalNanoseconds.map {
            nowNanoseconds >= $0 ? nowNanoseconds - $0 : 0
        }
        lastArrivalNanoseconds = nowNanoseconds

        if let expectedFrameIndex, hasStarted, frame.frameIndex < expectedFrameIndex {
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 0,
                lateDropCount: 1,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedFrames.count,
                targetCushionFrames: targetCushionFrames(for: playbackProfile),
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }
        if bufferedFrames[frame.frameIndex] != nil {
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 1,
                lateDropCount: 0,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedFrames.count,
                targetCushionFrames: targetCushionFrames(for: playbackProfile),
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }

        bufferedFrames[frame.frameIndex] = BufferedVoiceFrame(frame: frame)
        if !hasStarted, startupBufferedSinceNanoseconds == nil {
            startupBufferedSinceNanoseconds = nowNanoseconds
        }
        if expectedFrameIndex == nil {
            expectedFrameIndex = frame.frameIndex
        } else if !hasStarted, let expected = expectedFrameIndex, frame.frameIndex < expected {
            expectedFrameIndex = frame.frameIndex
        }

        let targetCushion = targetCushionFrames(
            for: playbackProfile,
            nowNanoseconds: nowNanoseconds
        )
        if !hasStarted,
           bufferedFrames.count < targetCushion,
           !hasStartupWaitElapsed(
               playbackProfile: playbackProfile,
               nowNanoseconds: nowNanoseconds
           ) {
            return VoicePlayoutInsertResult(
                framesToPlay: [],
                duplicateDropCount: 0,
                lateDropCount: 0,
                missingFrameCount: 0,
                plcRecoveryCount: 0,
                fecRecoveryCount: 0,
                resynchronizedGapFrameCount: 0,
                bufferDepthFrames: bufferedFrames.count,
                targetCushionFrames: targetCushion,
                interArrivalGapNanoseconds: interArrivalGap,
                largestScheduledGapFrames: 0,
                adaptiveCushionIncreased: false
            )
        }
        hasStarted = true
        startupBufferedSinceNanoseconds = nil

        var framesToPlay: [VoicePlayoutFrame] = []
        var missingFrameCount = 0
        var plcRecoveryCount = 0
        var fecRecoveryCount = 0
        var resynchronizedGapFrameCount = 0
        var largestScheduledGapFrames: UInt64 = 0
        while let expected = expectedFrameIndex {
            if let buffered = bufferedFrames.removeValue(forKey: expected) {
                let decodedPCM = try decode(buffered.frame)
                framesToPlay.append(
                    VoicePlayoutFrame(
                        frameIndex: expected,
                        pcmData: decodedPCM,
                        recovery: .received,
                        packetSizeBytes: buffered.frame.packet.count
                    )
                )
                expectedFrameIndex = expected &+ 1
                continue
            }

            guard let nextBufferedIndex = bufferedFrames.keys.min(),
                  nextBufferedIndex > expected else {
                break
            }
            guard bufferedFrames.count >= targetCushion else {
                break
            }
            let gap = nextBufferedIndex - expected
            largestScheduledGapFrames = max(largestScheduledGapFrames, gap)
            if shouldResynchronizeAfterLargeGap(gap, targetCushionFrames: targetCushion) {
                resynchronizedGapFrameCount += Int(min(gap, UInt64(Int.max)))
                expectedFrameIndex = nextBufferedIndex
                continue
            }
            let nextFrame = bufferedFrames[nextBufferedIndex]?.frame
            for missingIndex in expected ..< nextBufferedIndex {
                let recoveredWithFEC = missingIndex == (nextBufferedIndex &- 1)
                    && nextFrame?.features.contains(VoiceMediaCapabilities.fecFeature) == true
                let fecPCM: Data?
                if recoveredWithFEC, let nextFrame {
                    fecPCM = try? decodeFEC(nextFrame)
                } else {
                    fecPCM = nil
                }
                let pcmData: Data
                let recovery: VoicePlayoutRecovery
                if let fecPCM {
                    pcmData = fecPCM
                    recovery = .fec
                    fecRecoveryCount += 1
                } else {
                    pcmData = plc()
                    recovery = .plc
                    plcRecoveryCount += 1
                }
                framesToPlay.append(
                    VoicePlayoutFrame(
                        frameIndex: missingIndex,
                        pcmData: pcmData,
                        recovery: recovery,
                        packetSizeBytes: 0
                    )
                )
                missingFrameCount += 1
            }
            expectedFrameIndex = nextBufferedIndex
        }

        let oldTargetCushion = targetCushionFrames(
            for: playbackProfile,
            nowNanoseconds: nowNanoseconds
        )
        if missingFrameCount > 0 {
            epochExtraCushionFrames = min(
                Self.maximumEpochExtraCushionFrames,
                epochExtraCushionFrames + 1
            )
            rememberCarryoverCushion(
                playbackProfile: playbackProfile,
                extraFrames: 3,
                nowNanoseconds: nowNanoseconds
            )
        } else if let interArrivalGap,
                  interArrivalGap > excessiveJitterThresholdNanoseconds(for: playbackProfile) {
            let excessFrames = Int(
                min(
                    UInt64(Self.maximumCarryoverExtraCushionFrames),
                    max(
                        1,
                        (
                            interArrivalGap
                            - excessiveJitterThresholdNanoseconds(for: playbackProfile)
                        ) / VoiceFrameAccumulator.frameDurationNanoseconds
                    )
                )
            )
            rememberCarryoverCushion(
                playbackProfile: playbackProfile,
                extraFrames: max(3, excessFrames),
                nowNanoseconds: nowNanoseconds
            )
        }
        return VoicePlayoutInsertResult(
            framesToPlay: framesToPlay,
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: missingFrameCount,
            plcRecoveryCount: plcRecoveryCount,
            fecRecoveryCount: fecRecoveryCount,
            resynchronizedGapFrameCount: resynchronizedGapFrameCount,
            bufferDepthFrames: bufferedFrames.count,
            targetCushionFrames: targetCushionFrames(
                for: playbackProfile,
                nowNanoseconds: nowNanoseconds
            ),
            interArrivalGapNanoseconds: interArrivalGap,
            largestScheduledGapFrames: largestScheduledGapFrames,
            adaptiveCushionIncreased: targetCushionFrames(
                for: playbackProfile,
                nowNanoseconds: nowNanoseconds
            ) > oldTargetCushion
        )
    }

    private func targetCushionFrames(
        for playbackProfile: MediaSessionPlaybackProfile,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Int {
        expireCarryoverCushionIfNeeded(nowNanoseconds: nowNanoseconds)
        let base: Int
        switch playbackProfile {
        case .lowLatency:
            base = 4
        case .fastRelayBalanced:
            base = 5
        case .relayJitterBuffered:
            base = 7
        case .wakeBackgroundContinuity:
            base = 8
        }
        return base + epochExtraCushionFrames + carryoverExtraCushion(for: playbackProfile)
    }

    private func rememberCarryoverCushion(
        playbackProfile: MediaSessionPlaybackProfile,
        extraFrames: Int,
        nowNanoseconds: UInt64
    ) {
        guard playbackProfile == .fastRelayBalanced else { return }
        carryoverExtraCushionFrames = min(
            Self.maximumCarryoverExtraCushionFrames,
            max(carryoverExtraCushionFrames, extraFrames)
        )
        carryoverExtraCushionExpiresAtNanoseconds =
            nowNanoseconds &+ Self.rapidTurnJitterMemoryNanoseconds
    }

    private func carryoverExtraCushion(for playbackProfile: MediaSessionPlaybackProfile) -> Int {
        playbackProfile == .fastRelayBalanced ? carryoverExtraCushionFrames : 0
    }

    private func expireCarryoverCushionIfNeeded(nowNanoseconds: UInt64) {
        guard let expiresAt = carryoverExtraCushionExpiresAtNanoseconds else { return }
        guard nowNanoseconds >= expiresAt else { return }
        carryoverExtraCushionFrames = 0
        carryoverExtraCushionExpiresAtNanoseconds = nil
    }

    private func shouldResynchronizeAfterLargeGap(
        _ gap: UInt64,
        targetCushionFrames: Int
    ) -> Bool {
        let resyncThreshold = max(UInt64(targetCushionFrames * 2), 8)
        return gap >= resyncThreshold
    }

    private func hasStartupWaitElapsed(
        playbackProfile: MediaSessionPlaybackProfile,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard let startupBufferedSinceNanoseconds else { return false }
        let elapsedNanoseconds = nowNanoseconds >= startupBufferedSinceNanoseconds
            ? nowNanoseconds - startupBufferedSinceNanoseconds
            : 0
        return elapsedNanoseconds >= startupTimeoutNanoseconds(for: playbackProfile)
    }

    private func startupTimeoutNanoseconds(for playbackProfile: MediaSessionPlaybackProfile) -> UInt64 {
        let fastRelayCarryoverExtra = carryoverExtraCushion(for: playbackProfile)
        switch playbackProfile {
        case .lowLatency:
            return 80_000_000
        case .fastRelayBalanced:
            return 120_000_000 + UInt64(fastRelayCarryoverExtra) * 40_000_000
        case .relayJitterBuffered:
            return 200_000_000
        case .wakeBackgroundContinuity:
            return 280_000_000
        }
    }

    private func excessiveJitterThresholdNanoseconds(
        for playbackProfile: MediaSessionPlaybackProfile
    ) -> UInt64 {
        switch playbackProfile {
        case .lowLatency:
            return 120_000_000
        case .fastRelayBalanced:
            return 160_000_000
        case .relayJitterBuffered:
            return 240_000_000
        case .wakeBackgroundContinuity:
            return 360_000_000
        }
    }
}
