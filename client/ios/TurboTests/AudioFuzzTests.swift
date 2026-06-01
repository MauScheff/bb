import CryptoKit
import Foundation
import Testing

@testable import BeepBeep

@MainActor
struct AudioFuzzTests {
    @Test func audioPacketPlaybackGateFuzz() throws {
        let config = PropertyRunConfig(seed: 0xA11D_10F0_2026_0528, iterations: 240)

        try runProperty(config, name: "audioPacketPlaybackGateFuzz") { rng, iteration, seed in
            let contactID = UUID()
            let runtime = MediaRuntimeState()
            let deliveries = Self.generatePacketDeliveries(rng: &rng)
            var nowNanoseconds: UInt64 = 1_000_000_000
            var lastAcceptedSequence: UInt64?
            var acceptedSequences = Set<UInt64>()

            for delivery in deliveries {
                nowNanoseconds &+= delivery.deltaFrames * Self.frameDurationNanoseconds
                let decision = runtime.acceptIncomingAudioForPlayback(
                    contactID: contactID,
                    sequenceNumber: delivery.sequenceNumber,
                    transport: delivery.transport,
                    frameDurationNanoseconds: Self.frameDurationNanoseconds,
                    nowNanoseconds: nowNanoseconds
                )
                let summary = Self.packetDeliverySummary(deliveries)

                if delivery.transport.isUnorderedPacketMedia {
                    if acceptedSequences.contains(delivery.sequenceNumber) {
                        try requireProperty(
                            !decision.shouldPlay && decision.dropReason == .duplicateOrStaleSequence,
                            seed: seed,
                            iteration: iteration,
                            inputSummary: summary,
                            expectedInvariant: "packet playback gate drops exact duplicate packet audio sequence numbers",
                            observed: """
                            accepted duplicate sequence=\(delivery.sequenceNumber) \
                            transport=\(delivery.transport.diagnosticsValue) decision=\(decision)
                            """
                        )
                    } else {
                        try requireProperty(
                            decision.shouldPlay,
                            seed: seed,
                            iteration: iteration,
                            inputSummary: summary,
                            expectedInvariant: "packet media reorder reaches playout instead of being pre-dropped",
                            observed: "dropped packet sequence=\(delivery.sequenceNumber) transport=\(delivery.transport.diagnosticsValue) decision=\(decision)"
                        )
                        acceptedSequences.insert(delivery.sequenceNumber)
                        lastAcceptedSequence = max(lastAcceptedSequence ?? delivery.sequenceNumber, delivery.sequenceNumber)
                    }
                    continue
                }

                if let lastAcceptedSequence,
                   delivery.sequenceNumber <= lastAcceptedSequence {
                    try requireProperty(
                        !decision.shouldPlay && decision.dropReason == .duplicateOrStaleSequence,
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "packet playback gate drops stale or duplicate audio sequence numbers",
                        observed: """
                        accepted sequence=\(delivery.sequenceNumber) after lastPlayed=\(lastAcceptedSequence) \
                        transport=\(delivery.transport.diagnosticsValue) decision=\(decision)
                        """
                    )
                    continue
                }

                if decision.shouldPlay {
                    lastAcceptedSequence = delivery.sequenceNumber
                    acceptedSequences.insert(delivery.sequenceNumber)
                } else if case .orderedBacklog = decision.dropReason {
                    continue
                } else {
                    try requireProperty(
                        false,
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "new packet sequences either play or ordered fallback lanes drop stale backlog explicitly",
                        observed: "unexpected drop for sequence=\(delivery.sequenceNumber) decision=\(decision)"
                    )
                }
            }
        }
    }

