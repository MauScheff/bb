//
//  PTTViewModel+AudioSessionAndWake.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

extension PTTViewModel {
    func schedulePostWakeBackendRefresh(for contactID: UUID) {
        Task { [weak self] in
            await self?.controlPlaneCoordinator.handle(.postWakeRepairRequested(contactID: contactID))
        }
    }

    func setAudioOutputPreference(_ preference: AudioOutputPreference) {
        setAudioOutputPreference(preference, persist: true, reason: "manual")
    }

    func setAudioOutputPreference(
        _ preference: AudioOutputPreference,
        persist: Bool,
        reason: String
    ) {
        guard audioOutputPreference != preference else {
            applyPreferredAudioOutputRouteIfPossible()
            return
        }
        audioOutputPreference = preference
        if persist {
            UserDefaults.standard.set(preference.rawValue, forKey: AudioOutputPreference.storageKey)
        }
        syncEngineAudioOutputPreference(reason: reason)
        applyPreferredAudioOutputRouteIfPossible()
        _ = currentLocalConversationParticipantTelemetry(includeAudio: activeChannelId != nil)
        Task { @MainActor [weak self] in
            await self?.syncConversationParticipantTelemetryIfNeeded(reason: .audioRoutePreference(reason))
        }
        diagnostics.record(
            .media,
            message: "Audio output preference updated",
            metadata: [
                "preference": preference.rawValue,
                "persisted": String(persist),
                "reason": reason,
            ]
        )
        captureDiagnosticsState("audio-route:updated")
    }

