import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
import UserNotifications
import Intents
import CryptoKit
import TurboEngine

@testable import BeepBeep

@MainActor
final class TestPTTCallbackRecorder {
    struct JoinFailure {
        let channelID: UUID
        let error: Error
    }

    var joinedChannelIDs: [UUID] = []
    var leftChannelIDs: [UUID] = []
    var didBeginTransmittingChannelIDs: [UUID] = []
    var didEndTransmittingChannelIDs: [UUID] = []
    var activatedAudioSessionCategories: [AVAudioSession.Category] = []
    var deactivatedAudioSessionCategories: [AVAudioSession.Category] = []
    var joinFailures: [JoinFailure] = []
    var incomingPushes: [(UUID, TurboPTTPushPayload)] = []
    var ephemeralPushTokens: [Data] = []

    var callbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.ephemeralPushTokens.append(token)
            },
            receivedIncomingPush: { [weak self] channelID, payload in
                self?.incomingPushes.append((channelID, payload))
            },
            willReturnIncomingPushResult: { _, _, _ in },
            didJoinChannel: { [weak self] channelID, _ in
                self?.joinedChannelIDs.append(channelID)
            },
            didLeaveChannel: { [weak self] channelID, _ in
                self?.leftChannelIDs.append(channelID)
            },
            failedToJoinChannel: { [weak self] channelID, error in
                self?.joinFailures.append(JoinFailure(channelID: channelID, error: error))
            },
            failedToLeaveChannel: { _, _ in },
            didBeginTransmitting: { [weak self] channelID, _ in
                self?.didBeginTransmittingChannelIDs.append(channelID)
            },
            didEndTransmitting: { [weak self] channelID, _ in
                self?.didEndTransmittingChannelIDs.append(channelID)
            },
            failedToBeginTransmitting: { _, _ in },
            failedToStopTransmitting: { _, _ in },
            didActivateAudioSession: { [weak self] session in
                self?.activatedAudioSessionCategories.append(session.category)
            },
            didDeactivateAudioSession: { [weak self] session in
                self?.deactivatedAudioSessionCategories.append(session.category)
            },
            willRequestRestoredChannelDescriptor: { _ in },
            descriptorForRestoredChannel: { _ in
                PTChannelDescriptor(name: "Restored", image: nil)
            },
            restoredChannel: { _ in }
        )
    }
}

@MainActor
final class RecordingPTTSystemClient: PTTSystemClientProtocol {
    var isReady: Bool = true
    var modeDescription: String { "test" }
    var activeRemoteParticipantError: Error?
    var activeRemoteParticipantDelayNanoseconds: UInt64?
    private(set) var joinRequests: [UUID] = []
    private(set) var leaveRequests: [UUID] = []
    private(set) var beginTransmitRequests: [UUID] = []
    private(set) var stopTransmitRequests: [UUID] = []
    private(set) var transmissionModeUpdates: [(mode: PTTransmissionMode, channelUUID: UUID)] = []
    private(set) var activeRemoteParticipantUpdates: [(name: String?, channelUUID: UUID)] = []
    private(set) var accessoryButtonEventUpdates: [(enabled: Bool, channelUUID: UUID)] = []
    private(set) var serviceStatusUpdates: [(status: PTServiceStatus, channelUUID: UUID)] = []

    func configure(callbacks _: PTTSystemClientCallbacks) async throws {}

    func joinChannel(channelUUID: UUID, name _: String) throws {
        joinRequests.append(channelUUID)
    }

    func leaveChannel(channelUUID: UUID) throws {
        leaveRequests.append(channelUUID)
    }
    func beginTransmitting(channelUUID: UUID) throws {
        beginTransmitRequests.append(channelUUID)
    }
    func stopTransmitting(channelUUID: UUID) throws {
        stopTransmitRequests.append(channelUUID)
    }
    func setTransmissionMode(_ mode: PTTransmissionMode, channelUUID: UUID) async throws {
        transmissionModeUpdates.append((mode: mode, channelUUID: channelUUID))
    }
    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws {
        if let activeRemoteParticipantDelayNanoseconds {
            try? await Task.sleep(nanoseconds: activeRemoteParticipantDelayNanoseconds)
        }
        activeRemoteParticipantUpdates.append((name: name, channelUUID: channelUUID))
        if let activeRemoteParticipantError {
            throw activeRemoteParticipantError
        }
    }
    func setAccessoryButtonEventsEnabled(_ enabled: Bool, channelUUID: UUID) async throws {
        accessoryButtonEventUpdates.append((enabled: enabled, channelUUID: channelUUID))
    }
    func setServiceStatus(_ status: PTServiceStatus, channelUUID: UUID) async throws {
        serviceStatusUpdates.append((status: status, channelUUID: channelUUID))
    }
    func updateChannelDescriptor(name _: String, channelUUID _: UUID) async throws {}
}