    @Test func adaptiveVoicePlayoutBufferFuzzesLossReorderDuplicateAndDrain() throws {
        let config = PropertyRunConfig(seed: 0xA11D_0A05_2026_0528, iterations: 120)

        try runProperty(config, name: "adaptiveVoicePlayoutBufferFuzzesLossReorderDuplicateAndDrain") { rng, iteration, seed in
            let buffer = AdaptiveVoicePlayoutBuffer()
            let playbackProfile = rng.pick([
                MediaSessionPlaybackProfile.lowLatency,
                .fastRelayBalanced,
                .relayJitterBuffered,
                .wakeBackgroundContinuity,
            ])
            let deliveries = Self.generateVoiceFrameDeliveries(rng: &rng)
            var nowNanoseconds: UInt64 = 1_000_000_000
            var playedFrames: [VoicePlayoutFrame] = []

            for delivery in deliveries {
                nowNanoseconds &+= delivery.deltaFrames * Self.frameDurationNanoseconds
                let result = try buffer.insert(
                    frame: Self.opusFrame(delivery.frameIndex),
                    playbackProfile: playbackProfile,
                    decode: { Self.syntheticPCM(frameIndex: $0.frameIndex, marker: 0xA0) },
                    decodeFEC: { Self.syntheticPCM(frameIndex: $0.frameIndex &- 1, marker: 0xF0) },
                    plc: { Self.syntheticPCM(frameIndex: 0, marker: 0x00) },
                    nowNanoseconds: nowNanoseconds
                )
                playedFrames.append(contentsOf: result.framesToPlay)
            }

            let summary = Self.voiceDeliverySummary(deliveries, playbackProfile: playbackProfile)
            for pair in zip(playedFrames, playedFrames.dropFirst()) {
                try requireProperty(
                    pair.0.frameIndex < pair.1.frameIndex,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary,
                    expectedInvariant: "adaptive voice playout emits strictly increasing frame indexes",
                    observed: "played=\(playedFrames.map(\.frameIndex))"
                )
            }

            for frame in playedFrames {
                switch frame.recovery {
                case .received:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: frame.frameIndex, marker: 0xA0),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "received synthetic audio preserves its frame identity",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                case .fec:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: frame.frameIndex, marker: 0xF0),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "FEC recovery emits the missing frame identity",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                case .plc:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: 0, marker: 0x00),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "PLC recovery emits deterministic concealment audio",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                }
            }

            let lastSourceFrame = deliveries.lastSourceFrameIndex
            try requireProperty(
                playedFrames.last.map { $0.frameIndex >= lastSourceFrame } == true,
                seed: seed,
                iteration: iteration,
                inputSummary: summary,
                expectedInvariant: "synthetic playout drains through the source frame range after flush frames",
                observed: "played=\(playedFrames.map(\.frameIndex)) lastSourceFrame=\(lastSourceFrame)"
            )
        }
    }

    @Test func audioTransportLoopbackFuzzesCaptureEnvelopeGateAndPlayout() throws {
        let config = PropertyRunConfig(seed: 0xA11D_1009_2026_0528, iterations: 120)

        try runProperty(config, name: "audioTransportLoopbackFuzzesCaptureEnvelopeGateAndPlayout") { rng, iteration, seed in
            let contactID = UUID()
            let runtime = MediaRuntimeState()
            let playoutBuffer = AdaptiveVoicePlayoutBuffer()
            let playbackProfile = rng.pick([
                MediaSessionPlaybackProfile.lowLatency,
                .fastRelayBalanced,
                .relayJitterBuffered,
                .wakeBackgroundContinuity,
            ])
            let sourceFrameCount = rng.nextInt(in: 20...48)
            let flushFrameCount = 20
            let framePayloads = try Self.generateCapturedOpusPayloads(
                sourceFrameCount: sourceFrameCount,
                flushFrameCount: flushFrameCount,
                rng: &rng
            )
            let deliveries = Self.generateLoopbackDeliveries(
                framePayloads: framePayloads,
                sourceFrameCount: sourceFrameCount,
                rng: &rng
            )
            let encryptionKey = SymmetricKey(data: Data(repeating: 0xA7, count: MediaEndToEndEncryption.keyByteCount))
            let encryptionContext = MediaEncryptionContext(
                channelID: "loopback-channel",
                sessionID: MediaEndToEndEncryption.sessionID(channelID: "loopback-channel"),
                senderDeviceID: "loopback-sender",
                receiverDeviceID: "loopback-receiver"
            )
            let keyID = "sha256:loopback-audio-fuzz"
            let summary = Self.loopbackDeliverySummary(deliveries, playbackProfile: playbackProfile)
            var nowNanoseconds: UInt64 = 1_000_000_000
            var playedFrames: [VoicePlayoutFrame] = []
            var acceptedNonFlushFrameIndexes = Set<UInt64>()
            var acceptedEnvelopeCount = 0
            var decodedFrameCount = 0
            var transportCoverage = Set<String>()

            for delivery in deliveries {
                transportCoverage.insert(delivery.transport.diagnosticsValue)
                nowNanoseconds &+= delivery.deltaFrames * Self.frameDurationNanoseconds
                let openedPayload = try Self.roundTripOpenedPayload(
                    for: delivery,
                    encryptionKey: encryptionKey,
                    keyID: keyID,
                    encryptionContext: encryptionContext
                )
                let frameDurationNanoseconds = PCMOutgoingPayloadSplitter.durationNanoseconds(
                    forEncodedPayload: openedPayload.payload
                )
                let playbackDecision = runtime.acceptIncomingAudioForPlayback(
                    contactID: contactID,
                    sequenceNumber: openedPayload.encryptedSequenceNumber,
                    transport: delivery.transport,
                    frameDurationNanoseconds: frameDurationNanoseconds,
                    nowNanoseconds: nowNanoseconds
                )
                guard playbackDecision.shouldPlay else { continue }

                acceptedEnvelopeCount += 1
                let transportFrames = try #require(VoiceAudioFramePayloadCodec.decodeTransportFrames(openedPayload.payload))
                for transportFrame in transportFrames {
                    guard case .opus(let frame) = transportFrame else {
                        try requireProperty(
                            false,
                            seed: seed,
                            iteration: iteration,
                            inputSummary: summary,
                            expectedInvariant: "loopback transport emits opus-v2 frames",
                            observed: "decoded legacy PCM frame after opus loopback"
                        )
                        continue
                    }
                    decodedFrameCount += 1
                    if frame.frameIndex < UInt64(sourceFrameCount) {
                        acceptedNonFlushFrameIndexes.insert(frame.frameIndex)
                    }
                    let result = try playoutBuffer.insert(
                        frame: frame,
                        playbackProfile: playbackProfile,
                        decode: { Self.syntheticPCM(frameIndex: $0.frameIndex, marker: 0xA0) },
                        decodeFEC: { Self.syntheticPCM(frameIndex: $0.frameIndex &- 1, marker: 0xF0) },
                        plc: { Self.syntheticPCM(frameIndex: 0, marker: 0x00) },
                        nowNanoseconds: nowNanoseconds
                    )
                    playedFrames.append(contentsOf: result.framesToPlay)
                }
            }

            try requireProperty(
                transportCoverage == Set(IncomingAudioPayloadTransport.fuzzCases.map(\.diagnosticsValue)),
                seed: seed,
                iteration: iteration,
                inputSummary: summary,
                expectedInvariant: "loopback fuzz covers every incoming audio transport envelope",
                observed: "covered=\(transportCoverage.sorted())"
            )
            try requireProperty(
                acceptedEnvelopeCount > 0 && decodedFrameCount > 0 && !playedFrames.isEmpty,
                seed: seed,
                iteration: iteration,
                inputSummary: summary,
                expectedInvariant: "loopback audio makes forward progress through receive playout",
                observed: "acceptedEnvelopes=\(acceptedEnvelopeCount) decodedFrames=\(decodedFrameCount) played=\(playedFrames.map(\.frameIndex))"
            )

            for pair in zip(playedFrames, playedFrames.dropFirst()) {
                try requireProperty(
                    pair.0.frameIndex < pair.1.frameIndex,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary,
                    expectedInvariant: "loopback playout never repeats or reorders audio frames",
                    observed: "played=\(playedFrames.map(\.frameIndex))"
                )
            }

            for frame in playedFrames {
                switch frame.recovery {
                case .received:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: frame.frameIndex, marker: 0xA0),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "received loopback audio preserves frame identity",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                case .fec:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: frame.frameIndex, marker: 0xF0),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "FEC loopback audio recovers the missing frame identity",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                case .plc:
                    try requireProperty(
                        frame.pcmData == Self.syntheticPCM(frameIndex: 0, marker: 0x00),
                        seed: seed,
                        iteration: iteration,
                        inputSummary: summary,
                        expectedInvariant: "PLC loopback audio uses deterministic concealment audio",
                        observed: "frame=\(frame.frameIndex) recovery=\(frame.recovery)"
                    )
                }
            }

            if let highestAcceptedSourceFrame = acceptedNonFlushFrameIndexes.max() {
                try requireProperty(
                    playedFrames.last.map { $0.frameIndex >= highestAcceptedSourceFrame } == true,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary,
                    expectedInvariant: "flush frames drain playout through the highest accepted source frame",
                    observed: "highestAcceptedSourceFrame=\(highestAcceptedSourceFrame) played=\(playedFrames.map(\.frameIndex))"
                )
            }
        }
    }

    @Test func audioPlaybackSchedulerFuzzesLateIOCycleCushionAndDrain() throws {
        let config = PropertyRunConfig(seed: 0xA11D_5100_2026_0528, iterations: 180)

        try runProperty(config, name: "audioPlaybackSchedulerFuzzesLateIOCycleCushionAndDrain") { rng, iteration, seed in
            var lateIOCycleModel = Self.PlaybackSchedulerModel()
            let lateIOCycleAttemptCount = rng.nextInt(in: 26...96)
            try lateIOCycleModel.receiveBuffer(
                playbackProfile: .lowLatency,
                cushionPolicy: .alreadyCushioned,
                seed: seed,
                iteration: iteration,
                inputSummary: "lateIOCycleAttempts=\(lateIOCycleAttemptCount)"
            )

            for _ in 0..<lateIOCycleAttemptCount {
                try lateIOCycleModel.runPlaybackStartWaitStep(
                    seed: seed,
                    iteration: iteration,
                    inputSummary: "lateIOCycleAttempts=\(lateIOCycleAttemptCount)"
                )
            }
            try requireProperty(
                lateIOCycleModel.pendingPlaybackBufferCount == 1
                    && lateIOCycleModel.scheduledPlaybackBufferCount == 0
                    && lateIOCycleModel.isWaitingForPlaybackStart,
                seed: seed,
                iteration: iteration,
                inputSummary: "lateIOCycleAttempts=\(lateIOCycleAttemptCount)",
                expectedInvariant: "playback start wait remains armed while buffered audio is pending",
                observed: lateIOCycleModel.summary
            )

            lateIOCycleModel.playbackIOCycleAvailable = true
            try lateIOCycleModel.runPlaybackStartWaitStep(
                seed: seed,
                iteration: iteration,
                inputSummary: "lateIOCycleAttempts=\(lateIOCycleAttemptCount)"
            )
            try requireProperty(
                lateIOCycleModel.pendingPlaybackBufferCount == 0
                    && lateIOCycleModel.scheduledPlaybackBufferCount == 1
                    && lateIOCycleModel.isPlayerNodePlaying,
                seed: seed,
                iteration: iteration,
                inputSummary: "lateIOCycleAttempts=\(lateIOCycleAttemptCount)",
                expectedInvariant: "late playback IO availability drains deferred audio and starts playback",
                observed: lateIOCycleModel.summary
            )

            var model = Self.PlaybackSchedulerModel()
            model.playbackIOCycleAvailable = rng.nextBool()
            model.isPlayerNodePlaying = rng.nextBool()
            let operations = Self.generatePlaybackSchedulerOperations(rng: &rng)
            let inputSummary = Self.playbackSchedulerOperationSummary(operations)

            for operation in operations {
                try model.apply(
                    operation,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary
                )
            }

            model.playbackIOCycleAvailable = true
            if model.isWaitingForPlaybackStart {
                try model.runPlaybackStartWaitStep(
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary
                )
            }
            if model.pendingPlaybackBufferCount > 0 {
                model.startBufferedPlaybackAfterCushion()
            }
            try model.assertInvariants(
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary
            )
            try requireProperty(
                model.pendingPlaybackBufferCount == 0,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "playback scheduler can drain every buffered packet after IO and cushion recovery",
                observed: model.summary
            )
        }
    }

    @Test func pttWakeActivationTimingFuzzesBufferedAudioUntilFlushOrFallback() throws {
        let config = PropertyRunConfig(seed: 0xA11D_9A7E_2026_0528, iterations: 180)

        try runProperty(config, name: "pttWakeActivationTimingFuzzesBufferedAudioUntilFlushOrFallback") { rng, iteration, seed in
            let systemFirstOperations: [Self.WakeActivationOperation] = [
                .bufferOwn("system-pre-0"),
                .confirmPush,
                .activate,
                .deferFallback,
                .startFallback,
                .bufferOwn("system-late-0"),
            ]
            try Self.assertWakeActivationSequence(
                operations: systemFirstOperations + Self.generateWakeActivationOperations(rng: &rng),
                seed: seed,
                iteration: iteration,
                runName: "system-first",
                rng: &rng
            )

            let fallbackFirstOperations: [Self.WakeActivationOperation] = [
                .bufferOwn("fallback-pre-0"),
                .confirmPush,
                .deferFallback,
                .startFallback,
                .activate,
                .bufferOwn("fallback-late-0"),
            ]
            try Self.assertWakeActivationSequence(
                operations: fallbackFirstOperations + Self.generateWakeActivationOperations(rng: &rng),
                seed: seed,
                iteration: iteration,
                runName: "fallback-first",
                rng: &rng
            )
        }
    }

    @Test func audioIncidentCorpusReplaysExtractedDeviceTimelines() async throws {
        let corpusURLs = try Self.audioIncidentCorpusURLs()
        try requireProperty(
            !corpusURLs.isEmpty,
            seed: Self.audioIncidentCorpusSeed,
            iteration: 0,
            inputSummary: "corpusURLs=[]",
            expectedInvariant: "audio incident replay has at least one corpus file",
            observed: "no shared/fixtures/audio_incidents/*_corpus.json files found"
        )

        for corpusURL in corpusURLs {
            let corpusData = try Data(contentsOf: corpusURL)
            let corpus = try JSONDecoder().decode(AudioIncidentCorpus.self, from: corpusData)
            try requireProperty(
                corpus.schemaVersion == 1,
                seed: Self.audioIncidentCorpusSeed,
                iteration: 0,
                inputSummary: corpusURL.path,
                expectedInvariant: "audio incident corpus schema version is supported",
                observed: "schemaVersion=\(corpus.schemaVersion)"
            )
            for (index, incident) in corpus.incidents.enumerated() {
                let inputSummary = "\(corpusURL.lastPathComponent):\(incident.name)"
                try Self.replayPacketDeliveries(
                    incident.packetDeliveries,
                    seed: Self.audioIncidentCorpusSeed,
                    iteration: index,
                    inputSummary: inputSummary
                )
                try Self.replayVoiceFrameDeliveries(
                    incident.voiceFrameDeliveries,
                    seed: Self.audioIncidentCorpusSeed,
                    iteration: index,
                    inputSummary: inputSummary
                )
                try Self.replaySchedulerOperations(
                    incident.schedulerOperations,
                    seed: Self.audioIncidentCorpusSeed,
                    iteration: index,
                    inputSummary: inputSummary
                )
                try await Self.replayOutboundTransportIncidents(
                    incident.outboundTransportIncidents,
                    seed: Self.audioIncidentCorpusSeed,
                    iteration: index,
                    inputSummary: inputSummary
                )
            }
        }
    }

    @Test func audioIncidentCorpusMutatesAcrossPlaybackStateEnvelopes() async throws {
        let corpusURLs = try Self.audioIncidentCorpusURLs()
        try requireProperty(
            !corpusURLs.isEmpty,
            seed: Self.audioIncidentMutationSeed,
            iteration: 0,
            inputSummary: "corpusURLs=[]",
            expectedInvariant: "audio incident mutation has at least one corpus file",
            observed: "no shared/fixtures/audio_incidents/*_corpus.json files found"
        )

        var iteration = 0
        for corpusURL in corpusURLs {
            let corpusData = try Data(contentsOf: corpusURL)
            let corpus = try JSONDecoder().decode(AudioIncidentCorpus.self, from: corpusData)
            for incident in corpus.incidents {
                for envelope in AudioIncidentReplayEnvelope.allCases {
                    let inputSummary = "\(corpusURL.lastPathComponent):\(incident.name):\(envelope.name)"
                    try await Self.replayIncident(
                        incident,
                        envelope: envelope,
                        seed: Self.audioIncidentMutationSeed,
                        iteration: iteration,
                        inputSummary: inputSummary
                    )
                    iteration += 1
                }
            }
        }
    }
}

