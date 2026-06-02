import Foundation
import AVFAudio

nonisolated enum MediaConnectionState: Equatable {
    case idle
    case preparing
    case connected
    case failed(String)
    case closed
}

nonisolated enum MediaSessionActivationMode: Equatable {
    case appManaged
    case systemActivated
}

nonisolated enum MediaSessionStartupMode: Equatable {
    case interactive
    case playbackOnly
}

nonisolated enum MediaSessionPlaybackProfile: Equatable {
    case lowLatency
    case fastRelayBalanced
    case relayJitterBuffered
    case wakeBackgroundContinuity
}

nonisolated struct MediaTransportPlaybackCushionConfiguration: Equatable {
    let minimumBufferCount: Int
    let timeoutNanoseconds: UInt64
}

nonisolated struct MediaTransportSenderConfiguration: Equatable {
    let maximumPendingPayloads: Int
    let maximumPayloadsPerMessage: Int
    let payloadBatchCollectionNanoseconds: UInt64
    let minimumPayloadDispatchSpacingNanoseconds: UInt64
    let maximumInFlightSends: Int
    let sendTimeoutNanoseconds: UInt64?
    let slowSendDropThresholdNanoseconds: UInt64?
    let dropsPendingPayloadsAfterSlowSend: Bool
    let retainedNewestPayloadsAfterSlowSend: Int
    let stopDrainTimeoutNanoseconds: UInt64?

    static let directLowLatency = MediaTransportSenderConfiguration(
        maximumPendingPayloads: 32,
        maximumPayloadsPerMessage: 1,
        payloadBatchCollectionNanoseconds: 0,
        minimumPayloadDispatchSpacingNanoseconds: VoiceFrameAccumulator.frameDurationNanoseconds,
        maximumInFlightSends: 1,
        sendTimeoutNanoseconds: 250_000_000,
        slowSendDropThresholdNanoseconds: 250_000_000,
        dropsPendingPayloadsAfterSlowSend: true,
        retainedNewestPayloadsAfterSlowSend: 1,
        stopDrainTimeoutNanoseconds: 180_000_000
    )

    static let fastRelayBalanced = MediaTransportSenderConfiguration(
        maximumPendingPayloads: 32,
        maximumPayloadsPerMessage: 1,
        payloadBatchCollectionNanoseconds: 0,
        minimumPayloadDispatchSpacingNanoseconds: VoiceFrameAccumulator.frameDurationNanoseconds,
        maximumInFlightSends: 4,
        sendTimeoutNanoseconds: 750_000_000,
        slowSendDropThresholdNanoseconds: 750_000_000,
        dropsPendingPayloadsAfterSlowSend: true,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 220_000_000
    )

    static let websocketContinuity = MediaTransportSenderConfiguration(
        maximumPendingPayloads: 40,
        maximumPayloadsPerMessage: 5,
        payloadBatchCollectionNanoseconds: 80_000_000,
        minimumPayloadDispatchSpacingNanoseconds: 0,
        maximumInFlightSends: 1,
        sendTimeoutNanoseconds: 750_000_000,
        slowSendDropThresholdNanoseconds: nil,
        dropsPendingPayloadsAfterSlowSend: false,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 1_200_000_000
    )

    static let wakeBackgroundContinuity = MediaTransportSenderConfiguration(
        maximumPendingPayloads: 24,
        maximumPayloadsPerMessage: 5,
        payloadBatchCollectionNanoseconds: 0,
        minimumPayloadDispatchSpacingNanoseconds: 0,
        maximumInFlightSends: 1,
        sendTimeoutNanoseconds: nil,
        slowSendDropThresholdNanoseconds: nil,
        dropsPendingPayloadsAfterSlowSend: false,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 1_500_000_000
    )
}

nonisolated enum MediaTransportPolicy: String, Equatable {
    case directLowLatency = "direct-low-latency"
    case fastRelayBalanced = "fast-relay-balanced"
    case websocketContinuity = "websocket-continuity"
    case wakeBackgroundContinuity = "wake-background-continuity"

    var playbackProfile: MediaSessionPlaybackProfile {
        switch self {
        case .directLowLatency:
            return .lowLatency
        case .fastRelayBalanced:
            return .fastRelayBalanced
        case .websocketContinuity:
            return .relayJitterBuffered
        case .wakeBackgroundContinuity:
            return .wakeBackgroundContinuity
        }
    }

    var playbackCushion: MediaTransportPlaybackCushionConfiguration {
        switch self {
        case .directLowLatency:
            return MediaTransportPlaybackCushionConfiguration(
                minimumBufferCount: 4,
                timeoutNanoseconds: 80_000_000
            )
        case .fastRelayBalanced:
            return MediaTransportPlaybackCushionConfiguration(
                minimumBufferCount: 5,
                timeoutNanoseconds: 120_000_000
            )
        case .websocketContinuity:
            return MediaTransportPlaybackCushionConfiguration(
                minimumBufferCount: 7,
                timeoutNanoseconds: 200_000_000
            )
        case .wakeBackgroundContinuity:
            return MediaTransportPlaybackCushionConfiguration(
                minimumBufferCount: 8,
                timeoutNanoseconds: 280_000_000
            )
        }
    }

    var senderConfiguration: MediaTransportSenderConfiguration {
        switch self {
        case .directLowLatency:
            return .directLowLatency
        case .fastRelayBalanced:
            return .fastRelayBalanced
        case .websocketContinuity:
            return .websocketContinuity
        case .wakeBackgroundContinuity:
            return .wakeBackgroundContinuity
        }
    }

    func opusEncodingPolicy(
        observedPacketLossPercent: Int = 0
    ) -> OpusVoiceEncodingPolicy {
        switch self {
        case .directLowLatency, .fastRelayBalanced:
            return .packetLane(
                bitrate: 40_000,
                observedPacketLossPercent: observedPacketLossPercent
            )
        case .websocketContinuity, .wakeBackgroundContinuity:
            return .reliableFallback
        }
    }
}