    func applyPreferredAudioOutputRoute(to audioSession: AVAudioSession = .sharedInstance()) {
        let overridePlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: audioOutputPreference,
            category: audioSession.category,
            outputPortTypes: audioSession.currentRoute.outputs.map(\.portType)
        )
        if overridePlan.shouldClearSpeakerOverride {
            do {
                try audioSession.overrideOutputAudioPort(.none)
                diagnostics.record(
                    .media,
                    message: "Cleared preferred speaker audio route",
                    metadata: audioSessionDiagnostics(audioSession).merging(
                        ["preference": audioOutputPreference.rawValue]
                    ) { _, new in new }
                )
            } catch {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Failed to clear preferred speaker audio route",
                    metadata: [
                        "error": error.localizedDescription,
                        "preference": audioOutputPreference.rawValue,
                        "category": audioSession.category.rawValue,
                        "mode": audioSession.mode.rawValue,
                    ]
                )
            }
            return
        }

        guard overridePlan.shouldApplySpeakerOverride else {
            guard audioSession.category != .playAndRecord else { return }
            diagnostics.record(
                .media,
                message: "Skipped preferred audio output route override until play-and-record session is active",
                metadata: [
                    "preference": audioOutputPreference.rawValue,
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
            return
        }
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
            diagnostics.record(
                .media,
                message: "Applied preferred audio output route",
                metadata: audioSessionDiagnostics(audioSession).merging(
                    ["preference": audioOutputPreference.rawValue]
                ) { _, new in new }
            )
        } catch {
            let message = error.localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "session activation failed" {
                diagnostics.record(
                    .media,
                    message: "Deferred preferred audio output route until session activation",
                    metadata: [
                        "preference": audioOutputPreference.rawValue,
                        "category": audioSession.category.rawValue,
                        "mode": audioSession.mode.rawValue,
                    ]
                )
                return
            }
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to apply preferred audio output route",
                metadata: [
                    "error": message,
                    "preference": audioOutputPreference.rawValue,
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
        }
    }

    func applyPreferredAudioOutputRouteIfPossible() {
        guard mediaServices.hasSession() || pttCoordinator.state.systemChannelUUID != nil else { return }
        applyPreferredAudioOutputRoute()
    }

    func handleDeactivatedAudioSession(
        _ audioSession: AVAudioSession,
        applicationState: UIApplication.State? = nil,
        deactivatedEpoch: PTTAudioSessionEpoch? = nil
    ) async {
        let applicationState = applicationState ?? UIApplication.shared.applicationState
        let _ = audioSession
        isPTTAudioSessionActive = false
        if pttCoordinator.state.isTransmitting {
            let channelUUID = pttCoordinator.state.systemChannelUUID
            let activeTarget = channelUUID.flatMap { activeTransmitTarget(for: $0) }
            if shouldTreatPTTAudioDeactivationAsStaleReceiveHandoff(
                deactivatedEpoch: deactivatedEpoch,
                channelUUID: channelUUID,
                activeTarget: activeTarget
            ) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored stale remote-receive PTT audio deactivation during local transmit activation",
                    metadata: [
                        "channelUUID": channelUUID?.uuidString ?? "none",
                        "contactId": activeTarget?.contactID.uuidString ?? pttCoordinator.state.activeContactID?.uuidString ?? "none",
                        "channelId": activeTarget?.channelID ?? "none",
                        "transmitPressActive": String(transmitRuntime.isPressingTalk),
                        "coordinatorPressing": String(transmitCoordinator.state.isPressingTalk),
                        "coordinatorPhase": String(describing: transmitCoordinator.state.phase),
                        "pttAudioOwner": deactivatedEpoch?.owner.diagnosticsValue ?? "none",
                        "pttAudioEpochId": deactivatedEpoch?.id.uuidString ?? "none",
                    ]
                )
                syncPTTState()
                syncTransmitState()
                return
            }
            diagnostics.record(
                .pushToTalk,
                message: "Treating PTT audio deactivation during transmit as system transmit end",
                metadata: [
                    "channelUUID": channelUUID?.uuidString ?? "none",
                    "contactId": activeTarget?.contactID.uuidString ?? pttCoordinator.state.activeContactID?.uuidString ?? "none",
                    "channelId": activeTarget?.channelID ?? "none",
                    "applicationState": String(describing: applicationState),
                    "transmitPressActive": String(transmitRuntime.isPressingTalk),
                    "coordinatorPressing": String(transmitCoordinator.state.isPressingTalk),
                    "coordinatorPhase": String(describing: transmitCoordinator.state.phase),
                ]
            )
            mediaServices.replaceSendAudioChunk(nil)
            mediaServices.session()?.updateSendAudioChunk(nil)
            await mediaServices.session()?.abortSendingAudio()
            let hadPendingLifecycle = channelUUID.map { hasPendingTransmitLifecycle(for: $0) } ?? false
            cancelActiveTransmitForLifecycleInterruption(reason: "ptt-audio-deactivated")
            if let channelUUID {
                await pttCoordinator.handle(
                    .didEndTransmitting(
                        channelUUID: channelUUID,
                        origin: .systemCallback(source: "ptt-audio-deactivated")
                    )
                )
                if let activeTarget {
                    syncEngineSystemTransmitEnded(
                        target: activeTarget,
                        source: "ptt-audio-deactivated"
                    )
                }
                if hadPendingLifecycle {
                    await transmitCoordinator.handle(.systemEnded)
                }
                syncPTTState()
                syncTransmitState()
            }
        } else {
            try? await mediaServices.session()?.stopSendingAudio()
        }
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: nil)
        pttWakeRuntime.clearAll(clearSuppression: false)
        if applicationState != .active,
           let contactID = backgroundReceiverReadinessContactIDForPTTAudioDeactivation(
                deactivatedEpoch: deactivatedEpoch
           ) {
            controlPlaneCoordinator.send(
                .receiverAudioReadinessEpochAdvanced(contactID: contactID)
            )
            diagnostics.record(
                .backend,
                message: "Publishing receiver not-ready after background PTT audio deactivation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": "ptt-audio-deactivated-background-ready",
                    "pttAudioOwner": deactivatedEpoch?.owner.diagnosticsValue ?? "none",
                    "applicationState": String(describing: applicationState),
                ]
            )
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .appBackgroundMediaClosed
            )
        }
        if let contactID = mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID {
            guard applicationState == .active else {
                diagnostics.record(
                    .media,
                    message: "Deferred interactive audio prewarm after PTT audio deactivation until foreground",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "applicationState": String(describing: applicationState)
                    ]
                )
                reassertPTTTalkReadinessIfNeeded(
                    for: contactID,
                    reason: "ptt-audio-deactivated-background-ready"
                )
                return
            }
            guard !hasLocalTransmitStartupOrActiveIntent(for: contactID) else {
                cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
                    contactID: contactID,
                    reason: "ptt-audio-deactivated-during-local-transmit"
                )
                return
            }
            _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
            diagnostics.record(
                .media,
                message: "Resuming deferred interactive audio prewarm after PTT audio deactivation",
                metadata: ["contactId": contactID.uuidString]
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
            await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        }
    }

    private func backgroundReceiverReadinessContactIDForPTTAudioDeactivation(
        deactivatedEpoch: PTTAudioSessionEpoch?
    ) -> UUID? {
        let candidates = [
            deactivatedEpoch?.owner.contactID,
            mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID,
            pttCoordinator.state.activeContactID,
            selectedContactId,
        ]

        for contactID in candidates.compactMap({ $0 }) {
            guard let contact = contacts.first(where: { $0.id == contactID }),
                  contact.backendChannelId != nil,
                  contact.remoteUserId != nil,
                  devicePTTEvidenceExists(for: contactID) else {
                continue
            }
            return contactID
        }
        return nil
    }

    private func shouldTreatPTTAudioDeactivationAsStaleReceiveHandoff(
        deactivatedEpoch: PTTAudioSessionEpoch?,
        channelUUID: UUID?,
        activeTarget: TransmitTarget?
    ) -> Bool {
        guard let deactivatedEpoch,
              let channelUUID,
              let activeTarget else {
            return false
        }
        guard currentApplicationState() == .active else { return false }
        guard hasActiveTransmitPressIntent() else { return false }
        guard transmitStartupTiming.elapsedMilliseconds(for: "transmit-start-signal-sent") == nil else {
            return false
        }
        guard case .remoteReceive(
            let ownerChannelUUID,
            let ownerContactID,
            let ownerChannelID
        ) = deactivatedEpoch.owner else {
            return false
        }
        guard ownerChannelUUID == channelUUID else { return false }
        if let ownerContactID, ownerContactID != activeTarget.contactID {
            return false
        }
        if let ownerChannelID, ownerChannelID != activeTarget.channelID {
            return false
        }
        guard case .localTransmit(
            let pendingChannelUUID,
            let pendingContactID,
            let pendingChannelID,
            _
        ) = pttAudioSessionRuntime.pendingActivationOwner else {
            return false
        }
        return pendingChannelUUID == channelUUID
            && pendingContactID == activeTarget.contactID
            && pendingChannelID == activeTarget.channelID
    }

    func scheduleWakePlaybackFallback(for contactID: UUID) {
        guard pttWakeRuntime.hasPendingWake(for: contactID) else { return }
        guard !pttWakeRuntime.hasPlaybackFallbackTask(for: contactID) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: wakePlaybackFallbackDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.runWakePlaybackFallbackIfNeeded(for: contactID)
        }
        pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: task)
    }

    func resumeBufferedWakePlaybackIfNeeded(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard let pendingWake = pttWakeRuntime.pendingIncomingPush else { return }
        guard pttWakeRuntime.shouldBufferAudioChunk(for: pendingWake.contactID) else { return }
        guard pttWakeRuntime.bufferedAudioChunkCount(for: pendingWake.contactID) > 0 else { return }
        await runWakePlaybackFallbackIfNeeded(
            for: pendingWake.contactID,
            reason: reason,
            applicationState: applicationState
        )
    }

    func scheduleForegroundSystemReceivePlaybackFallback(
        for contactID: UUID,
        channelID: String,
        delayNanoseconds overrideDelayNanoseconds: UInt64? = nil
    ) {
        guard foregroundSystemReceivePlaybackFallbackDelayNanoseconds > 0 else { return }
        guard !isPTTAudioSessionActive else { return }
        guard currentApplicationState() == .active else { return }
        guard !mediaRuntime.hasActiveForegroundSystemReceivePlaybackFallback(
            for: contactID,
            channelID: channelID
        ) else { return }
        guard !mediaRuntime.hasForegroundSystemReceivePlaybackFallbackTask(for: contactID) else {
            return
        }
        let delayNanoseconds = overrideDelayNanoseconds ?? foregroundSystemReceivePlaybackFallbackDelayNanoseconds
        let task = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.runForegroundSystemReceivePlaybackFallbackIfNeeded(
                for: contactID,
                channelID: channelID,
                reason: delayNanoseconds == 0
                    ? "foreground-app-managed-receive"
                    : "ptt-activation-timeout"
            )
        }
        mediaRuntime.replaceForegroundSystemReceivePlaybackFallbackTask(
            for: contactID,
            with: task
        )
    }

    func runForegroundSystemReceivePlaybackFallbackIfNeeded(
        for contactID: UUID,
        channelID: String,
        reason: String
    ) async {
        defer {
            mediaRuntime.replaceForegroundSystemReceivePlaybackFallbackTask(for: contactID, with: nil)
        }

        let applicationState = currentApplicationState()
        guard applicationState == .active else { return }
        guard !isPTTAudioSessionActive else { return }
        guard shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
            for: contactID,
            channelID: channelID,
            applicationState: applicationState
        ) else { return }

        let bufferedChunkCount = mediaRuntime.foregroundSystemReceiveBufferedAudioChunkCount(for: contactID)
        guard bufferedChunkCount > 0 else { return }
        mediaRuntime.activateForegroundSystemReceivePlaybackFallback(
            for: contactID,
            channelID: channelID,
            reason: reason
        )

        let isImmediateAppManagedReceive = reason == "foreground-app-managed-receive"
        if !isImmediateAppManagedReceive {
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Transmit.appleGatedAudioActivationDeadlineElapsed(
                    contactID: contactID,
                    channelID: channelID,
                    channelUUID: channelUUID(for: contactID) ?? pttCoordinator.state.systemChannelUUID ?? UUID(),
                    targetDeviceID: directQuicPeerDeviceID(for: contactID) ?? "unknown",
                    trigger: "foreground-receive-playback-fallback",
                    startupPolicy: directQuicTransmitStartupPolicy.rawValue,
                    isPTTAudioSessionActive: isPTTAudioSessionActive,
                    timeoutMilliseconds: foregroundSystemReceivePlaybackFallbackDelayNanoseconds / 1_000_000
                )
            )
        }
        diagnostics.record(
            .media,
            message: isImmediateAppManagedReceive
                ? "Starting app-managed foreground receive playback fallback"
                : "PTT activation timed out; starting app-managed foreground receive playback fallback",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "bufferedChunkCount": String(bufferedChunkCount),
                "reason": reason,
            ]
        )
        captureDiagnosticsState("foreground-receive:fallback-started")

        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        guard mediaRuntime.markForegroundSystemReceivePlaybackFallbackReady(
            for: contactID,
            channelID: channelID
        ) else { return }
        let bufferedAudioChunks = mediaRuntime.takeForegroundSystemReceiveAudioChunks(for: contactID)
        guard !bufferedAudioChunks.isEmpty else { return }
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        diagnostics.record(
            .media,
            message: "Flushing buffered foreground receive audio through app-managed playback fallback",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason,
            ]
        )
        await playBufferedForegroundSystemReceiveAudioChunks(
            bufferedAudioChunks,
            contactID: contactID
        )
        captureDiagnosticsState("foreground-receive:fallback-flushed")
    }

    func runWakePlaybackFallbackIfNeeded(for contactID: UUID) async {
        await runWakePlaybackFallbackIfNeeded(
            for: contactID,
            reason: "ptt-activation-timeout",
            applicationState: currentApplicationState()
        )
    }

    func runWakePlaybackFallbackIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State
    ) async {
        defer {
            pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
        }

        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return }
        let bufferedChunkCount = pttWakeRuntime.bufferedAudioChunkCount(for: contactID)
        guard shouldUseAppManagedWakePlaybackFallback(applicationState: applicationState) else {
            pttWakeRuntime.markFallbackDeferredUntilForeground(for: contactID)
            diagnostics.record(
                .media,
                level: .error,
                message: "PTT system audio activation timed out while app remained backgrounded",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "applicationState": String(describing: applicationState),
                    "bufferedChunkCount": String(bufferedChunkCount),
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeActivationState": String(describing: pttWakeRuntime.pendingIncomingPush?.activationState ?? .signalBuffered),
                ]
            )
            captureDiagnosticsState("ptt-wake:fallback-deferred")
            return
        }
        guard bufferedChunkCount > 0 else {
            diagnostics.record(
                .media,
                message: "PTT activation timed out before buffered audio arrived",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "applicationState": String(describing: applicationState),
                ]
            )
            captureDiagnosticsState("ptt-wake:fallback-timeout-no-audio")
            return
        }

        diagnostics.record(
            .media,
            message: "PTT activation timed out; starting app-managed playback fallback",
            metadata: [
                "contactId": contactID.uuidString,
                "bufferedChunkCount": String(bufferedChunkCount),
                "reason": reason
            ]
        )
        captureDiagnosticsState("ptt-wake:fallback-started")

        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )

        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed playback fallback because wake activation changed during startup",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "activationState": String(
                        describing: pttWakeRuntime.incomingWakeActivationState(for: contactID) ?? .signalBuffered
                    )
                ]
            )
            return
        }

        let bufferedAudioChunks = pttWakeRuntime.takeBufferedWakeAudioChunks(for: contactID)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        recordWakeReceiveTiming(
            stage: "app-managed-fallback-flush-started",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason,
            ]
        )
        diagnostics.record(
            .media,
            message: "Flushing buffered wake audio through app-managed playback fallback",
            metadata: [
                "contactId": contactID.uuidString,
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason
            ]
        )
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        await playBufferedWakeAudioChunks(
            bufferedAudioChunks,
            contactID: contactID,
            reason: reason,
            flushSource: "app-managed-fallback"
        )
        recordWakeReceiveTiming(
            stage: "app-managed-fallback-flush-completed",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason,
            ]
        )
        recordWakeReceiveTimingSummary(
            reason: "app-managed-fallback-flush",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "fallbackReason": reason,
            ]
        )
    }

    func playBufferedWakeAudioChunks(
        _ bufferedAudioChunks: BufferedWakeAudioChunkBatch,
        contactID: UUID,
        reason: String,
        flushSource: String
    ) async {
        if bufferedAudioChunks.canUseStructuredMediaChunks {
            diagnostics.record(
                .media,
                message: "Flushing structured wake media chunks",
                metadata: [
                    "contactId": contactID.uuidString,
                    "bufferedChunkCount": String(bufferedAudioChunks.count),
                    "flushSource": flushSource,
                    "reason": reason,
                ]
            )
            await playBufferedForegroundSystemReceiveAudioChunks(
                bufferedAudioChunks.mediaChunks,
                contactID: contactID
            )
            return
        }

        if !bufferedAudioChunks.mediaChunks.isEmpty {
            diagnostics.recordInvariantViolation(
                invariantID: "media.wake_buffer_identity_matches_audio_buffer",
                scope: .local,
                message: "wake buffered media identity count diverged from buffered audio payload count",
                metadata: [
                    "contactId": contactID.uuidString,
                    "audioPayloadCount": String(bufferedAudioChunks.audioPayloads.count),
                    "mediaChunkCount": String(bufferedAudioChunks.mediaChunks.count),
                    "flushSource": flushSource,
                    "reason": reason,
                ]
            )
        }

        for payload in bufferedAudioChunks.audioPayloads {
            await receiveRemoteAudioChunk(payload)
        }
    }
}