private extension AudioFuzzTests {
    static let frameDurationNanoseconds: UInt64 = 20_000_000
    static let audioIncidentCorpusSeed: UInt64 = 0xA11D_C012_2026_0528
    static let audioIncidentMutationSeed: UInt64 = 0xA11D_5A7E_2026_0528

    struct PacketDelivery {
        let sequenceNumber: UInt64
        let transport: IncomingAudioPayloadTransport
        let deltaFrames: UInt64
    }

    struct VoiceFrameDelivery {
        let frameIndex: UInt64
        let deltaFrames: UInt64
        let isFlushFrame: Bool
    }

    struct LoopbackFramePayload {
        let frameIndex: UInt64
        let payload: String
        let isFlushFrame: Bool
    }

    struct LoopbackDelivery {
        let sequenceNumber: UInt64
        let transport: IncomingAudioPayloadTransport
        let deltaFrames: UInt64
        let frames: [LoopbackFramePayload]
    }

    struct LoopbackOpenedPayload {
        let payload: String
        let encryptedSequenceNumber: UInt64
    }

    struct AudioIncidentCorpus: Decodable {
        let schemaVersion: Int
        let incidents: [AudioIncident]
    }

    struct AudioIncident: Decodable {
        let name: String
        let packetDeliveries: [CorpusPacketDelivery]
        let voiceFrameDeliveries: [CorpusVoiceFrameDelivery]
        let schedulerOperations: [CorpusSchedulerOperation]
        let outboundTransportIncidents: [CorpusOutboundTransportIncident]

        enum CodingKeys: String, CodingKey {
            case name
            case packetDeliveries
            case voiceFrameDeliveries
            case schedulerOperations
            case outboundTransportIncidents
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            packetDeliveries = try container.decodeIfPresent(
                [CorpusPacketDelivery].self,
                forKey: .packetDeliveries
            ) ?? []
            voiceFrameDeliveries = try container.decodeIfPresent(
                [CorpusVoiceFrameDelivery].self,
                forKey: .voiceFrameDeliveries
            ) ?? []
            schedulerOperations = try container.decodeIfPresent(
                [CorpusSchedulerOperation].self,
                forKey: .schedulerOperations
            ) ?? []
            outboundTransportIncidents = try container.decodeIfPresent(
                [CorpusOutboundTransportIncident].self,
                forKey: .outboundTransportIncidents
            ) ?? []
        }
    }

    struct CorpusPacketDelivery: Decodable {
        let sequenceNumber: UInt64
        let transport: String
        let deltaFrames: UInt64
    }

    struct CorpusVoiceFrameDelivery: Decodable {
        let frameIndex: UInt64
        let deltaFrames: UInt64
        let isFlushFrame: Bool
    }

    struct CorpusSchedulerOperation: Decodable {
        let type: String
        let available: Bool?
        let playbackProfile: String?
        let cushionPolicy: String?
        let count: Int?
    }

    struct CorpusOutboundTransportIncident: Decodable {
        let type: String
        let reason: String?
        let droppedPayloadCount: Int?
        let elapsedMilliseconds: UInt64?
        let maximumPendingPayloads: Int?
        let payloadLength: Int?
        let pendingPayloadCount: Int?
        let transportDigest: String?
    }

    actor AudioTransportIncidentRecorder {
        private(set) var payloads: [String] = []
        private var metadataByEvent: [String: [[String: String]]] = [:]

        func appendPayload(_ payload: String) {
            payloads.append(payload)
        }

        func appendEvent(_ event: String, metadata: [String: String]) {
            metadataByEvent[event, default: []].append(metadata)
        }

        func decodedPayloads() -> [String] {
            payloads.flatMap(AudioChunkPayloadCodec.decode)
        }

        func firstMetadata(for event: String) -> [String: String]? {
            metadataByEvent[event]?.first
        }
    }

