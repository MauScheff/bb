//
//  PTTViewModel+TransmitTiming.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

enum OutgoingAudioSendError: LocalizedError, Sendable {
    case remoteReceiverAudioNotReady

    var errorDescription: String? {
        switch self {
        case .remoteReceiverAudioNotReady:
            return "remote receiver audio was not ready"
        }
    }
}

actor RemoteParticipantClearResultBox {
    private var result: Result<Void, Error>?

    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
    }

    func currentResult() -> Result<Void, Error>? {
        result
    }
}

extension PTTViewModel {
    var wakePlaybackFallbackDelayNanoseconds: UInt64 { 3_500_000_000 }
    var wakeCapableInitialAudioSendGraceNanoseconds: UInt64 { 300_000_000 }
    var wakeCapablePostReleaseAudioSendGraceNanoseconds: UInt64 { 4_500_000_000 }
    var mediaSessionRetryCooldown: TimeInterval { 0.75 }
    var deferredInteractivePrewarmRecoveryDelayNanoseconds: UInt64 { 500_000_000 }
    var transmitLeaseRenewIntervalNanoseconds: UInt64 { 1_000_000_000 }
    var minimumUsableBackendTransmitLeaseSeconds: TimeInterval { 3.0 }
    var remoteReceiverAudioReadyGateTimeoutNanoseconds: UInt64 { 6_000_000_000 }
    var remoteReceiverAudioReadyGatePollNanoseconds: UInt64 { 50_000_000 }
    var remoteParticipantClearBeforeTransmitTimeoutNanoseconds: UInt64 { 250_000_000 }

    func startTransmitStartupTiming(
        for request: TransmitRequestContext,
        source: String
    ) {
        clearFirstAudioPlaybackAckState(
            contactID: request.contactID,
            channelID: request.backendChannelID,
            senderDeviceID: backendServices?.deviceID ?? backendConfig?.deviceID
        )
        transmitStartupTiming.start(
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            backendChannelID: request.backendChannelID,
            source: source
        )
        recordTransmitStartupTiming(
            stage: "press-requested",
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            channelID: request.backendChannelID
        )
    }

