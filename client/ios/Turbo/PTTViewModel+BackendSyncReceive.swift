//
//  PTTViewModel+BackendSyncReceive.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import UIKit

private enum PendingPlaybackDrainDecision {
    case notPending
    case deferTimeout(elapsedNanoseconds: UInt64, maxNanoseconds: UInt64)
    case exceeded(elapsedNanoseconds: UInt64, maxNanoseconds: UInt64)
}

extension PTTViewModel {
    var encryptedAudioRecoveryMaxBufferedPayloads: Int { 16 }
    var encryptedAudioRecoveryAttempts: Int { 6 }
    var encryptedAudioRecoveryRetryNanoseconds: UInt64 { 250_000_000 }

    private func remoteAudioTimeoutNanoseconds(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) -> UInt64 {
        switch phase {
        case .awaitingFirstAudioChunk:
            if currentApplicationState() == .active,
               !pttWakeRuntime.hasPendingWake(for: contactID) {
                return min(
                    remoteAudioInitialChunkTimeoutNanoseconds,
                    remoteAudioForegroundInitialChunkTimeoutNanoseconds
                )
            }
            return remoteAudioInitialChunkTimeoutNanoseconds
        case .drainingAudio:
            let peerTransmitStillOpen =
                receiveExecutionCoordinator
                    .state
                    .remoteActivityByContactID[contactID]?
                    .phase == .receivingAudio
            let authoritativePeerTransmit =
                selectedChannelSnapshot(for: contactID)?.status == .receiving
                || selectedChannelSnapshot(for: contactID)?.readinessStatus?.isPeerTransmitting == true
            if !peerTransmitStillOpen && !authoritativePeerTransmit {
                return min(
                    remoteAudioSilenceTimeoutNanoseconds,
                    remoteAudioNonAuthoritativePlaybackDrainPollNanoseconds
                )
            }
            return remoteAudioSilenceTimeoutNanoseconds
        }
    }

