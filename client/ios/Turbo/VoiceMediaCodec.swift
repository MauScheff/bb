import Darwin
import Dispatch
import Foundation
import TurboOpus

nonisolated enum VoiceMediaPayloadFormat: String, Equatable, Sendable {
    case legacyPCM = "legacy-pcm"
    case opusV2 = "opus-v2"
}

nonisolated struct VoiceMediaCapabilities: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let opusCodec = "opus"
    static let opusFrameV2Feature = "turbo-audio-frame-v2"
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
            features: [opusFrameV2Feature, plcFeature, fecFeature]
        )
    }

    var supportsOpusV2: Bool {
        codecs.contains(Self.opusCodec)
            && features.contains(Self.opusFrameV2Feature)
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
        codecAvailable: Bool = OpusVoiceCodec.isAvailable()
    ) -> VoiceMediaPayloadFormat {
        guard codecAvailable,
              localCapabilities.supportsOpusV2 else {
            return .legacyPCM
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
    let bufferDepthFrames: Int
    let targetCushionFrames: Int
    let interArrivalGapNanoseconds: UInt64?
    let largestScheduledGapFrames: UInt64
    let adaptiveCushionIncreased: Bool
}

nonisolated private struct BufferedVoiceFrame {
    let frame: VoiceOpusFramePayload
}

nonisolated final class AdaptiveVoicePlayoutBuffer {
    private var bufferedFrames: [UInt64: BufferedVoiceFrame] = [:]
    private var expectedFrameIndex: UInt64?
    private var hasStarted = false
    private var lastArrivalNanoseconds: UInt64?
    private var startupBufferedSinceNanoseconds: UInt64?
    private var adaptiveExtraCushionFrames = 0

    func reset() {
        bufferedFrames.removeAll(keepingCapacity: false)
        expectedFrameIndex = nil
        hasStarted = false
        lastArrivalNanoseconds = nil
        startupBufferedSinceNanoseconds = nil
        adaptiveExtraCushionFrames = 0
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

        let targetCushion = targetCushionFrames(for: playbackProfile)
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

        let oldExtra = adaptiveExtraCushionFrames
        if missingFrameCount > 0 {
            adaptiveExtraCushionFrames = min(3, adaptiveExtraCushionFrames + 1)
        }
        return VoicePlayoutInsertResult(
            framesToPlay: framesToPlay,
            duplicateDropCount: 0,
            lateDropCount: 0,
            missingFrameCount: missingFrameCount,
            plcRecoveryCount: plcRecoveryCount,
            fecRecoveryCount: fecRecoveryCount,
            bufferDepthFrames: bufferedFrames.count,
            targetCushionFrames: targetCushionFrames(for: playbackProfile),
            interArrivalGapNanoseconds: interArrivalGap,
            largestScheduledGapFrames: largestScheduledGapFrames,
            adaptiveCushionIncreased: adaptiveExtraCushionFrames > oldExtra
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
        return base + adaptiveExtraCushionFrames
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
        switch playbackProfile {
        case .lowLatency:
            return 80_000_000
        case .fastRelayBalanced:
            return 120_000_000
        case .relayJitterBuffered:
            return 200_000_000
        case .wakeBackgroundContinuity:
            return 280_000_000
        }
    }
}