    func recordTransmitStartupTiming(
        stage: String,
        contactID: UUID? = nil,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:]
    ) {
        let resolvedContactID = contactID ?? transmitStartupTiming.contactID
        let resolvedChannelUUID = channelUUID ?? transmitStartupTiming.channelUUID
        let resolvedChannelID = channelID ?? transmitStartupTiming.backendChannelID
        let elapsedMilliseconds = transmitStartupTiming.noteStage(stage)
        var metadata = extraMetadata
        metadata["stage"] = stage
        metadata["pressToStageMs"] = elapsedMilliseconds.map(String.init) ?? "unknown"
        metadata["contactId"] = resolvedContactID?.uuidString ?? "none"
        metadata["channelUUID"] = resolvedChannelUUID?.uuidString ?? "none"
        metadata["channelId"] = resolvedChannelID ?? "none"
        metadata["source"] = transmitStartupTiming.source ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["isPTTAudioSessionActive"] = String(isPTTAudioSessionActive)
        metadata["backendWebSocketConnected"] = String(backendRuntime.isWebSocketConnected)
        if let resolvedContactID {
            metadata["directQuicActive"] = String(shouldUseDirectQuicTransport(for: resolvedContactID))
        }
        diagnostics.record(
            subsystem,
            message: "Transmit startup timing",
            metadata: metadata
        )
    }

    func recordFirstTransmitStartupTimingStageIfAbsent(
        _ stage: String,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:]
    ) {
        guard transmitStartupTiming.elapsedMilliseconds(for: stage) == nil else {
            return
        }
        recordTransmitStartupTiming(
            stage: stage,
            subsystem: subsystem,
            metadata: extraMetadata
        )
    }

    func recordTransmitStartupTimingForMediaEvent(
        _ message: String,
        metadata: [String: String]
    ) {
        let stage: String?
        switch message {
        case "Captured local audio buffer":
            stage = "first-audio-captured"
        case "Enqueued outbound audio chunk":
            stage = "first-audio-enqueued"
        case "Dispatching outbound audio transport payload":
            stage = "first-audio-dispatched"
        case "Delivered outbound audio transport payload":
            stage = "first-audio-delivered"
        default:
            stage = nil
        }
        guard let stage else { return }
        recordFirstTransmitStartupTimingStageIfAbsent(
            stage,
            metadata: metadata
        )
    }

    func recordTransmitStartupTimingSummary(
        reason: String,
        contactID: UUID? = nil,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        metadata extraMetadata: [String: String] = [:]
    ) {
        let resolvedContactID = contactID ?? transmitStartupTiming.contactID
        let resolvedChannelUUID = channelUUID ?? transmitStartupTiming.channelUUID
        let resolvedChannelID = channelID ?? transmitStartupTiming.backendChannelID
        let stages = [
            "press-requested",
            "system-handoff-started",
            "system-handoff-requested",
            "system-transmit-began",
            "system-audio-session-activated",
            "backend-lease-requested",
            "backend-lease-granted",
            "direct-quic-transmit-prepare-requested",
            "direct-quic-transmit-prepare-sent",
            "media-session-start-requested",
            "media-session-start-completed",
            "early-media-session-start-requested",
            "early-media-session-start-completed",
            "audio-capture-start-requested",
            "audio-capture-start-completed",
            "early-audio-capture-start-requested",
            "early-audio-capture-start-completed",
            "first-audio-captured",
            "first-audio-enqueued",
            "first-audio-dispatched",
            "first-audio-delivered",
            "transmit-start-signal-sent",
            "startup-completed",
            "system-transmit-ended",
        ]
        var metadata = extraMetadata
        metadata["reason"] = reason
        metadata["contactId"] = resolvedContactID?.uuidString ?? "none"
        metadata["channelUUID"] = resolvedChannelUUID?.uuidString ?? "none"
        metadata["channelId"] = resolvedChannelID ?? "none"
        metadata["source"] = transmitStartupTiming.source ?? "unknown"
        metadata["totalPressElapsedMs"] = transmitStartupTiming.elapsedMilliseconds().map(String.init) ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["isPTTAudioSessionActive"] = String(isPTTAudioSessionActive)
        metadata["backendWebSocketConnected"] = String(backendRuntime.isWebSocketConnected)
        if let resolvedContactID {
            metadata["directQuicActive"] = String(shouldUseDirectQuicTransport(for: resolvedContactID))
        }
        for stage in stages {
            if let elapsed = transmitStartupTiming.elapsedMilliseconds(for: stage) {
                metadata["\(stage)Ms"] = String(elapsed)
            }
        }
        if let appleStarted = transmitStartupTiming.elapsedMilliseconds(for: "system-handoff-requested"),
           let appleReady = transmitStartupTiming.elapsedMilliseconds(for: "system-audio-session-activated") {
            metadata["appleActivationDeltaMs"] = String(max(0, appleReady - appleStarted))
        }
        if let backendRequested = transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-requested"),
           let backendGranted = transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-granted") {
            metadata["backendLeaseDeltaMs"] = String(max(0, backendGranted - backendRequested))
        }
        let captureStartCandidates = [
            transmitStartupTiming.elapsedMilliseconds(for: "audio-capture-start-requested"),
            transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-requested"),
        ].compactMap { $0 }
        if let captureRequested = captureStartCandidates.min(),
           let firstCaptured = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-captured") {
            metadata["captureToFirstAudioDeltaMs"] = String(max(0, firstCaptured - captureRequested))
        }
        if let captured = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-captured"),
           let delivered = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-delivered") {
            metadata["firstAudioTransportDeltaMs"] = String(max(0, delivered - captured))
        }
        diagnostics.record(
            .media,
            message: "Transmit startup timing summary",
            metadata: metadata
        )
    }

    func recordWakeReceiveTiming(
        stage: String,
        contactID: UUID,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:],
        ifAbsent: Bool = false
    ) {
        guard pttWakeRuntime.timing.contactID == contactID else { return }
        if ifAbsent {
            pttWakeRuntime.noteTimingStage(stage, for: contactID, ifAbsent: true)
        } else {
            pttWakeRuntime.noteTimingStage(stage, for: contactID)
        }
        let elapsedMilliseconds = pttWakeRuntime.timing.elapsedMilliseconds(for: stage)
        var metadata = extraMetadata
        metadata["stage"] = stage
        metadata["wakeToStageMs"] = elapsedMilliseconds.map(String.init) ?? "unknown"
        metadata["contactId"] = contactID.uuidString
        metadata["channelUUID"] =
            channelUUID?.uuidString
            ?? pttWakeRuntime.timing.channelUUID?.uuidString
            ?? "none"
        metadata["channelId"] = channelID ?? pttWakeRuntime.timing.channelID ?? "none"
        metadata["source"] = pttWakeRuntime.timing.source ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["incomingWakeActivationState"] =
            pttWakeRuntime.incomingWakeActivationState(for: contactID).map(String.init(describing:)) ?? "none"
        metadata["bufferedAudioChunkCount"] = String(pttWakeRuntime.bufferedAudioChunkCount(for: contactID))
        diagnostics.record(
            subsystem,
            message: "Wake receive timing",
            metadata: metadata
        )
    }

    func recordWakeReceiveTimingForMediaEvent(
        _ message: String,
        metadata: [String: String]
    ) {
        guard let contactID = mediaSessionContactID,
              pttWakeRuntime.timing.contactID == contactID else {
            return
        }
        let stage: String?
        switch message {
        case "Media session start requested":
            stage = "media-session-start-requested"
        case "Media session start completed":
            stage = "media-session-start-completed"
        case "Playback buffer scheduled":
            stage = "first-playback-buffer-scheduled"
        case "Playback engine started":
            stage = "playback-engine-started"
        case "Playback node started":
            stage = metadata["reason"] == "system-activated-playback-prime"
                ? "playback-node-primed"
                : "playback-node-started"
        case "Playback node startup reasserted":
            stage = "playback-node-startup-reasserted"
        default:
            stage = nil
        }
        guard let stage else { return }
        recordWakeReceiveTiming(
            stage: stage,
            contactID: contactID,
            metadata: metadata,
            ifAbsent: stage == "first-playback-buffer-scheduled"
        )
    }

    func recordWakeReceiveTimingSummary(
        reason: String,
        contactID: UUID,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        metadata extraMetadata: [String: String] = [:]
    ) {
        guard pttWakeRuntime.timing.contactID == contactID else { return }
        let stages = [
            "wake-started",
            "provisional-wake-candidate-created",
            "incoming-push-result-active-participant-returned",
            "incoming-push-confirmed",
            "backend-peer-transmit-prepare-observed",
            "backend-peer-transmit-refresh-observed",
            "backend-peer-transmitting-observed",
            "active-remote-participant-requested",
            "active-remote-participant-completed",
            "active-remote-participant-failed",
            "direct-quic-audio-received",
            "signal-audio-received",
            "first-audio-buffered",
            "latest-audio-buffered",
            "system-audio-activation-observed",
            "media-session-start-requested",
            "media-session-start-completed",
            "playback-engine-started",
            "playback-node-primed",
            "playback-node-started",
            "playback-node-startup-reasserted",
            "buffered-audio-flush-started",
            "first-playback-buffer-scheduled",
            "buffered-audio-flush-completed",
            "app-managed-fallback-started",
            "app-managed-fallback-flush-started",
            "app-managed-fallback-flush-completed",
            "fallback-deferred-until-foreground",
            "system-activation-interrupted-by-transmit-end",
        ]
        var metadata = extraMetadata
        metadata["reason"] = reason
        metadata["contactId"] = contactID.uuidString
        metadata["channelUUID"] =
            channelUUID?.uuidString
            ?? pttWakeRuntime.timing.channelUUID?.uuidString
            ?? "none"
        metadata["channelId"] = channelID ?? pttWakeRuntime.timing.channelID ?? "none"
        metadata["source"] = pttWakeRuntime.timing.source ?? "unknown"
        metadata["totalWakeElapsedMs"] = pttWakeRuntime.timing.elapsedMilliseconds().map(String.init) ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["incomingWakeActivationState"] =
            pttWakeRuntime.incomingWakeActivationState(for: contactID).map(String.init(describing:)) ?? "none"
        metadata["bufferedAudioChunkCount"] = String(pttWakeRuntime.bufferedAudioChunkCount(for: contactID))
        for stage in stages {
            if let elapsed = pttWakeRuntime.timing.elapsedMilliseconds(for: stage) {
                metadata["\(stage)Ms"] = String(elapsed)
            }
        }
        if let started = pttWakeRuntime.timing.elapsedMilliseconds(for: "wake-started"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["wakeToSystemActivationDeltaMs"] = String(max(0, activated - started))
        }
        if let firstBuffered = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["firstBufferedToSystemActivationDeltaMs"] = String(max(0, activated - firstBuffered))
        }
        if let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed"),
           let playbackScheduled = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-playback-buffer-scheduled") {
            metadata["systemActivationToFirstPlaybackScheduledDeltaMs"] = String(max(0, playbackScheduled - activated))
        }
        if let firstBuffered = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
           let playbackScheduled = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-playback-buffer-scheduled") {
            metadata["firstBufferedToFirstPlaybackScheduledDeltaMs"] = String(max(0, playbackScheduled - firstBuffered))
        }
        if let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["activeParticipantRequestedToDidActivateMs"] = String(activated - requested)
        }
        if let completed = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-completed"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["activeParticipantCompletedToDidActivateMs"] = String(activated - completed)
        }
        let firstAudioReceived = [
            pttWakeRuntime.timing.elapsedMilliseconds(for: "direct-quic-audio-received"),
            pttWakeRuntime.timing.elapsedMilliseconds(for: "signal-audio-received"),
            pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
        ]
        .compactMap { $0 }
        .min()
        if let firstAudioReceived,
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["firstAudioToActiveParticipantRequestedMs"] = String(requested - firstAudioReceived)
        }
        if let backendPeerTransmit = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmitting-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerTransmitToActiveParticipantRequestedMs"] = String(requested - backendPeerTransmit)
        }
        if let backendPeerPrepare = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmit-prepare-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerPrepareToActiveParticipantRequestedMs"] = String(requested - backendPeerPrepare)
        }
        if let backendPeerRefresh = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmit-refresh-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerRefreshToActiveParticipantRequestedMs"] = String(requested - backendPeerRefresh)
        }
        if let incomingPushResult = pttWakeRuntime.timing.elapsedMilliseconds(for: "incoming-push-result-active-participant-returned"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["incomingPushResultToDidActivateMs"] = String(activated - incomingPushResult)
        }
        diagnostics.record(
            .media,
            message: "Wake receive timing summary",
            metadata: metadata
        )
    }

}