    func runReceiveExecutionEffect(_ effect: ReceiveExecutionEffect) {
        switch effect {
        case .scheduleRemoteSilenceTimeout(let contactID, let phase, let generation):
            let task = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: self?.remoteAudioTimeoutNanoseconds(for: contactID, phase: phase) ?? 0
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard
                        let activityState = self.receiveExecutionCoordinator
                            .state
                            .remoteActivityByContactID[contactID],
                        activityState.timeoutPhase == phase,
                        activityState.activityGeneration == generation
                    else {
                        return
                    }
                    self.handleRemoteAudioSilenceTimeout(for: contactID, phase: phase)
                }
            }
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: task)

        case .cancelRemoteSilenceTimeout(let contactID):
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)

        case .cancelAllRemoteSilenceTimeouts:
            receiveExecutionRuntime.cancelAllRemoteAudioSilenceTasks()
        }
    }

    func handleRemoteAudioSilenceTimeout(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase? = nil
    ) {
        let resolvedPhase = phase
            ?? receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.timeoutPhase
            ?? .drainingAudio
        if repairExpiredRemoteTransmitLeaseIfNeeded(contactID: contactID) {
            return
        }
        synthesizeMissingRemoteTransmitStopFromAudioSilenceTimeoutIfNeeded(
            for: contactID,
            phase: resolvedPhase
        )
        switch pendingPlaybackDrainDecision(for: contactID, phase: resolvedPhase) {
        case .deferTimeout(let elapsedNanoseconds, let maxNanoseconds):
            diagnostics.record(
                .media,
                message: "Deferred remote audio silence timeout while playback is still draining",
                metadata: [
                    "contactId": contactID.uuidString,
                    "phase": resolvedPhase.rawValue,
                    "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                    "maxMilliseconds": String(maxNanoseconds / 1_000_000),
                ]
            )
            runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: resolvedPhase,
                    generation: receiveExecutionCoordinator
                        .state
                        .remoteActivityByContactID[contactID]?
                        .activityGeneration ?? 0
                )
            )
            return
        case .exceeded(let elapsedNanoseconds, let maxNanoseconds):
            if selectedConversationState(for: contactID).phase == .receiving {
                diagnostics.recordInvariantViolation(
                    invariantID: "selected.receiving_stale_pending_playback_drain",
                    scope: .local,
                    message: "selectedConversationPhase=receiving while pending playback drain exceeded maximum duration",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "phase": resolvedPhase.rawValue,
                        "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                        "maxMilliseconds": String(maxNanoseconds / 1_000_000),
                        "backendChannelStatus": selectedChannelSnapshot(for: contactID)?.status?.rawValue ?? "none",
                        "backendReadiness": selectedChannelSnapshot(for: contactID)?.readinessStatus?.kind ?? "none",
                        "selectedConversationPhase": String(describing: selectedConversationState(for: contactID).phase),
                    ]
                )
            }
        case .notPending:
            break
        }
        if shouldDeferRemoteAudioSilenceTimeout(for: contactID, phase: resolvedPhase) {
            diagnostics.record(
                .media,
                message: "Deferred remote audio silence timeout while peer transmit is authoritative",
                metadata: [
                    "contactId": contactID.uuidString,
                    "phase": resolvedPhase.rawValue,
                    "backendChannelStatus": selectedChannelSnapshot(for: contactID)?.status?.rawValue ?? "none",
                    "remoteActivityActive": String(remoteTransmittingContactIDs.contains(contactID)),
                ]
            )
            runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: resolvedPhase,
                    generation: receiveExecutionCoordinator
                        .state
                        .remoteActivityByContactID[contactID]?
                        .activityGeneration ?? 0
                )
            )
            return
        }
        finishRemoteAudioActivity(
            for: contactID,
            phase: resolvedPhase,
            engineSource: "remote-audio-silence-timeout",
            diagnosticsMessage: resolvedPhase == .awaitingFirstAudioChunk
                ? "Initial remote audio chunk timed out"
                : "Remote audio activity timed out",
            closeMessage: "Closed receive media session after remote audio silence timeout",
            deferPrewarmMessage: "Deferred interactive audio prewarm after remote audio silence timeout"
        )
    }

    func handleRemotePlaybackDrained(
        for contactID: UUID,
        allowMediaPathPreservation: Bool = true
    ) {
        guard mediaSessionContactID == contactID else { return }
        guard
            let activityState = receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID],
            activityState.phase == .drainingAudio
        else {
            return
        }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return }
        guard mediaServices.session()?.hasPendingPlayback() != true else { return }

        finishRemoteAudioActivity(
            for: contactID,
            phase: .drainingAudio,
            engineSource: "remote-playback-drained",
            diagnosticsMessage: "Remote playback drained",
            closeMessage: "Closed receive media session after remote playback drained",
            deferPrewarmMessage: "Deferred interactive audio prewarm after remote playback drained",
            allowMediaPathPreservation: allowMediaPathPreservation
        )
    }

    private func finishRemoteAudioActivity(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase,
        engineSource: String,
        diagnosticsMessage: String,
        closeMessage: String,
        deferPrewarmMessage: String,
        allowMediaPathPreservation: Bool = true
    ) {
        receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)
        receiveExecutionRuntime.replaceRemoteTransmitLeaseExpiryTask(for: contactID, with: nil)
        receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
        syncEngineRemotePlaybackDrained(contactID: contactID, source: engineSource)
        receiveExecutionCoordinator.send(.silenceTimeoutElapsed(contactID: contactID))
        diagnostics.record(
            .media,
            message: diagnosticsMessage,
            metadata: [
                "contactId": contactID.uuidString,
                "phase": phase.rawValue,
            ]
        )
        resetRemoteAudioReceiveRuntime(for: contactID, reason: engineSource)

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            pttWakeRuntime.clear(for: contactID)
            diagnostics.record(
                .pushToTalk,
                message: "Cleared completed wake state after remote audio activity ended",
                metadata: ["contactId": contactID.uuidString]
            )
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            break
        }

        finalizeReceiveMediaSessionIfNeeded(
            for: contactID,
            closeMessage: closeMessage,
            deferPrewarmMessage: deferPrewarmMessage,
            allowMediaPathPreservation: allowMediaPathPreservation
        )
        clearSystemRemoteParticipantIfNeededAfterRemoteAudioEnded(for: contactID)

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
        reconcileAutomaticAudioRouteAfterLiveReceiveIfNeeded(reason: engineSource)
    }

    private func synthesizeMissingRemoteTransmitStopFromAudioSilenceTimeoutIfNeeded(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) {
        guard
            let activityState = receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID]
        else {
            return
        }
        guard activityState.timeoutPhase == phase else { return }
        guard
            !receiveExecutionCoordinator
                .state
                .remoteTransmitStoppedContactIDs
                .contains(contactID)
        else {
            return
        }
        if shouldDeferRemoteAudioSilenceTimeout(for: contactID, phase: phase) {
            return
        }
        guard let channelID =
            contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId
        else {
            return
        }

        syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: "remote-audio-silence-timeout",
            source: "remote-audio-silence-timeout"
        )

        if activityState.phase.hasReceivedAudioChunk {
            markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
        } else {
            clearRemoteAudioActivity(for: contactID)
        }

        diagnostics.record(
            .media,
            level: .notice,
            message: "Synthesized missing remote transmit stop from audio silence timeout",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "phase": phase.rawValue,
                "remoteActivity": String(describing: activityState),
            ]
        )
    }

    private func pendingPlaybackDrainDecision(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) -> PendingPlaybackDrainDecision {
        guard phase == .drainingAudio else { return .notPending }
        guard mediaSessionContactID == contactID else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .notPending
        }
        guard mediaServices.session()?.hasPendingPlayback() == true else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .notPending
        }

        let authoritativePeerTransmit =
            selectedChannelSnapshot(for: contactID)?.status == .receiving
            || selectedChannelSnapshot(for: contactID)?.readinessStatus?.isPeerTransmitting == true
        let maximumDrainNanoseconds =
            authoritativePeerTransmit
            ? remoteAudioPendingPlaybackDrainMaxNanoseconds
            : min(
                remoteAudioPendingPlaybackDrainMaxNanoseconds,
                remoteAudioNonAuthoritativePlaybackDrainMaxNanoseconds
            )
        let elapsedNanoseconds = receiveExecutionRuntime
            .pendingPlaybackDrainDeferralElapsedNanoseconds(for: contactID)
        guard elapsedNanoseconds < maximumDrainNanoseconds else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .exceeded(
                elapsedNanoseconds: elapsedNanoseconds,
                maxNanoseconds: maximumDrainNanoseconds
            )
        }
        return .deferTimeout(
            elapsedNanoseconds: elapsedNanoseconds,
            maxNanoseconds: maximumDrainNanoseconds
        )
    }

    private func shouldDeferRemoteAudioSilenceTimeout(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) -> Bool {
        guard phase == .awaitingFirstAudioChunk || phase == .drainingAudio else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        let authoritativePeerTransmit =
            channelSnapshot.status == .receiving
            || channelSnapshot.readinessStatus?.isPeerTransmitting == true
        guard authoritativePeerTransmit else { return false }
        guard !selectedPeerTransmitLeaseExpired(for: contactID) else { return false }
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        guard phase == .awaitingFirstAudioChunk,
              let activityState = receiveExecutionCoordinator
                  .state
                  .remoteActivityByContactID[contactID]
        else {
            return false
        }
        switch activityState.phase {
        case .prepared, .awaitingFirstAudioChunk:
            return true
        case .receivingAudio, .drainingAudio:
            return false
        }
    }

    func shouldResumeLocalInteractivePrewarmForRemoteReady(
        contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard selectedContactId == contactID else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return false }

        switch localMediaWarmupState(for: contactID) {
        case .cold, .failed:
            return true
        case .prewarming, .ready:
            return false
        }
    }

    func resumeLocalInteractivePrewarmForRemoteReady(
        contactID: UUID,
        applicationState: UIApplication.State
    ) async {
        guard shouldResumeLocalInteractivePrewarmForRemoteReady(
            contactID: contactID,
            applicationState: applicationState
        ) else { return }

        diagnostics.record(
            .media,
            message: "Resuming local interactive audio prewarm after peer became ready",
            metadata: [
                "contactId": contactID.uuidString,
                "applicationState": String(describing: applicationState),
            ]
        )
        await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        updateStatusForSelectedContact()
    }

    func shouldReleaseLocalInteractivePrewarmForRemoteBackgrounding(
        contactID: UUID,
        readinessSignalReason: ReceiverAudioReadinessReason,
        applicationState: UIApplication.State
    ) -> Bool {
        guard readinessSignalReason.isBackgroundMediaClosure else { return false }
        guard applicationState == .active else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return false }
        return true
    }

    func releaseLocalInteractivePrewarmForRemoteBackgrounding(
        contactID: UUID,
        readinessSignalReason: ReceiverAudioReadinessReason,
        applicationState: UIApplication.State
    ) {
        guard shouldReleaseLocalInteractivePrewarmForRemoteBackgrounding(
            contactID: contactID,
            readinessSignalReason: readinessSignalReason,
            applicationState: applicationState
        ) else { return }

        diagnostics.record(
            .media,
            message: "Released local interactive audio prewarm after peer backgrounded",
            metadata: [
                "contactId": contactID.uuidString,
                "applicationState": String(describing: applicationState),
                "reason": readinessSignalReason.wireValue,
            ]
        )
        let preserveDirectQuic = shouldUseDirectQuicTransport(for: contactID)
        closeMediaSession(
            preserveDirectQuic: preserveDirectQuic,
            preserveMediaRelay: !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: contactID)
        )
        updateStatusForSelectedContact()
    }
}
