//
//  PTTViewModel+Transmit.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit
import TurboEngine

private enum TransmitAudioCaptureStartError: LocalizedError {
    case missingMediaSession

    var errorDescription: String? {
        "Media session is not available for transmit audio capture"
    }
}

extension PTTViewModel {
    func shouldUseAppManagedWakePlaybackFallback(
        applicationState: UIApplication.State
    ) -> Bool {
        applicationState == .active
    }
}

extension PTTViewModel {
    func startCurrentMediaSessionSendingAudio(
        contactID: UUID,
        channelID: String,
        channelUUID: UUID,
        trigger: String,
        metadata extraMetadata: [String: String] = [:]
    ) async throws {
        guard let session = mediaServices.session() else {
            var metadata = extraMetadata
            metadata["contactId"] = contactID.uuidString
            metadata["channelId"] = channelID
            metadata["channelUUID"] = channelUUID.uuidString
            metadata["trigger"] = trigger
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit audio capture start failed because media session is missing",
                metadata: metadata
            )
            throw TransmitAudioCaptureStartError.missingMediaSession
        }
        try await session.startSendingAudio()
    }

    func shouldSuspendForegroundMediaForBackgroundTransition(
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        guard mediaServices.hasSession() else { return false }
        guard let contactID = mediaSessionContactID else { return false }
        guard !isTransmitting else { return false }
        guard !engineTransmitLifecycleTouchesContact(contactID) else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        return true
    }

    func engineTransmitLifecycleTouchesContact(_ contactID: UUID) -> Bool {
        switch engine.snapshot.transmit {
        case .idle, .failed(_):
            return false
        case .beginning(let attempt):
            return attempt.conversation.friend.contactID.rawValue == contactID.uuidString
        case .active(let epoch):
            return epoch.conversation.friend.contactID.rawValue == contactID.uuidString
        case .stopping(let stop):
            return stop.epoch.conversation.friend.contactID.rawValue == contactID.uuidString
        }
    }

    func suspendForegroundMediaForBackgroundTransition(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard shouldSuspendForegroundMediaForBackgroundTransition(
            applicationState: applicationState
        ) else { return }
        guard let contactID = mediaSessionContactID else { return }
        diagnostics.record(
            .media,
            message: "Suspending foreground media for background transition",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "applicationState": String(describing: applicationState)
            ]
        )
        closeMediaSession()
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .appBackgroundMediaClosed
        )
        updateStatusForSelectedContact()
    }

    func backgroundTransitionTransportContactIDs() -> Set<UUID> {
        Set([selectedContactId, activeChannelId, mediaSessionContactID].compactMap { $0 })
    }

    func shouldPublishReceiverNotReadyForIdleBackgroundTransition(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        return !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
    }

    @discardableResult
    func retireIdleDirectQuicForBackgroundTransitionImmediately(
        reason: String,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            diagnostics.record(
                .media,
                message: "Preserving Direct QUIC during proximity inactive transition",
                metadata: ["reason": reason]
            )
            return false
        }

        var didUpdateTransport = false
        for contactID in backgroundTransitionTransportContactIDs() {
            guard shouldRetireIdleDirectQuicForBackgroundTransition(
                for: contactID,
                applicationState: applicationState
            ) else { continue }

            didUpdateTransport = retireDirectQuicPathImmediately(
                for: contactID,
                reason: reason,
                sendHangup: true,
                configureActiveRoute: false
            ) || didUpdateTransport
        }

        if didUpdateTransport {
            updateStatusForSelectedContact()
        }
        return didUpdateTransport
    }

    func reconcileIdleTransportForBackgroundTransition(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard applicationState != .active else { return }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            diagnostics.record(
                .media,
                message: "Skipped background transport reconciliation during proximity inactive transition",
                metadata: ["reason": reason]
            )
            return
        }

        var didUpdateTransport = false
        for contactID in backgroundTransitionTransportContactIDs() {
            let retired = await retireIdleDirectQuicForBackgroundTransitionIfNeeded(
                for: contactID,
                reason: reason,
                applicationState: applicationState
            )
            didUpdateTransport = didUpdateTransport || retired

            if shouldPublishReceiverNotReadyForIdleBackgroundTransition(
                for: contactID,
                applicationState: applicationState
            ) {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .appBackgroundMediaClosed
                )
            }
        }

        if didUpdateTransport {
            updateStatusForSelectedContact()
        }
    }

    func desiredLocalReceiverAudioReadiness(for contactID: UUID) -> Bool {
        guard !receiverAudioReadinessBlockedByPendingLeave(for: contactID) else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        let peerDeviceID =
            channelReadinessByContactID[contactID]?.peerTargetDeviceId
            ?? directQuicPeerDeviceID(for: contactID)
        guard localReceiverMediaEncryptionReadyForLiveMedia(
            contactID: contactID,
            channelID: contact.backendChannelId,
            peerDeviceID: peerDeviceID
        ) else {
            diagnostics.record(
                .media,
                message: "Withholding receiver-ready until media E2EE session is configured",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": contact.backendChannelId ?? "none",
                    "peerDeviceId": peerDeviceID ?? "none",
                    "peerIdentityAdvertised": String(mediaEncryptionIsRequired(for: contactID)),
                ]
            )
            return false
        }

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            // Wake-activated receive should publish ready from the actual
            // connected playback session even if the selected-conversation
            // projection is still polluted by a stale local transmit path.
            return true
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            break
        }

        guard !isTransmitting else { return false }

        if localReceiverAudioReadinessSessionIsLive(for: contactID) {
            return true
        }

        let projection = selectedConversationProjection(for: contactID)
        guard projection.devicePTTContinuity == .connected else { return false }
        guard projection.connectedExecution == nil else { return false }
        return true
    }

    func localReceiverAudioReadinessSessionIsLive(for contactID: UUID) -> Bool {
        guard devicePTTEvidenceExists(for: contactID) else { return false }

        guard let channel = selectedChannelSnapshot(for: contactID),
              channel.membership.hasLocalMembership else {
            return false
        }

        switch channel.status {
        case .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        case .outgoingBeep, .incomingBeep, .idle, nil:
            return false
        }
    }

    func peerIsRoutableForReceiverAudioReadiness(for contactID: UUID) -> Bool {
        guard !receiverAudioReadinessBlockedByPendingLeave(for: contactID) else { return false }
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        if channel.membership.peerDeviceConnected {
            return true
        }

        if let readiness = channelReadinessByContactID[contactID],
           readiness.peerHasActiveDevice,
           readiness.peerTargetDeviceId != nil,
           readiness.remoteAudioReadiness == .ready {
            return true
        }

        if channel.membership.hasPeerMembership,
           deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
                channel: channel,
                readiness: channelReadinessByContactID[contactID]
           ) {
            return true
        }

        guard systemSessionMatches(contactID) else { return false }

        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .signalBuffered, .awaitingSystemActivation, .appManagedFallback, .systemActivated:
            return true
        case .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            return false
        }
    }

    func receiverAudioReadinessBlockedByPendingLeave(for contactID: UUID) -> Bool {
        conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
    }

    func deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
        channel: ChannelReadinessSnapshot,
        readiness: TurboChannelReadinessResponse?
    ) -> Bool {
        let hasTargetDevice =
            readiness?.peerTargetDeviceId != nil
            || {
                if case .wakeCapable = channel.remoteWakeCapability {
                    return true
                }
                return false
            }()
        guard hasTargetDevice else { return false }

        switch channel.remoteAudioReadiness {
        case .ready, .wakeCapable:
            return true
        case .waiting, .unknown:
            if case .wakeCapable = channel.remoteWakeCapability {
                return true
            }
            return false
        }
    }

    func shouldReassertBackendJoinAfterWake(for contactID: UUID) -> Bool {
        guard backendServices != nil else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        guard contact.backendChannelId != nil, contact.remoteUserId != nil else { return false }
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        guard !channel.membership.hasLocalMembership else { return false }
        return devicePTTEvidenceExists(for: contactID)
    }

    @discardableResult
    func reassertBackendJoinAfterWakeIfNeeded(
        for contactID: UUID,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) async -> Bool {
        guard shouldReassertBackendJoinAfterWake(for: contactID) else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        diagnostics.record(
            .backend,
            message: "Reasserting backend join after wake recovery",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
        // A readiness publish sent before backend membership is repaired may be
        // ignored by the control plane. Force a clean republish after rejoin.
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        await reassertBackendJoinAndWaitForVisibility(
            for: contact,
            source: "wake-recovery",
            deviceSessionProof: deviceSessionProof
        )
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        return true
    }

    func syncLocalReceiverAudioReadinessSignal(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) async {
        guard !shouldDropSupersededReceiverAudioReadinessMediaSync(
            for: contactID,
            reason: reason
        ) else {
            return
        }

        guard !shouldSuppressReceiverReadyPublicationWithoutStableEvidence(
            for: contactID,
            reason: reason,
            source: "sync-request"
        ) else {
            return
        }

        forceReceiverAudioReadinessRepublishIfBackendHasNotObservedLocalReady(
            for: contactID,
            reason: reason
        )

        guard let intent = receiverAudioReadinessIntent(for: contactID, reason: reason) else {
            controlPlaneCoordinator.send(.receiverAudioReadinessContextUnavailable(contactID: contactID))
            return
        }

        let peerIsRoutable =
            intent.reason.isBackgroundMediaClosure
            || peerIsRoutableForReceiverAudioReadiness(for: contactID)

        await controlPlaneCoordinator.handle(
            .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: peerIsRoutable,
                webSocketConnected: backendServices?.isWebSocketConnected == true
            )
        )
    }

    func shouldDropSupersededReceiverAudioReadinessMediaSync(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) -> Bool {
        guard case .mediaState(let reasonState) = reason else { return false }
        let currentState = mediaConnectionState
        guard currentState != reasonState else { return false }
        diagnostics.record(
            .websocket,
            message: "Dropped stale receiver audio readiness sync for superseded media state",
            metadata: [
                "contactId": contactID.uuidString,
                "reasonState": String(describing: reasonState),
                "currentState": String(describing: currentState),
                "reason": reason.wireValue,
            ]
        )
        return true
    }

    func shouldSuppressReceiverReadyPublicationWithoutStableEvidence(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason,
        source: String
    ) -> Bool {
        if backendServices?.isWebSocketSuspended == true,
           desiredLocalReceiverAudioReadiness(for: contactID) {
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Suppressed receiver-ready publication while WebSocket is deliberately suspended",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason.wireValue,
                    "source": source,
                ]
            )
            return true
        }

        guard let blocker = reason.readyPublicationBlocker else { return false }
        guard desiredLocalReceiverAudioReadiness(for: contactID) else { return false }
        let channelSnapshot = selectedChannelSnapshot(for: contactID)
        diagnostics.recordContractViolation(
            DiagnosticsContracts.Media.receiverReadyRequiresStableEvidence(
                contactID: contactID,
                channelID: contacts.first(where: { $0.id == contactID })?.backendChannelId,
                reason: reason.wireValue,
                blocker: blocker,
                source: source,
                mediaState: String(describing: mediaConnectionState),
                applicationState: String(describing: currentApplicationState()),
                backendReadiness: channelSnapshot?.readinessStatus?.kind ?? "none",
                localAudioReadiness: String(
                    describing: channelSnapshot?.localAudioReadiness ?? .unknown
                )
            )
        )
        return true
    }

    func forceReceiverAudioReadinessRepublishIfBackendHasNotObservedLocalReady(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) {
        guard desiredLocalReceiverAudioReadiness(for: contactID) else { return }
        guard peerIsRoutableForReceiverAudioReadiness(for: contactID) else { return }
        guard let published = localReceiverAudioReadinessPublications[contactID],
              published.isReady,
              published.peerWasRoutable else {
            return
        }
        guard channelReadinessByContactID[contactID]?.localAudioReadiness != .ready else {
            return
        }
        guard let recoveryBasis = reason.recoveryPublicationBasis else {
            return
        }
        guard shouldForceReceiverAudioReadinessRepublish(
            previousBasis: published.basis,
            recoveryBasis: recoveryBasis
        ) else {
            return
        }

        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        diagnostics.record(
            .websocket,
            message: "Republishing receiver audio readiness because backend has not observed local ready",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason.wireValue,
                "recoveryBasis": String(describing: recoveryBasis),
                "previousBasis": String(describing: published.basis),
                "backendLocalAudioReadiness": String(
                    describing: channelReadinessByContactID[contactID]?.localAudioReadiness ?? .unknown
                ),
                "backendReadiness": channelReadinessByContactID[contactID]?.statusKind ?? "none",
            ]
        )
    }

    func shouldForceReceiverAudioReadinessRepublish(
        previousBasis: ReceiverAudioReadinessPublicationBasis,
        recoveryBasis: ReceiverAudioReadinessPublicationBasis
    ) -> Bool {
        guard previousBasis != recoveryBasis else { return false }
        return recoveryBasis == .webSocketReconnect
    }

    func prewarmLocalMediaIfNeeded(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped foreground media prewarm while leave is in flight",
                metadata: ["contactId": contactID.uuidString]
            )
            return
        }
        guard !isTransmitting else { return }
        guard applicationState == .active else {
            diagnostics.record(
                .media,
                message: "Deferred interactive audio prewarm until app is foregrounded",
                metadata: [
                    "contactId": contactID.uuidString,
                    "applicationState": String(describing: applicationState)
                ]
            )
            return
        }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed foreground audio prewarm before system PTT activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "applicationState": String(describing: applicationState),
                    "reason": "avoid-ptt-audio-session-contention",
                ]
            )
            return
        }
        guard !isPTTAudioSessionActive else {
            diagnostics.record(
                .media,
                message: "Deferred interactive audio prewarm while PTT audio session is active",
                metadata: ["contactId": contactID.uuidString]
            )
            deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
            return
        }

        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let media = mediaServices

        if media.contactID() == contactID, mediaConnectionState == .connected {
            return
        }
        if media.isStartupInFlight(startupContext) {
            return
        }

        diagnostics.record(
            .media,
            message: "Prewarming foreground media for joined session",
            metadata: ["contactId": contactID.uuidString]
        )
        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        updateStatusForSelectedContact()
    }

    func shouldPrewarmForegroundTalkPath(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard selectedContactId == contactID else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !remoteReceiveBlocksLocalTransmit(for: contactID) else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.membership.hasLocalMembership else { return false }
        guard channelSnapshot.canTransmit else { return false }
        return true
    }

    func foregroundTalkPathNeedsPrewarm(for contactID: UUID) -> Bool {
        let mediaNeedsWarmup: Bool = {
            guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
                return false
            }
            switch localMediaWarmupState(for: contactID) {
            case .cold, .failed:
                return true
            case .prewarming, .ready:
                return false
            }
        }()
        let webSocketNeedsWarmup =
            backendServices?.supportsWebSocket == true
            && backendServices?.isWebSocketConnected != true
        let localReceiverReadinessNeedsPublish =
            desiredLocalReceiverAudioReadiness(for: contactID)
            && channelReadinessByContactID[contactID]?.localAudioReadiness != .ready

        return mediaNeedsWarmup
            || webSocketNeedsWarmup
            || localReceiverReadinessNeedsPublish
            || shouldRequestAutomaticDirectQuicProbe(for: contactID)
    }

    func firstTalkReadiness(for contactID: UUID) -> FirstTalkReadinessProjection {
        let localMediaWarm =
            localMediaWarmupState(for: contactID) == .ready
            || shouldUseDirectQuicTransport(for: contactID)
        let receiverWarm =
            selectedChannelSnapshot(for: contactID)?.remoteAudioReadyForLiveTransmit == true
            || mediaRuntime.receiverPrewarmRequestIsAcknowledged(
                for: contactID,
                maximumAge: TimeInterval(directQuicAudioFreshnessMilliseconds) / 1_000
            )
        let transportWarm = selectedMediaTransportState(for: contactID).isReadyForTransmit

        return FirstTalkReadinessProjection(
            localMediaWarm: localMediaWarm,
            receiverWarm: receiverWarm,
            transportWarm: transportWarm
        )
    }

    func firstTalkStartupProfile(
        for contactID: UUID,
        startGraceIfNeeded: Bool = false
    ) -> FirstTalkStartupProfile {
        if shouldUseDirectQuicTransport(for: contactID) {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return .directQuicWarm
        }

        let relayReadiness = firstTalkReadiness(for: contactID)
        let relayPathWarm = relayReadiness.receiverWarm && relayReadiness.transportWarm
        let relayProfile: FirstTalkStartupProfile = relayPathWarm ? .relayWarm : .relayWarming
        guard !relayPathWarm else {
            if startGraceIfNeeded {
                kickDirectQuicFirstTalkWarmupProbeIfNeeded(for: contactID)
            }
            return .relayWarm
        }

        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId else {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return relayProfile
        }

        let directWarmupBlockReason = directQuicFirstTalkWarmupBlockReason(for: contactID)
        guard directWarmupBlockReason == nil || directWarmupBlockReason == "not-listener-offerer" else {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return relayProfile
        }

        let existingGrace = mediaRuntime.firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        )
        if !startGraceIfNeeded {
            guard let existingGrace else { return relayProfile }
            let elapsedMilliseconds = Int(Date().timeIntervalSince(existingGrace.startedAt) * 1_000)
            return !existingGrace.expired && elapsedMilliseconds < directQuicFirstTalkGraceMilliseconds
                ? .directQuicWarming
                : relayProfile
        }
        let grace = mediaRuntime.markFirstTalkDirectQuicGraceStartedIfNeeded(
            for: contactID,
            channelID: channelID
        )
        if existingGrace == nil {
            diagnostics.record(
                .media,
                message: "Started Direct QUIC first-talk grace window",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "graceMs": String(directQuicFirstTalkGraceMilliseconds),
                ]
            )
            kickDirectQuicFirstTalkWarmupProbeIfNeeded(for: contactID)
        }

        let elapsedMilliseconds = Int(Date().timeIntervalSince(grace.startedAt) * 1_000)
        guard !grace.expired,
              elapsedMilliseconds < directQuicFirstTalkGraceMilliseconds else {
            mediaRuntime.expireFirstTalkDirectQuicGrace(
                for: contactID,
                channelID: channelID
            )
            return relayProfile
        }

        scheduleDirectQuicFirstTalkGraceExpirationRefresh(
            for: contactID,
            channelID: channelID,
            remainingMilliseconds: directQuicFirstTalkGraceMilliseconds - elapsedMilliseconds
        )
        return .directQuicWarming
    }

    func kickDirectQuicFirstTalkWarmupProbeIfNeeded(for contactID: UUID) {
        guard shouldRequestAutomaticDirectQuicProbe(for: contactID) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "first-talk-grace"
            )
        }
    }

    func scheduleDirectQuicFirstTalkGraceExpirationRefresh(
        for contactID: UUID,
        channelID: String,
        remainingMilliseconds: Int
    ) {
        guard !mediaRuntime.hasFirstTalkDirectQuicGraceExpiryTask(for: contactID) else { return }
        let delayMilliseconds = max(remainingMilliseconds, 0)
        mediaRuntime.replaceFirstTalkDirectQuicGraceExpiryTask(
            for: contactID,
            with: Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.mediaRuntime.expireFirstTalkDirectQuicGrace(
                        for: contactID,
                        channelID: channelID
                    )
                    self.diagnostics.record(
                        .media,
                        message: "Direct QUIC first-talk grace expired; allowing relay startup",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "graceMs": String(self.directQuicFirstTalkGraceMilliseconds),
                        ]
                    )
                    self.updateStatusForSelectedContact()
                    self.captureDiagnosticsState("direct-quic:first-talk-grace-expired")
                }
            }
        )
    }

    func prewarmForegroundTalkPathIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard shouldPrewarmForegroundTalkPath(
            for: contactID,
            applicationState: applicationState
        ) else { return }
        guard foregroundTalkPathNeedsPrewarm(for: contactID) else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelID = contact.backendChannelId else {
            return
        }

        diagnostics.record(
            .media,
            message: "Prewarming foreground talk path",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "channelId": backendChannelID,
                "reason": reason,
                "localMediaWarmupState": String(describing: localMediaWarmupState(for: contactID)),
                "appManagedAudioPrewarmEnabled": String(foregroundAppManagedInteractiveAudioPrewarmEnabled),
                "webSocketConnected": String(backendServices?.isWebSocketConnected == true),
                "directQuicActive": String(shouldUseDirectQuicTransport(for: contactID)),
            ]
        )

        if let backend = backendServices {
            resumeWebSocketBeforePTTTransportWaitIfNeeded(
                backend,
                contactID: contactID,
                channelID: backendChannelID,
                reason: "foreground-talk-prewarm-\(reason)"
            )
        }
        let mediaWasAlreadyConnected =
            mediaSessionContactID == contactID
            && mediaConnectionState == .connected
        if foregroundAppManagedInteractiveAudioPrewarmEnabled {
            await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        }
        let mediaConnectedDuringPrewarm =
            !mediaWasAlreadyConnected
            && mediaSessionContactID == contactID
            && mediaConnectionState == .connected
        if mediaConnectedDuringPrewarm {
            diagnostics.record(
                .websocket,
                message: "Skipped foreground receiver readiness sync because media-connected will publish readiness",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
        } else {
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .foregroundTalkPrewarm(reason)
            )
        }
        await maybeStartAutomaticDirectQuicProbe(
            for: contactID,
            reason: "foreground-talk-prewarm-\(reason)"
        )
        await requestReceiverPrewarmForFirstTalk(
            for: contactID,
            reason: "foreground-talk-prewarm-\(reason)"
        )
        updateStatusForSelectedContact()
    }

    func shouldClosePrewarmedMediaBeforeSystemTransmit(for contactID: UUID) -> Bool {
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        if directQuicTransmitStartupPolicy == .appleGated,
           shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID) {
            return true
        }
        guard !shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID) else {
            return false
        }

        switch mediaConnectionState {
        case .connected, .preparing:
            return true
        case .idle, .failed, .closed:
            return false
        }
    }

    func shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for contactID: UUID) -> Bool {
        directQuicTransmitStartupPolicy == .appleGated
            && shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID)
    }

    func shouldBridgePrewarmedDirectMediaDuringSystemTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return false }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else { return false }
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        return true
    }

    func shouldBridgePrewarmedMediaRelayDuringSystemTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return false }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else { return false }
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !shouldUseDirectQuicTransport(for: contactID) else { return false }
        guard mediaRuntime.hasActiveMediaRelayClient else { return false }
        return mediaTransportPathState.isFastRelay
    }

    func shouldUseForegroundWarmDirectTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        shouldBridgePrewarmedDirectMediaDuringSystemTransmit(
            for: contactID,
            applicationState: applicationState
        )
    }

    func shouldUseForegroundDirectQuicControlPath(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        return shouldUseDirectQuicTransport(for: contactID)
    }

    func deferInteractivePrewarmUntilPTTAudioDeactivation(for contactID: UUID) {
        mediaRuntime.requestInteractivePrewarmAfterAudioDeactivation(for: contactID)
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.deferredInteractivePrewarmRecoveryDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(for: contactID)
        })
    }

    func recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID else { return }
        guard !isPTTAudioSessionActive else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard !hasLocalTransmitStartupOrActiveIntent(for: contactID) else {
            cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
                contactID: contactID,
                reason: "local-transmit-active-during-recovery"
            )
            return
        }
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }
        guard applicationState == .active else { return }

        _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
        diagnostics.record(
            .media,
            message: "Recovering deferred interactive audio prewarm without PTT deactivation callback",
            metadata: ["contactId": contactID.uuidString]
        )
        await prewarmLocalMediaIfNeeded(for: contactID)
    }

    func resumeInteractiveAudioPrewarmIfNeeded(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard applicationState == .active else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard !transmitCoordinator.state.isPressingTalk else { return }
        guard let contact = selectedContact else { return }
        guard isJoined, activeChannelId == contact.id else { return }
        guard systemSessionMatches(contact.id) else { return }
        guard !isTransmitting else { return }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed interactive audio prewarm after app activation",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                ]
            )
            return
        }

        switch localMediaWarmupState(for: contact.id) {
        case .cold, .failed:
            diagnostics.record(
                .media,
                message: "Resuming interactive audio prewarm after app activation",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                ]
            )
            await prewarmLocalMediaIfNeeded(for: contact.id)
        case .prewarming, .ready:
            return
        }
    }

    func shouldRecreateMediaSession(connectionState: MediaConnectionState) -> Bool {
        switch connectionState {
        case .closed, .failed:
            return true
        case .idle, .preparing, .connected:
            return false
        }
    }

    func shouldTreatTransmitBeginMembershipLossAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not a channel member"
    }

    func shouldTreatTransmitStopCleanupAsAlreadyComplete(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        switch message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "not a channel member", "no active transmit state for sender":
            return true
        default:
            return false
        }
    }

    func shouldPreserveLocalTransmitState(
        selectedContactID: UUID?,
        refreshedContactID: UUID,
        backendChannelStatus: String,
        transmitSnapshot: TransmitDomainSnapshot
    ) -> Bool {
        guard selectedContactID == refreshedContactID else { return false }
        if transmitSnapshot.isSystemTransmitting {
            return true
        }
        if transmitSnapshot.activeContactID == refreshedContactID,
           transmitSnapshot.isPressActive {
            return true
        }
        if backendChannelStatus == ConversationState.transmitting.rawValue {
            if transmitSnapshot.isStopping(for: refreshedContactID) {
                return true
            }
            return transmitSnapshot.hasTransmitIntent(for: refreshedContactID)
                || (
                    transmitSnapshot.isSystemTransmitting
                    && !transmitSnapshot.explicitStopRequested
                )
        }

        switch transmitSnapshot.phase {
        case .idle:
            return false
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == refreshedContactID
        }
    }

    func shouldAcceptBackendLocalTransmitProjection(
        backendShowsLocalTransmit: Bool,
        refreshedContactID: UUID,
        transmitSnapshot: TransmitDomainSnapshot,
        leaveInFlight: Bool = false
    ) -> Bool {
        backendShowsLocalTransmit
            && !leaveInFlight
            && !transmitSnapshot.explicitStopRequested
            && (
                transmitSnapshot.hasTransmitIntent(for: refreshedContactID)
                || transmitSnapshot.isSystemTransmitting
            )
    }

    func hasActiveTransmitPressIntent() -> Bool {
        !transmitRuntime.explicitStopRequested
            && (transmitRuntime.isPressingTalk || transmitCoordinator.state.isPressingTalk)
    }

    func hasLocalTransmitStartupOrActiveIntent(for contactID: UUID) -> Bool {
        if hasActiveTransmitPressIntent() { return true }
        if isTransmitting || pttCoordinator.state.isTransmitting { return true }
        if transmitCoordinator.state.pendingRequest?.contactID == contactID { return true }
        if transmitCoordinator.state.activeTarget?.contactID == contactID { return true }
        return false
    }

    func markLocalTransmitStopProjectionGrace(
        for contactID: UUID,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        localTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] = nowNanoseconds
        localTransmitStopProjectionGraceStartedAtMillisecondsByContactID[contactID] = nowMilliseconds
    }

    func clearLocalTransmitStopProjectionGrace(for contactID: UUID) {
        localTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] = nil
        localTransmitStopProjectionGraceStartedAtMillisecondsByContactID[contactID] = nil
    }

    func localTransmitStopProjectionGraceIsActive(
        for contactID: UUID,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        guard let startedAt = localTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] else {
            return false
        }
        return nowNanoseconds >= startedAt
            ? nowNanoseconds - startedAt <= localTransmitStopProjectionGraceNanoseconds
            : true
    }

    func shouldDeferBeginTransmitUntilPostLiveSettlingCompletes(for contactID: UUID) -> Bool {
        guard selectedContactId == contactID,
              isJoined,
              activeChannelId == contactID,
              systemSessionMatches(contactID),
              selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity,
              !remoteReceiveProjectsRemoteTalkTurn(for: contactID),
              !remotePlaybackDrainBlocksLocalTransmit(for: contactID) else {
            return false
        }

        return localTransmitStopProjectionGraceIsActive(for: contactID)
            || remoteTransmitStopProjectionGraceIsActive(for: contactID)
    }

    func deferBeginTransmitUntilPostLiveSettlingCompletes(
        request: TransmitRequestContext,
        reason: String
    ) {
        pendingBeginTransmitAfterSettlingTask?.cancel()
        diagnostics.record(
            .media,
            message: "Deferring begin transmit until post-live settling completes",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "reason": reason,
            ]
        )
        startTransmitStartupTiming(for: request, source: "hold-to-talk-\(reason)")
        cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
            contactID: request.contactID,
            reason: "begin-transmit-\(reason)"
        )
        transmitRuntime.markPressBegan()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:deferred-post-live-settling")

        pendingBeginTransmitAfterSettlingTask = Task { [weak self] in
            await self?.runDeferredBeginTransmitAfterPostLiveSettling(
                request: request,
                reason: reason
            )
        }
    }

    func cancelDeferredBeginTransmitAfterPostLiveSettling(reason: String) {
        guard pendingBeginTransmitAfterSettlingTask != nil else { return }
        pendingBeginTransmitAfterSettlingTask?.cancel()
        pendingBeginTransmitAfterSettlingTask = nil
        diagnostics.record(
            .media,
            message: "Cancelled deferred begin transmit after post-live settling",
            metadata: ["reason": reason]
        )
    }

    func runDeferredBeginTransmitAfterPostLiveSettling(
        request: TransmitRequestContext,
        reason: String
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + localTransmitStopProjectionGraceNanoseconds
        while !Task.isCancelled {
            guard selectedContactId == request.contactID,
                  transmitRuntime.isPressingTalk,
                  !transmitRuntime.explicitStopRequested else {
                pendingBeginTransmitAfterSettlingTask = nil
                return
            }

            let channelCanTransmit = selectedChannelState(for: request.contactID)?.canTransmit == true
            let wakeReady = selectedConversationState(for: request.contactID).phase == .wakeReady
            if !hasPendingBeginOrActiveTransmit,
               !remoteReceiveBlocksLocalTransmit(for: request.contactID),
               channelCanTransmit || wakeReady {
                pendingBeginTransmitAfterSettlingTask = nil
                diagnostics.record(
                    .media,
                    message: "Starting deferred begin transmit after post-live settling",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "reason": reason,
                    ]
                )
                await transmitCoordinator.handle(.pressRequested(request))
                syncTransmitState()
                return
            }

            if DispatchTime.now().uptimeNanoseconds >= deadline {
                pendingBeginTransmitAfterSettlingTask = nil
                transmitRuntime.markPressEnded()
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Deferred begin transmit timed out during post-live settling",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "reason": reason,
                        "channelCanTransmit": String(channelCanTransmit),
                        "hasPendingBeginOrActiveTransmit": String(hasPendingBeginOrActiveTransmit),
                    ]
                )
                updateStatusForSelectedContact()
                captureDiagnosticsState("transmit-begin:deferred-post-live-settling-timeout")
                return
            }

            await refreshChannelState(for: request.contactID)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
        contactID: UUID,
        reason: String
    ) {
        guard mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID else {
            return
        }
        _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: nil)
        diagnostics.record(
            .media,
            message: "Cancelled deferred interactive audio prewarm for local transmit",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
    }

    func shouldDeferBeginTransmitUntilForcedDirectQuicIsReady(
        contact: Contact,
        request: TransmitRequestContext
    ) -> Bool {
        guard TurboMediaLaneDebugOverride.mediaLaneOverride() == .forceDirectQuic else { return false }
        guard !shouldUseDirectQuicAudioTransport(for: contact.id) else { return false }

        diagnostics.record(
            .media,
            level: .notice,
            message: "Deferred begin transmit until forced Direct QUIC media lane is ready",
            metadata: [
                "reason": "forced-direct-quic-not-ready",
                "contact": contact.handle,
                "contactId": contact.id.uuidString,
                "channelId": request.backendChannelID,
                "mediaLaneOverride": TurboMediaLaneOverride.forceDirectQuic.rawValue,
                "mediaLaneEffective": mediaTransportPathState.diagnosticsValue,
                "directQuicActive": String(shouldUseDirectQuicTransport(for: contact.id)),
                "directQuicAudioEligible": String(shouldUseDirectQuicAudioTransport(for: contact.id)),
            ]
        )
        backendStatusMessage = "Preparing Direct QUIC"
        statusMessage = "Preparing Direct QUIC"
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:forced-direct-quic-not-ready")

        Task { [weak self] in
            guard let self else { return }
            await self.maybeStartAutomaticDirectQuicProbe(
                for: contact.id,
                reason: "forced-direct-quic-begin-blocked"
            )
            await self.requestReceiverPrewarmForFirstTalk(
                for: contact.id,
                reason: "forced-direct-quic-begin-blocked"
            )
        }
        return true
    }

    func beginTransmit() {
        guard isJoined else {
            diagnostics.record(.media, message: "Ignored begin transmit request", metadata: ["reason": "not-joined"])
            return
        }
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            diagnostics.record(.media, message: "Ignored begin transmit request", metadata: ["reason": "no-selected-contact"])
            return
        }
        guard !pttCoordinator.state.isTransmitting else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: [
                    "reason": "system-transmit-still-active",
                    "contact": contact.handle,
                    "systemContactId": pttCoordinator.state.activeContactID?.uuidString ?? "none",
                ]
            )
            return
        }
        guard !transmitRuntime.isPressingTalk else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "local-press-already-active", "contact": contact.handle]
            )
            return
        }
        guard !transmitRuntime.requiresReleaseBeforeNextPress else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "requires-fresh-press-after-unexpected-end", "contact": contact.handle]
            )
            return
        }
        guard activeChannelId == contact.id else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: [
                    "reason": "selected-contact-not-active-channel",
                    "contact": contact.handle,
                    "activeChannelId": activeChannelId?.uuidString ?? "none",
                ]
            )
            return
        }
        guard !remoteReceiveBlocksLocalTransmit(for: contact.id) else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "peer-receive-still-draining", "contact": contact.handle]
            )
            updateStatusForSelectedContact()
            return
        }
        let selectedConversation = selectedConversationState(for: contact.id)
        let isWakeReady = selectedConversation.phase == .wakeReady

        guard canBeginTransmit(for: contact.id) else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: [
                    "reason": "selected-conversation-disallows-hold-to-talk",
                    "contact": contact.handle,
                    "phase": String(describing: selectedConversation.phase),
                ]
            )
            updateStatusForSelectedContact()
            return
        }

        guard conversationParticipantTelemetry(for: contact.id)?.audio?.isVolumeOff != true else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "receiver-volume-off", "contact": contact.handle]
            )
            updateStatusForSelectedContact()
            return
        }

        guard let backendChannelId = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let backend = backendServices else {
            statusMessage = "Channel is not ready"
            return
        }

        let request = TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket
        )

        guard !hasPendingBeginOrActiveTransmit else {
            guard shouldDeferBeginTransmitUntilPostLiveSettlingCompletes(for: contact.id) else {
                diagnostics.record(
                    .media,
                    message: "Ignored begin transmit request",
                    metadata: ["reason": "pending-begin-or-active-target", "contact": contact.handle]
                )
                return
            }
            deferBeginTransmitUntilPostLiveSettlingCompletes(
                request: request,
                reason: "previous-stop-in-flight"
            )
            return
        }

        if !isWakeReady {
            guard let channelState = selectedChannelState,
                  channelState.canTransmit else {
                guard shouldDeferBeginTransmitUntilPostLiveSettlingCompletes(for: contact.id) else {
                    diagnostics.record(
                        .media,
                        message: "Ignored begin transmit request",
                        metadata: [
                            "reason": "backend-channel-cannot-transmit",
                            "contact": contact.handle,
                            "channelStatus": selectedChannelState?.status ?? "none",
                        ]
                    )
                    updateStatusForSelectedContact()
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Accepted begin transmit during post-live backend settling",
                    metadata: [
                        "reason": "backend-channel-cannot-transmit-yet",
                        "contact": contact.handle,
                        "channelStatus": selectedChannelState?.status ?? "none",
                    ]
                )
                deferBeginTransmitUntilPostLiveSettlingCompletes(
                    request: request,
                    reason: "backend-channel-settling"
                )
                return
            }
        }

        guard !shouldDeferBeginTransmitUntilForcedDirectQuicIsReady(
            contact: contact,
            request: request
        ) else {
            return
        }

        diagnostics.record(.media, message: "Begin transmit requested", metadata: ["contact": contact.handle])
        sendTelemetryEvent(
            eventName: "ios.transmit.begin_requested",
            severity: .notice,
            reason: "hold-to-talk",
            message: "Begin transmit requested",
            metadata: [
                "contact": contact.handle,
                "backendChannelId": contact.backendChannelId ?? "none",
                "usesLocalHTTPBackend": String(usesLocalHTTPBackend),
            ],
            peerHandle: contact.handle,
            channelId: contact.backendChannelId
        )
        syncEngineJoinedConversation(contactID: contact.id, reason: "begin-transmit")
        syncEngineBeginTalkIntent(reason: "hold-to-talk")
        startTransmitStartupTiming(for: request, source: "hold-to-talk")
        // Latch the press locally before the async reducer runs so a single
        // hold gesture cannot enqueue multiple begin-transmit attempts.
        fenceRemoteAudioReceiveForLocalTransmitStart(
            contactID: contact.id,
            reason: "hold-to-talk"
        )
        cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
            contactID: contact.id,
            reason: "begin-transmit"
        )
        transmitRuntime.markPressBegan()
        transmitRuntime.markControlPlaneBeginHandoffRequested()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:requested")
        Task {
            await transmitCoordinator.handle(.pressRequested(request))
            transmitRuntime.markControlPlaneBeginHandoffCompleted()
            syncTransmitState()
        }
    }

    func handleSystemOriginatedBeginTransmitIfNeeded(
        channelUUID: UUID,
        source: String,
        origin: SystemTransmitBeginOrigin
    ) async {
        guard !usesLocalHTTPBackend else { return }
        guard !transmitRuntime.isPressingTalk else { return }
        guard !transmitCoordinator.state.isPressingTalk else { return }
        guard !hasPendingBeginOrActiveTransmit else { return }
        guard let request = systemOriginatedTransmitRequest(for: channelUUID) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "System-originated transmit began without resolvable backend request context",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "origin": origin.rawValue,
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Beginning backend transmit after system-originated handoff",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "channelId": request.backendChannelID,
                "source": source,
                "origin": origin.rawValue,
            ]
        )
        if selectedContactId == nil {
            selectedContactId = request.contactID
        }
        forceSyncEngineJoinedConversation(contactID: request.contactID, reason: "system-originated-begin-transmit")
        syncEngineObservedSystemTransmit(
            contactID: request.contactID,
            channelUUID: channelUUID,
            reason: "system-originated-\(origin.rawValue)"
        )
        fenceRemoteAudioReceiveForLocalTransmitStart(
            contactID: request.contactID,
            reason: "system-originated-\(origin.rawValue)"
        )
        startTransmitStartupTiming(for: request, source: "system-originated-\(origin.rawValue)")
        transmitRuntime.markPressBegan()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:system-originated")
        await transmitCoordinator.handle(.systemPressRequested(request))
        syncTransmitState()
    }

    func systemOriginatedTransmitRequest(for channelUUID: UUID) -> TransmitRequestContext? {
        guard isJoined else { return nil }
        guard let contactID = contactId(for: channelUUID),
              activeChannelId == contactID,
              let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelId = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let backend = backendServices else {
            return nil
        }

        return TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID,
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket,
            requiresAuthoritativeBackendJoinRefresh: true
        )
    }

    func hasPendingTransmitLifecycle(for systemChannelUUID: UUID) -> Bool {
        transmitProjection.hasPendingLifecycle(
            for: systemChannelUUID,
            channelUUIDForContact: { [weak self] contactID in
                self?.channelUUID(for: contactID)
            }
        )
    }

    func noteTransmitTouchReleased() {
        transmitRuntime.noteTouchReleased()
    }

    @discardableResult
    func cancelActiveTransmitForLifecycleInterruption(reason: String) -> Bool {
        let hasPendingOrActiveTransmit =
            transmitCoordinator.state.isPressingTalk
            || transmitRuntime.isPressingTalk
            || hasPendingBeginOrActiveTransmit
            || isTransmitting
        guard hasPendingOrActiveTransmit else { return false }

        diagnostics.record(
            .media,
            message: "Cancelling active transmit for lifecycle interruption",
            metadata: [
                "reason": reason,
                "isTransmitting": String(isTransmitting),
                "runtimePressing": String(transmitRuntime.isPressingTalk),
                "coordinatorPressing": String(transmitCoordinator.state.isPressingTalk),
                "coordinatorPhase": String(describing: transmitCoordinator.state.phase),
            ]
        )
        endTransmit(reason: reason)
        return true
    }

    func endTransmit(reason: String = "release") {
        transmitRuntime.noteTouchReleased()
        cancelDeferredBeginTransmitAfterPostLiveSettling(reason: reason)
        guard isJoined else { return }
        let hasPendingOrActiveTransmit =
            transmitCoordinator.state.isPressingTalk
            || transmitRuntime.isPressingTalk
            || hasPendingBeginOrActiveTransmit
            || isTransmitting
        guard hasPendingOrActiveTransmit else { return }
        diagnostics.record(.media, message: "End transmit requested", metadata: ["reason": reason])
        sendTelemetryEvent(
            eventName: "ios.transmit.end_requested",
            severity: .notice,
            reason: reason,
            message: "End transmit requested",
            metadata: ["reason": reason]
        )
        syncEngineEndTalkIntent(reason: reason)
        // Clear the local press latch immediately so a system-end callback racing
        // with release does not look like an unexpected end that should be retried.
        if let activeTarget = transmitCoordinator.state.activeTarget ?? transmitRuntime.activeTarget {
            markLocalTransmitStopProjectionGrace(for: activeTarget.contactID)
            cutLocalOutgoingAudioImmediatelyForExplicitStop(
                target: activeTarget,
                reason: reason
            )
        } else if let activeChannelId {
            markLocalTransmitStopProjectionGrace(for: activeChannelId)
        }
        transmitRuntime.markExplicitStopRequested()
        transmitRuntime.markPressEnded()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        let systemChannelUUID =
            transmitCoordinator.state.pendingRequest?.channelUUID
            ?? transmitCoordinator.state.activeTarget.flatMap { channelUUID(for: $0.contactID) }
            ?? transmitRuntime.activeTarget.flatMap { channelUUID(for: $0.contactID) }
            ?? activeChannelId.flatMap { channelUUID(for: $0) }
        cancelRequestedSystemTransmitHandoffIfNeeded(
            channelUUID: systemChannelUUID,
            reason: reason
        )
        transmitTaskCoordinator.send(.cancelBegin)
        syncTransmitState()
        Task {
            await transmitCoordinator.handle(.releaseRequested)
            syncTransmitState()
            updateStatusForSelectedContact()
        }
    }

    func runTransmitEffect(_ effect: TransmitEffect) async {
        switch effect {
        case .beginTransmit(let request):
            transmitTaskCoordinator.send(.beginRequested(request))
        case .activateTransmit(let request, let target):
            await performActivateTransmit(request, target: target)
        case .stopTransmit(let target):
            await performStopTransmit(target)
        case .abortTransmit(let target):
            await performAbortTransmit(target)
        }
    }

    func runTransmitTaskEffect(_ effect: TransmitTaskEffect) {
        switch effect {
        case .cancelBegin:
            transmitTaskRuntime.cancelBeginTask()
        case .startBegin(let workID, let request):
            transmitTaskRuntime.replaceBeginTask(
                with: Task { [weak self] in
                    await self?.performBeginTransmit(request, workID: workID)
                },
                id: workID
            )
        case .cancelRenewal:
            transmitTaskRuntime.cancelRenewalTask()
        case .startRenewal(let workID, let target):
            transmitTaskRuntime.replaceRenewalTask(
                with: Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.performTransmitLeaseRenewal(for: target, workID: workID)
                },
                id: workID,
                target: target
            )
        }
    }

    private func resumeWebSocketBeforePTTTransportWaitIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String,
        reason: String
    ) {
        guard backend.supportsWebSocket else { return }
        guard !backend.isWebSocketConnected else { return }
        guard !backend.isWebSocketSuspended else { return }
        backend.resumeWebSocket()
        diagnostics.record(
            .websocket,
            message: "Resuming WebSocket before PTT transport wait",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "reason": reason,
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
    }

    func refreshWebSocketForSystemTransmitActivationIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String
    ) {
        guard backend.supportsWebSocket else { return }
        let applicationState = currentApplicationState()
        resumeWebSocketBeforePTTTransportWaitIfNeeded(
            backend,
            contactID: contactID,
            channelID: channelID,
            reason: "system-transmit-activation"
        )
        guard applicationState != .active else { return }
        guard backend.isWebSocketConnected else {
            diagnostics.record(
                .websocket,
                message: "Allowing background WebSocket reconnect to continue for system-originated transmit activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "applicationState": String(describing: applicationState),
                ]
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Preserving active WebSocket during system-originated transmit activation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "applicationState": String(describing: applicationState),
            ]
        )
    }

    func refreshWebSocketForWakeReceiveActivationIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String
    ) {
        guard backend.supportsWebSocket else { return }
        let applicationState = currentApplicationState()
        resumeWebSocketBeforePTTTransportWaitIfNeeded(
            backend,
            contactID: contactID,
            channelID: channelID,
            reason: "wake-receive-activation"
        )
        guard applicationState != .active else { return }
        guard !backend.isWebSocketConnected else {
            diagnostics.record(
                .websocket,
                message: "Preserving active WebSocket during wake receive activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "applicationState": String(describing: applicationState),
                ]
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Refreshing WebSocket for wake receive activation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "applicationState": String(describing: applicationState),
            ]
        )
        backend.forceReconnectWebSocket()
    }

    private func backendTalkTurnLeaseRequest(
        for request: TransmitRequestContext,
        backend: BackendServices,
        source: String
    ) throws -> TurboBeginTransmitLeaseRequest {
        guard let currentUserID = backend.currentUserID, !currentUserID.isEmpty else {
            throw TurboBackendError.server("missing current user for talk turn lease")
        }
        return TurboBeginTransmitLeaseRequest(
            deviceId: backend.deviceID,
            requestingParticipantId: currentUserID,
            targetParticipantId: request.remoteUserID,
            operationId: "\(source)-\(UUID().uuidString.lowercased())"
        )
    }

    private func requestBackendTalkTurnLease(
        for request: TransmitRequestContext,
        backend: BackendServices,
        source: String
    ) async throws -> TurboBeginTransmitResponse {
        try await backend.beginTransmit(
            channelId: request.backendChannelID,
            request: backendTalkTurnLeaseRequest(
                for: request,
                backend: backend,
                source: source
            )
        )
    }

    private func grantedTransmitTarget(
        from response: TurboBeginTransmitResponse,
        request: TransmitRequestContext,
        source: String
    ) throws -> TransmitTarget {
        guard !response.isDenied else {
            throw TurboBackendError.server("talk turn denied: \(response.reason ?? "unknown")")
        }
        guard let targetDeviceID = response.targetDeviceId, !targetDeviceID.isEmpty else {
            throw TurboBackendError.invalidResponseDetails(
                "begin-transmit grant missing targetDeviceId source=\(source)"
            )
        }
        let transmitID = response.transmitId ?? response.startedAt
        return TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: targetDeviceID,
            channelID: request.backendChannelID,
            transmitID: transmitID
        )
    }

    private func handleBackendTalkTurnDenied(
        _ response: TurboBeginTransmitResponse,
        request: TransmitRequestContext,
        source: String
    ) async {
        cancelRequestedSystemTransmitHandoffIfNeeded(
            channelUUID: request.channelUUID,
            reason: "backend-talk-turn-denied"
        )
        transmitRuntime.markPressEnded()
        let reason = response.reason ?? "unknown"
        if let channelUUID = request.channelUUID,
           let contact = contacts.first(where: { $0.id == request.contactID }) {
            _ = try? await setSystemActiveRemoteParticipant(
                name: contact.name,
                channelUUID: channelUUID,
                contactID: contact.id,
                reason: "backend-talk-turn-denied"
            )
        }
        recoverRemoteReceiveAfterBackendTalkTurnDenied(
            response,
            request: request,
            reason: reason
        )
        await transmitCoordinator.handle(.beginFailed("Peer is talking"))
        syncTransmitState()
        updateStatusForSelectedContact()
        diagnostics.record(
            .media,
            level: .notice,
            message: "Backend talk turn denied local transmit",
            metadata: [
                "contactId": request.contactID.uuidString,
                "contact": request.contactHandle,
                "channelId": request.backendChannelID,
                "reason": reason,
                "source": source,
            ]
        )
    }

    private func recoverRemoteReceiveAfterBackendTalkTurnDenied(
        _ response: TurboBeginTransmitResponse,
        request: TransmitRequestContext,
        reason: String
    ) {
        guard backendTalkTurnDeniedBecausePeerIsActive(reason) else { return }
        let senderDeviceID =
            response.targetDeviceId
            ?? directQuicPeerDeviceID(for: request.contactID)
            ?? "backend-talk-turn-denied-peer"
        syncEngineRemoteTransmitStarted(
            contactID: request.contactID,
            channelID: request.backendChannelID,
            senderDeviceID: senderDeviceID,
            source: "backend-talk-turn-denied"
        )
        beginRemoteAudioReceiveEpochIfNeeded(
            contactID: request.contactID,
            channelID: request.backendChannelID,
            senderDeviceID: senderDeviceID,
            source: .transmitStartSignal,
            controlTransport: "backend-talk-turn-denied"
        )
        markRemoteAudioActivity(for: request.contactID, source: .transmitStartSignal)
        diagnostics.record(
            .media,
            message: "Recovered remote receive after backend talk turn denied",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "reason": reason,
                "senderDeviceId": senderDeviceID,
                "source": "backend-talk-turn-denied",
            ]
        )
    }

    private func backendTalkTurnDeniedBecausePeerIsActive(_ reason: String) -> Bool {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "current-talk-turn-active"
            || normalized == "active-talk-turn"
            || normalized == "peer-is-talking"
    }

    private func performBeginTransmit(_ request: TransmitRequestContext, workID: Int) async {
        defer {
            transmitTaskCoordinator.send(.beginFinished(id: workID))
            syncTransmitState()
        }
        guard let backend = backendServices else { return }

        do {
            recordTransmitStartupTiming(
                stage: "begin-work-started",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            if request.backendSupportsWebSocket {
                recordTransmitStartupTiming(
                    stage: "websocket-resume-requested",
                    contactID: request.contactID,
                    channelUUID: request.channelUUID,
                    channelID: request.backendChannelID,
                    subsystem: .websocket
                )
                resumeWebSocketBeforePTTTransportWaitIfNeeded(
                    backend,
                    contactID: request.contactID,
                    channelID: request.backendChannelID,
                    reason: "begin-transmit"
                )
            }
            var authoritativeJoinRefreshed = false
            if await reassertBackendJoinAfterWakeIfNeeded(
                for: request.contactID,
                deviceSessionProof: request.requiresAuthoritativeBackendJoinRefresh ? .pttSystem : nil
            ) {
                await refreshChannelState(for: request.contactID)
                guard backendJoinIsVisibleForCriticalOperation(contactID: request.contactID) else {
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Aborting transmit begin until backend join is authoritative",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelId": request.backendChannelID,
                            "source": "begin-transmit",
                            "backendMembership": String(describing: selectedChannelSnapshot(for: request.contactID)?.membership),
                            "localHasActiveDevice": String(selectedChannelSnapshot(for: request.contactID)?.localHasActiveDevice ?? false),
                        ]
                    )
                    throw TurboBackendError.server("backend join not visible after wake recovery")
                }
                authoritativeJoinRefreshed = true
            }
            if request.requiresAuthoritativeBackendJoinRefresh, !authoritativeJoinRefreshed {
                guard let contact = contacts.first(where: { $0.id == request.contactID }) else {
                    throw TurboBackendError.server("missing contact for authoritative backend join refresh")
                }
                let visible = await reassertBackendJoinAndWaitForVisibility(
                    for: contact,
                    source: "system-originated-background-transmit",
                    deviceSessionProof: .pttSystem
                )
                await refreshChannelState(for: request.contactID)
                guard visible, backendJoinIsVisibleForCriticalOperation(contactID: request.contactID) else {
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Aborting system-originated transmit until backend join is authoritative",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelId": request.backendChannelID,
                            "source": "system-originated-background-transmit",
                            "backendMembership": String(describing: selectedChannelSnapshot(for: request.contactID)?.membership),
                            "localHasActiveDevice": String(selectedChannelSnapshot(for: request.contactID)?.localHasActiveDevice ?? false),
                        ]
                    )
                    throw TurboBackendError.server("backend join not visible before system-originated transmit")
                }
            }
            // `beginTransmit` is an HTTP control-plane call that acquires the
            // transmit lease and triggers APNs wake. Do not block that on
            // websocket readiness, which can take several seconds on a cold
            // background path. The later activation step still waits for the
            // websocket before live audio signaling starts.
            recordTransmitStartupTiming(
                stage: "backend-lease-requested",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            let backendLeaseRequestStartedAt = Date()
            let response = try await requestBackendTalkTurnLease(
                for: request,
                backend: backend,
                source: "begin-transmit"
            )
            let backendLeaseRequestElapsedMs = Int(Date().timeIntervalSince(backendLeaseRequestStartedAt) * 1_000)
            if response.isDenied {
                await handleBackendTalkTurnDenied(
                    response,
                    request: request,
                    source: "begin-transmit"
                )
                return
            }
            let target = try grantedTransmitTarget(
                from: response,
                request: request,
                source: "begin-transmit"
            )
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.leaseStartedAtDescription,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.leaseExpirationDescription,
                    "targetDeviceId": target.deviceID,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ]
            )
            recordTransmitStartupTiming(
                stage: "backend-lease-granted",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "targetDeviceId": target.deviceID,
                    "startedAt": response.leaseStartedAtDescription,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.leaseExpirationDescription,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.transmit.backend_granted",
                severity: .notice,
                reason: "begin-transmit",
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.leaseStartedAtDescription,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.leaseExpirationDescription,
                    "targetDeviceId": target.deviceID,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ],
                peerHandle: request.contactHandle,
                channelId: target.channelID
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
                    target: target,
                    backend: backend,
                    source: "begin-transmit"
                )
                return
            }
            let usableTarget = try await refreshBackendTransmitLeaseBeforeActivationIfNeeded(
                response: response,
                target: target,
                request: request,
                backend: backend,
                source: "begin-transmit"
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
                    target: usableTarget,
                    backend: backend,
                    source: "begin-transmit-post-renew"
                )
                return
            }
            transmitRuntime.syncActiveTarget(usableTarget)
            configureOutgoingAudioRoute(target: usableTarget)
            recordTransmitStartupTiming(
                stage: "audio-route-configured-after-lease",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            // The backend lease starts as soon as beginTransmit succeeds.
            // Keep it alive from that point, not from later PTT activation
            // callbacks, which can land seconds later on a cold wake path.
            diagnostics.record(
                .media,
                message: "Starting transmit lease renewal after backend grant",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": "begin-transmit",
                ]
            )
            startRenewingTransmit(usableTarget)
            syncEngineBackendTransmitAccepted(
                target: usableTarget,
                source: "begin-transmit"
            )
            await transmitCoordinator.handle(.beginSucceeded(usableTarget, request))
            syncTransmitState()
            try await requestSystemTransmitHandoffIfNeeded(for: request)
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: usableTarget
            )
        } catch {
            if Task.isCancelled || isExpectedBackendSyncCancellation(error) {
                cancelRequestedSystemTransmitHandoffIfNeeded(
                    channelUUID: request.channelUUID,
                    reason: "backend-begin-cancelled"
                )
                return
            }
            if shouldTreatTransmitBeginMembershipLossAsRecoverable(error) {
                diagnostics.record(
                    .media,
                    message: "Recovering transmit begin after membership drift",
                    metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
                )
                if await recoverTransmitBeginMembershipLoss(
                    request: request,
                    backend: backend,
                    workID: workID
                ) {
                    return
                }
            }
            cancelRequestedSystemTransmitHandoffIfNeeded(
                channelUUID: request.channelUUID,
                reason: "backend-begin-failed"
            )
            let message = error.localizedDescription
            await transmitCoordinator.handle(.beginFailed(message))
            syncTransmitState()
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(.media, level: .error, message: "Transmit failed", metadata: ["contact": request.contactHandle, "error": message])
        }
    }

    private func recoverTransmitBeginMembershipLoss(
        request: TransmitRequestContext,
        backend: BackendServices,
        workID: Int
    ) async -> Bool {
        do {
            _ = try await backend.joinChannel(channelId: request.backendChannelID)
            let response = try await requestBackendTalkTurnLease(
                for: request,
                backend: backend,
                source: "membership-recovery"
            )
            if response.isDenied {
                await handleBackendTalkTurnDenied(
                    response,
                    request: request,
                    source: "membership-recovery"
                )
                return true
            }
            let target = try grantedTransmitTarget(
                from: response,
                request: request,
                source: "membership-recovery"
            )
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.leaseStartedAtDescription,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.leaseExpirationDescription,
                    "targetDeviceId": target.deviceID,
                ]
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
                    target: target,
                    backend: backend,
                    source: "membership-recovery"
                )
                return true
            }
            let usableTarget = try await refreshBackendTransmitLeaseBeforeActivationIfNeeded(
                response: response,
                target: target,
                request: request,
                backend: backend,
                source: "membership-recovery"
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
                    target: usableTarget,
                    backend: backend,
                    source: "membership-recovery-post-renew"
                )
                return true
            }
            transmitRuntime.syncActiveTarget(usableTarget)
            diagnostics.record(
                .media,
                message: "Starting transmit lease renewal after recovered backend grant",
                metadata: [
                    "contactId": usableTarget.contactID.uuidString,
                    "channelId": usableTarget.channelID,
                    "source": "membership-recovery",
                ]
            )
            startRenewingTransmit(usableTarget)
            diagnostics.record(
                .media,
                message: "Recovered transmit membership drift",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
            )
            syncEngineBackendTransmitAccepted(
                target: usableTarget,
                source: "membership-recovery"
            )
            await transmitCoordinator.handle(.beginSucceeded(usableTarget, request))
            syncTransmitState()
            try await requestSystemTransmitHandoffIfNeeded(for: request)
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: usableTarget
            )
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit membership recovery failed",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID, "error": error.localizedDescription]
            )
            await refreshChannelState(for: request.contactID)
            return false
        }
    }

    func shouldActivateBackendTransmitLease(
        request: TransmitRequestContext,
        workID: Int
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        if let runningRequest = transmitTaskCoordinator.state.begin.request,
           runningRequest != request {
            return false
        }
        guard !transmitRuntime.explicitStopRequested else { return false }
        let hasMatchingSystemHandoff =
            request.channelUUID.map {
                transmitRuntime.isSystemTransmitBeginPending(channelUUID: $0)
                || (
                    pttCoordinator.state.isTransmitting
                    && pttCoordinator.state.systemChannelUUID == $0
                )
            } ?? false
        guard transmitRuntime.isPressingTalk
            || transmitCoordinator.state.isPressingTalk
            || hasMatchingSystemHandoff else { return false }
        guard transmitCoordinator.state.isPressingTalk || hasMatchingSystemHandoff else { return false }
        guard transmitCoordinator.state.pendingRequest == request else { return false }
        return true
    }

    func parsedBackendInstant(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let withoutZone = String(text.dropLast())
        let parts = withoutZone.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let baseText = String(parts[0]) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let baseDate = formatter.date(from: baseText) else { return nil }
        guard parts.count == 2 else { return baseDate }

        let fractionalDigits = parts[1].prefix { $0 >= "0" && $0 <= "9" }
        guard !fractionalDigits.isEmpty else { return baseDate }
        let scale = pow(10.0, Double(fractionalDigits.count))
        let fractionalSeconds = (Double(fractionalDigits) ?? 0) / scale
        return baseDate.addingTimeInterval(fractionalSeconds)
    }

    func backendTransmitLeaseRemainingSeconds(
        expiresAt: String,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let expiration = parsedBackendInstant(expiresAt) else { return nil }
        return expiration.timeIntervalSince(now)
    }

    func backendTransmitLeaseNeedsImmediateRenewal(
        expiresAt: String,
        now: Date = Date()
    ) -> Bool {
        guard let remaining = backendTransmitLeaseRemainingSeconds(expiresAt: expiresAt, now: now) else {
            return false
        }
        return remaining < minimumUsableBackendTransmitLeaseSeconds
    }

    private func refreshBackendTransmitLeaseBeforeActivationIfNeeded(
        response: TurboBeginTransmitResponse,
        target: TransmitTarget,
        request: TransmitRequestContext,
        backend: BackendServices,
        source: String
    ) async throws -> TransmitTarget {
        guard let expiresAt = response.expiresAt else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Backend transmit lease expiration is not ISO8601",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "expiresAt": response.leaseExpirationDescription,
                    "source": source,
                ]
            )
            return target
        }
        guard let remainingSeconds = backendTransmitLeaseRemainingSeconds(expiresAt: expiresAt) else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Could not parse backend transmit lease expiration",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "expiresAt": response.leaseExpirationDescription,
                    "source": source,
                ]
            )
            return target
        }
        guard remainingSeconds < minimumUsableBackendTransmitLeaseSeconds else { return target }

        let remainingMilliseconds = Int(remainingSeconds * 1_000)
        diagnostics.record(
            .media,
            level: .notice,
            message: "Backend transmit lease grant had low remaining lifetime; renewing before activation",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "targetDeviceId": target.deviceID,
                "startedAt": response.leaseStartedAtDescription,
                "expiresAt": response.leaseExpirationDescription,
                "remainingMs": String(remainingMilliseconds),
                "minimumUsableMs": String(Int(minimumUsableBackendTransmitLeaseSeconds * 1_000)),
                "source": source,
            ]
        )
        recordTransmitStartupTiming(
            stage: "backend-lease-immediate-renew-requested",
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            channelID: request.backendChannelID,
            metadata: [
                "targetDeviceId": target.deviceID,
                "remainingMs": String(remainingMilliseconds),
                "source": source,
            ]
        )

        let renewStartedAt = Date()
        do {
            let renewed = try await backend.renewTransmit(
                channelId: target.channelID,
                transmitId: target.transmitID
            )
            let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1_000)
            diagnostics.record(
                .media,
                message: "Backend transmit lease renewed before activation",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "targetDeviceId": target.deviceID,
                    "startedAt": renewed.startedAt,
                    "transmitId": renewed.transmitId ?? target.transmitID ?? "missing",
                    "expiresAt": renewed.expiresAt,
                    "renewDurationMs": String(renewDurationMs),
                    "source": source,
                ]
            )
            recordTransmitStartupTiming(
                stage: "backend-lease-immediate-renewed",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "targetDeviceId": target.deviceID,
                    "expiresAt": renewed.expiresAt,
                    "renewDurationMs": String(renewDurationMs),
                    "source": source,
                ]
            )
            return TransmitTarget(
                contactID: target.contactID,
                userID: target.userID,
                deviceID: target.deviceID,
                channelID: target.channelID,
                transmitID: renewed.transmitId ?? target.transmitID
            )
        } catch {
            guard shouldTreatTransmitLeaseLossAsStop(error) else { throw error }

            diagnostics.record(
                .media,
                level: .notice,
                message: "Backend transmit lease expired before activation; reacquiring",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "targetDeviceId": target.deviceID,
                    "remainingMs": String(remainingMilliseconds),
                    "error": error.localizedDescription,
                    "source": source,
                ]
            )
            let reacquired = try await requestBackendTalkTurnLease(
                for: request,
                backend: backend,
                source: "\(source)-reacquire"
            )
            if reacquired.isDenied {
                throw TurboBackendError.server("talk turn denied: \(reacquired.reason ?? "unknown")")
            }
            return try grantedTransmitTarget(
                from: reacquired,
                request: request,
                source: "\(source)-reacquire"
            )
        }
    }

    func scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
        target: TransmitTarget,
        backend: BackendServices,
        source: String
    ) {
        Task { @MainActor [weak self, backend] in
            await self?.cleanupBackendTransmitLeaseGrantedAfterRelease(
                target: target,
                backend: backend,
                source: source
            )
        }
    }

    func cleanupBackendTransmitLeaseGrantedAfterRelease(
        target: TransmitTarget,
        backend: BackendServices,
        source: String
    ) async {
        guard !transmitRuntime.isPressingTalk || transmitRuntime.explicitStopRequested else {
            diagnostics.record(
                .media,
                message: "Ignoring stale backend transmit lease while another press is active",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Backend transmit lease granted after release; ending without activating",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "source": source,
            ]
        )
        transmitTaskCoordinator.send(.renewalCancelled)
        transmitTaskRuntime.cancelCaptureReassertionTask()
        syncEngineEndTalkIntent(reason: "\(source)-late-lease-after-release")
        await mediaServices.session()?.abortSendingAudio()
        if backend.supportsWebSocket && backend.isWebSocketConnected {
            try? await backend.sendSignal(
                TurboSignalEnvelope(
                    type: .transmitStop,
                    channelId: target.channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: target.userID,
                    toDeviceId: target.deviceID,
                    payload: "ptt-end"
                )
            )
        }
        do {
            _ = try await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
            diagnostics.record(
                .media,
                message: "Ended late backend transmit lease after release",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to end late backend transmit lease after release",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                    "error": error.localizedDescription,
                ]
            )
        }
        await refreshChannelState(for: target.contactID)
        updateStatusForSelectedContact()
    }

    private func performActivateTransmit(_ request: TransmitRequestContext, target: TransmitTarget) async {
        if request.usesLocalHTTPBackend {
            configureOutgoingAudioRoute(target: target)
            startRenewingTransmit(target)
            syncEngineBackendTransmitAccepted(target: target, source: "local-http")
        } else {
            guard request.channelUUID != nil else {
                let message = "PTT channel is not ready"
                statusMessage = message
                await transmitCoordinator.handle(.stopFailed(target, message))
                syncTransmitState()
                return
            }
            // Keep the backend transmit lease alive during the cold PTT
            // activation window instead of waiting for later audio-session
            // callbacks, which can arrive after the initial lease expires.
            startRenewingTransmit(target)
            if let channelUUID = request.channelUUID,
               pttCoordinator.state.systemChannelUUID == channelUUID,
               pttCoordinator.state.isTransmitting,
               !isPTTAudioSessionActive {
                scheduleAppleGatedAudioActivationTimeoutAfterSystemBeginIfNeeded(
                    channelUUID: channelUUID,
                    source: "backend-lease-granted"
                )
            }
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: target
            )
        }

        await refreshChannelState(for: request.contactID)
    }

    private func requestSystemTransmitHandoffIfNeeded(
        for request: TransmitRequestContext
    ) async throws {
        guard !request.usesLocalHTTPBackend else { return }
        guard let channelUUID = request.channelUUID else { return }
        recordTransmitStartupTiming(
            stage: "direct-quic-transmit-prepare-requested",
            contactID: request.contactID,
            channelUUID: channelUUID,
            channelID: request.backendChannelID,
            subsystem: .media
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.shouldContinueDirectQuicTransmitPrepareTask(
                for: request,
                source: "system-transmit-handoff"
            ) else {
                return
            }
            let didSendDirectQuicTransmitPrepare = await self.sendDirectQuicReceiverTransmitPrepareIfPossible(
                for: request.contactID,
                reason: "system-transmit-handoff",
                sendWarmPing: false
            )
            guard didSendDirectQuicTransmitPrepare else { return }
            guard self.shouldContinueDirectQuicTransmitPrepareTask(
                for: request,
                source: "system-transmit-handoff-sent"
            ) else {
                return
            }
            self.recordTransmitStartupTiming(
                stage: "direct-quic-transmit-prepare-sent",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                subsystem: .media
            )
            await self.sendDirectQuicWarmPingIfPossible(
                for: request.contactID,
                reason: "transmit-system-transmit-handoff"
            )
        }
        guard !pttCoordinator.state.isTransmitting || pttCoordinator.state.systemChannelUUID != channelUUID else { return }
        guard !transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID) else { return }
        guard shouldContinueSystemTransmitHandoffRequest(for: request) else { return }
        transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        recordTransmitStartupTiming(
            stage: "system-handoff-started",
            contactID: request.contactID,
            channelUUID: channelUUID,
            channelID: request.backendChannelID,
            subsystem: .pushToTalk
        )
        await clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: request.contactID,
            channelUUID: channelUUID,
            reason: "before-system-transmit-handoff",
            timeoutNanoseconds: remoteParticipantClearBeforeTransmitTimeoutNanoseconds
        )

        if shouldClosePrewarmedMediaBeforeSystemTransmit(for: request.contactID) {
            let deactivateAudioSession =
                shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for: request.contactID)
            let preserveDirectQuic = shouldUseDirectQuicTransport(for: request.contactID)
            let preserveMediaRelay =
                !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: request.contactID)
            diagnostics.record(
                .media,
                message: "Closing app-managed media session before system transmit handoff",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                    "deactivateAudioSession": String(deactivateAudioSession),
                    "preserveDirectQuic": String(preserveDirectQuic),
                    "preserveMediaRelay": String(preserveMediaRelay),
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                ]
            )
            closeMediaSession(
                deactivateAudioSession: deactivateAudioSession,
                preserveDirectQuic: preserveDirectQuic,
                preserveMediaRelay: preserveMediaRelay
            )
            recordTransmitStartupTiming(
                stage: "prewarmed-media-closed",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID
            )
            configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
                for: request,
                reason: "after-prewarmed-media-close"
            )
            if directQuicTransmitStartupPolicy == .appleGated,
               preserveDirectQuic,
               let provisionalTarget = provisionalDirectQuicTransmitTarget(
                    for: request,
                    reason: "apple-gated-deferral-after-prewarmed-media-close"
               ) {
                recordAppleGatedWarmDirectCaptureDeferred(
                    request: request,
                    target: provisionalTarget,
                    trigger: "system-transmit-handoff",
                    reason: "waiting-for-apple-audio-session"
                )
            }
        } else if shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: request.contactID) {
            diagnostics.record(
                .media,
                message: "Preserving prewarmed Direct QUIC media session for system transmit bridge",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                ]
            )
            recordTransmitStartupTiming(
                stage: "prewarmed-media-preserved",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    "bridge": "prewarmed-direct",
                ]
            )
            configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
                for: request,
                reason: "prewarmed-media-preserved"
            )
        }
        guard transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID),
              shouldContinueSystemTransmitHandoffRequest(for: request) else {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            diagnostics.record(
                .pushToTalk,
                message: "Cancelled system transmit handoff before Apple request",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "source": "pre-apple-request-continuation",
                ]
            )
            return
        }

        diagnostics.record(
            .pushToTalk,
            message: "Requesting system transmit handoff",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "source": "post-backend-grant",
            ]
        )
        armPTTLocalTransmitAudioActivation(
            request: request,
            channelUUID: channelUUID,
            source: "system-transmit-handoff"
        )
        do {
            try pttSystemClient.beginTransmitting(channelUUID: channelUUID)
            recordTransmitStartupTiming(
                stage: "system-handoff-requested",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                subsystem: .pushToTalk
            )
        } catch {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            clearPendingLocalPTTAudioActivation(
                channelUUID: channelUUID,
                source: "system-transmit-handoff-failed"
            )
            throw error
        }
    }

    private func shouldContinueSystemTransmitHandoffRequest(
        for request: TransmitRequestContext
    ) -> Bool {
        guard hasActiveTransmitPressIntent() else { return false }
        if transmitCoordinator.state.pendingRequest == request {
            return true
        }
        if let activeTarget = transmitCoordinator.state.activeTarget {
            return activeTarget.contactID == request.contactID
                && activeTarget.channelID == request.backendChannelID
        }
        return false
    }

    func shouldContinueDirectQuicTransmitPrepareTask(
        for request: TransmitRequestContext,
        source: String
    ) -> Bool {
        let shouldContinue = shouldContinueSystemTransmitHandoffRequest(for: request)
        guard !shouldContinue else { return true }
        diagnostics.record(
            .media,
            message: "Skipped stale Direct QUIC transmit prepare after talk intent ended",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "source": source,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
            ]
        )
        return false
    }

    func scheduleAppleGatedAudioActivationTimeoutAfterSystemBeginIfNeeded(
        channelUUID: UUID,
        source: String
    ) {
        guard directQuicTransmitStartupPolicy == .appleGated else { return }
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard !ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "apple-gated-timeout-schedule"
        ) else {
            return
        }

        transmitTaskRuntime.replaceCaptureReassertionTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                let timeout = self.appleGatedAudioActivationTimeoutNanoseconds
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                guard !self.ensurePTTAudioSessionIsOwnedByLocalTransmit(
                    channelUUID: channelUUID,
                    target: target,
                    stage: "apple-gated-timeout-fired"
                ) else {
                    return
                }
                await self.abortAppleGatedSystemTransmitAfterMissingAudioActivationIfNeeded(
                    target: target,
                    channelUUID: channelUUID,
                    trigger: "system-transmit-began:\(source)"
                )
            }
        )
    }

    @discardableResult
    func abortAppleGatedSystemTransmitAfterMissingAudioActivationIfNeeded(
        target: TransmitTarget,
        channelUUID: UUID,
        trigger: String
    ) async -> Bool {
        guard !usesLocalHTTPBackend else { return false }
        guard directQuicTransmitStartupPolicy == .appleGated else { return false }
        guard !ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "apple-gated-timeout-abort"
        ) else {
            return false
        }
        guard currentApplicationState() == .active else { return false }
        guard hasActiveTransmitPressIntent() else { return false }
        guard pttCoordinator.state.systemChannelUUID == channelUUID,
              pttCoordinator.state.isTransmitting else {
            return false
        }
        guard transmitStartupTiming.elapsedMilliseconds(for: "transmit-start-signal-sent") == nil else { return false }

        let contract = DiagnosticsContracts.Transmit.appleGatedAudioActivationDeadlineElapsed(
            contactID: target.contactID,
            channelID: target.channelID,
            channelUUID: channelUUID,
            targetDeviceID: target.deviceID,
            trigger: trigger,
            startupPolicy: directQuicTransmitStartupPolicy.rawValue,
            isPTTAudioSessionActive: isPTTAudioSessionActive,
            timeoutMilliseconds: appleGatedAudioActivationTimeoutNanoseconds / 1_000_000
        )
        let metadata = contract.metadata
        diagnostics.recordContractViolation(
            contract
        )
        diagnostics.record(
            .pushToTalk,
            level: .error,
            message: "Aborting Apple-gated transmit after missing PTT audio activation",
            metadata: metadata
        )
        recordTransmitStartupTiming(
            stage: "ptt-audio-activation-timeout-abort-started",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID,
            subsystem: .pushToTalk,
            metadata: metadata
        )
        transmitRuntime.markUnexpectedSystemEndRequiresRelease(contactID: target.contactID)
        transmitRuntime.noteSystemTransmitEnded()
        transmitRuntime.clearSystemTransmitActivation(channelUUID: channelUUID)
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        syncEngineSystemTransmitBeginFailed(
            message: "PTT audio activation timed out",
            source: "apple-gated-audio-activation-timeout"
        )
        await pttCoordinator.handle(
            .failedToBeginTransmitting(
                channelUUID: channelUUID,
                message: "PTT audio activation timed out"
            )
        )
        await transmitCoordinator.handle(.systemBeginFailed("PTT audio activation timed out"))
        clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
        syncTransmitState()
        syncPTTState()
        updateStatusForSelectedContact()
        recordTransmitStartupTiming(
            stage: "ptt-audio-activation-timeout-aborted",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID,
            subsystem: .pushToTalk,
            metadata: metadata
        )
        captureDiagnosticsState("ptt-audio-activation-timeout-aborted")
        return true
    }

    @discardableResult
    func startPrewarmedMediaRelaySystemTransmitBridgeIfPossible(
        request: TransmitRequestContext,
        trigger: String
    ) async -> Bool {
        guard !request.usesLocalHTTPBackend else { return false }
        guard let channelUUID = request.channelUUID else { return false }
        guard hasActiveTransmitPressIntent() else { return false }
        guard shouldBridgePrewarmedMediaRelayDuringSystemTransmit(for: request.contactID) else {
            return false
        }
        guard let target = activeTransmitTarget(for: channelUUID) else {
            return false
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "fast-relay-bridge-start"
        ) else {
            return false
        }
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "fast-relay-bridge-start"
        ) else {
            return false
        }
        let reservation = await reserveTransmitAudioCaptureStart(
            channelUUID: channelUUID,
            contactID: request.contactID,
            channelID: request.backendChannelID,
            intent: .initial,
            trigger: "fast-relay-\(trigger)",
            shouldContinue: {
                shouldContinueSystemTransmitActivation(
                    channelUUID: channelUUID,
                    target: target,
                    stage: "fast-relay-bridge-reservation"
                )
            }
        )
        switch reservation {
        case .reserved:
            break
        case .alreadyCompleted, .cancelled:
            return false
        }

        do {
            configureOutgoingAudioRoute(target: target)
            diagnostics.record(
                .media,
                message: "Starting Fast Relay audio after PTT activation",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "channelUUID": channelUUID.uuidString,
                    "trigger": trigger,
                ]
            )
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-requested",
                metadata: ["trigger": "fast-relay-\(trigger)"]
            )
            try await startCurrentMediaSessionSendingAudio(
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: channelUUID,
                trigger: trigger,
                metadata: ["bridge": "fast-relay"]
            )
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "fast-relay-bridge-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
                await mediaServices.session()?.abortSendingAudio()
                return false
            }
            noteTransmitAudioCaptureStartCompleted(channelUUID: channelUUID, intent: .initial)
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-completed",
                metadata: ["trigger": "fast-relay-\(trigger)"]
            )
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Prewarmed Fast Relay audio bridge failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "channelUUID": channelUUID.uuidString,
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            return false
        }
    }

    @discardableResult
    func clearSystemRemoteParticipantBeforeLocalTransmit(
        contactID: UUID,
        channelUUID: UUID,
        reason: String,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        let startedAt = Date()
        let clearResult: Result<Void, Error>?

        if let timeoutNanoseconds {
            let resultBox = RemoteParticipantClearResultBox()
            Task { @MainActor [weak self] in
                guard let self else {
                    await resultBox.resolve(.failure(PTTSystemClientError.notReady))
                    return
                }
                do {
                    try await self.setSystemActiveRemoteParticipant(
                        name: nil,
                        channelUUID: channelUUID,
                        contactID: contactID,
                        reason: reason,
                        allowStaleClearReassert: false
                    )
                    await resultBox.resolve(.success(()))
                } catch {
                    await resultBox.resolve(.failure(error))
                }
            }

            let pollNanoseconds: UInt64 = 10_000_000
            let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
            var resolvedResult: Result<Void, Error>?
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let result = await resultBox.currentResult() {
                    resolvedResult = result
                    break
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                let remaining = deadline - now
                try? await Task.sleep(nanoseconds: min(pollNanoseconds, remaining))
            }
            if let resolvedResult {
                clearResult = resolvedResult
            } else {
                clearResult = await resultBox.currentResult()
            }
        } else {
            do {
                try await setSystemActiveRemoteParticipant(
                    name: nil,
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reason,
                    allowStaleClearReassert: false
                )
                clearResult = .success(())
            } catch {
                clearResult = .failure(error)
            }
        }

        guard let clearResult else {
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            diagnostics.record(
                .pushToTalk,
                message: "Timed out clearing active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "timeoutMs": String((timeoutNanoseconds ?? 0) / 1_000_000),
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-timed-out",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "timeoutMs": String((timeoutNanoseconds ?? 0) / 1_000_000),
                ]
            )
            return false
        }

        switch clearResult {
        case .success:
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            diagnostics.record(
                .pushToTalk,
                message: "Cleared active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-completed",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                ]
            )
            return true

        case .failure(let error):
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            if isExpectedPTTRemoteParticipantClearFailure(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Skipped remote participant clear because no active remote participant was present",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                recordTransmitStartupTiming(
                    stage: "remote-participant-clear-not-needed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                return true
            }
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Skipped remote participant clear for unavailable system channel",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                recordTransmitStartupTiming(
                    stage: "remote-participant-clear-skipped",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                return true
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Failed to clear active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "error": error.localizedDescription,
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-failed",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    private func cancelRequestedSystemTransmitHandoffIfNeeded(
        channelUUID: UUID?,
        reason: String
    ) {
        guard let channelUUID else { return }
        let hadPendingBegin = transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID)
        let isActiveSystemTransmit =
            pttCoordinator.state.systemChannelUUID == channelUUID
            && (pttCoordinator.state.isTransmitting || isPTTAudioSessionActive)
        guard hadPendingBegin || isActiveSystemTransmit else { return }

        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        clearPendingLocalPTTAudioActivation(
            channelUUID: channelUUID,
            source: "system-transmit-handoff-cancelled:\(reason)"
        )
        diagnostics.record(
            .pushToTalk,
            message: "Cancelling requested system transmit handoff",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "reason": reason,
                "hadPendingBegin": String(hadPendingBegin),
                "isActiveSystemTransmit": String(isActiveSystemTransmit),
            ]
        )
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
    }

    private func completeDeferredSystemTransmitActivationIfReady(
        request: TransmitRequestContext,
        target: TransmitTarget
    ) async {
        guard !request.usesLocalHTTPBackend else { return }
        guard let channelUUID = request.channelUUID else { return }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return }
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "deferred-activation-ready"
        ) else {
            return
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "deferred-activation-ready"
        ) else {
            return
        }
        await completeSystemTransmitActivation(channelUUID: channelUUID)
    }

    @discardableResult
    func startPrewarmedDirectSystemTransmitBridgeIfPossible(
        request: TransmitRequestContext,
        trigger: String
    ) async -> Bool {
        guard let target = provisionalDirectQuicTransmitTarget(
            for: request,
            reason: "prewarmed-direct-bridge-\(trigger)"
        ) else {
            return false
        }
        return await startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            target: target,
            trigger: trigger
        )
    }

    @discardableResult
    func startPrewarmedDirectSystemTransmitBridgeIfPossible(
        request: TransmitRequestContext,
        target: TransmitTarget,
        trigger: String
    ) async -> Bool {
        guard !request.usesLocalHTTPBackend else { return false }
        guard let channelUUID = request.channelUUID else { return false }
        guard hasActiveTransmitPressIntent() else { return false }
        guard shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: request.contactID) else {
            return false
        }
        guard let leaseTarget = activeTransmitTarget(for: channelUUID),
              leaseTarget.contactID == request.contactID,
              leaseTarget.channelID == request.backendChannelID else {
            diagnostics.record(
                .media,
                message: "Deferring Direct QUIC capture until backend lease is granted",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "channelUUID": channelUUID.uuidString,
                    "trigger": trigger,
                ]
            )
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-deferred-until-backend-lease",
                metadata: ["trigger": trigger, "bridge": "prewarmed-direct"]
            )
            return false
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: leaseTarget,
            stage: "prewarmed-direct-bridge-start"
        ) else {
            recordAppleGatedWarmDirectCaptureDeferred(
                request: request,
                target: target,
                trigger: trigger,
                reason: "waiting-for-local-transmit-audio-epoch"
            )
            return false
        }
        let authorizedTarget = leaseTarget
        let reservation = await reserveTransmitAudioCaptureStart(
            channelUUID: channelUUID,
            contactID: request.contactID,
            channelID: request.backendChannelID,
            intent: .initial,
            trigger: trigger,
            shouldContinue: {
                shouldContinuePrewarmedDirectSystemTransmitBridge(
                    request: request,
                    target: authorizedTarget,
                    stage: "capture-reservation"
                )
            }
        )
        switch reservation {
        case .reserved:
            break
        case .alreadyCompleted, .cancelled:
            return false
        }

        configureOutgoingAudioRoute(target: authorizedTarget)
        diagnostics.record(
            .media,
            message: "Starting Direct QUIC audio after PTT activation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "targetDeviceId": authorizedTarget.deviceID,
                "trigger": trigger,
                "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
            ]
        )
        do {
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-requested",
                metadata: ["trigger": trigger, "bridge": "prewarmed-direct"]
            )
            try await startCurrentMediaSessionSendingAudio(
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: channelUUID,
                trigger: trigger,
                metadata: ["bridge": "prewarmed-direct"]
            )
            guard shouldContinuePrewarmedDirectSystemTransmitBridge(
                request: request,
                target: authorizedTarget,
                stage: "early-audio-capture-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
                await mediaServices.session()?.abortSendingAudio()
                return false
            }
            noteTransmitAudioCaptureStartCompleted(channelUUID: channelUUID, intent: .initial)
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-completed",
                metadata: ["trigger": trigger, "bridge": "prewarmed-direct"]
            )
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Prewarmed Direct QUIC audio bridge failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            return false
        }
    }

    func recordAppleGatedWarmDirectCaptureDeferred(
        request: TransmitRequestContext,
        target: TransmitTarget,
        trigger: String,
        reason: String
    ) {
        diagnostics.record(
            .media,
            message: "Deferring warm Direct QUIC capture until Apple audio activation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "targetDeviceId": target.deviceID,
                "trigger": trigger,
                "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                "applicationState": String(describing: currentApplicationState()),
                "mediaState": String(describing: mediaConnectionState),
                "reason": reason,
            ]
        )
        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-audio-capture-deferred-until-system-activation",
            metadata: [
                "trigger": trigger,
                "bridge": "prewarmed-direct",
                "reason": reason,
            ]
        )
    }

    func activeTransmitTarget(for systemChannelUUID: UUID) -> TransmitTarget? {
        transmitProjection.activeTarget(
            for: systemChannelUUID,
            channelUUIDForContact: { [weak self] contactID in
                self?.channelUUID(for: contactID)
            }
        )
    }

    private func stageCompletedTransmitStartupSideEffect(_ stage: String) -> Bool {
        switch stage {
        case "audio-capture-start-completed",
             "early-audio-capture-start-completed",
             "audio-capture-refreshed-after-system-activation",
             "transmit-start-signal-sent":
            return true
        default:
            return false
        }
    }

    private func recordStaleTransmitStartupSideEffectInvariantIfNeeded(
        stage: String,
        reason: String,
        contactID: UUID,
        channelID: String,
        channelUUID: UUID?,
        metadata: [String: String] = [:]
    ) {
        guard stageCompletedTransmitStartupSideEffect(stage) else { return }
        diagnostics.recordContractViolation(
            DiagnosticsContracts.Transmit.staleStartupSideEffect(
                stage: stage,
                reason: reason,
                contactID: contactID,
                channelID: channelID,
                channelUUID: channelUUID,
                runtimePressActive: transmitRuntime.isPressingTalk,
                coordinatorPressActive: transmitCoordinator.state.isPressingTalk,
                explicitStopRequested: transmitRuntime.explicitStopRequested
            ),
            metadata: metadata
        )
    }

    func shouldContinueSystemTransmitActivation(
        channelUUID: UUID,
        target: TransmitTarget,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = activeTransmitTarget(for: channelUUID)
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if peerTransmitBlocksLocalSystemActivation(for: target.contactID) {
            reason = "peer-transmit-authoritative"
        } else if pttCoordinator.state.systemChannelUUID != channelUUID {
            reason = "system-channel-mismatch"
        } else if !pttCoordinator.state.isTransmitting {
            reason = "system-not-transmitting"
        } else if activeTarget != target {
            reason = "active-target-mismatch"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale system transmit activation continuation",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "channelUUID": channelUUID.uuidString,
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "activeTargetMatches": String(activeTarget == target),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: target.contactID,
                channelID: target.channelID,
                channelUUID: channelUUID,
                metadata: ["activeTargetMatches": String(activeTarget == target)]
            )
        }
        if reason == "peer-transmit-authoritative" {
            cancelLocalSystemTransmitActivationAfterPeerBecameAuthoritative(
                channelUUID: channelUUID,
                target: target,
                stage: stage
            )
        }
        return false
    }

    private func peerTransmitBlocksLocalSystemActivation(for contactID: UUID) -> Bool {
        let channelSnapshot = selectedChannelSnapshot(for: contactID)
        let backendPeerIsTransmitting =
            channelSnapshot?.readinessStatus?.conversationState == .receiving
            || channelSnapshot?.status == .receiving
        return backendPeerIsTransmitting || remoteReceiveBlocksLocalTransmit(for: contactID)
    }

    private func cancelLocalSystemTransmitActivationAfterPeerBecameAuthoritative(
        channelUUID: UUID,
        target: TransmitTarget,
        stage: String
    ) {
        let backendSnapshot = selectedChannelSnapshot(for: target.contactID)
        let hadPendingBegin = transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID)
        let pttWasTransmitting =
            pttCoordinator.state.systemChannelUUID == channelUUID
            && pttCoordinator.state.isTransmitting
        let activeTarget = transmitCoordinator.state.activeTarget

        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        transmitRuntime.markPressEnded()
        transmitRuntime.clearSystemTransmitActivation(channelUUID: channelUUID)
        clearPendingLocalPTTAudioActivation(
            channelUUID: channelUUID,
            source: "peer-transmit-authoritative:\(stage)"
        )
        clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
        clearTransmitAudioCaptureStartIfInFlight(
            channelUUID: channelUUID,
            intent: .systemActivationRefresh
        )
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        pttCoordinator.send(
            .didEndTransmitting(
                channelUUID: channelUUID,
                origin: .explicitStopReconciliation(source: "peer-transmit-authoritative")
            )
        )
        transmitCoordinator.reset()
        transmitRuntime.syncActiveTarget(nil)
        if let activeTarget, let backend = backendServices {
            scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
                target: activeTarget,
                backend: backend,
                source: "peer-transmit-authoritative"
            )
        }
        syncPTTState()
        syncTransmitState()
        updateStatusForSelectedContact()
        diagnostics.record(
            .pushToTalk,
            level: .notice,
            message: "Cancelled local transmit activation because peer became authoritative",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "channelUUID": channelUUID.uuidString,
                "stage": stage,
                "hadPendingSystemBegin": String(hadPendingBegin),
                "pttWasTransmitting": String(pttWasTransmitting),
                "backendChannelStatus": backendSnapshot?.status?.rawValue ?? "none",
                "backendReadiness": backendSnapshot?.readinessStatus?.kind ?? "none",
                "remoteActivityBlocksTransmit": String(
                    remoteReceiveBlocksLocalTransmit(for: target.contactID)
                ),
            ]
        )
        captureDiagnosticsState("transmit-activation:cancelled-peer-active")
    }

    func shouldContinuePendingSystemTransmitAudioCapture(
        request: TransmitRequestContext,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = request.channelUUID.flatMap { activeTransmitTarget(for: $0) }
        let requestStillCurrent =
            transmitCoordinator.state.pendingRequest == request
            || (
                activeTarget?.contactID == request.contactID
                && activeTarget?.channelID == request.backendChannelID
                && activeTarget?.userID == request.remoteUserID
            )
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if peerTransmitBlocksLocalSystemActivation(for: request.contactID) {
            reason = "peer-transmit-authoritative"
        } else if pttCoordinator.state.systemChannelUUID != request.channelUUID {
            reason = "system-channel-mismatch"
        } else if !pttCoordinator.state.isTransmitting {
            reason = "system-not-transmitting"
        } else if !requestStillCurrent {
            reason = "request-not-current"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale pending system transmit audio capture",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "requestStillCurrent": String(requestStillCurrent),
                "remoteActivityBlocksTransmit": String(
                    remoteReceiveBlocksLocalTransmit(for: request.contactID)
                ),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: request.channelUUID,
                metadata: [
                    "requestKind": "pending-system-audio-capture",
                    "requestStillCurrent": String(requestStillCurrent),
                ]
            )
        }
        if reason == "peer-transmit-authoritative" {
            cancelPendingSystemTransmitActivationAfterPeerBecameAuthoritative(
                request: request,
                stage: stage
            )
        }
        return false
    }

    private func cancelPendingSystemTransmitActivationAfterPeerBecameAuthoritative(
        request: TransmitRequestContext,
        stage: String
    ) {
        let channelUUID = request.channelUUID
        let backendSnapshot = selectedChannelSnapshot(for: request.contactID)
        let hadPendingBegin = channelUUID.map {
            transmitRuntime.isSystemTransmitBeginPending(channelUUID: $0)
        } ?? false
        let pttWasTransmitting =
            channelUUID.map {
                pttCoordinator.state.systemChannelUUID == $0
                    && pttCoordinator.state.isTransmitting
            } ?? false

        if let channelUUID {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            transmitRuntime.clearSystemTransmitActivation(channelUUID: channelUUID)
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            clearTransmitAudioCaptureStartIfInFlight(
                channelUUID: channelUUID,
                intent: .systemActivationRefresh
            )
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            pttCoordinator.send(
                .didEndTransmitting(
                    channelUUID: channelUUID,
                    origin: .explicitStopReconciliation(source: "peer-transmit-authoritative")
                )
            )
        } else {
            transmitRuntime.clearPendingSystemTransmitBegin()
            transmitRuntime.clearSystemTransmitActivation()
        }
        transmitRuntime.markPressEnded()
        cancelPendingTransmitWork()
        transmitCoordinator.reset()
        transmitRuntime.syncActiveTarget(nil)
        syncPTTState()
        syncTransmitState()
        updateStatusForSelectedContact()
        diagnostics.record(
            .pushToTalk,
            level: .notice,
            message: "Cancelled local transmit activation because peer became authoritative",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": channelUUID?.uuidString ?? "none",
                "stage": stage,
                "requestKind": "pending-system-audio-capture",
                "hadPendingSystemBegin": String(hadPendingBegin),
                "pttWasTransmitting": String(pttWasTransmitting),
                "backendChannelStatus": backendSnapshot?.status?.rawValue ?? "none",
                "backendReadiness": backendSnapshot?.readinessStatus?.kind ?? "none",
                "remoteActivityBlocksTransmit": String(
                    remoteReceiveBlocksLocalTransmit(for: request.contactID)
                ),
            ]
        )
        captureDiagnosticsState("transmit-activation:cancelled-pending-peer-active")
    }

    func hasPreActivationTransmitAudioCaptureEvidence(channelUUID: UUID) -> Bool {
        switch transmitRuntime.audioCaptureStartState {
        case .starting(let existingChannelUUID),
             .started(let existingChannelUUID):
            if existingChannelUUID == channelUUID {
                return true
            }
        case .idle, .refreshing, .refreshed:
            break
        }
        return transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-requested") != nil
            || transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") != nil
    }

    func reserveTransmitAudioCaptureStart(
        channelUUID: UUID,
        contactID: UUID,
        channelID: String,
        intent: TransmitAudioCaptureStartIntent,
        trigger: String,
        shouldContinue: () -> Bool
    ) async -> TransmitAudioCaptureStartReservation {
        var loggedWait = false
        while true {
            switch transmitRuntime.beginAudioCaptureStartIfNeeded(
                channelUUID: channelUUID,
                intent: intent
            ) {
            case .begin:
                return .reserved
            case .alreadyCompleted:
                return .alreadyCompleted
            case .waitForInFlight:
                guard shouldContinue() else { return .cancelled }
                if !loggedWait {
                    loggedWait = true
                    diagnostics.record(
                        .media,
                        message: "Waiting for in-flight transmit audio capture start",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "channelUUID": channelUUID.uuidString,
                            "intent": String(describing: intent),
                            "trigger": trigger,
                        ]
                    )
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func noteTransmitAudioCaptureStartCompleted(
        channelUUID: UUID,
        intent: TransmitAudioCaptureStartIntent
    ) {
        transmitRuntime.noteAudioCaptureStartCompleted(
            channelUUID: channelUUID,
            intent: intent
        )
    }

    func clearTransmitAudioCaptureStartIfInFlight(
        channelUUID: UUID,
        intent: TransmitAudioCaptureStartIntent
    ) {
        transmitRuntime.clearAudioCaptureStartIfInFlight(
            channelUUID: channelUUID,
            intent: intent
        )
    }

    func startTransmitAudioCaptureWithTransientRetry(
        channelUUID: UUID,
        target: TransmitTarget,
        trigger: String,
        retryStagePrefix: String,
        metadata extraMetadata: [String: String] = [:]
    ) async throws -> Bool {
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "\(retryStagePrefix)-start"
        ) else {
            return false
        }
        do {
            try await startCurrentMediaSessionSendingAudio(
                contactID: target.contactID,
                channelID: target.channelID,
                channelUUID: channelUUID,
                trigger: trigger,
                metadata: extraMetadata
            )
            return true
        } catch {
            guard currentApplicationState() == .active,
                  ensurePTTAudioSessionIsOwnedByLocalTransmit(
                      channelUUID: channelUUID,
                      target: target,
                      stage: "\(retryStagePrefix)-retry-evaluation"
                  ),
                  hasActiveTransmitPressIntent(),
                  shouldContinueSystemTransmitActivation(
                      channelUUID: channelUUID,
                      target: target,
                      stage: "\(retryStagePrefix)-retry-evaluation",
                      recordCompletedSideEffectInvariant: false
                  ) else {
                throw error
            }

            var metadata = extraMetadata
            metadata["contactId"] = target.contactID.uuidString
            metadata["channelId"] = target.channelID
            metadata["channelUUID"] = channelUUID.uuidString
            metadata["trigger"] = trigger
            metadata["error"] = error.localizedDescription
            diagnostics.record(
                .media,
                level: .notice,
                message: "Retrying transmit audio capture after transient start failure",
                metadata: metadata
            )
            recordTransmitStartupTiming(
                stage: "\(retryStagePrefix)-retry-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: extraMetadata
            )

            await mediaServices.session()?.abortSendingAudio()
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
                channelUUID: channelUUID,
                target: target,
                stage: "\(retryStagePrefix)-retry-start"
            ),
            shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "\(retryStagePrefix)-retry-start",
                recordCompletedSideEffectInvariant: false
            ) else {
                return false
            }

            do {
                try await startCurrentMediaSessionSendingAudio(
                    contactID: target.contactID,
                    channelID: target.channelID,
                    channelUUID: channelUUID,
                    trigger: trigger,
                    metadata: extraMetadata
                )
            } catch {
                var failureMetadata = metadata
                failureMetadata["retryError"] = error.localizedDescription
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Transmit audio capture retry failed",
                    metadata: failureMetadata
                )
                throw error
            }

            recordTransmitStartupTiming(
                stage: "\(retryStagePrefix)-retry-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: extraMetadata
            )
            return true
        }
    }

    func startOrRefreshTransmitAudioCaptureForSystemActivation(
        channelUUID: UUID,
        target: TransmitTarget,
        trigger: String,
        refreshMessage: String,
        duplicateMessage: String,
        metadata extraMetadata: [String: String] = [:]
    ) async throws -> Bool {
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "audio-capture-entry"
        ) else {
            return false
        }
        let shouldRefreshAfterSystemActivation =
            hasPreActivationTransmitAudioCaptureEvidence(channelUUID: channelUUID)
        let intent: TransmitAudioCaptureStartIntent = shouldRefreshAfterSystemActivation
            ? .systemActivationRefresh
            : .initial
        let reservation = await reserveTransmitAudioCaptureStart(
            channelUUID: channelUUID,
            contactID: target.contactID,
            channelID: target.channelID,
            intent: intent,
            trigger: trigger,
            shouldContinue: {
                shouldContinueSystemTransmitActivation(
                    channelUUID: channelUUID,
                    target: target,
                    stage: "audio-capture-reservation"
                )
            }
        )
        switch reservation {
        case .reserved:
            break
        case .cancelled:
            return false
        case .alreadyCompleted:
            var metadata = extraMetadata
            metadata["contactId"] = target.contactID.uuidString
            metadata["channelId"] = target.channelID
            metadata["channelUUID"] = channelUUID.uuidString
            diagnostics.record(
                .media,
                message: duplicateMessage,
                metadata: metadata
            )
            recordTransmitStartupTiming(
                stage: "audio-capture-already-started",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: extraMetadata
            )
            return true
        }

        if intent == .systemActivationRefresh {
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "audio-capture-refresh-after-system-activation-requested"
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(
                    channelUUID: channelUUID,
                    intent: .systemActivationRefresh
                )
                return false
            }
            var metadata = extraMetadata
            metadata["contactId"] = target.contactID.uuidString
            metadata["channelId"] = target.channelID
            metadata["channelUUID"] = channelUUID.uuidString
            metadata["trigger"] = trigger
            diagnostics.record(.media, message: refreshMessage, metadata: metadata)
            recordTransmitStartupTiming(
                stage: "audio-capture-refresh-after-system-activation-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: extraMetadata
            )
            do {
                guard try await startTransmitAudioCaptureWithTransientRetry(
                    channelUUID: channelUUID,
                    target: target,
                    trigger: trigger,
                    retryStagePrefix: "audio-capture-refresh-after-system-activation",
                    metadata: extraMetadata
                ) else {
                    clearTransmitAudioCaptureStartIfInFlight(
                        channelUUID: channelUUID,
                        intent: .systemActivationRefresh
                    )
                    return false
                }
            } catch {
                clearTransmitAudioCaptureStartIfInFlight(
                    channelUUID: channelUUID,
                    intent: .systemActivationRefresh
                )
                throw error
            }
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "audio-capture-refresh-after-system-activation-start-returned",
                recordCompletedSideEffectInvariant: false
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(
                    channelUUID: channelUUID,
                    intent: .systemActivationRefresh
                )
                await mediaServices.session()?.abortSendingAudio()
                return false
            }
            noteTransmitAudioCaptureStartCompleted(
                channelUUID: channelUUID,
                intent: .systemActivationRefresh
            )
            recordTransmitStartupTiming(
                stage: "audio-capture-refreshed-after-system-activation",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: extraMetadata
            )
            return true
        }

        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "audio-capture-start-requested"
        ) else {
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            return false
        }
        recordTransmitStartupTiming(
            stage: "audio-capture-start-requested",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID,
            metadata: extraMetadata
        )
        do {
            guard try await startTransmitAudioCaptureWithTransientRetry(
                channelUUID: channelUUID,
                target: target,
                trigger: trigger,
                retryStagePrefix: "audio-capture-start",
                metadata: extraMetadata
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
                return false
            }
        } catch {
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            throw error
        }
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "audio-capture-start-completed",
            recordCompletedSideEffectInvariant: false
        ) else {
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            await mediaServices.session()?.abortSendingAudio()
            return false
        }
        noteTransmitAudioCaptureStartCompleted(channelUUID: channelUUID, intent: .initial)
        recordTransmitStartupTiming(
            stage: "audio-capture-start-completed",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID,
            metadata: extraMetadata
        )
        return true
    }

    func shouldContinuePrewarmedDirectSystemTransmitBridge(
        request: TransmitRequestContext,
        target: TransmitTarget,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = request.channelUUID.flatMap { activeTransmitTarget(for: $0) }
        let requestStillCurrent =
            transmitCoordinator.state.pendingRequest == request
            || activeTarget == target
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if pttCoordinator.state.systemChannelUUID != request.channelUUID {
            reason = "system-channel-mismatch"
        } else if !pttCoordinator.state.isTransmitting {
            reason = "system-not-transmitting"
        } else if !requestStillCurrent {
            reason = "request-not-current"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale prewarmed Direct QUIC bridge continuation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "targetDeviceId": target.deviceID,
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "requestStillCurrent": String(requestStillCurrent),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: request.channelUUID,
                metadata: [
                    "requestKind": "prewarmed-direct-bridge",
                    "targetDeviceId": target.deviceID,
                    "requestStillCurrent": String(requestStillCurrent),
                ]
            )
        }
        return false
    }

    private func pttAudioTransmitID(for target: TransmitTarget) -> String {
        target.transmitID ?? "local-\(target.channelID)"
    }

    @discardableResult
    func armPTTAudioSessionActivation(
        owner: PTTAudioSessionOwner,
        source: String
    ) -> PTTAudioSessionOwner {
        let owner = pttAudioSessionRuntime.expectActivation(owner: owner)
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session activation armed",
            metadata: [
                "source": source,
                "pttAudioOwner": owner.diagnosticsValue,
                "pttAudioOwnerChannelUUID": owner.channelUUID?.uuidString ?? "none",
                "pttAudioOwnerContactId": owner.contactID?.uuidString ?? "none",
                "pttAudioOwnerChannelId": owner.channelID ?? "none",
            ]
        )
        return owner
    }

    @discardableResult
    func armPTTLocalTransmitAudioActivation(
        request: TransmitRequestContext,
        channelUUID: UUID,
        source: String
    ) -> PTTAudioSessionOwner {
        armPTTAudioSessionActivation(
            owner: .pendingLocalTransmit(
                channelUUID: channelUUID,
                contactID: request.contactID,
                channelID: request.backendChannelID
            ),
            source: source
        )
    }

    @discardableResult
    func armPTTLocalTransmitAudioActivation(
        channelUUID: UUID,
        target: TransmitTarget,
        source: String
    ) -> PTTAudioSessionOwner {
        armPTTAudioSessionActivation(
            owner: .localTransmit(
                channelUUID: channelUUID,
                contactID: target.contactID,
                channelID: target.channelID,
                transmitID: pttAudioTransmitID(for: target)
            ),
            source: source
        )
    }

    func clearPendingLocalPTTAudioActivation(
        channelUUID: UUID?,
        source: String
    ) {
        guard let clearedOwner = pttAudioSessionRuntime.clearPendingActivationOwner(
            channelUUID: channelUUID,
            localTransmitOnly: true
        ) else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Cleared pending local PTT audio session activation",
            metadata: [
                "source": source,
                "pttAudioOwner": clearedOwner.diagnosticsValue,
                "pttAudioOwnerChannelUUID": clearedOwner.channelUUID?.uuidString ?? "none",
                "pttAudioOwnerContactId": clearedOwner.contactID?.uuidString ?? "none",
                "pttAudioOwnerChannelId": clearedOwner.channelID ?? "none",
            ]
        )
    }

    func notePTTAudioSessionActivatedForCurrentContext(source: String) -> PTTAudioSessionEpoch {
        let expectedOwner = pttAudioSessionRuntime.pendingActivationOwner
        let epoch = pttAudioSessionRuntime.activateExpected(
            fallbackOwner: pttAudioSessionOwnerForCurrentContext()
        )
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session epoch activated",
            metadata: epoch.diagnosticsMetadata.merging(
                [
                    "source": source,
                    "pttAudioExpectedOwner": expectedOwner?.diagnosticsValue ?? "none",
                    "pttAudioUsedFallbackOwner": String(expectedOwner == nil),
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        return epoch
    }

    private func pttAudioSessionOwnerForCurrentContext() -> PTTAudioSessionOwner {
        let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID
        if let wake = pttWakeRuntime.pendingIncomingPush {
            return .wakeReceive(
                channelUUID: wake.channelUUID,
                contactID: wake.contactID,
                channelID: wake.payload.channelId
            )
        }
        if let channelUUID = activeSystemChannelUUID {
            if let target = activeTransmitTarget(for: channelUUID) {
                return .localTransmit(
                    channelUUID: channelUUID,
                    contactID: target.contactID,
                    channelID: target.channelID,
                    transmitID: pttAudioTransmitID(for: target)
                )
            }
            if let pendingRequest = transmitCoordinator.state.pendingRequest,
               pendingRequest.channelUUID == channelUUID {
                return .pendingLocalTransmit(
                    channelUUID: channelUUID,
                    contactID: pendingRequest.contactID,
                    channelID: pendingRequest.backendChannelID
                )
            }
            let contactID = contactId(for: channelUUID)
            let channelID = contactID.flatMap { contactID in
                contacts.first(where: { $0.id == contactID })?.backendChannelId
                    ?? channelStateByContactID[contactID]?.channelId
            }
            return .remoteReceive(
                channelUUID: channelUUID,
                contactID: contactID,
                channelID: channelID
            )
        }
        return .unattributed(channelUUID: activeSystemChannelUUID)
    }

    private func activePTTAudioSessionOwnerDescription() -> String {
        if let activeOwner = pttAudioSessionRuntime.activeEpoch?.owner {
            return activeOwner.diagnosticsValue
        }
        if let pendingOwner = pttAudioSessionRuntime.pendingActivationOwner {
            return "pending:\(pendingOwner.diagnosticsValue)"
        }
        return isPTTAudioSessionActive ? "active-without-epoch" : "inactive"
    }

    @discardableResult
    func ensurePTTAudioSessionIsOwnedByLocalTransmit(
        channelUUID: UUID,
        target: TransmitTarget,
        stage: String
    ) -> Bool {
        let transmitID = pttAudioTransmitID(for: target)
        if pttAudioSessionRuntime.hasActiveLocalTransmit(
            channelUUID: channelUUID,
            contactID: target.contactID,
            channelID: target.channelID,
            transmitID: transmitID
        ) {
            return true
        }
        if let epoch = pttAudioSessionRuntime.bindPendingLocalTransmit(
            channelUUID: channelUUID,
            contactID: target.contactID,
            channelID: target.channelID,
            transmitID: transmitID
        ) {
            diagnostics.record(
                .pushToTalk,
                message: "Bound pending PTT audio session epoch to local transmit",
                metadata: epoch.diagnosticsMetadata.merging(
                    ["stage": stage],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return true
        }
        if currentApplicationState() == .active,
           isPTTAudioSessionActive,
           pttCoordinator.state.systemChannelUUID == channelUUID,
           pttCoordinator.state.isTransmitting,
           hasActiveTransmitPressIntent(),
           case .remoteReceive = pttAudioSessionRuntime.activeEpoch?.owner {
            diagnostics.record(
                .pushToTalk,
                message: "Waiting for fresh local PTT audio activation after remote receive handoff",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "channelUUID": channelUUID.uuidString,
                    "transmitId": transmitID,
                    "stage": stage,
                    "pttAudioOwner": activePTTAudioSessionOwnerDescription(),
                ]
            )
        }
        diagnostics.record(
            .media,
            message: "Deferring system transmit activation until local transmit PTT audio epoch",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "channelUUID": channelUUID.uuidString,
                "transmitId": transmitID,
                "stage": stage,
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                "pttAudioOwner": activePTTAudioSessionOwnerDescription(),
            ]
        )
        return false
    }

    func hasPTTAudioSessionForPendingLocalTransmit(
        request: TransmitRequestContext,
        channelUUID: UUID,
        stage: String
    ) -> Bool {
        if pttAudioSessionRuntime.hasActivePendingLocalTransmit(
            channelUUID: channelUUID,
            contactID: request.contactID,
            channelID: request.backendChannelID
        ) {
            return true
        }
        if let target = activeTransmitTarget(for: channelUUID),
           target.contactID == request.contactID,
           target.channelID == request.backendChannelID {
            return ensurePTTAudioSessionIsOwnedByLocalTransmit(
                channelUUID: channelUUID,
                target: target,
                stage: stage
            )
        }
        diagnostics.record(
            .media,
            message: "Deferring pending transmit audio capture until local transmit PTT audio epoch",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": channelUUID.uuidString,
                "stage": stage,
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                "pttAudioOwner": activePTTAudioSessionOwnerDescription(),
            ]
        )
        return false
    }

    func completeSystemTransmitActivation(channelUUID: UUID) async {
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "activation-start"
        ) else {
            return
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: target,
            stage: "activation-start"
        ) else {
            return
        }
        guard transmitRuntime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID) else {
            if hasPreActivationTransmitAudioCaptureEvidence(channelUUID: channelUUID) {
                do {
                    guard try await startOrRefreshTransmitAudioCaptureForSystemActivation(
                        channelUUID: channelUUID,
                        target: target,
                        trigger: "duplicate-system-activation",
                        refreshMessage: "Refreshing prewarmed audio capture after duplicate system audio activation",
                        duplicateMessage: "Skipping duplicate system audio capture refresh because capture was already refreshed"
                    ) else {
                        return
                    }
                } catch {
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Duplicate system transmit activation capture refresh failed",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                            "error": error.localizedDescription,
                        ]
                    )
                    await performStopTransmit(target)
                }
                return
            }
            diagnostics.record(
                .media,
                message: "Skipped duplicate system transmit activation",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                ]
            )
            return
        }

        var activationCompleted = false
        defer {
            if !activationCompleted {
                transmitRuntime.clearSystemTransmitActivation(channelUUID: channelUUID)
            }
        }

        startRenewingTransmit(target)
        recordTransmitStartupTiming(
            stage: "system-activation-started",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID
        )

        do {
            let backend = backendServices
            if let backend, backend.supportsWebSocket {
                refreshWebSocketForSystemTransmitActivationIfNeeded(
                    backend,
                    contactID: target.contactID,
                    channelID: target.channelID
                )
                let signalReadinessStage = backend.isWebSocketConnected
                    ? "websocket-ready-for-system-activation-signal"
                    : "websocket-unavailable-for-system-activation-signal"
                recordTransmitStartupTiming(
                    stage: signalReadinessStage,
                    contactID: target.contactID,
                    channelUUID: channelUUID,
                    channelID: target.channelID,
                    subsystem: .websocket
                )
            }
            configureOutgoingAudioRoute(target: target)
            recordTransmitStartupTiming(
                stage: "media-session-start-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            await ensureMediaSession(
                for: target.contactID,
                activationMode: .systemActivated,
                startupMode: .interactive
            )
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "media-session-start-completed"
            ) else {
                return
            }
            recordTransmitStartupTiming(
                stage: "media-session-start-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            configureOutgoingAudioRoute(target: target)
            guard try await startOrRefreshTransmitAudioCaptureForSystemActivation(
                channelUUID: channelUUID,
                target: target,
                trigger: "system-activation",
                refreshMessage: "Refreshing prewarmed audio capture after system audio activation",
                duplicateMessage: "Skipping duplicate system audio capture start because prewarmed bridge is already sending"
            ) else {
                return
            }
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "before-transmit-start-signal",
                recordCompletedSideEffectInvariant: false
            ) else {
                return
            }
            if let backend, backend.supportsWebSocket {
                if backend.isWebSocketConnected {
                    do {
                        try await backend.sendSignal(
                            TurboSignalEnvelope(
                                type: .transmitStart,
                                channelId: target.channelID,
                                fromUserId: backend.currentUserID ?? "",
                                fromDeviceId: backend.deviceID,
                                toUserId: target.userID,
                                toDeviceId: target.deviceID,
                                payload: "ptt-begin"
                            )
                        )
                        guard shouldContinueSystemTransmitActivation(
                            channelUUID: channelUUID,
                            target: target,
                            stage: "transmit-start-signal-sent",
                            recordCompletedSideEffectInvariant: false
                        ) else {
                            return
                        }
                        recordTransmitStartupTiming(
                            stage: "transmit-start-signal-sent",
                            contactID: target.contactID,
                            channelUUID: channelUUID,
                            channelID: target.channelID
                        )
                    } catch {
                        diagnostics.record(
                            .media,
                            level: .error,
                            message: "Transmit start signal send failed after audio capture started",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "channelUUID": channelUUID.uuidString,
                                "error": error.localizedDescription,
                            ]
                        )
                        recordTransmitStartupTiming(
                            stage: "transmit-start-signal-send-failed-after-capture",
                            contactID: target.contactID,
                            channelUUID: channelUUID,
                            channelID: target.channelID,
                            subsystem: .websocket,
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                } else {
                    diagnostics.record(
                        .websocket,
                        message: "Continuing system transmit activation without WebSocket start signal",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                            "applicationState": String(describing: currentApplicationState()),
                        ]
                    )
                    recordTransmitStartupTiming(
                        stage: "transmit-start-signal-skipped-websocket-unavailable",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID,
                        subsystem: .websocket
                    )
                }
            } else {
                diagnostics.record(
                    .websocket,
                    message: "Continuing system transmit activation without WebSocket support",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "channelUUID": channelUUID.uuidString,
                    ]
                )
            }
            transmitRuntime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
            activationCompleted = true
            recordTransmitStartupTiming(
                stage: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            recordTransmitStartupTimingSummary(
                reason: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            await refreshChannelState(for: target.contactID)
        } catch {
            let message = error.localizedDescription
            let contactHandle = contacts.first(where: { $0.id == target.contactID })?.handle ?? "unknown"
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit activation failed",
                metadata: ["contact": contactHandle, "error": message]
            )
            recordTransmitStartupTimingSummary(
                reason: "activation-failed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: ["error": message]
            )
            await performStopTransmit(target)
        }
    }

    func startPendingSystemTransmitAudioCaptureIfPossible(
        channelUUID: UUID,
        trigger: String
    ) async {
        guard !usesLocalHTTPBackend else { return }
        guard let request = transmitCoordinator.state.pendingRequest else { return }
        guard request.channelUUID == channelUUID else { return }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return }
        guard shouldContinuePendingSystemTransmitAudioCapture(
            request: request,
            stage: "start"
        ) else {
            return
        }
        guard hasPTTAudioSessionForPendingLocalTransmit(
            request: request,
            channelUUID: channelUUID,
            stage: "pending-capture-start"
        ) else {
            return
        }
        guard mediaSessionContactID == nil || mediaSessionContactID == request.contactID else { return }
        guard let pendingAudioTarget = pendingSystemTransmitOutgoingAudioTarget(for: request) else {
            diagnostics.record(
                .media,
                message: "Deferring early transmit audio capture until backend lease is granted",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                ]
            )
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-deferred-until-backend-lease",
                metadata: ["trigger": trigger]
            )
            return
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: pendingAudioTarget,
            stage: "pending-capture-target-ready"
        ) else {
            return
        }

        _ = configureProvisionalOutgoingAudioRouteIfPossible(
            for: request,
            reason: "early-system-audio-capture-\(trigger)"
        )

        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-media-session-start-requested",
            metadata: ["trigger": trigger]
        )
        await ensureMediaSession(
            for: request.contactID,
            activationMode: .systemActivated,
            startupMode: .interactive
        )
        guard shouldContinuePendingSystemTransmitAudioCapture(
            request: request,
            stage: "media-session-start-completed"
        ) else {
            return
        }
        guard ensurePTTAudioSessionIsOwnedByLocalTransmit(
            channelUUID: channelUUID,
            target: pendingAudioTarget,
            stage: "pending-capture-media-session-start-completed"
        ) else {
            return
        }
        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-media-session-start-completed",
            metadata: ["trigger": trigger]
        )
        guard await waitForPendingSystemTransmitOutgoingAudioRouteIfNeeded(
            request: request,
            channelUUID: channelUUID,
            trigger: trigger
        ) else {
            diagnostics.record(
                .media,
                message: "Deferred early transmit audio capture until outgoing audio transport is configured",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                ]
            )
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-deferred-until-outgoing-transport",
                metadata: ["trigger": trigger]
            )
            return
        }
        do {
            let shouldRefreshAfterSystemActivation =
                trigger == "audio-session-activated"
                && hasPreActivationTransmitAudioCaptureEvidence(channelUUID: channelUUID)
            let intent: TransmitAudioCaptureStartIntent = shouldRefreshAfterSystemActivation
                ? .systemActivationRefresh
                : .initial
            let reservation = await reserveTransmitAudioCaptureStart(
                channelUUID: channelUUID,
                contactID: request.contactID,
                channelID: request.backendChannelID,
                intent: intent,
                trigger: trigger,
                shouldContinue: {
                    shouldContinuePendingSystemTransmitAudioCapture(
                        request: request,
                        stage: "audio-capture-reservation"
                    )
                }
            )
            switch reservation {
            case .reserved:
                break
            case .cancelled:
                return
            case .alreadyCompleted:
                diagnostics.record(
                    .media,
                    message: "Skipping duplicate pending system audio capture start because audio capture is already active",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "channelUUID": channelUUID.uuidString,
                        "trigger": trigger,
                    ]
                )
                return
            }

            if intent == .systemActivationRefresh {
                guard shouldContinuePendingSystemTransmitAudioCapture(
                    request: request,
                    stage: "audio-capture-refresh-after-system-activation-requested"
                ) else {
                    clearTransmitAudioCaptureStartIfInFlight(
                        channelUUID: channelUUID,
                        intent: .systemActivationRefresh
                    )
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Refreshing prewarmed audio capture after system audio activation",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "channelUUID": channelUUID.uuidString,
                        "trigger": trigger,
                    ]
                )
                recordFirstTransmitStartupTimingStageIfAbsent(
                    "audio-capture-refresh-after-system-activation-requested",
                    metadata: ["trigger": trigger]
                )
                guard try await startTransmitAudioCaptureWithTransientRetry(
                    channelUUID: channelUUID,
                    target: pendingAudioTarget,
                    trigger: trigger,
                    retryStagePrefix: "early-audio-capture-refresh-after-system-activation"
                ) else {
                    clearTransmitAudioCaptureStartIfInFlight(
                        channelUUID: channelUUID,
                        intent: .systemActivationRefresh
                    )
                    return
                }
                guard shouldContinuePendingSystemTransmitAudioCapture(
                    request: request,
                    stage: "audio-capture-refresh-after-system-activation-start-returned",
                    recordCompletedSideEffectInvariant: false
                ) else {
                    clearTransmitAudioCaptureStartIfInFlight(
                        channelUUID: channelUUID,
                        intent: .systemActivationRefresh
                    )
                    await mediaServices.session()?.abortSendingAudio()
                    return
                }
                noteTransmitAudioCaptureStartCompleted(
                    channelUUID: channelUUID,
                    intent: .systemActivationRefresh
                )
                recordFirstTransmitStartupTimingStageIfAbsent(
                    "audio-capture-refreshed-after-system-activation",
                    metadata: ["trigger": trigger]
                )
                return
            }

            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-requested",
                metadata: ["trigger": trigger]
            )
            guard try await startTransmitAudioCaptureWithTransientRetry(
                channelUUID: channelUUID,
                target: pendingAudioTarget,
                trigger: trigger,
                retryStagePrefix: "early-audio-capture-start"
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
                return
            }
            guard shouldContinuePendingSystemTransmitAudioCapture(
                request: request,
                stage: "audio-capture-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
                await mediaServices.session()?.abortSendingAudio()
                return
            }
            noteTransmitAudioCaptureStartCompleted(channelUUID: channelUUID, intent: .initial)
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-completed",
                metadata: ["trigger": trigger]
            )
        } catch {
            clearTransmitAudioCaptureStartIfInFlight(channelUUID: channelUUID, intent: .initial)
            clearTransmitAudioCaptureStartIfInFlight(
                channelUUID: channelUUID,
                intent: .systemActivationRefresh
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Early transmit audio capture failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func waitForPendingSystemTransmitOutgoingAudioRouteIfNeeded(
        request: TransmitRequestContext,
        channelUUID: UUID,
        trigger: String,
        timeoutNanoseconds: UInt64 = 200_000_000,
        pollNanoseconds: UInt64 = 20_000_000
    ) async -> Bool {
        if mediaServices.sendAudioChunk() != nil {
            return true
        }
        if let activeTarget = pendingSystemTransmitOutgoingAudioTarget(for: request) {
            configureOutgoingAudioRoute(target: activeTarget)
            if mediaServices.sendAudioChunk() != nil {
                diagnostics.record(
                    .media,
                    message: "Configured outgoing audio route from active transmit target during pending system audio capture",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "channelId": request.backendChannelID,
                        "targetDeviceId": activeTarget.deviceID,
                        "trigger": trigger,
                    ]
                )
                return true
            }
        }

        var waitedNanoseconds: UInt64 = 0
        while waitedNanoseconds < timeoutNanoseconds {
            guard shouldContinuePendingSystemTransmitAudioCapture(
                request: request,
                stage: "outgoing-transport-wait"
            ) else {
                return false
            }

            let sleepNanoseconds = min(pollNanoseconds, timeoutNanoseconds - waitedNanoseconds)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            waitedNanoseconds += sleepNanoseconds

            if mediaServices.sendAudioChunk() != nil {
                return true
            }
            if let activeTarget = pendingSystemTransmitOutgoingAudioTarget(for: request) {
                configureOutgoingAudioRoute(target: activeTarget)
                if mediaServices.sendAudioChunk() != nil {
                    diagnostics.record(
                        .media,
                        message: "Configured outgoing audio route from active transmit target during pending system audio capture",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelUUID": channelUUID.uuidString,
                            "channelId": request.backendChannelID,
                            "targetDeviceId": activeTarget.deviceID,
                            "trigger": trigger,
                            "waitedMilliseconds": String(waitedNanoseconds / 1_000_000),
                        ]
                    )
                    return true
                }
            }
        }

        return mediaServices.sendAudioChunk() != nil
            || configureProvisionalOutgoingAudioRouteIfPossible(
                for: request,
                reason: "post-media-session-start-\(trigger)"
            )
    }

    func pendingSystemTransmitOutgoingAudioTarget(
        for request: TransmitRequestContext
    ) -> TransmitTarget? {
        guard let activeTarget = transmitCoordinator.state.activeTarget else {
            return nil
        }
        guard activeTarget.contactID == request.contactID else { return nil }
        guard activeTarget.channelID == request.backendChannelID else { return nil }
        return activeTarget
    }

    @discardableResult
    func configureProvisionalOutgoingAudioRouteIfPossible(
        for request: TransmitRequestContext,
        reason: String
    ) -> Bool {
        if configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
            for: request,
            reason: reason
        ) {
            return true
        }

        guard let peerDeviceID = directQuicPeerDeviceID(for: request.contactID),
              !peerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                message: "Skipped provisional outgoing audio route because peer device is unknown",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "reason": reason,
                ]
            )
            return false
        }

        let provisionalTarget = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: peerDeviceID,
            channelID: request.backendChannelID
        )
        configureOutgoingAudioRoute(target: provisionalTarget)
        guard mediaServices.sendAudioChunk() != nil else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to configure provisional outgoing audio route",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
            return false
        }

        diagnostics.record(
            .media,
            message: "Configured provisional outgoing audio route",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
                "transport": configuredOutgoingAudioTransportLabel(for: request.contactID),
            ]
        )
        return true
    }

    @discardableResult
    func configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
        for request: TransmitRequestContext,
        reason: String
    ) -> Bool {
        guard let provisionalTarget = provisionalDirectQuicTransmitTarget(
            for: request,
            reason: reason
        ) else {
            return false
        }

        configureOutgoingAudioRoute(target: provisionalTarget)
        diagnostics.record(
            .media,
            message: "Configured provisional Direct QUIC outgoing audio route",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "peerDeviceId": provisionalTarget.deviceID,
                "reason": reason,
            ]
        )
        return true
    }

    func provisionalDirectQuicTransmitTarget(
        for request: TransmitRequestContext,
        reason: String
    ) -> TransmitTarget? {
        guard shouldUseDirectQuicTransport(for: request.contactID) else {
            return nil
        }
        let peerDeviceID =
            directQuicAttempt(for: request.contactID)?.peerDeviceID
            ?? directQuicPeerDeviceID(for: request.contactID)
        guard let peerDeviceID, !peerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                message: "Skipped provisional Direct QUIC audio route because peer device is unknown",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "reason": reason,
                ]
            )
            return nil
        }

        return TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: peerDeviceID,
            channelID: request.backendChannelID,
            transmitID: directQuicAttempt(for: request.contactID)?.attemptId
        )
    }

    func handleActivatedAudioSession(_ audioSession: AVAudioSession) async {
        if isPTTAudioSessionActive, pttAudioSessionRuntime.activeEpoch == nil {
            _ = notePTTAudioSessionActivatedForCurrentContext(source: "handle-activated-audio-session")
        }
        applyPreferredAudioOutputRoute(to: audioSession)
        let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID
        let activeTarget = activeSystemChannelUUID.flatMap(activeTransmitTarget(for:))
        let pendingRequest = transmitCoordinator.state.pendingRequest
        let pendingWake = pttWakeRuntime.pendingIncomingPush
        let receiveContactIDForActiveSystemChannel = activeSystemChannelUUID.flatMap(contactId(for:))
        let systemActivationHasAuthoritativeRemoteTransmit =
            activeTarget == nil
            && pendingWake == nil
            && receiveContactIDForActiveSystemChannel.map { contactID in
                peerTransmitBlocksLocalSystemActivation(for: contactID)
            } == true
        if let activeSystemChannelUUID {
            recordTransmitStartupTiming(
                stage: "system-audio-session-activated",
                contactID: activeTarget?.contactID ?? pendingRequest?.contactID ?? contactId(for: activeSystemChannelUUID),
                channelUUID: activeSystemChannelUUID,
                channelID: activeTarget?.channelID ?? pendingRequest?.backendChannelID,
                subsystem: .pushToTalk,
                metadata: [
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                    "targetSource": activeTarget == nil ? "pending-request" : "active-target",
                ]
            )
        }
        if let activeTarget {
            syncEnginePTTAudioActivated(
                contactID: activeTarget.contactID,
                channelID: activeTarget.channelID,
                source: "active-transmit"
            )
        }
        if let activeSystemChannelUUID {
            if activeTarget != nil {
                await completeSystemTransmitActivation(channelUUID: activeSystemChannelUUID)
            } else if systemActivationHasAuthoritativeRemoteTransmit,
                      let pendingRequest,
                      pendingRequest.channelUUID == activeSystemChannelUUID {
                cancelPendingSystemTransmitActivationAfterPeerBecameAuthoritative(
                    request: pendingRequest,
                    stage: "audio-session-activated-receive-authoritative"
                )
            } else {
                await startPendingSystemTransmitAudioCaptureIfPossible(
                    channelUUID: activeSystemChannelUUID,
                    trigger: "audio-session-activated"
                )
            }
        }
        if let activeTarget,
           audioSession.category != .playAndRecord {
            diagnostics.record(
                .media,
                message: "Continuing system transmit activation from initial audio session category",
                metadata: [
                    "contactId": activeTarget.contactID.uuidString,
                    "channelUUID": activeSystemChannelUUID?.uuidString ?? "none",
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
        }
        if let wake = pendingWake {
            let contactID = wake.contactID
            if wake.activationState == .appManagedFallback,
               prefersForegroundAppManagedReceivePlayback(for: contactID),
               mediaSessionContactID == contactID,
               (mediaConnectionState == .connected || mediaConnectionState == .preparing) {
                pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
                await mediaServices.session()?.audioRouteDidChange(allowCaptureRefresh: false)
                recordWakeReceiveTiming(
                    stage: "late-system-audio-activation-preserved-app-managed-playback",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    subsystem: .pushToTalk
                )
                diagnostics.record(
                    .media,
                    message: "Preserved app-managed wake playback after late PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": wake.channelUUID.uuidString,
                    ]
                )
                diagnostics.record(
                    .media,
                    message: "Refreshed app-managed wake playback after late PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": wake.channelUUID.uuidString,
                    ]
                )
                captureDiagnosticsState("ptt-wake:preserved-app-managed-playback")
                schedulePostWakeBackendRefresh(for: contactID)
                return
            }
            pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
            pttWakeRuntime.markAudioSessionActivated(for: wake.channelUUID)
            if let channelID =
                wake.payload.channelId
                ?? contacts.first(where: { $0.id == contactID })?.backendChannelId {
                syncEnginePTTAudioActivated(
                    contactID: contactID,
                    channelID: channelID,
                    source: "wake-receive"
                )
            }
            recordWakeReceiveTiming(
                stage: "system-audio-activation-observed",
                contactID: contactID,
                channelUUID: wake.channelUUID,
                channelID: wake.payload.channelId,
                subsystem: .pushToTalk
            )
            diagnostics.record(
                .pushToTalk,
                message: "Handling PTT wake audio activation",
                metadata: [
                    "channelUUID": wake.channelUUID.uuidString,
                    "contactID": wake.contactID.uuidString,
                    "event": wake.payload.event.rawValue,
                ]
            )
            if let backend = backendServices,
               let channelID =
                wake.payload.channelId
                ?? contacts.first(where: { $0.id == contactID })?.backendChannelId {
                // The pre-activation reconnect may still be a stale `connecting`
                // socket started before the system granted background audio
                // execution. Once the system PTT session is active, force a
                // fresh reconnect so deferred receiver-ready publications can
                // actually drain during the wake window.
                refreshWebSocketForWakeReceiveActivationIfNeeded(
                    backend,
                    contactID: contactID,
                    channelID: channelID
                )
            } else {
                backendServices?.resumeWebSocket()
            }
            diagnostics.record(
                .media,
                message: "Recreating media session after PTT audio activation",
                metadata: ["contactId": contactID.uuidString]
            )
            closeMediaSession(
                deactivateAudioSession: false,
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
            await ensureMediaSession(
                for: contactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
            let bufferedAudioChunks = pttWakeRuntime.takeBufferedWakeAudioChunks(for: contactID)
            if !bufferedAudioChunks.isEmpty {
                markRemoteAudioActivity(for: contactID, source: .audioChunk)
                recordWakeReceiveTiming(
                    stage: "buffered-audio-flush-started",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
                diagnostics.record(
                    .media,
                    message: "Flushing buffered wake audio after PTT activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "bufferedChunkCount": String(bufferedAudioChunks.count)
                    ]
                )
                await playBufferedWakeAudioChunks(
                    bufferedAudioChunks,
                    contactID: contactID,
                    reason: "system-audio-activated",
                    flushSource: "system-activated-buffered-flush"
                )
                recordWakeReceiveTiming(
                    stage: "buffered-audio-flush-completed",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
                recordWakeReceiveTimingSummary(
                    reason: "system-activated-buffered-flush",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
            } else {
                diagnostics.record(
                    .media,
                    message: "No buffered wake audio to flush after PTT activation",
                    metadata: ["contactId": contactID.uuidString]
                )
                recordWakeReceiveTimingSummary(
                    reason: "system-activated-no-buffered-audio",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId
                )
            }
            captureDiagnosticsState("ptt-wake:audio-activated")
            schedulePostWakeBackendRefresh(for: contactID)
        }

        if activeTarget == nil,
           pendingWake == nil,
           let activeSystemChannelUUID,
           let receiveContactID = receiveContactIDForActiveSystemChannel,
           remoteTransmittingContactIDs.contains(receiveContactID),
           shouldPreserveForegroundAppManagedReceivePlaybackAfterPTTActivation(
            for: receiveContactID
           ) {
            if let channelID =
                contacts.first(where: { $0.id == receiveContactID })?.backendChannelId
                ?? channelStateByContactID[receiveContactID]?.channelId {
                syncEnginePTTAudioActivated(
                    contactID: receiveContactID,
                    channelID: channelID,
                    source: "foreground-app-managed-receive"
                )
            }
            mediaRuntime.replaceForegroundSystemReceivePlaybackFallbackTask(
                for: receiveContactID,
                with: nil
            )
            await mediaServices.session()?.audioRouteDidChange(allowCaptureRefresh: false)
            recordDeferredLiveReceiveAudioRouteRefresh(
                source: "foreground-app-managed-ptt-audio-activation",
                contactID: receiveContactID,
                channelUUID: activeSystemChannelUUID
            )
            diagnostics.record(
                .media,
                message: "Preserved foreground app-managed receive playback after PTT audio activation",
                metadata: [
                    "contactId": receiveContactID.uuidString,
                    "channelUUID": activeSystemChannelUUID.uuidString,
                    "transportPath": mediaTransportPathState.rawValue,
                ]
            )
            captureDiagnosticsState("foreground-receive:app-managed-preserved-after-ptt-activation")
            return
        }

        if activeTarget == nil,
           pendingWake == nil,
           let activeSystemChannelUUID,
           let receiveContactID = receiveContactIDForActiveSystemChannel,
           remoteTransmittingContactIDs.contains(receiveContactID),
            shouldUseSystemActivatedReceivePlayback(for: receiveContactID) {
            if mediaSessionContactID == receiveContactID,
               mediaConnectionState == .connected || mediaConnectionState == .preparing {
                recordDeferredLiveReceiveAudioRouteRefresh(
                    source: "ptt-audio-activation",
                    contactID: receiveContactID,
                    channelUUID: activeSystemChannelUUID
                )
            }
            if let channelID = contacts.first(where: { $0.id == receiveContactID })?.backendChannelId {
                syncEnginePTTAudioActivated(
                    contactID: receiveContactID,
                    channelID: channelID,
                    source: "system-receive"
                )
            }
            diagnostics.record(
                .media,
                message: "Preparing receive media session after PTT audio activation",
                metadata: [
                    "contactId": receiveContactID.uuidString,
                    "channelUUID": activeSystemChannelUUID.uuidString
                ]
            )
            await ensureMediaSession(
                for: receiveContactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
            mediaRuntime.deactivateForegroundSystemReceivePlaybackFallback(for: receiveContactID)
            let bufferedAudioChunks = mediaRuntime.takeForegroundSystemReceiveAudioChunks(
                for: receiveContactID
            )
            mediaRuntime.replaceForegroundSystemReceivePlaybackFallbackTask(
                for: receiveContactID,
                with: nil
            )
            if !bufferedAudioChunks.isEmpty {
                diagnostics.record(
                    .media,
                    message: "Flushing buffered foreground receive audio after PTT activation",
                    metadata: [
                        "contactId": receiveContactID.uuidString,
                        "channelUUID": activeSystemChannelUUID.uuidString,
                        "bufferedChunkCount": String(bufferedAudioChunks.count),
                    ]
                )
                markRemoteAudioActivity(for: receiveContactID, source: .audioChunk)
                await playBufferedForegroundSystemReceiveAudioChunks(
                    bufferedAudioChunks,
                    contactID: receiveContactID
                )
            } else {
                diagnostics.record(
                    .media,
                    message: "No buffered foreground receive audio to flush after PTT activation",
                    metadata: [
                        "contactId": receiveContactID.uuidString,
                        "channelUUID": activeSystemChannelUUID.uuidString,
                    ]
                )
            }
        }

        if let activeSystemChannelUUID,
           let activeTarget {
            configureOutgoingAudioRoute(target: activeTarget)
            await completeSystemTransmitActivation(channelUUID: activeSystemChannelUUID)
        }
    }

    func shouldDeferAudioRouteRefreshDuringLiveReceive(contactID: UUID? = nil) -> Bool {
        if let contactID {
            return remoteTransmittingContactIDs.contains(contactID)
        }
        return !remoteTransmittingContactIDs.isEmpty
    }

    func recordDeferredLiveReceiveAudioRouteRefresh(
        source: String,
        contactID: UUID?,
        channelUUID: UUID? = nil,
        reason: String? = nil
    ) {
        var metadata: [String: String] = [
            "source": source,
            "liveReceiveContactCount": String(remoteTransmittingContactIDs.count),
        ]
        metadata["contactId"] = contactID?.uuidString ?? "none"
        metadata["channelUUID"] = channelUUID?.uuidString ?? "none"
        if let reason {
            metadata["reason"] = reason
        }
        diagnostics.record(
            .media,
            message: "Deferred audio route refresh during live receive",
            metadata: metadata
        )
    }

}