final class RecordingMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private(set) var state: MediaConnectionState = .idle
    private(set) var closedDeactivateAudioSessionFlags: [Bool] = []
    private(set) var startSendingAudioCallCount = 0
    private(set) var stopSendingAudioCallCount = 0
    private(set) var abortSendingAudioCallCount = 0
    private(set) var beginReceiveEpochCallCount = 0
    private(set) var audioRouteDidChangeCallCount = 0
    private(set) var receivedRemoteAudioChunks: [String] = []
    private(set) var receivedPlaybackProfiles: [MediaSessionPlaybackProfile] = []
    private(set) var outboundVoiceMediaPolicyUpdates: [VoiceMediaPayloadFormat] = []
    private(set) var outboundOpusEncodingPolicyUpdates: [OpusVoiceEncodingPolicy] = []
    private(set) var sendAudioChunkConfiguredWhenStopSendingAudio: Bool?
    private(set) var sendAudioChunkConfiguredWhenAbortSendingAudio: Bool?
    private(set) var sendAudioChunkWasClearedAfterStopSendingAudio = false
    private(set) var sendAudioChunkWasClearedAfterAbortSendingAudio = false
    private var currentSendAudioChunk: (@Sendable (String) async throws -> Void)?
    var startSendingAudioDelayNanoseconds: UInt64?
    var audioRouteDidChangeDelayNanoseconds: UInt64?
    var receiveRemoteAudioChunkDelayNanoseconds: UInt64?
    var hasPendingPlaybackResult = false
    var receiveRemoteAudioChunkResult = true

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        currentSendAudioChunk = handler
        if handler == nil, stopSendingAudioCallCount > 0 {
            sendAudioChunkWasClearedAfterStopSendingAudio = true
        }
        if handler == nil, abortSendingAudioCallCount > 0 {
            sendAudioChunkWasClearedAfterAbortSendingAudio = true
        }
    }

    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat) {
        outboundVoiceMediaPolicyUpdates.append(policy)
    }

    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) {
        outboundOpusEncodingPolicyUpdates.append(policy)
    }

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func startSendingAudio() async throws {
        startSendingAudioCallCount += 1
        if let startSendingAudioDelayNanoseconds {
            try? await Task.sleep(nanoseconds: startSendingAudioDelayNanoseconds)
        }
    }

    func stopSendingAudio() async throws {
        stopSendingAudioCallCount += 1
        sendAudioChunkConfiguredWhenStopSendingAudio = currentSendAudioChunk != nil
    }

    func abortSendingAudio() async {
        abortSendingAudioCallCount += 1
        sendAudioChunkConfiguredWhenAbortSendingAudio = currentSendAudioChunk != nil
    }

    func beginRemoteAudioReceiveEpoch() {
        beginReceiveEpochCallCount += 1
    }

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) async -> Bool {
        receivedRemoteAudioChunks.append(payload)
        receivedPlaybackProfiles.append(playbackProfile)
        if let receiveRemoteAudioChunkDelayNanoseconds {
            try? await Task.sleep(nanoseconds: receiveRemoteAudioChunkDelayNanoseconds)
        }
        return receiveRemoteAudioChunkResult
    }

    func audioRouteDidChange() async {
        audioRouteDidChangeCallCount += 1
        if let audioRouteDidChangeDelayNanoseconds {
            try? await Task.sleep(nanoseconds: audioRouteDidChangeDelayNanoseconds)
        }
    }

    func hasPendingPlayback() -> Bool { hasPendingPlaybackResult }

    func waitForReceivedChunkCount(
        _ expectedCount: Int,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if receivedRemoteAudioChunks.count >= expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return receivedRemoteAudioChunks.count >= expectedCount
    }

    func close(deactivateAudioSession: Bool) {
        closedDeactivateAudioSessionFlags.append(deactivateAudioSession)
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}

final class BlockingPlaybackMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private let lock = NSLock()
    private let blockingNanoseconds: UInt64
    private var chunks: [String] = []
    private var threadIsMain: [Bool] = []

    private(set) var state: MediaConnectionState = .connected

    init(blockingNanoseconds: UInt64) {
        self.blockingNanoseconds = blockingNanoseconds
    }

    var receivedRemoteAudioChunks: [String] {
        lock.withLock { chunks }
    }

    var receivedOnMainThread: [Bool] {
        lock.withLock { threadIsMain }
    }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func startSendingAudio() async throws {}

    func stopSendingAudio() async throws {}

    func abortSendingAudio() async {}

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile _: MediaSessionPlaybackProfile
    ) async -> Bool {
        lock.withLock {
            chunks.append(payload)
            threadIsMain.append(Thread.isMainThread)
        }
        if blockingNanoseconds > 0 {
            blockCurrentThread(for: blockingNanoseconds)
        }
        return true
    }

    private func blockCurrentThread(for nanoseconds: UInt64) {
        Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
    }

    func waitForReceivedChunkCount(
        _ expectedCount: Int,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if receivedRemoteAudioChunks.count >= expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return receivedRemoteAudioChunks.count >= expectedCount
    }

    func beginRemoteAudioReceiveEpoch() {}

    func audioRouteDidChange() async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}

final class DelayedStartMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private(set) var state: MediaConnectionState = .idle
    private(set) var startCallCount = 0

    private let delayNanoseconds: UInt64
    private var shouldFinishStart = false
    private var isClosed = false

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        startCallCount += 1
        state = .preparing
        delegate?.mediaSession(self, didChange: .preparing)
        while !shouldFinishStart && !isClosed {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !isClosed else { return }
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func finishStart() {
        shouldFinishStart = true
    }

    func startSendingAudio() async throws {}

    func stopSendingAudio() async throws {}

    func beginRemoteAudioReceiveEpoch() {}

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile _: MediaSessionPlaybackProfile
    ) async -> Bool { true }

    func audioRouteDidChange() async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        isClosed = true
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}