    actor AudioTransportDelay {
        private var shouldDelayNextSend = true
        let delayNanoseconds: UInt64

        init(delayNanoseconds: UInt64) {
            self.delayNanoseconds = delayNanoseconds
        }

        func delayFirstSend() async {
            guard shouldDelayNextSend else { return }
            shouldDelayNextSend = false
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
    }

    actor AudioTransportGate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let waiting = continuations
            continuations.removeAll(keepingCapacity: false)
            for continuation in waiting {
                continuation.resume()
            }
        }
    }

    enum AudioIncidentReplayEnvelope: CaseIterable {
        case observed
        case directOnly
        case fastRelayPacketOnly
        case relayWebSocketOnly
        case lowLatencyPlayout
        case wakeContinuityPlayout
        case coldLateIO
        case alreadyPlayingReceive
        case routeReassertion
        case cushionTimeout

        var name: String {
            switch self {
            case .observed:
                return "observed"
            case .directOnly:
                return "direct-only"
            case .fastRelayPacketOnly:
                return "fast-relay-packet-only"
            case .relayWebSocketOnly:
                return "relay-websocket-only"
            case .lowLatencyPlayout:
                return "low-latency-playout"
            case .wakeContinuityPlayout:
                return "wake-continuity-playout"
            case .coldLateIO:
                return "cold-late-io"
            case .alreadyPlayingReceive:
                return "already-playing-receive"
            case .routeReassertion:
                return "route-reassertion"
            case .cushionTimeout:
                return "cushion-timeout"
            }
        }

        var transportOverride: String? {
            switch self {
            case .directOnly:
                return "directQuic"
            case .fastRelayPacketOnly:
                return "mediaRelayPacket"
            case .relayWebSocketOnly:
                return "relayWebSocket"
            case .observed, .lowLatencyPlayout, .wakeContinuityPlayout,
                    .coldLateIO, .alreadyPlayingReceive, .routeReassertion, .cushionTimeout:
                return nil
            }
        }

        var playbackProfile: MediaSessionPlaybackProfile {
            switch self {
            case .wakeContinuityPlayout:
                return .wakeBackgroundContinuity
            case .lowLatencyPlayout, .directOnly, .coldLateIO:
                return .lowLatency
            case .fastRelayPacketOnly:
                return .fastRelayBalanced
            case .observed, .relayWebSocketOnly, .alreadyPlayingReceive, .routeReassertion, .cushionTimeout:
                return .relayJitterBuffered
            }
        }
    }

    @MainActor
    struct PlaybackSchedulerModel {
        private let maximumPendingPlaybackBuffers = 24

        var playbackIOCycleAvailable = false
        var isPlayerNodePlaying = false
        private(set) var pendingPlaybackBufferCount = 0
        private(set) var scheduledPlaybackBufferCount = 0
        private(set) var completedPlaybackBufferCount = 0
        private(set) var acceptedPlaybackBufferCount = 0
        private(set) var droppedPendingPlaybackBufferCount = 0
        private(set) var isWaitingForPlaybackStart = false

        var summary: String {
            """
            io=\(playbackIOCycleAvailable) playing=\(isPlayerNodePlaying) pending=\(pendingPlaybackBufferCount) \
            scheduled=\(scheduledPlaybackBufferCount) completed=\(completedPlaybackBufferCount) \
            accepted=\(acceptedPlaybackBufferCount) droppedPending=\(droppedPendingPlaybackBufferCount) \
            waiting=\(isWaitingForPlaybackStart)
            """
        }

        mutating func apply(
            _ operation: PlaybackSchedulerOperation,
            seed: UInt64,
            iteration: Int,
            inputSummary: String
        ) throws {
            switch operation {
            case .receive(let playbackProfile, let cushionPolicy):
                try receiveBuffer(
                    playbackProfile: playbackProfile,
                    cushionPolicy: cushionPolicy,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary
                )

            case .setIOCycleAvailable(let available):
                playbackIOCycleAvailable = available

            case .playbackNodeStopped:
                isPlayerNodePlaying = false

            case .playbackNodeStarted:
                isPlayerNodePlaying = true
                drainPendingPlaybackBuffers()

            case .startWaitPoll:
                try runPlaybackStartWaitStep(
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary
                )

            case .cushionTimeout:
                if pendingPlaybackBufferCount > 0 {
                    startBufferedPlaybackAfterCushion()
                }

            case .scheduledBufferCompleted:
                if scheduledPlaybackBufferCount > 0 {
                    scheduledPlaybackBufferCount -= 1
                    completedPlaybackBufferCount += 1
                }

            case .startupReassertion:
                if PCMWebSocketMediaSession.shouldReassertPlaybackNode(
                    isPlayerNodePlaying: isPlayerNodePlaying,
                    pendingPlaybackBufferCount: pendingPlaybackBufferCount,
                    scheduledPlaybackBufferCount: scheduledPlaybackBufferCount
                ) {
                    isPlayerNodePlaying = true
                    drainPendingPlaybackBuffers()
                }
            }

            try assertInvariants(
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary
            )
        }

        mutating func receiveBuffer(
            playbackProfile: MediaSessionPlaybackProfile,
            cushionPolicy: PlaybackCushionPolicy,
            seed: UInt64,
            iteration: Int,
            inputSummary: String
        ) throws {
            acceptedPlaybackBufferCount += 1
            let receivePlan = PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: isPlayerNodePlaying,
                playbackIOCycleAvailable: playbackIOCycleAvailable
            )
            switch receivePlan {
            case .deferUntilIOCycle:
                enqueuePendingPlaybackBuffer()
                isWaitingForPlaybackStart = true

            case .scheduleAndStartNode:
                if shouldBufferForPlaybackCushion(
                    playbackProfile: playbackProfile,
                    cushionPolicy: cushionPolicy,
                    receivePlan: receivePlan
                ) {
                    bufferPlaybackForCushion(playbackProfile: playbackProfile)
                } else {
                    schedulePlaybackBuffer()
                    isPlayerNodePlaying = true
                    drainPendingPlaybackBuffers()
                }

            case .scheduleOnly:
                if shouldBufferForPlaybackCushion(
                    playbackProfile: playbackProfile,
                    cushionPolicy: cushionPolicy,
                    receivePlan: receivePlan
                ) {
                    bufferPlaybackForCushion(playbackProfile: playbackProfile)
                } else {
                    schedulePlaybackBuffer()
                }
            }

            try assertInvariants(
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary
            )
        }

        mutating func runPlaybackStartWaitStep(
            seed: UInt64,
            iteration: Int,
            inputSummary: String
        ) throws {
            guard isWaitingForPlaybackStart else {
                try assertInvariants(seed: seed, iteration: iteration, inputSummary: inputSummary)
                return
            }

            switch PCMWebSocketMediaSession.playbackStartWaitPlan(
                isPlayerNodePlaying: isPlayerNodePlaying,
                playbackIOCycleAvailable: playbackIOCycleAvailable,
                pendingPlaybackBufferCount: pendingPlaybackBufferCount
            ) {
            case .drainPendingBuffers:
                drainPendingPlaybackBuffers()
                isWaitingForPlaybackStart = false
            case .schedulePendingBuffersAndStartNode:
                scheduledPlaybackBufferCount += pendingPlaybackBufferCount
                pendingPlaybackBufferCount = 0
                isPlayerNodePlaying = true
                isWaitingForPlaybackStart = false
            case .waitForIOCycle:
                isWaitingForPlaybackStart = true
            case .stopWaiting:
                isWaitingForPlaybackStart = false
            }

            try assertInvariants(seed: seed, iteration: iteration, inputSummary: inputSummary)
        }

        mutating func startBufferedPlaybackAfterCushion() {
            if isPlayerNodePlaying {
                drainPendingPlaybackBuffers()
                return
            }
            scheduledPlaybackBufferCount += pendingPlaybackBufferCount
            pendingPlaybackBufferCount = 0
            isPlayerNodePlaying = true
            isWaitingForPlaybackStart = false
        }

        func assertInvariants(
            seed: UInt64,
            iteration: Int,
            inputSummary: String
        ) throws {
            try requireProperty(
                pendingPlaybackBufferCount <= maximumPendingPlaybackBuffers,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "pending playback buffers remain capped",
                observed: summary
            )
            try requireProperty(
                pendingPlaybackBufferCount >= 0 && scheduledPlaybackBufferCount >= 0,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "playback scheduler counts never go negative",
                observed: summary
            )
            try requireProperty(
                pendingPlaybackBufferCount
                    + scheduledPlaybackBufferCount
                    + completedPlaybackBufferCount
                    + droppedPendingPlaybackBufferCount == acceptedPlaybackBufferCount,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "accepted playback buffers are pending, scheduled, completed, or capped off",
                observed: summary
            )
        }

        private mutating func bufferPlaybackForCushion(
            playbackProfile: MediaSessionPlaybackProfile
        ) {
            enqueuePendingPlaybackBuffer()
            let configuration = PCMWebSocketMediaSession.playbackCushionConfiguration(for: playbackProfile)
            if pendingPlaybackBufferCount >= configuration.minimumBufferCount {
                startBufferedPlaybackAfterCushion()
            }
        }

        private func shouldBufferForPlaybackCushion(
            playbackProfile: MediaSessionPlaybackProfile,
            cushionPolicy: PlaybackCushionPolicy,
            receivePlan: PlaybackBufferReceivePlan
        ) -> Bool {
            let configuration = PCMWebSocketMediaSession.playbackCushionConfiguration(for: playbackProfile)
            return PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: playbackProfile,
                cushionPolicy: cushionPolicy,
                receivePlan: receivePlan,
                isPlayerNodePlaying: isPlayerNodePlaying,
                pendingPlaybackBufferCount: pendingPlaybackBufferCount,
                scheduledPlaybackBufferCount: scheduledPlaybackBufferCount,
                minimumCushionBufferCount: configuration.minimumBufferCount
            )
        }

        private mutating func enqueuePendingPlaybackBuffer() {
            pendingPlaybackBufferCount += 1
            if pendingPlaybackBufferCount > maximumPendingPlaybackBuffers {
                let droppedBufferCount = pendingPlaybackBufferCount - maximumPendingPlaybackBuffers
                droppedPendingPlaybackBufferCount += droppedBufferCount
                pendingPlaybackBufferCount = maximumPendingPlaybackBuffers
            }
        }

        private mutating func schedulePlaybackBuffer() {
            scheduledPlaybackBufferCount += 1
            isWaitingForPlaybackStart = false
        }

        private mutating func drainPendingPlaybackBuffers() {
            guard isPlayerNodePlaying else { return }
            scheduledPlaybackBufferCount += pendingPlaybackBufferCount
            pendingPlaybackBufferCount = 0
            isWaitingForPlaybackStart = false
        }
    }

    enum PlaybackSchedulerOperation {
        case receive(MediaSessionPlaybackProfile, PlaybackCushionPolicy)
        case setIOCycleAvailable(Bool)
        case playbackNodeStopped
        case playbackNodeStarted
        case startWaitPoll
        case cushionTimeout
        case scheduledBufferCompleted
        case startupReassertion
    }

    enum WakeActivationOperation {
        case confirmPush
        case confirmWrongChannel
        case bufferOwn(String)
        case bufferOther(String)
        case activate
        case activateWrongChannel
        case deferFallback
        case startFallback
        case interruptByTransmitEnd
        case clearBuffered
        case clearOtherBuffered
    }

    static func generatePlaybackSchedulerOperations(rng: inout SeededRNG) -> [PlaybackSchedulerOperation] {
        var operations: [PlaybackSchedulerOperation] = [
            .setIOCycleAvailable(false),
            .receive(.lowLatency, .alreadyCushioned),
            .startWaitPoll,
            .setIOCycleAvailable(true),
            .startWaitPoll,
        ]
        let playbackProfiles: [MediaSessionPlaybackProfile] = [
            .lowLatency,
            .fastRelayBalanced,
            .relayJitterBuffered,
            .wakeBackgroundContinuity,
        ]
        let operationCount = rng.nextInt(in: 80...180)
        for index in 0..<operationCount {
            switch rng.nextInt(in: 0...99) {
            case 0..<42:
                operations.append(
                    .receive(
                        rng.pick(playbackProfiles),
                        rng.nextBool() ? .applyTransportCushion : .alreadyCushioned
                    )
                )
            case 42..<54:
                operations.append(.setIOCycleAvailable(rng.nextBool()))
            case 54..<66:
                operations.append(.startWaitPoll)
            case 66..<74:
                operations.append(.cushionTimeout)
            case 74..<82:
                operations.append(.scheduledBufferCompleted)
            case 82..<88:
                operations.append(.startupReassertion)
            case 88..<94:
                operations.append(.playbackNodeStopped)
            default:
                operations.append(.playbackNodeStarted)
            }

            if index.isMultiple(of: 17) {
                operations.append(.startWaitPoll)
            }
        }
        return operations
    }

    static func playbackSchedulerOperationSummary(
        _ operations: [PlaybackSchedulerOperation]
    ) -> String {
        operations.prefix(48)
            .map { operation in
                switch operation {
                case .receive(let playbackProfile, let cushionPolicy):
                    return "receive(\(playbackProfile),\(cushionPolicy))"
                case .setIOCycleAvailable(let available):
                    return "io(\(available))"
                case .playbackNodeStopped:
                    return "stop"
                case .playbackNodeStarted:
                    return "start"
                case .startWaitPoll:
                    return "poll"
                case .cushionTimeout:
                    return "cushion-timeout"
                case .scheduledBufferCompleted:
                    return "complete"
                case .startupReassertion:
                    return "reassert"
                }
            }
            .joined(separator: ",")
    }

    static func generateWakeActivationOperations(rng: inout SeededRNG) -> [WakeActivationOperation] {
        var operations: [WakeActivationOperation] = []
        let operationCount = rng.nextInt(in: 48...120)
        for index in 0..<operationCount {
            switch rng.nextInt(in: 0...99) {
            case 0..<32:
                operations.append(.bufferOwn("audio-\(index)-\(rng.nextInt(in: 0...999))"))
            case 32..<40:
                operations.append(.bufferOther("other-audio-\(index)"))
            case 40..<50:
                operations.append(.confirmPush)
            case 50..<56:
                operations.append(.confirmWrongChannel)
            case 56..<65:
                operations.append(.activate)
            case 65..<70:
                operations.append(.activateWrongChannel)
            case 70..<78:
                operations.append(.deferFallback)
            case 78..<86:
                operations.append(.startFallback)
            case 86..<92:
                operations.append(.interruptByTransmitEnd)
            case 92..<97:
                operations.append(.clearBuffered)
            default:
                operations.append(.clearOtherBuffered)
            }
        }
        return operations
    }

    @MainActor
    static func assertWakeActivationSequence(
        operations: [WakeActivationOperation],
        seed: UInt64,
        iteration: Int,
        runName: String,
        rng: inout SeededRNG
    ) throws {
        let contactID = rng.uuid()
        let otherContactID = rng.uuid()
        let channelUUID = rng.uuid()
        let wrongChannelUUID = rng.uuid()
        let provisionalPayload = makeWakePayload(
            channelID: "wake-\(runName)",
            senderDeviceID: "provisional-\(runName)"
        )
        let confirmedPayload = makeWakePayload(
            channelID: "wake-\(runName)",
            senderDeviceID: "confirmed-\(runName)"
        )
        var state = WakeExecutionReducer.reduce(
            state: WakeExecutionSessionState(),
            event: .store(
                PendingIncomingPTTPush(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: provisionalPayload
                )
            ),
            maximumBufferedAudioChunks: 12
        ).state
        var expectedBufferedAudioChunks: [String] = []
        let inputSummary = "\(runName):\(wakeActivationOperationSummary(operations))"

        for operation in operations {
            let previousActivationState = state.incomingWakeActivationState(for: contactID)
            let previousAllowsBuffering = state.shouldBufferAudioChunk(for: contactID)
            switch operation {
            case .confirmPush:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .confirmIncomingPush(channelUUID: channelUUID, payload: confirmedPayload),
                    maximumBufferedAudioChunks: 12
                ).state

            case .confirmWrongChannel:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .confirmIncomingPush(channelUUID: wrongChannelUUID, payload: confirmedPayload),
                    maximumBufferedAudioChunks: 12
                ).state

            case .bufferOwn(let payload):
                if previousAllowsBuffering {
                    expectedBufferedAudioChunks.append(payload)
                    if expectedBufferedAudioChunks.count > 12 {
                        expectedBufferedAudioChunks.removeFirst(expectedBufferedAudioChunks.count - 12)
                    }
                }
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .bufferAudioChunk(contactID: contactID, payload: payload),
                    maximumBufferedAudioChunks: 12
                ).state

            case .bufferOther(let payload):
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .bufferAudioChunk(contactID: otherContactID, payload: payload),
                    maximumBufferedAudioChunks: 12
                ).state

            case .activate:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .markAudioSessionActivated(channelUUID: channelUUID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .activateWrongChannel:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .markAudioSessionActivated(channelUUID: wrongChannelUUID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .deferFallback:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .markFallbackDeferredUntilForeground(contactID: contactID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .startFallback:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .markAppManagedFallbackStarted(contactID: contactID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .interruptByTransmitEnd:
                if previousActivationState == .signalBuffered
                    || previousActivationState == .awaitingSystemActivation
                    || previousActivationState == .systemActivationTimedOutWaitingForForeground {
                    expectedBufferedAudioChunks = []
                }
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .markSystemActivationInterruptedByTransmitEnd(contactID: contactID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .clearBuffered:
                expectedBufferedAudioChunks = []
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .clearBufferedAudioChunks(contactID: contactID),
                    maximumBufferedAudioChunks: 12
                ).state

            case .clearOtherBuffered:
                state = WakeExecutionReducer.reduce(
                    state: state,
                    event: .clearBufferedAudioChunks(contactID: otherContactID),
                    maximumBufferedAudioChunks: 12
                ).state
            }

            try assertWakeActivationInvariants(
                state: state,
                expectedBufferedAudioChunks: expectedBufferedAudioChunks,
                previousActivationState: previousActivationState,
                contactID: contactID,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary
            )
        }
    }

    @MainActor
    static func assertWakeActivationInvariants(
        state: WakeExecutionSessionState,
        expectedBufferedAudioChunks: [String],
        previousActivationState: IncomingWakeActivationState?,
        contactID: UUID,
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) throws {
        let activationState = state.incomingWakeActivationState(for: contactID)
        let bufferedAudioChunks = state.bufferedAudioChunks(for: contactID)
        try requireProperty(
            bufferedAudioChunks == expectedBufferedAudioChunks,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "wake audio buffering preserves order, cap, and explicit flush semantics",
            observed: "activation=\(String(describing: activationState)) buffered=\(bufferedAudioChunks) expected=\(expectedBufferedAudioChunks)"
        )
        try requireProperty(
            bufferedAudioChunks.count <= 12,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "wake audio pre-activation buffer remains bounded",
            observed: "buffered=\(bufferedAudioChunks)"
        )

        let shouldBuffer = activationState == .signalBuffered
            || activationState == .awaitingSystemActivation
            || activationState == .systemActivationTimedOutWaitingForForeground
        try requireProperty(
            state.shouldBufferAudioChunk(for: contactID) == shouldBuffer,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "wake audio buffers only before terminal playback activation",
            observed: "activation=\(String(describing: activationState)) shouldBuffer=\(state.shouldBufferAudioChunk(for: contactID))"
        )

        if previousActivationState == .systemActivated
            || previousActivationState == .appManagedFallback
            || previousActivationState == .systemActivationInterruptedByTransmitEnd {
            try requireProperty(
                activationState == previousActivationState,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "terminal wake activation states are monotonic under late callbacks",
                observed: "previous=\(String(describing: previousActivationState)) current=\(String(describing: activationState))"
            )
        }

        if activationState == .systemActivated {
            try requireProperty(
                state.mediaSessionActivationMode(for: contactID) == .systemActivated,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "system-activated wake playback keeps system media session ownership",
                observed: "mode=\(state.mediaSessionActivationMode(for: contactID))"
            )
        }
        if activationState == .appManagedFallback {
            try requireProperty(
                state.mediaSessionActivationMode(for: contactID) == .appManaged,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "app-managed wake fallback keeps app media session ownership",
                observed: "mode=\(state.mediaSessionActivationMode(for: contactID))"
            )
        }
    }

    static func wakeActivationOperationSummary(
        _ operations: [WakeActivationOperation]
    ) -> String {
        operations.prefix(64)
            .map { operation in
                switch operation {
                case .confirmPush:
                    return "confirm"
                case .confirmWrongChannel:
                    return "confirm-wrong"
                case .bufferOwn(let payload):
                    return "buffer(\(payload))"
                case .bufferOther:
                    return "buffer-other"
                case .activate:
                    return "activate"
                case .activateWrongChannel:
                    return "activate-wrong"
                case .deferFallback:
                    return "defer"
                case .startFallback:
                    return "fallback"
                case .interruptByTransmitEnd:
                    return "interrupt"
                case .clearBuffered:
                    return "clear"
                case .clearOtherBuffered:
                    return "clear-other"
                }
            }
            .joined(separator: ",")
    }

    static func makeWakePayload(
        channelID: String,
        senderDeviceID: String
    ) -> TurboPTTPushPayload {
        TurboPTTPushPayload(
            event: .transmitStart,
            channelId: channelID,
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: senderDeviceID
        )
    }

    static func audioIncidentCorpusURLs() throws -> [URL] {
        if let explicitPath = ProcessInfo.processInfo.environment["TURBO_AUDIO_INCIDENT_CORPUS_PATH"],
           !explicitPath.isEmpty {
            return [URL(fileURLWithPath: explicitPath)]
        }
        let bridgedPathURL = URL(fileURLWithPath: "/tmp/turbo-audio-incident-corpus-path")
        if let bridgedPath = try? String(contentsOf: bridgedPathURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bridgedPath.isEmpty {
            return [URL(fileURLWithPath: bridgedPath)]
        }

        let repoRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpusDirectoryURL = repoRootURL
            .appendingPathComponent("fixtures")
            .appendingPathComponent("audio_incidents")
        guard FileManager.default.fileExists(atPath: corpusDirectoryURL.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: corpusDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix("_corpus.json") }
        .sorted { $0.path < $1.path }
    }

    static func replayPacketDeliveries(
        _ corpusDeliveries: [CorpusPacketDelivery],
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) throws {
        guard !corpusDeliveries.isEmpty else { return }
        let contactID = UUID()
        let runtime = MediaRuntimeState()
        var nowNanoseconds: UInt64 = 1_000_000_000
        var lastAcceptedSequence: UInt64?
        var acceptedSequences = Set<UInt64>()

        for corpusDelivery in corpusDeliveries {
            let delivery = try packetDelivery(from: corpusDelivery)
            nowNanoseconds &+= delivery.deltaFrames * frameDurationNanoseconds
            let decision = runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: delivery.sequenceNumber,
                transport: delivery.transport,
                frameDurationNanoseconds: frameDurationNanoseconds,
                nowNanoseconds: nowNanoseconds
            )

            if delivery.transport.isUnorderedPacketMedia {
                if acceptedSequences.contains(delivery.sequenceNumber) {
                    try requireProperty(
                        !decision.shouldPlay && decision.dropReason == .duplicateOrStaleSequence,
                        seed: seed,
                        iteration: iteration,
                        inputSummary: inputSummary,
                        expectedInvariant: "device-derived packet replay drops exact duplicate packet audio sequence numbers",
                        observed: "accepted duplicate sequence=\(delivery.sequenceNumber) decision=\(decision)"
                    )
                } else {
                    try requireProperty(
                        decision.shouldPlay,
                        seed: seed,
                        iteration: iteration,
                        inputSummary: inputSummary,
                        expectedInvariant: "device-derived packet replay preserves reorder for playout",
                        observed: "dropped packet sequence=\(delivery.sequenceNumber) decision=\(decision)"
                    )
                    acceptedSequences.insert(delivery.sequenceNumber)
                    lastAcceptedSequence = max(lastAcceptedSequence ?? delivery.sequenceNumber, delivery.sequenceNumber)
                }
                continue
            }

            if let lastAcceptedSequence,
               delivery.sequenceNumber <= lastAcceptedSequence {
                try requireProperty(
                    !decision.shouldPlay && decision.dropReason == .duplicateOrStaleSequence,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary,
                    expectedInvariant: "device-derived packet replay drops stale or duplicate audio sequence numbers",
                    observed: "accepted sequence=\(delivery.sequenceNumber) after lastPlayed=\(lastAcceptedSequence) decision=\(decision)"
                )
                continue
            }

            if decision.shouldPlay {
                lastAcceptedSequence = delivery.sequenceNumber
                acceptedSequences.insert(delivery.sequenceNumber)
            } else if case .orderedBacklog = decision.dropReason {
                continue
            } else {
                try requireProperty(
                    false,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary,
                    expectedInvariant: "device-derived packet replay either plays new packets or identifies ordered backlog",
                    observed: "unexpected drop for sequence=\(delivery.sequenceNumber) decision=\(decision)"
                )
            }
        }
    }

    static func replayVoiceFrameDeliveries(
        _ corpusDeliveries: [CorpusVoiceFrameDelivery],
        playbackProfile: MediaSessionPlaybackProfile = .relayJitterBuffered,
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) throws {
        guard !corpusDeliveries.isEmpty else { return }
        let playoutBuffer = AdaptiveVoicePlayoutBuffer()
        let deliveries = voiceFrameDeliveriesWithSyntheticFlush(corpusDeliveries)
        var nowNanoseconds: UInt64 = 1_000_000_000
        var playedFrames: [VoicePlayoutFrame] = []

        for delivery in deliveries {
            nowNanoseconds &+= delivery.deltaFrames * frameDurationNanoseconds
            let result = try playoutBuffer.insert(
                frame: opusFrame(delivery.frameIndex),
                playbackProfile: playbackProfile,
                decode: { syntheticPCM(frameIndex: $0.frameIndex, marker: 0xA0) },
                decodeFEC: { syntheticPCM(frameIndex: $0.frameIndex &- 1, marker: 0xF0) },
                plc: { syntheticPCM(frameIndex: 0, marker: 0x00) },
                nowNanoseconds: nowNanoseconds
            )
            playedFrames.append(contentsOf: result.framesToPlay)
        }

        for pair in zip(playedFrames, playedFrames.dropFirst()) {
            try requireProperty(
                pair.0.frameIndex < pair.1.frameIndex,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "device-derived playout replay never repeats or reorders audio frames",
                observed: "played=\(playedFrames.map(\.frameIndex))"
            )
        }

        if let highestSourceFrame = corpusDeliveries.map(\.frameIndex).max() {
            try requireProperty(
                playedFrames.last.map { $0.frameIndex >= highestSourceFrame } == true,
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "device-derived playout replay drains through the highest observed frame",
                observed: "highestSourceFrame=\(highestSourceFrame) played=\(playedFrames.map(\.frameIndex))"
            )
        }
    }

    @MainActor
    static func replaySchedulerOperations(
        _ corpusOperations: [CorpusSchedulerOperation],
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) throws {
        guard !corpusOperations.isEmpty else { return }
        var model = PlaybackSchedulerModel()
        for corpusOperation in corpusOperations {
            let count = max(1, corpusOperation.count ?? 1)
            for _ in 0..<count {
                try model.apply(
                    try playbackSchedulerOperation(from: corpusOperation),
                    seed: seed,
                    iteration: iteration,
                    inputSummary: inputSummary
                )
            }
        }

        model.playbackIOCycleAvailable = true
        if model.isWaitingForPlaybackStart {
            try model.runPlaybackStartWaitStep(
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary
            )
        }
        if model.pendingPlaybackBufferCount > 0 {
            model.startBufferedPlaybackAfterCushion()
        }
        try model.assertInvariants(seed: seed, iteration: iteration, inputSummary: inputSummary)
        try requireProperty(
            model.pendingPlaybackBufferCount == 0,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "device-derived scheduler replay drains pending audio after IO recovery",
            observed: model.summary
        )
    }

    static func replayOutboundTransportIncidents(
        _ incidents: [CorpusOutboundTransportIncident],
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) async throws {
        guard !incidents.isEmpty else { return }
        for (incidentIndex, incident) in incidents.enumerated() {
            let summary = "\(inputSummary):outbound[\(incidentIndex)]:\(incident.type)"
            switch incident.type {
            case "slowSend":
                try await replayOutboundSlowSendIncident(
                    incident,
                    shouldDropQueuedPayloads: false,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary
                )
            case "slowSendDrop":
                try await replayOutboundSlowSendIncident(
                    incident,
                    shouldDropQueuedPayloads: true,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary
                )
            case "backpressureDrop":
                try await replayOutboundBackpressureIncident(
                    incident,
                    seed: seed,
                    iteration: iteration,
                    inputSummary: summary
                )
            default:
                throw PropertyFailure(message: "unknown outbound transport incident \(incident.type)")
            }
        }
    }

    static func replayOutboundSlowSendIncident(
        _ incident: CorpusOutboundTransportIncident,
        shouldDropQueuedPayloads: Bool,
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) async throws {
        let droppedPayloadCount = shouldDropQueuedPayloads
            ? max(1, min(incident.droppedPayloadCount ?? incident.pendingPayloadCount ?? 1, 64))
            : 0
        let maximumPendingPayloads = max(
            1,
            min(incident.maximumPendingPayloads ?? max(droppedPayloadCount, 8), 96)
        )
        let delay = AudioTransportDelay(
            delayNanoseconds: max((incident.elapsedMilliseconds ?? 251) + 70, 300) * 1_000_000
        )
        let firstTransportSendStarted = AudioTransportGate()
        let recorder = AudioTransportIncidentRecorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                if AudioChunkPayloadCodec.decode(payload).contains("corpus-chunk-0") {
                    await firstTransportSendStarted.open()
                }
                await delay.delayFirstSend()
                await recorder.appendPayload(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: maximumPendingPayloads,
            maximumPayloadsPerMessage: 1,
            maximumInFlightSends: 1,
            dropsPendingPayloadsAfterSlowSend: shouldDropQueuedPayloads
        )

        let firstSend = Task {
            await sender.enqueue("corpus-chunk-0")
        }
        if shouldDropQueuedPayloads {
            await firstTransportSendStarted.wait()
            let queuedSend = Task {
                await sender.enqueue(
                    (1...droppedPayloadCount).map { "corpus-stale-\($0)" }
                )
            }
            await firstSend.value
            await queuedSend.value
        } else {
            await firstSend.value
        }
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let slowMetadata = await recorder.firstMetadata(
            for: "Outbound audio transport send was slow"
        )
        try requireProperty(
            slowMetadata?["invariantID"] == "media.outbound_audio_transport_send_slow",
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "device-derived outbound slow send replays through AudioChunkSender",
            observed: "slowMetadata=\(String(describing: slowMetadata))"
        )

        if shouldDropQueuedPayloads {
            let deliveredPayloads = await recorder.decodedPayloads()
            let stalePayloads = Set((1...droppedPayloadCount).map { "corpus-stale-\($0)" })
            try requireProperty(
                deliveredPayloads.allSatisfy { !stalePayloads.contains($0) },
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "slow outbound transport drops stale queued speech instead of draining it late",
                observed: "deliveredPayloads=\(deliveredPayloads)"
            )

            let dropMetadata = await recorder.firstMetadata(
                for: "Dropped stale outbound audio transport payload"
            )
            try requireProperty(
                dropMetadata?["invariantID"] == "media.outbound_audio_transport_slow_send_drop"
                    && dropMetadata?["reason"] == "outbound-transport-slow-send",
                seed: seed,
                iteration: iteration,
                inputSummary: inputSummary,
                expectedInvariant: "device-derived slow send drop emits the sender backpressure invariant",
                observed: "dropMetadata=\(String(describing: dropMetadata))"
            )
        }
    }

    static func replayOutboundBackpressureIncident(
        _ incident: CorpusOutboundTransportIncident,
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) async throws {
        let maximumPendingPayloads = max(1, min(incident.maximumPendingPayloads ?? 3, 64))
        let overflowCount = max(1, min(incident.droppedPayloadCount ?? 1, 64))
        let queuedPayloadCount = maximumPendingPayloads + overflowCount
        let gate = AudioTransportGate()
        let recorder = AudioTransportIncidentRecorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await gate.wait()
                await recorder.appendPayload(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: maximumPendingPayloads,
            maximumPayloadsPerMessage: 1
        )

        let firstSend = Task {
            await sender.enqueue("corpus-chunk-0")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let queuedSends = (1...queuedPayloadCount).map { index in
            Task {
                await sender.enqueue("corpus-overflow-\(index)")
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await gate.open()
        await firstSend.value
        for queuedSend in queuedSends {
            await queuedSend.value
        }
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let dropMetadata = await recorder.firstMetadata(
            for: "Dropped stale outbound audio transport payload"
        )
        try requireProperty(
            dropMetadata?["invariantID"] == "media.outbound_audio_transport_backpressure_drop"
                && dropMetadata?["reason"] == "outbound-transport-backpressure",
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary,
            expectedInvariant: "device-derived outbound backpressure drops oldest queued speech",
            observed: "dropMetadata=\(String(describing: dropMetadata))"
        )
    }

    @MainActor
    static func replayIncident(
        _ incident: AudioIncident,
        envelope: AudioIncidentReplayEnvelope,
        seed: UInt64,
        iteration: Int,
        inputSummary: String
    ) async throws {
        try replayPacketDeliveries(
            packetDeliveries(
                incident.packetDeliveries,
                applying: envelope
            ),
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary
        )
        try replayVoiceFrameDeliveries(
            incident.voiceFrameDeliveries,
            playbackProfile: envelope.playbackProfile,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary
        )
        try replaySchedulerOperations(
            schedulerOperations(
                incident.schedulerOperations,
                applying: envelope
            ),
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary
        )
        try await replayOutboundTransportIncidents(
            incident.outboundTransportIncidents,
            seed: seed,
            iteration: iteration,
            inputSummary: inputSummary
        )
    }

    static func packetDeliveries(
        _ deliveries: [CorpusPacketDelivery],
        applying envelope: AudioIncidentReplayEnvelope
    ) -> [CorpusPacketDelivery] {
        guard let transportOverride = envelope.transportOverride else { return deliveries }
        return deliveries.map {
            CorpusPacketDelivery(
                sequenceNumber: $0.sequenceNumber,
                transport: transportOverride,
                deltaFrames: $0.deltaFrames
            )
        }
    }

    static func schedulerOperations(
        _ operations: [CorpusSchedulerOperation],
        applying envelope: AudioIncidentReplayEnvelope
    ) -> [CorpusSchedulerOperation] {
        schedulerPrefix(for: envelope) + operations
    }

    static func schedulerPrefix(
        for envelope: AudioIncidentReplayEnvelope
    ) -> [CorpusSchedulerOperation] {
        switch envelope {
        case .coldLateIO:
            return [
                corpusOperation(type: "setIOCycleAvailable", available: false),
                corpusOperation(
                    type: "receive",
                    playbackProfile: "lowLatency",
                    cushionPolicy: "alreadyCushioned"
                ),
                corpusOperation(type: "startWaitPoll", count: 64),
                corpusOperation(type: "setIOCycleAvailable", available: true),
                corpusOperation(type: "startWaitPoll"),
            ]
        case .alreadyPlayingReceive:
            return [
                corpusOperation(type: "setIOCycleAvailable", available: true),
                corpusOperation(type: "playbackNodeStarted"),
                corpusOperation(
                    type: "receive",
                    playbackProfile: "relayJitterBuffered",
                    cushionPolicy: "alreadyCushioned"
                ),
                corpusOperation(type: "scheduledBufferCompleted"),
            ]
        case .routeReassertion:
            return [
                corpusOperation(type: "setIOCycleAvailable", available: true),
                corpusOperation(
                    type: "receive",
                    playbackProfile: "fastRelayBalanced",
                    cushionPolicy: "alreadyCushioned"
                ),
                corpusOperation(type: "playbackNodeStopped"),
                corpusOperation(type: "startupReassertion"),
            ]
        case .cushionTimeout:
            return [
                corpusOperation(type: "setIOCycleAvailable", available: true),
                corpusOperation(
                    type: "receive",
                    playbackProfile: "relayJitterBuffered",
                    cushionPolicy: "applyTransportCushion"
                ),
                corpusOperation(type: "cushionTimeout"),
            ]
        case .observed, .directOnly, .fastRelayPacketOnly, .relayWebSocketOnly,
                .lowLatencyPlayout, .wakeContinuityPlayout:
            return []
        }
    }

    static func corpusOperation(
        type: String,
        available: Bool? = nil,
        playbackProfile: String? = nil,
        cushionPolicy: String? = nil,
        count: Int? = nil
    ) -> CorpusSchedulerOperation {
        CorpusSchedulerOperation(
            type: type,
            available: available,
            playbackProfile: playbackProfile,
            cushionPolicy: cushionPolicy,
            count: count
        )
    }

    static func packetDelivery(from delivery: CorpusPacketDelivery) throws -> PacketDelivery {
        guard let transport = incomingAudioPayloadTransport(from: delivery.transport) else {
            throw PropertyFailure(message: "unknown packet transport \(delivery.transport)")
        }
        return PacketDelivery(
            sequenceNumber: delivery.sequenceNumber,
            transport: transport,
            deltaFrames: delivery.deltaFrames
        )
    }

    @MainActor
    static func playbackSchedulerOperation(
        from operation: CorpusSchedulerOperation
    ) throws -> PlaybackSchedulerOperation {
        switch operation.type {
        case "receive":
            return .receive(
                playbackProfile(from: operation.playbackProfile ?? "lowLatency"),
                playbackCushionPolicy(from: operation.cushionPolicy ?? "alreadyCushioned")
            )
        case "setIOCycleAvailable":
            return .setIOCycleAvailable(operation.available ?? false)
        case "playbackNodeStopped":
            return .playbackNodeStopped
        case "playbackNodeStarted":
            return .playbackNodeStarted
        case "startWaitPoll":
            return .startWaitPoll
        case "cushionTimeout":
            return .cushionTimeout
        case "scheduledBufferCompleted":
            return .scheduledBufferCompleted
        case "startupReassertion":
            return .startupReassertion
        default:
            throw PropertyFailure(message: "unknown scheduler operation \(operation.type)")
        }
    }

    static func voiceFrameDeliveriesWithSyntheticFlush(
        _ corpusDeliveries: [CorpusVoiceFrameDelivery]
    ) -> [VoiceFrameDelivery] {
        var deliveries = corpusDeliveries.map {
            VoiceFrameDelivery(
                frameIndex: $0.frameIndex,
                deltaFrames: $0.deltaFrames,
                isFlushFrame: $0.isFlushFrame
            )
        }
        let highestFrameIndex = deliveries.map(\.frameIndex).max() ?? 0
        for frameIndex in (highestFrameIndex + 1)...(highestFrameIndex + 16) {
            deliveries.append(
                VoiceFrameDelivery(
                    frameIndex: frameIndex,
                    deltaFrames: 1,
                    isFlushFrame: true
                )
            )
        }
        return deliveries
    }

    static func incomingAudioPayloadTransport(
        from value: String
    ) -> IncomingAudioPayloadTransport? {
        switch value {
        case "directQuic":
            return .directQuic
        case "mediaRelayPacket":
            return .mediaRelayPacket
        case "mediaRelayTcp":
            return .mediaRelayTcp
        case "relayWebSocket":
            return .relayWebSocket
        default:
            return nil
        }
    }

    static func playbackProfile(from value: String) -> MediaSessionPlaybackProfile {
        switch value {
        case "fastRelayBalanced":
            return .fastRelayBalanced
        case "relayJitterBuffered":
            return .relayJitterBuffered
        case "wakeBackgroundContinuity":
            return .wakeBackgroundContinuity
        default:
            return .lowLatency
        }
    }

    static func playbackCushionPolicy(from value: String) -> PlaybackCushionPolicy {
        value == "applyTransportCushion" ? .applyTransportCushion : .alreadyCushioned
    }

    static func generatePacketDeliveries(rng: inout SeededRNG) -> [PacketDelivery] {
        var deliveries: [PacketDelivery] = [
            PacketDelivery(sequenceNumber: 5, transport: .directQuic, deltaFrames: 1),
            PacketDelivery(sequenceNumber: 3, transport: .mediaRelayPacket, deltaFrames: 1),
        ]
        var nextSequence: UInt64 = 6
        let eventCount = rng.nextInt(in: 32...96)

        for _ in 0..<eventCount {
            let transport = rng.pick(IncomingAudioPayloadTransport.fuzzCases)
            let choice = rng.nextInt(in: 0...99)
            let sequenceNumber: UInt64
            if choice < 58 {
                sequenceNumber = nextSequence
                nextSequence &+= 1
            } else if choice < 72 {
                nextSequence &+= UInt64(rng.nextInt(in: 1...4))
                sequenceNumber = nextSequence
                nextSequence &+= 1
            } else if nextSequence > 0 {
                sequenceNumber = UInt64(rng.nextInt(in: 0...Int(nextSequence - 1)))
            } else {
                sequenceNumber = 0
                nextSequence = 1
            }

            deliveries.append(
                PacketDelivery(
                    sequenceNumber: sequenceNumber,
                    transport: transport,
                    deltaFrames: UInt64(rng.nextInt(in: 0...18))
                )
            )

            if rng.nextInt(in: 0...99) < 24 {
                deliveries.append(
                    PacketDelivery(
                        sequenceNumber: sequenceNumber,
                        transport: rng.pick(IncomingAudioPayloadTransport.fuzzCases),
                        deltaFrames: UInt64(rng.nextInt(in: 0...2))
                    )
                )
            }

            if deliveries.count >= 2,
               rng.nextInt(in: 0...99) < 16 {
                deliveries.swapAt(deliveries.count - 1, deliveries.count - 2)
            }
        }

        return deliveries
    }

    static func generateVoiceFrameDeliveries(rng: inout SeededRNG) -> [VoiceFrameDelivery] {
        let sourceFrameCount = rng.nextInt(in: 18...52)
        var deliveries: [VoiceFrameDelivery] = [
            VoiceFrameDelivery(frameIndex: 0, deltaFrames: 1, isFlushFrame: false),
        ]

        for frameIndex in 1..<sourceFrameCount {
            if rng.nextInt(in: 0...99) < 18 {
                continue
            }
            deliveries.append(
                VoiceFrameDelivery(
                    frameIndex: UInt64(frameIndex),
                    deltaFrames: UInt64(rng.nextInt(in: 0...4)),
                    isFlushFrame: false
                )
            )
            if rng.nextInt(in: 0...99) < 20 {
                deliveries.append(
                    VoiceFrameDelivery(
                        frameIndex: UInt64(frameIndex),
                        deltaFrames: UInt64(rng.nextInt(in: 0...1)),
                        isFlushFrame: false
                    )
                )
            }
            if deliveries.count >= 2,
               rng.nextInt(in: 0...99) < 22 {
                deliveries.swapAt(deliveries.count - 1, deliveries.count - 2)
            }
        }

        for flushFrame in sourceFrameCount..<(sourceFrameCount + 16) {
            deliveries.append(
                VoiceFrameDelivery(
                    frameIndex: UInt64(flushFrame),
                    deltaFrames: 1,
                    isFlushFrame: true
                )
            )
        }

        return deliveries
    }

    static func generateCapturedOpusPayloads(
        sourceFrameCount: Int,
        flushFrameCount: Int,
        rng: inout SeededRNG
    ) throws -> [LoopbackFramePayload] {
        let totalFrameCount = sourceFrameCount + flushFrameCount
        var stream = Data()
        for frameIndex in 0..<totalFrameCount {
            stream.append(
                syntheticPCM(
                    frameIndex: UInt64(frameIndex),
                    marker: frameIndex < sourceFrameCount ? 0xC0 : 0x50
                )
            )
        }

        var accumulator = VoiceFrameAccumulator()
        var offset = 0
        var payloads: [LoopbackFramePayload] = []
        while offset < stream.count {
            let chunkByteCount = min(
                stream.count - offset,
                rng.nextInt(in: 1...(VoiceFrameAccumulator.bytesPerFrame * 2))
            )
            let frames = accumulator.append(stream.subdata(in: offset..<(offset + chunkByteCount)))
            for frame in frames {
                guard let payload = VoiceAudioFramePayloadCodec.encodeOpus(
                    packet: syntheticOpusPacket(frameIndex: frame.frameIndex, pcmData: frame.pcmData),
                    frameIndex: frame.frameIndex,
                    features: [
                        VoiceMediaCapabilities.plcFeature,
                        VoiceMediaCapabilities.fecFeature,
                    ]
                ) else {
                    throw PropertyFailure(message: "failed to encode synthetic opus frame \(frame.frameIndex)")
                }
                payloads.append(
                    LoopbackFramePayload(
                        frameIndex: frame.frameIndex,
                        payload: payload,
                        isFlushFrame: Int(frame.frameIndex) >= sourceFrameCount
                    )
                )
            }
            offset += chunkByteCount
        }
        guard payloads.count == totalFrameCount else {
            throw PropertyFailure(message: "captured \(payloads.count) frames, expected \(totalFrameCount)")
        }
        return payloads
    }

    static func generateLoopbackDeliveries(
        framePayloads: [LoopbackFramePayload],
        sourceFrameCount: Int,
        rng: inout SeededRNG
    ) -> [LoopbackDelivery] {
        let sourceFrames = Array(framePayloads.prefix(sourceFrameCount))
        let flushFrames = Array(framePayloads.dropFirst(sourceFrameCount))
        var sourceDeliveries: [LoopbackDelivery] = []
        var sequenceNumber: UInt64 = 0
        var frameOffset = 0
        while frameOffset < sourceFrames.count {
            let batchSize = min(sourceFrames.count - frameOffset, rng.nextInt(in: 1...3))
            let transport = sourceDeliveries.count < IncomingAudioPayloadTransport.fuzzCases.count
                ? IncomingAudioPayloadTransport.fuzzCases[sourceDeliveries.count]
                : rng.pick(IncomingAudioPayloadTransport.fuzzCases)
            sourceDeliveries.append(
                LoopbackDelivery(
                    sequenceNumber: sequenceNumber,
                    transport: transport,
                    deltaFrames: UInt64(rng.nextInt(in: 0...6)),
                    frames: Array(sourceFrames[frameOffset..<(frameOffset + batchSize)])
                )
            )
            sequenceNumber &+= 1
            frameOffset += batchSize
        }

        var deliveries: [LoopbackDelivery] = []
        for delivery in sourceDeliveries {
            if delivery.sequenceNumber < UInt64(IncomingAudioPayloadTransport.fuzzCases.count)
                || rng.nextInt(in: 0...99) >= 16 {
                deliveries.append(delivery)
            }
            if rng.nextInt(in: 0...99) < 22 {
                deliveries.append(
                    LoopbackDelivery(
                        sequenceNumber: delivery.sequenceNumber,
                        transport: rng.pick(IncomingAudioPayloadTransport.fuzzCases),
                        deltaFrames: UInt64(rng.nextInt(in: 0...2)),
                        frames: delivery.frames
                    )
                )
            }
            if deliveries.count > IncomingAudioPayloadTransport.fuzzCases.count,
               rng.nextInt(in: 0...99) < 20 {
                deliveries.swapAt(deliveries.count - 1, deliveries.count - 2)
            }
        }
        if let stale = sourceDeliveries.prefix(max(1, sourceDeliveries.count / 2)).last,
           rng.nextInt(in: 0...99) < 80 {
            deliveries.append(
                LoopbackDelivery(
                    sequenceNumber: stale.sequenceNumber,
                    transport: rng.pick(IncomingAudioPayloadTransport.fuzzCases),
                    deltaFrames: UInt64(rng.nextInt(in: 0...12)),
                    frames: stale.frames
                )
            )
        }

        frameOffset = 0
        while frameOffset < flushFrames.count {
            let batchSize = min(flushFrames.count - frameOffset, rng.nextInt(in: 1...3))
            deliveries.append(
                LoopbackDelivery(
                    sequenceNumber: sequenceNumber,
                    transport: rng.pick(IncomingAudioPayloadTransport.fuzzCases),
                    deltaFrames: 1,
                    frames: Array(flushFrames[frameOffset..<(frameOffset + batchSize)])
                )
            )
            sequenceNumber &+= 1
            frameOffset += batchSize
        }
        return deliveries
    }

    static func roundTripOpenedPayload(
        for delivery: LoopbackDelivery,
        encryptionKey: SymmetricKey,
        keyID: String,
        encryptionContext: MediaEncryptionContext
    ) throws -> LoopbackOpenedPayload {
        let payload = AudioChunkPayloadCodec.encode(delivery.frames.map(\.payload))
        let encryptedPayload = try MediaEndToEndEncryption.sealTransportPayload(
            payload,
            using: encryptionKey,
            keyID: keyID,
            sequenceNumber: delivery.sequenceNumber,
            context: encryptionContext
        )
        let incomingPayload = try roundTripTransportEnvelope(
            encryptedPayload,
            delivery: delivery
        )
        let packet = try MediaEndToEndEncryption.decodePacket(incomingPayload)
        let openedPayload = try MediaEndToEndEncryption.openTransportPayload(
            incomingPayload,
            using: encryptionKey,
            context: encryptionContext
        )
        return LoopbackOpenedPayload(
            payload: openedPayload,
            encryptedSequenceNumber: packet.sequenceNumber
        )
    }

    static func roundTripTransportEnvelope(
        _ encryptedPayload: String,
        delivery: LoopbackDelivery
    ) throws -> String {
        let sentAtMilliseconds = Int64(1_000 + delivery.sequenceNumber * 20)
        switch delivery.transport {
        case .directQuic:
            let encoded = try DirectQuicMediaDatagramCodec.encode(
                .packetAudio(
                    payload: encryptedPayload,
                    sequenceNumber: delivery.sequenceNumber,
                    sentAtMilliseconds: sentAtMilliseconds
                )
            )
            guard case .packetAudio(let payload, let sequenceNumber, let sentAt) = try DirectQuicMediaDatagramCodec.decode(encoded),
                  payload == encryptedPayload,
                  sequenceNumber == delivery.sequenceNumber,
                  sentAt == sentAtMilliseconds else {
                throw PropertyFailure(message: "direct QUIC loopback envelope mismatch")
            }
            return payload

        case .mediaRelayPacket:
            let encoded = try TurboMediaRelayDatagramCodec.encode(
                .packetAudio(
                    sessionId: "loopback-channel",
                    senderDeviceId: "loopback-sender",
                    sequenceNumber: delivery.sequenceNumber,
                    sentAtMs: sentAtMilliseconds,
                    payload: encryptedPayload
                )
            )
            guard case .packetAudio(
                let sessionID,
                let senderDeviceID,
                let sequenceNumber,
                let sentAtMs,
                let payload
            ) = try TurboMediaRelayDatagramCodec.decode(encoded),
                sessionID == "loopback-channel",
                senderDeviceID == "loopback-sender",
                sequenceNumber == delivery.sequenceNumber,
                sentAtMs == sentAtMilliseconds,
                payload == encryptedPayload else {
                throw PropertyFailure(message: "media relay packet loopback envelope mismatch")
            }
            return payload

        case .mediaRelayTcp:
            var buffer = try TurboMediaRelayCodec.encode(
                .tcpAudio(
                    sessionId: "loopback-channel",
                    senderDeviceId: "loopback-sender",
                    sequenceNumber: delivery.sequenceNumber,
                    sentAtMs: sentAtMilliseconds,
                    payload: encryptedPayload
                )
            )
            let decoded = try TurboMediaRelayCodec.decodeAvailable(from: &buffer)
            guard decoded.count == 1,
                  buffer.isEmpty,
                  case .tcpAudio(
                      let sessionID,
                      let senderDeviceID,
                      let sequenceNumber,
                      let sentAtMs,
                      let payload
                  ) = decoded[0],
                  sessionID == "loopback-channel",
                  senderDeviceID == "loopback-sender",
                  sequenceNumber == delivery.sequenceNumber,
                  sentAtMs == sentAtMilliseconds,
                  payload == encryptedPayload else {
                throw PropertyFailure(message: "media relay TCP loopback envelope mismatch")
            }
            return payload

        case .relayWebSocket:
            let encoded = try TurboRelayWebSocketAudioPayloadCodec.encode(
                TurboRelayWebSocketAudioPayload(
                    payload: encryptedPayload,
                    sequenceNumber: delivery.sequenceNumber,
                    sentAtMilliseconds: sentAtMilliseconds
                )
            )
            guard let decoded = TurboRelayWebSocketAudioPayloadCodec.decodeIfPresent(encoded),
                  decoded.payload == encryptedPayload,
                  decoded.sequenceNumber == delivery.sequenceNumber,
                  decoded.sentAtMilliseconds == sentAtMilliseconds else {
                throw PropertyFailure(message: "relay WebSocket loopback envelope mismatch")
            }
            return decoded.payload
        }
    }

    static func opusFrame(_ frameIndex: UInt64) -> VoiceOpusFramePayload {
        VoiceOpusFramePayload(
            frameIndex: frameIndex,
            sampleRate: VoiceFrameAccumulator.sampleRate,
            channels: VoiceFrameAccumulator.channelCount,
            frameDurationMilliseconds: VoiceFrameAccumulator.frameDurationMilliseconds,
            features: [VoiceMediaCapabilities.plcFeature, VoiceMediaCapabilities.fecFeature],
            packet: Data([
                UInt8((frameIndex >> 0) & 0xff),
                UInt8((frameIndex >> 8) & 0xff),
                UInt8((frameIndex >> 16) & 0xff),
                UInt8((frameIndex >> 24) & 0xff),
            ])
        )
    }

    static func syntheticPCM(frameIndex: UInt64, marker: UInt8) -> Data {
        var data = Data(repeating: marker, count: VoiceFrameAccumulator.bytesPerFrame)
        withUnsafeBytes(of: frameIndex.littleEndian) { bytes in
            data.replaceSubrange(0..<bytes.count, with: bytes)
        }
        return data
    }

    static func syntheticOpusPacket(frameIndex: UInt64, pcmData: Data) -> Data {
        var packet = Data([0x54, 0x42, 0x4F, 0x50])
        withUnsafeBytes(of: frameIndex.littleEndian) { bytes in
            packet.append(contentsOf: bytes)
        }
        packet.append(pcmData.prefix(12))
        return packet
    }

    static func packetDeliverySummary(_ deliveries: [PacketDelivery]) -> String {
        deliveries.prefix(24)
            .map { "\($0.sequenceNumber):\($0.transport.diagnosticsValue):+\($0.deltaFrames)" }
            .joined(separator: ",")
    }

    static func voiceDeliverySummary(
        _ deliveries: [VoiceFrameDelivery],
        playbackProfile: MediaSessionPlaybackProfile
    ) -> String {
        let prefix = deliveries.prefix(30)
            .map { "\($0.frameIndex)\($0.isFlushFrame ? "f" : ""):+\($0.deltaFrames)" }
            .joined(separator: ",")
        return "profile=\(playbackProfile) deliveries=\(prefix)"
    }

    static func loopbackDeliverySummary(
        _ deliveries: [LoopbackDelivery],
        playbackProfile: MediaSessionPlaybackProfile
    ) -> String {
        let prefix = deliveries.prefix(30)
            .map {
                let frames = $0.frames
                    .map { "\($0.frameIndex)\($0.isFlushFrame ? "f" : "")" }
                    .joined(separator: "+")
                return "\($0.sequenceNumber):\($0.transport.diagnosticsValue):[\(frames)]:+\($0.deltaFrames)"
            }
            .joined(separator: ",")
        return "profile=\(playbackProfile) deliveries=\(prefix)"
    }
}

private extension Array where Element == AudioFuzzTests.VoiceFrameDelivery {
    var lastSourceFrameIndex: UInt64 {
        self.last { !$0.isFlushFrame }?.frameIndex ?? 0
    }
}

private extension IncomingAudioPayloadTransport {
    static var fuzzCases: [IncomingAudioPayloadTransport] {
        [.directQuic, .mediaRelayPacket, .mediaRelayTcp, .relayWebSocket]
    }

    var isUnorderedPacketMedia: Bool {
        self == .directQuic || self == .mediaRelayPacket
    }
}
