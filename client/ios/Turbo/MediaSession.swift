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

nonisolated enum MediaSessionReceivePlaybackReadiness: Equatable, Sendable {
    case ready
    case notReady(reason: Reason)

    nonisolated enum Reason: String, Equatable, Sendable {
        case idle
        case preparing
        case systemAudioActivation
        case recovering
        case closed
        case failed
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var diagnosticsValue: String {
        switch self {
        case .ready:
            return "ready"
        case .notReady(let reason):
            return reason.rawValue
        }
    }
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
    let dropsPendingPayloadsWhenTransportBecomesAvailable: Bool
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
        dropsPendingPayloadsWhenTransportBecomesAvailable: true,
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
        dropsPendingPayloadsWhenTransportBecomesAvailable: true,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 220_000_000
    )

    static let orderedContinuity = MediaTransportSenderConfiguration(
        maximumPendingPayloads: 160,
        maximumPayloadsPerMessage: 8,
        payloadBatchCollectionNanoseconds: 120_000_000,
        minimumPayloadDispatchSpacingNanoseconds: 0,
        maximumInFlightSends: 1,
        sendTimeoutNanoseconds: nil,
        slowSendDropThresholdNanoseconds: nil,
        dropsPendingPayloadsAfterSlowSend: false,
        dropsPendingPayloadsWhenTransportBecomesAvailable: false,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 2_000_000_000
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
        dropsPendingPayloadsWhenTransportBecomesAvailable: false,
        retainedNewestPayloadsAfterSlowSend: 0,
        stopDrainTimeoutNanoseconds: 1_500_000_000
    )
}

nonisolated enum MediaTransportPolicy: String, Equatable {
    case directLowLatency = "direct-low-latency"
    case fastRelayBalanced = "fast-relay-balanced"
    case orderedContinuity = "ordered-continuity"
    case wakeBackgroundContinuity = "wake-background-continuity"

    var playbackProfile: MediaSessionPlaybackProfile {
        switch self {
        case .directLowLatency:
            return .lowLatency
        case .fastRelayBalanced:
            return .fastRelayBalanced
        case .orderedContinuity:
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
        case .orderedContinuity:
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
        case .orderedContinuity:
            return .orderedContinuity
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
        case .orderedContinuity, .wakeBackgroundContinuity:
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
    nonisolated var state: MediaConnectionState { get }
    nonisolated var receivePlaybackReadiness: MediaSessionReceivePlaybackReadiness { get }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?)
    func updateSenderConfiguration(_ configuration: MediaTransportSenderConfiguration)
    func resetOutgoingAudioTransport(reason: String) async
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
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?
    ) async -> Bool
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?,
        playbackDeadlineNanoseconds: UInt64?
    ) async -> Bool
    nonisolated
    func currentRemoteAudioReceiveEpoch() -> UInt64
    func beginRemoteAudioReceiveEpoch()
    func audioRouteDidChange(allowCaptureRefresh: Bool) async
    func hasPendingPlayback() -> Bool
    func close(deactivateAudioSession: Bool)
}

protocol TransportArrivalAwareMediaSession: MediaSession {
    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?,
        playbackDeadlineNanoseconds: UInt64?,
        transportReceivedAtNanoseconds: UInt64?
    ) async -> Bool
}

extension MediaSession {
    nonisolated var receivePlaybackReadiness: MediaSessionReceivePlaybackReadiness {
        switch state {
        case .connected:
            return .ready
        case .preparing:
            return .notReady(reason: .preparing)
        case .idle:
            return .notReady(reason: .idle)
        case .failed:
            return .notReady(reason: .failed)
        case .closed:
            return .notReady(reason: .closed)
        }
    }

    func updateSenderConfiguration(_ configuration: MediaTransportSenderConfiguration) {}

    func resetOutgoingAudioTransport(reason: String) async {}

    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat) {}

    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) {}

    func beginRemoteAudioReceiveEpoch() {}

    func audioRouteDidChange() async {
        await audioRouteDidChange(allowCaptureRefresh: true)
    }

    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(_ payload: String) async -> Bool {
        await receiveRemoteAudioChunk(payload, playbackProfile: .lowLatency)
    }

    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch _: UInt64?
    ) async -> Bool {
        await receiveRemoteAudioChunk(payload, playbackProfile: playbackProfile)
    }

    @discardableResult
    nonisolated
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?,
        playbackDeadlineNanoseconds _: UInt64?
    ) async -> Bool {
        await receiveRemoteAudioChunk(
            payload,
            playbackProfile: playbackProfile,
            expectedReceiveEpoch: expectedReceiveEpoch
        )
    }

    nonisolated
    func currentRemoteAudioReceiveEpoch() -> UInt64 { 0 }

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
    senderConfiguration: MediaTransportSenderConfiguration = .orderedContinuity,
    outboundVoiceMediaPolicy: VoiceMediaPayloadFormat = .opusV2,
    outboundOpusEncodingPolicy: OpusVoiceEncodingPolicy = .reliableFallback,
    voiceMediaCoreMode: VoiceMediaCoreMode = TurboVoiceMediaCoreDebugOverride.liveMode()
) -> any MediaSession {
    #if targetEnvironment(simulator)
    _ = shouldUseRealDeviceMediaSession(isSimulator: true, supportsWebSocket: supportsWebSocket)
    // Simulator scenarios validate control-plane behavior, not real audio I/O.
    return StubRelayMediaSession()
    #else
    guard shouldUseRealDeviceMediaSession(
        isSimulator: false,
        supportsWebSocket: supportsWebSocket
    ) else {
        return StubRelayMediaSession()
    }
    return PCMWebSocketMediaSession(
        sendAudioChunk: sendAudioChunk,
        reportEvent: reportEvent,
        senderConfiguration: senderConfiguration,
        outboundVoiceMediaPolicy: outboundVoiceMediaPolicy,
        outboundOpusEncodingPolicy: outboundOpusEncodingPolicy,
        voiceMediaCoreMode: voiceMediaCoreMode
    )
    #endif
}

nonisolated
func shouldUseRealDeviceMediaSession(
    isSimulator: Bool,
    supportsWebSocket: Bool
) -> Bool {
    // Runtime WebSocket support is a control-plane capability. Physical devices
    // still need the real media engine for Direct QUIC and Fast Relay media.
    _ = supportsWebSocket
    return !isSimulator
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

    func updateSenderConfiguration(_ configuration: MediaTransportSenderConfiguration) {}

    func resetOutgoingAudioTransport(reason: String) async {}

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

    func audioRouteDidChange(allowCaptureRefresh _: Bool) async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        isStarted = false
        state = .closed
    }
}