nonisolated struct MediaSessionAudioConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let shouldConfigureSession: Bool
    let shouldActivateSession: Bool
}

nonisolated enum MediaSessionAudioPolicy {
    static let routeCapableOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP,
        .allowBluetoothA2DP,
    ]

    static func configuration(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) -> MediaSessionAudioConfiguration {
        // Keep the category aligned with Apple's PTT guidance. System-activated
        // receive paths preserve Apple's session; app-managed paths must activate
        // so foreground playback-only audio is audible immediately.
        let shouldActivateSession = activationMode == .appManaged
        let shouldConfigureSession = !(activationMode == .systemActivated && startupMode == .playbackOnly)

        switch startupMode {
        case .interactive:
            return MediaSessionAudioConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: routeCapableOptions,
                shouldConfigureSession: shouldConfigureSession,
                shouldActivateSession: shouldActivateSession
            )
        case .playbackOnly:
            return MediaSessionAudioConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: routeCapableOptions,
                shouldConfigureSession: shouldConfigureSession,
                shouldActivateSession: shouldActivateSession
            )
        }
    }
}

protocol MediaSessionDelegate: AnyObject {
    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState)
    func mediaSession(_ session: MediaSession, didMeasureLocalAudioLevel level: Double)
    func mediaSessionDidDrainPendingPlayback(_ session: MediaSession)
}

extension MediaSessionDelegate {
    func mediaSession(_ session: MediaSession, didMeasureLocalAudioLevel level: Double) {}
    func mediaSessionDidDrainPendingPlayback(_ session: MediaSession) {}
}

protocol MediaSession: AnyObject {
    var delegate: MediaSessionDelegate? { get set }
    var state: MediaConnectionState { get }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?)
    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat)
    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy)
    func start(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) async throws
    func startSendingAudio() async throws
    func stopSendingAudio() async throws
    func abortSendingAudio() async
    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) async -> Bool
    func beginRemoteAudioReceiveEpoch()
    func audioRouteDidChange() async
    func hasPendingPlayback() -> Bool
    func close(deactivateAudioSession: Bool)
}

extension MediaSession {
    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat) {}

    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) {}

    func beginRemoteAudioReceiveEpoch() {}

    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(_ payload: String) async -> Bool {
        await receiveRemoteAudioChunk(payload, playbackProfile: .lowLatency)
    }

    func close() {
        close(deactivateAudioSession: true)
    }

    func abortSendingAudio() async {
        try? await stopSendingAudio()
    }
}

func makeDefaultMediaSession(
    supportsWebSocket: Bool,
    sendAudioChunk: (@Sendable (String) async throws -> Void)?,
    reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil,
    senderConfiguration: MediaTransportSenderConfiguration = .websocketContinuity,
    outboundVoiceMediaPolicy: VoiceMediaPayloadFormat = .legacyPCM,
    outboundOpusEncodingPolicy: OpusVoiceEncodingPolicy = .reliableFallback
) -> any MediaSession {
    #if targetEnvironment(simulator)
    // Simulator scenarios validate control-plane behavior, not real audio I/O.
    return StubRelayMediaSession()
    #else
    if supportsWebSocket {
        return PCMWebSocketMediaSession(
            sendAudioChunk: sendAudioChunk,
            reportEvent: reportEvent,
            senderConfiguration: senderConfiguration,
            outboundVoiceMediaPolicy: outboundVoiceMediaPolicy,
            outboundOpusEncodingPolicy: outboundOpusEncodingPolicy
        )
    }
    return StubRelayMediaSession()
    #endif
}

final class StubRelayMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?

    private(set) var state: MediaConnectionState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.mediaSession(self, didChange: state)
        }
    }

    private var isStarted = false

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat) {}

    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        guard !isStarted else { return }
        state = .preparing
        isStarted = true
        state = .connected
    }

    func startSendingAudio() async throws {
        if !isStarted {
            try await start(activationMode: .appManaged, startupMode: .interactive)
        }
    }

    func stopSendingAudio() async throws {}

    func abortSendingAudio() async {}

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile _: MediaSessionPlaybackProfile
    ) async -> Bool { true }

    func audioRouteDidChange() async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        isStarted = false
        state = .closed
    }
}
