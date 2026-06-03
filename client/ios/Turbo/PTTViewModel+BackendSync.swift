//
//  PTTViewModel+BackendSync.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

nonisolated enum IncomingAudioPayloadTransport: Equatable, Hashable, Sendable {
    case relayWebSocket
    case mediaRelayPacket
    case mediaRelayTcp
    case directQuic

    var diagnosticsValue: String {
        switch self {
        case .relayWebSocket:
            return "relay-websocket"
        case .mediaRelayPacket:
            return "media-relay-packet"
        case .mediaRelayTcp:
            return "media-relay-tcp"
        case .directQuic:
            return "direct-quic"
        }
    }

    var isUnreliablePacketMedia: Bool {
        switch self {
        case .directQuic, .mediaRelayPacket:
            return true
        case .relayWebSocket, .mediaRelayTcp:
            return false
        }
    }

    init(mediaRelayMediaMode: TurboMediaRelayMediaMode) {
        switch mediaRelayMediaMode {
        case .quicDatagram:
            self = .mediaRelayPacket
        case .tcpOrdered:
            self = .mediaRelayTcp
        }
    }
}

private enum PendingPlaybackDrainDecision {
    case notPending
    case deferTimeout(elapsedNanoseconds: UInt64)
    case exceeded(elapsedNanoseconds: UInt64)
}

extension PTTViewModel {
    func mergedChannelReadinessPreservingWakeCapableFallback(
        existing: TurboChannelReadinessResponse?,
        fetched: TurboChannelReadinessResponse?,
        peerDeviceConnected: Bool,
        peerMembershipPresent: Bool = true,
        existingDevicePTTSessionWasRoutable: Bool = false,
        suppressWakeCapableAudioReadiness: Bool = false
    ) -> TurboChannelReadinessResponse? {
        guard let fetched else { return existing }
        let effectiveFetched: TurboChannelReadinessResponse = {
            guard suppressWakeCapableAudioReadiness,
                  fetched.remoteAudioReadiness == .wakeCapable else {
                return fetched
            }
            return fetched.settingRemoteAudioReadiness(.waiting)
        }()
        guard let existing else { return effectiveFetched }

        let shouldPreserveExplicitReadySignal =
            peerMembershipPresent
            && peerDeviceConnected
            && existingDevicePTTSessionWasRoutable
            && existing.remoteAudioReadiness == .ready
            && effectiveFetched.remoteAudioReadiness == .wakeCapable
        if shouldPreserveExplicitReadySignal {
            return effectiveFetched.settingRemoteAudioReadiness(.ready)
        }

        let fetchedWakeFallbackDowngrade: Bool = {
            guard case .wakeCapable = effectiveFetched.remoteWakeCapability else { return false }
            guard !effectiveFetched.canTransmit else { return false }
            guard !effectiveFetched.peerHasActiveDevice else { return false }
            switch effectiveFetched.statusView {
            case .waitingForPeer:
                return true
            case .inactive, .waitingForSelf, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let shouldPreserveRoutableReadyProjection =
            peerMembershipPresent
            && existingDevicePTTSessionWasRoutable
            && existing.statusView == .ready
            && existing.selfHasActiveDevice
            && existing.peerHasActiveDevice
            && existing.remoteAudioReadiness == .ready
            && !fetchedWakeFallbackDowngrade
            && !effectiveFetched.canTransmit
            && (
                effectiveFetched.selfHasActiveDevice
                || effectiveFetched.peerHasActiveDevice
            )
            && {
                switch effectiveFetched.statusView {
                case .waitingForSelf, .waitingForPeer:
                    return true
                case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                    return false
                }
            }()
        if shouldPreserveRoutableReadyProjection {
            diagnostics.record(
                .backend,
                message: "Preserved routable ready projection across transient backend readiness downgrade",
                metadata: [
                    "channelId": effectiveFetched.channelId,
                    "existingStatus": existing.statusKind,
                    "fetchedStatus": effectiveFetched.statusKind,
                    "fetchedSelfHasActiveDevice": String(effectiveFetched.selfHasActiveDevice),
                    "fetchedPeerHasActiveDevice": String(effectiveFetched.peerHasActiveDevice),
                    "fetchedPeerDeviceConnected": String(peerDeviceConnected),
                    "fetchedRemoteAudioReadiness": String(describing: effectiveFetched.remoteAudioReadiness),
                    "existingServerTimestamp": existing.serverTimestamp ?? "none",
                    "fetchedServerTimestamp": effectiveFetched.serverTimestamp ?? "none",
                ]
            )
            return effectiveFetched.preservingRoutableReadyProjection(from: existing)
        }

        guard case .wakeCapable = existing.remoteWakeCapability else {
            return effectiveFetched
        }

        let existingWakeFallbackWasAuthoritative: Bool = {
            if existingDevicePTTSessionWasRoutable {
                return true
            }
            switch existing.statusView {
            case .ready, .selfTransmitting, .peerTransmitting:
                return true
            case .inactive, .waitingForSelf, .waitingForPeer, .unknown:
                return false
            }
        }()

        let fetchedLooksLikeTransientBackgroundDrift: Bool = {
            guard !effectiveFetched.canTransmit else { return false }
            switch effectiveFetched.statusView {
            case .waitingForSelf, .waitingForPeer:
                return true
            case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let shouldPreserveWakeCapableFallback =
            peerMembershipPresent
            && (
                !peerDeviceConnected
                || (existingWakeFallbackWasAuthoritative && fetchedLooksLikeTransientBackgroundDrift)
            )
        guard shouldPreserveWakeCapableFallback else { return effectiveFetched }

        var merged = effectiveFetched

        let fetchedWakeCapabilityStillPresent: Bool = {
            if case .wakeCapable = effectiveFetched.remoteWakeCapability {
                return true
            }
            return false
        }()

        if existing.remoteAudioReadiness == .wakeCapable,
           fetchedWakeCapabilityStillPresent,
           !suppressWakeCapableAudioReadiness {
            switch effectiveFetched.remoteAudioReadiness {
            case .waiting, .unknown:
                merged = merged.settingRemoteAudioReadiness(.wakeCapable)
            case .ready, .wakeCapable:
                break
            }
        }

        return merged
    }

    func trackedPresenceFallbackTargets(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) -> [(contactID: UUID, handle: String)] {
        let summaryContactIDs = Set(summaries.keys)
        return contacts.compactMap { contact in
            guard trackedContactIDs.contains(contact.id) else { return nil }
            guard !summaryContactIDs.contains(contact.id) else { return nil }
            let normalizedHandle = Contact.normalizedHandle(contact.handle)
            guard normalizedHandle != currentDevUserHandle else { return nil }
            return (contact.id, normalizedHandle)
        }
    }

    func shouldPreserveLocalChannelReferenceForTrackedFallback(contactID: UUID) -> Bool {
        if activeChannelId == contactID || mediaSessionContactID == contactID {
            return true
        }
        if conversationActionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return true
        }
        return systemSessionMatches(contactID)
    }

    func clearStaleTrackedChannelReferencesMissingFromSummaries(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) {
        let summaryContactIDs = Set(summaries.keys)
        let staleTrackedContacts = contacts.filter { contact in
            trackedContactIDs.contains(contact.id)
                && !summaryContactIDs.contains(contact.id)
                && contact.backendChannelId != nil
                && !shouldPreserveLocalChannelReferenceForTrackedFallback(contactID: contact.id)
        }

        guard !staleTrackedContacts.isEmpty else { return }

        for contact in staleTrackedContacts {
            let staleChannelID = contact.backendChannelId ?? "none"
            updateContact(contact.id) { staleContact in
                staleContact.backendChannelId = nil
                staleContact.channelId = UUID()
            }
            backendSyncCoordinator.send(.channelStateCleared(contactID: contact.id))
            diagnostics.record(
                .channel,
                message: "Cleared stale tracked channel reference missing from summaries",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "channelId": staleChannelID,
                ]
            )
        }
    }

    func refreshTrackedContactPresenceFallback(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) async {
        guard let backend = backendServices else { return }

        for target in trackedPresenceFallbackTargets(excluding: summaries) {
            do {
                let presence = try await backend.lookupPresence(handle: target.handle)
                updateContact(target.contactID) { contact in
                    contact.isOnline = presence.isOnline
                    contact.remoteUserId = presence.userId
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Tracked presence lookup failed",
                    metadata: ["handle": target.handle, "error": error.localizedDescription]
                )
            }
        }
    }

    func shouldTreatIncomingSignalAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        switch receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase {
        case .receivingAudio, .drainingAudio:
            return false
        case .prepared, .awaitingFirstAudioChunk, .none:
            break
        }
        // Once the system-owned PTT audio session is active, later signal-path
        // chunks belong to the current receive flow and must not rearm wake.
        // Foreground receive stays on the existing media path; provisional wake
        // candidates are only for background/inactive receivers that need
        // Apple PTT activation.
        guard !isPTTAudioSessionActive else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldIgnoreForegroundDirectQuicTransmitControlSignal(
        _ envelope: TurboSignalEnvelope,
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard envelope.type == .transmitStart || envelope.type == .transmitStop else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard !isTransmitting, !pttCoordinator.state.isTransmitting else { return false }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        guard !pttWakeRuntime.hasPendingWake(for: contactID) else { return false }

        let activityState = receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]
        switch envelope.type {
        case .transmitStart:
            guard envelope.payload == "ptt-begin" else { return false }
            return activityState?.phase == .receivingAudio
                || activityState?.phase == .drainingAudio
                || activityState?.phase == .prepared
                || (activityState == nil && mediaSessionContactID == contactID && mediaConnectionState == .connected)
        case .transmitStop:
            switch activityState?.phase {
            case .drainingAudio:
                return true
            case .prepared, .awaitingFirstAudioChunk, .receivingAudio, .none:
                return false
            }
        case .offer,
             .answer,
             .iceCandidate,
             .hangup,
             .directQuicUpgradeRequest,
             .selectedFriendPrewarm,
             .conversationParticipantTelemetry,
             .audioPlaybackStarted,
             .audioChunk,
             .receiverReady,
             .receiverNotReady:
            return false
        }
    }

    func shouldBufferDeferredBackgroundAudioAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldUseForegroundAppManagedWakePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> Bool {
        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return false }
        return prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        )
    }

    func startForegroundAppManagedWakePlayback(
        for contactID: UUID,
        channelID: String
    ) {
        pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        recordWakeReceiveTiming(
            stage: "foreground-app-managed-playback-started",
            contactID: contactID,
            channelID: channelID
        )
        diagnostics.record(
            .media,
            message: "Using app-managed wake playback for foreground audio",
            metadata: [
                "channelId": channelID,
                "contactId": contactID.uuidString,
            ]
        )
    }

    func shouldTreatIncomingControlSignalAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard !isPTTAudioSessionActive else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldSetSystemRemoteParticipantFromSignalPath(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
            && !pttCoordinator.state.isTransmitting
    }

    func shouldSuppressForegroundDirectQuicRemoteParticipant(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard directQuicTransmitStartupPolicy == .appleGated else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        return shouldUseDirectQuicTransport(for: contactID)
    }

    func shouldClearSystemRemoteParticipantFromSignalPath(for contactID: UUID) -> Bool {
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return false }
        return !pttCoordinator.state.isTransmitting
    }

    func prefersForegroundAppManagedReceivePlayback(for contactID: UUID) -> Bool {
        prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: currentApplicationState()
        )
    }

    func prefersForegroundAppManagedReceivePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport? = nil
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        let isAppleGatedForegroundLiveAudio =
            directQuicTransmitStartupPolicy == .appleGated
            && (
                incomingAudioTransport == .directQuic
                    || incomingAudioTransport == .mediaRelayPacket
                    || incomingAudioTransport == .mediaRelayTcp
            )
        let isAlreadyAppManagedFallback =
            pttWakeRuntime.incomingWakeActivationState(for: contactID) == .appManagedFallback
        guard isAppleGatedForegroundLiveAudio || isAlreadyAppManagedFallback else {
            return false
        }
        return systemSessionMatches(contactID)
    }

    func shouldUseSystemActivatedReceivePlayback(for contactID: UUID) -> Bool {
        shouldUseSystemActivatedReceivePlayback(
            for: contactID,
            applicationState: currentApplicationState()
        )
    }

    func shouldUseSystemActivatedReceivePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport? = nil
    ) -> Bool {
        guard !prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) else { return false }
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
            && !pttCoordinator.state.isTransmitting
            && isPTTAudioSessionActive
    }

    func shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
        for contactID: UUID,
        channelID: String? = nil,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard !mediaRuntime.hasReadyForegroundSystemReceivePlaybackFallback(
            for: contactID,
            channelID: channelID
        ) else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
            && !pttCoordinator.state.isTransmitting
    }

    @discardableResult
    func bufferForegroundSystemReceiveAudioChunkUntilPTTActivation(
        _ payload: String,
        incomingMediaPayload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        frameDurationNanoseconds: UInt64?,
        ingressSource: String,
        applicationState: UIApplication.State
    ) -> Bool {
        guard shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
            for: contactID,
            channelID: channelID,
            applicationState: applicationState
        ) else { return false }
        let bufferResult = mediaRuntime.bufferForegroundSystemReceiveAudioChunk(
            BufferedForegroundReceiveAudioChunk(
                payload: payload,
                incomingMediaPayload: incomingMediaPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                transport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                frameDurationNanoseconds: frameDurationNanoseconds,
                ingressSource: ingressSource
            ),
            for: contactID
        )
        diagnostics.record(
            .media,
            message: "Buffered foreground receive audio chunk until PTT activation",
            metadata: [
                "channelId": channelID,
                "contactId": contactID.uuidString,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "bufferedChunkCount": String(bufferResult.bufferedChunkCount),
                "droppedStaleBufferedChunkCount": String(bufferResult.droppedChunkCount),
            ]
        )
        scheduleForegroundSystemReceivePlaybackFallback(
            for: contactID,
            channelID: channelID
        )
        return true
    }

    @discardableResult
    func bufferWakeAudioChunkUntilPTTActivation(
        _ payload: String,
        channelID: String,
        contactID: UUID
    ) -> Bool {
        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return false }
        pttWakeRuntime.bufferAudioChunk(payload, for: contactID)
        recordWakeReceiveTiming(
            stage: "first-audio-buffered",
            contactID: contactID,
            channelID: channelID,
            ifAbsent: true
        )
        recordWakeReceiveTiming(
            stage: "latest-audio-buffered",
            contactID: contactID,
            channelID: channelID
        )
        diagnostics.record(
            .media,
            message: "Buffered wake audio chunk until PTT activation",
            metadata: ["channelId": channelID, "contactId": contactID.uuidString]
        )
        return true
    }

    func ensurePendingWakeCandidate(
        for contactID: UUID,
        channelId: String,
        senderUserId: String,
        senderDeviceId: String,
        scheduleFallback: Bool = true
    ) {
        let alreadyPending = pttWakeRuntime.hasPendingWake(for: contactID)
        if alreadyPending {
            if scheduleFallback {
                scheduleWakePlaybackFallback(for: contactID)
            }
            return
        }
        guard let channelUUID = channelUUID(for: contactID) else { return }
        let speakerName =
            contacts.first(where: { $0.id == contactID })?.name
            ?? contacts.first(where: { $0.id == contactID })?.handle
            ?? "Remote"
        pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: channelId,
                    activeSpeaker: speakerName,
                    senderUserId: senderUserId,
                    senderDeviceId: senderDeviceId
                )
            )
        )
        recordWakeReceiveTiming(
            stage: "provisional-wake-candidate-created",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: channelId,
            subsystem: .pushToTalk,
            metadata: [
                "senderDeviceId": senderDeviceId,
                "senderUserId": senderUserId,
            ]
        )
        diagnostics.record(
            .pushToTalk,
            message: "Created provisional wake candidate from signal path",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactID": contactID.uuidString,
                "channelId": channelId,
            ]
        )
        if scheduleFallback {
            scheduleWakePlaybackFallback(for: contactID)
        }
    }

    func clearRemoteAudioActivity(for contactID: UUID) {
        receiveExecutionCoordinator.send(
            .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: false)
        )
        receiveExecutionRuntime.markRemoteTransmitStopProjectionGrace(for: contactID)
        mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        mediaRuntime.clearForegroundSystemReceiveAudioChunks(for: contactID)
        mediaRuntime.directQuicProbeController?.resetIncomingAudioPayloadQueue(
            reason: "remote-transmit-stopped"
        )
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
    }

    func markRemoteTransmitStoppedPreservingPlaybackDrain(for contactID: UUID) {
        receiveExecutionCoordinator.send(
            .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        )
        receiveExecutionRuntime.markRemoteTransmitStopProjectionGrace(for: contactID)
        mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        mediaRuntime.clearForegroundSystemReceiveAudioChunks(for: contactID)
        mediaRuntime.directQuicProbeController?.resetIncomingAudioPayloadQueue(
            reason: "remote-transmit-stopped"
        )
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:draining")
        }
    }

    func fenceRemoteAudioReceiveForLocalTransmitStart(
        contactID: UUID,
        reason: String
    ) {
        receiveExecutionCoordinator.send(
            .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: false)
        )
        mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
        mediaRuntime.resetDirectQuicIncomingAudioQueueDelayDiagnostics(for: contactID)
        mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        mediaRuntime.clearForegroundSystemReceiveAudioChunks(for: contactID)
        mediaRuntime.directQuicProbeController?.resetIncomingAudioPayloadQueue(
            reason: "local-transmit-start"
        )
        mediaServices.session()?.beginRemoteAudioReceiveEpoch()
        diagnostics.record(
            .media,
            message: "Fenced remote audio receive before local transmit",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
    }

    func shouldDeferReceiveTeardownUntilRemoteAudioDrain(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard !isTransmitting else { return false }
        let shouldPreserveForegroundDirectPacketSession =
            currentApplicationState() == .active
            && isJoined
            && activeChannelId == contactID
            && shouldUseDirectQuicTransport(for: contactID)
        let shouldPreserveWakeActivatedSession: Bool
        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            shouldPreserveWakeActivatedSession = true
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            shouldPreserveWakeActivatedSession = false
        }
        guard let activityState = receiveExecutionCoordinator.state.remoteActivityByContactID[contactID] else {
            return shouldPreserveForegroundDirectPacketSession || shouldPreserveWakeActivatedSession
        }
        switch activityState.phase {
        case .receivingAudio, .drainingAudio:
            return true
        case .prepared, .awaitingFirstAudioChunk:
            return shouldPreserveForegroundDirectPacketSession || shouldPreserveWakeActivatedSession
        }
    }

    func finalizeReceiveMediaSessionIfNeeded(
        for contactID: UUID,
        closeMessage: String,
        deferPrewarmMessage: String
    ) {
        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        guard mediaSessionContactID == contactID, !isTransmitting else { return }

        if shouldKeepInteractiveMediaWarmAfterReceiveEnd(
            for: contactID,
            closeMessage: closeMessage
        ) {
            diagnostics.record(
                .media,
                message: "Kept receive media session warm after remote audio ended",
                metadata: [
                    "contactId": contactID.uuidString,
                    "closeMessage": closeMessage,
                ]
            )
            Task {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .remoteAudioEndedKeepalive
                )
            }
            return
        }

        let preserveDirectQuic = shouldUseDirectQuicTransport(for: contactID)
        closeMediaSession(
            preserveDirectQuic: preserveDirectQuic,
            preserveMediaRelay: !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: contactID)
        )
        if backendStatusMessage.hasPrefix("Media ") {
            backendStatusMessage = "Connected"
        }
        diagnostics.record(
            .media,
            message: closeMessage,
            metadata: ["contactId": contactID.uuidString]
        )
        if shouldRestoreInteractivePrewarm {
            deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
            diagnostics.record(
                .media,
                message: deferPrewarmMessage,
                metadata: ["contactId": contactID.uuidString]
            )
        }
    }

    private func shouldKeepInteractiveMediaWarmAfterReceiveEnd(
        for contactID: UUID,
        closeMessage: String
    ) -> Bool {
        let eligibleCloseMessages: Set<String> = [
            "Closed receive media session after remote audio silence timeout",
            "Closed receive media session after remote playback drained",
        ]
        guard eligibleCloseMessages.contains(closeMessage) else {
            return false
        }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else { return false }
        guard currentApplicationState() == .active else { return false }
        guard selectedContactId == contactID else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.membership.hasLocalMembership else { return false }
        guard channelSnapshot.membership.hasPeerMembership else { return false }
        let readiness = channelReadinessByContactID[contactID]
        let transientPeerDeviceLoss =
            channelSnapshot.status == .waitingForPeer
            && readiness?.statusView == .waitingForPeer
            && deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
                channel: channelSnapshot,
                readiness: readiness
            )

        if !transientPeerDeviceLoss {
            guard channelSnapshot.status == .ready else { return false }
            guard channelSnapshot.canTransmit else { return false }
            guard readiness?.statusView == .ready else { return false }
        }
        return true
    }

    func clearSystemRemoteParticipantIfNeededAfterRemoteAudioEnded(for contactID: UUID) {
        guard shouldClearSystemRemoteParticipantFromSignalPath(for: contactID) else { return }
        Task {
            await updateSystemRemoteParticipant(for: contactID, isActive: false)
        }
    }

    func shouldRecoverRemoteTransmitStopFromChannelRefresh(
        contactID: UUID,
        existingChannelState: TurboChannelStateResponse?,
        effectiveChannelState: TurboChannelStateResponse
    ) -> Bool {
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        // Wake receive is still establishing until the pending wake lifecycle
        // clears. Channel refresh must not synthesize a stop during that window,
        // or late-arriving audio will be stranded behind a rearmed wake.
        guard !pttWakeRuntime.hasPendingWake(for: contactID) else { return false }

        let backendPreviouslyShowedPeerTransmit =
            existingChannelState?.conversationStatus == .receiving
        guard backendPreviouslyShowedPeerTransmit else { return false }
        return effectiveChannelState.conversationStatus != .receiving
    }

    func recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
        contactID: UUID,
        existingChannelState: TurboChannelStateResponse?,
        effectiveChannelState: TurboChannelStateResponse
    ) async {
        guard shouldRecoverRemoteTransmitStopFromChannelRefresh(
            contactID: contactID,
            existingChannelState: existingChannelState,
            effectiveChannelState: effectiveChannelState
        ) else { return }

        diagnostics.record(
            .backend,
            message: "Recovered missing transmit-stop from channel refresh",
            metadata: [
                "contactId": contactID.uuidString,
                "previousStatus": existingChannelState?.status ?? "none",
                "effectiveStatus": effectiveChannelState.status,
            ]
        )

        let shouldClearRemoteParticipant = shouldClearSystemRemoteParticipantFromSignalPath(for: contactID)
        let shouldPreservePlaybackDrain: Bool = {
            switch receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase {
            case .receivingAudio, .drainingAudio:
                return true
            case .prepared, .awaitingFirstAudioChunk, .none:
                return false
            }
        }()
        syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: effectiveChannelState.channelId,
            senderDeviceID: "backend-channel-refresh",
            source: "backend-channel-refresh"
        )
        if shouldPreservePlaybackDrain {
            markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
        } else {
            clearRemoteAudioActivity(for: contactID)
        }

        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        if mediaSessionContactID == contactID && !isTransmitting && !shouldPreservePlaybackDrain {
            let preserveDirectQuic = shouldUseDirectQuicTransport(for: contactID)
            closeMediaSession(
                preserveDirectQuic: preserveDirectQuic,
                preserveMediaRelay: !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: contactID)
            )
            diagnostics.record(
                .media,
                message: "Closed receive media session after channel-refresh transmit stop recovery",
                metadata: ["contactId": contactID.uuidString]
            )
            if shouldRestoreInteractivePrewarm {
                deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
                diagnostics.record(
                    .media,
                    message: "Deferred interactive audio prewarm after channel-refresh transmit stop recovery",
                    metadata: ["contactId": contactID.uuidString]
                )
            }
        }

        if shouldClearRemoteParticipant {
            await updateSystemRemoteParticipant(for: contactID, isActive: false)
        }
    }

    func prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?
    ) async {
        let backendShowsPeerTransmit =
            effectiveChannelState.conversationStatus == .receiving
            || effectiveChannelReadiness?.statusView.isPeerTransmitting == true
        guard backendShowsPeerTransmit else { return }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return }
        let applicationState = currentApplicationState()
        guard shouldTreatIncomingSignalAsWakeCandidate(
            for: contactID,
            applicationState: applicationState
        ) else { return }

        let senderUserId =
            effectiveChannelState.activeTransmitterUserId
            ?? effectiveChannelReadiness?.activeTransmitterUserId
            ?? contacts.first(where: { $0.id == contactID })?.remoteUserId
            ?? effectiveChannelState.peerUserId
        let senderDeviceId: String = {
            if case .wakeCapable(let targetDeviceId) = effectiveChannelReadiness?.remoteWakeCapability {
                return targetDeviceId
            }
            return "backend-channel-refresh"
        }()

        syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: effectiveChannelState.channelId,
            senderDeviceID: senderDeviceId,
            source: "backend-channel-refresh"
        )
        ensurePendingWakeCandidate(
            for: contactID,
            channelId: effectiveChannelState.channelId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            scheduleFallback: false
        )
        recordWakeReceiveTiming(
            stage: "backend-peer-transmit-refresh-observed",
            contactID: contactID,
            channelID: effectiveChannelState.channelId,
            subsystem: .backend,
            metadata: [
                "senderUserId": senderUserId,
                "senderDeviceId": senderDeviceId,
                "channelStatus": effectiveChannelState.statusKind,
                "readinessStatus": effectiveChannelReadiness?.statusKind ?? "none",
            ],
            ifAbsent: true
        )
        diagnostics.record(
            .backend,
            message: "Preparing receiver from backend peer-transmitting refresh",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": effectiveChannelState.channelId,
                "senderUserId": senderUserId,
                "senderDeviceId": senderDeviceId,
            ]
        )

        if shouldSetSystemRemoteParticipantFromSignalPath(
            for: contactID,
            applicationState: applicationState
        ) {
            await updateSystemRemoteParticipant(
                for: contactID,
                isActive: true,
                reason: "backend-refresh-remote-active"
            )
        }
    }

    func markRemoteAudioActivity(
        for contactID: UUID,
        source: RemoteReceiveActivitySource = .audioChunk
    ) {
        if source != .audioChunk {
            receiveExecutionRuntime.clearRemoteTransmitStopProjectionGrace(for: contactID)
        }
        receiveExecutionCoordinator.send(.remoteActivityDetected(contactID: contactID, source: source))
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
        }
    }

    func remoteTransmitStopProjectionGraceIsActive(for contactID: UUID) -> Bool {
        receiveExecutionRuntime.remoteTransmitStopProjectionGraceIsActive(
            for: contactID,
            maximumAgeNanoseconds: remoteTransmitStopProjectionGraceNanoseconds
        )
    }

    func remoteReceiveBlocksLocalTransmit(for contactID: UUID) -> Bool {
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        return remotePlaybackDrainBlocksLocalTransmit(for: contactID)
    }

    func remotePlaybackDrainBlocksLocalTransmit(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard
            let activityState = receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID],
            activityState.phase == .drainingAudio
        else {
            return false
        }
        return mediaServices.session()?.hasPendingPlayback() == true
    }

    func remoteReceiveProjectsRemoteTalkTurn(for contactID: UUID) -> Bool {
        remoteTransmittingContactIDs.contains(contactID)
    }

    func incomingAudioDiagnosticDetailedReportLimit() -> Int {
        3
    }

    @discardableResult
    func beginRemoteAudioReceiveEpochIfNeeded(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String,
        source: RemoteReceiveActivitySource,
        controlTransport: String
    ) -> Bool {
        guard receiveExecutionCoordinator.state.shouldBeginRemoteAudioEpoch(
            contactID: contactID,
            source: source
        ) else {
            diagnostics.record(
                .media,
                message: "Skipped remote audio epoch reset for duplicate transmit control",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": senderDeviceID,
                    "source": source.rawValue,
                    "controlTransport": controlTransport,
                    "remoteActivity": String(
                        describing: receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]
                    ),
                ]
            )
            return false
        }

        mediaRuntime.resetIncomingRelayAudioDiagnostics(
            for: contactID,
            detailedReportLimit: incomingAudioDiagnosticDetailedReportLimit()
        )
        mediaRuntime.resetDirectQuicIncomingAudioQueueDelayDiagnostics(for: contactID)
        mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        mediaServices.session()?.beginRemoteAudioReceiveEpoch()
        clearFirstAudioPlaybackAckSentState(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: senderDeviceID
        )
        diagnostics.record(
            .media,
            message: "Started remote audio receive epoch",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "senderDeviceId": senderDeviceID,
                "source": source.rawValue,
                "controlTransport": controlTransport,
                "audioPacketDiagnostics": TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled() ? "enabled" : "disabled",
                "detailedReportLimit": String(incomingAudioDiagnosticDetailedReportLimit()),
            ]
        )
        return true
    }

    func isExpectedBackendSyncCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        return error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    func hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: UUID) -> Bool {
        let localConversationEvidenceActive = devicePTTOrEngineConversationEvidenceExists(for: contactID)
        let matchingDevicePTTSessionActive = systemSessionMatches(contactID)
        let mediaSessionActive = mediaSessionContactID == contactID

        let transmitLifecycleTouchesContact: Bool
        switch transmitCoordinator.state.phase {
        case .idle:
            transmitLifecycleTouchesContact = false
        case .requesting(let transmitContactID),
             .active(let transmitContactID),
             .stopping(let transmitContactID):
            transmitLifecycleTouchesContact = transmitContactID == contactID
        }

        return localConversationEvidenceActive
            || matchingDevicePTTSessionActive
            || mediaSessionActive
            || transmitLifecycleTouchesContact
    }

    func shouldTreatChannelRefreshFailureAsAuthoritativeChannelLoss(_ error: Error) -> Bool {
        shouldTreatBackendJoinChannelNotFoundAsRecoverable(error)
    }

    func clearDevicePTTSessionAfterAuthoritativeChannelLoss(
        contactID: UUID,
        backendChannelID: String,
        error: Error
    ) {
        diagnostics.record(
            .channel,
            message: "Clearing Device PTT session after authoritative channel loss",
            metadata: [
                "contactId": contactID.uuidString,
                "backendChannelId": backendChannelID,
                "error": error.localizedDescription,
            ]
        )

        clearRemoteAudioActivity(for: contactID)
        if let channelUUID = pttCoordinator.state.systemChannelUUID ?? channelUUID(for: contactID) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        }
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        pttCoordinator.reset()
        syncPTTState()
        conversationActionCoordinator.clearPendingConnect(for: contactID)
        conversationActionCoordinator.clearPendingJoin(for: contactID)
        conversationActionCoordinator.clearLeaveAction(for: contactID)
        backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        updateStatusForSelectedContact()
        captureDiagnosticsState("backend-sync:authoritative-channel-loss")
    }

    func shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss(
        contactID: UUID,
        existing: TurboChannelStateResponse?
    ) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard conversationActionCoordinator.pendingAction.pendingTeardownContactID != contactID else {
            return false
        }
        guard channelStateLooksActive(existing) else { return false }
        if hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID) {
            return true
        }
        guard let existing else { return false }
        guard !existing.membership.hasLocalMembership else { return false }
        return existing.membership.hasPeerMembership
            || existing.membership.peerDeviceConnected
            || existing.conversationStatus == .waitingForPeer
    }

    func channelStateLooksActive(_ channelState: TurboChannelStateResponse?) -> Bool {
        guard let channelState else { return false }

        let membershipLooksActive =
            channelState.membership.hasLocalMembership
            || channelState.membership.hasPeerMembership
            || channelState.membership.peerDeviceConnected

        if membershipLooksActive {
            return true
        }

        switch channelState.conversationStatus {
        case .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        case .idle, .outgoingBeep, .incomingBeep, nil:
            return false
        }
    }

    func shouldPreserveConversationStateDuringTransientMembershipDrift(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> Bool {
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
            return false
        }

        guard let existing else { return false }
        guard existing.channelId == incoming.channelId else { return false }

        let localConversationEvidenceActive =
            hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID)
            || remoteTransmittingContactIDs.contains(contactID)

        guard localConversationEvidenceActive else { return false }

        let concreteConversationEvidence =
            devicePTTOrEngineConversationEvidenceExists(for: contactID)
            || mediaSessionContactID == contactID
            || remoteTransmittingContactIDs.contains(contactID)

        let existingConversationReady =
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (
                existing.membership.peerDeviceConnected
                || remoteTransmittingContactIDs.contains(contactID)
                || (
                    existing.conversationStatus == .ready
                    && concreteConversationEvidence
                )
            )

        let existingConversationRecoverableDuringSignalingRecovery =
            existing.membership.hasLocalMembership
            && concreteConversationEvidence
            && {
                switch existing.conversationStatus {
                case .waitingForPeer, .ready, .transmitting, .receiving:
                    return true
                case .idle, .outgoingBeep, .incomingBeep, nil:
                    return false
                }
            }()

        let incomingLostMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        let incomingLooksTransient =
            incoming.status == "connecting"
            || incoming.status == ConversationState.waitingForPeer.rawValue
            || (
                incoming.status == ConversationState.ready.rawValue
                && existingConversationReady
                && concreteConversationEvidence
            )
            || (
                incoming.status == ConversationState.idle.rawValue
                && (
                    existing.conversationStatus == .receiving
                    || remoteTransmittingContactIDs.contains(contactID)
                    || (
                        backendRuntime.signalingJoinRecoveryTask != nil
                        && existingConversationRecoverableDuringSignalingRecovery
                    )
                    || (
                        existingConversationReady
                        && concreteConversationEvidence
                    )
                )
            )

        return (
            existingConversationReady
                && incomingLostMembership
                && incomingLooksTransient
        ) || (
                backendRuntime.signalingJoinRecoveryTask != nil
                && (existingConversationReady || existingConversationRecoverableDuringSignalingRecovery)
                && incomingLostMembership
                && incomingLooksTransient
            )
    }

    func effectiveChannelStatePreservingConversationMembership(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse,
        authoritativeMembershipLoss: Bool = false
    ) -> TurboChannelStateResponse {
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
            return incoming
        }

        guard let existing else { return incoming }
        guard existing.channelId == incoming.channelId else { return incoming }

        let incomingLostAllMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        if authoritativeMembershipLoss, incomingLostAllMembership {
            return incoming
        }

        if shouldPreserveConversationStateDuringTransientMembershipDrift(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        ) {
            return existing
        }

        let localConversationEvidenceActive =
            hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID)
            || remoteTransmittingContactIDs.contains(contactID)
        guard localConversationEvidenceActive else { return incoming }

        let existingConversationReady =
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (existing.membership.peerDeviceConnected || remoteTransmittingContactIDs.contains(contactID))
        guard existingConversationReady else { return incoming }

        let incomingDroppedOnlyPeerMembership =
            incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected
        let incomingDroppedOnlyLocalMembership =
            !incoming.membership.hasLocalMembership
            && incoming.membership.hasPeerMembership

        if incomingDroppedOnlyLocalMembership {
            let incomingLooksLikeTransientSelfMembershipDrift =
                incoming.status == "connecting"
                || incoming.status == ConversationState.waitingForPeer.rawValue
                || (
                    incoming.status == ConversationState.ready.rawValue
                    && incoming.membership.peerDeviceConnected
                )
            guard incomingLooksLikeTransientSelfMembershipDrift else { return incoming }
            return incoming.settingMembership(existing.membership)
        }

        guard incomingDroppedOnlyPeerMembership else { return incoming }

        let incomingLooksLikeActiveConversationReuse =
            incoming.conversationStatus == .transmitting
            || incoming.status == "connecting"
            || incoming.status == ConversationState.waitingForPeer.rawValue
        guard incomingLooksLikeActiveConversationReuse else { return incoming }

        return incoming.settingMembership(existing.membership)
    }

    func shouldIgnoreStaleJoinedChannelRefreshDuringLeave(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localDevicePTTEvidenceCleared: Bool
    ) -> Bool {
        guard conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
            return false
        }
        guard localDevicePTTEvidenceCleared else { return false }
        guard effectiveChannelState.membership.hasLocalMembership else { return false }
        return true
    }

    func shouldTreatChannelReadinessMembershipLossAsAuthoritative(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not a channel member"
    }

    func shouldHonorAuthoritativeChannelReadinessMembershipLoss(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> Bool {
        if conversationActionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return false
        }
        if conversationActionCoordinator.pendingAction.pendingJoinContactID == contactID {
            return false
        }
        if conversationActionCoordinator.pendingConnectAcceptedIncomingBeepContactID == contactID {
            return false
        }
        if devicePTTEvidenceExists(for: contactID) {
            return false
        }
        if hasChannelMatchedUnattributedSystemSession(contactID: contactID) {
            return false
        }
        if let existingRelationship = existing?.beepThreadProjection,
           existingRelationship != .none {
            return false
        }
        if incoming.beepThreadProjection != .none {
            return false
        }
        return true
    }

    func shouldHonorInactiveChannelReadinessMembershipLoss(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse?
    ) -> Bool {
        guard readiness?.statusView == .inactive else { return false }
        guard incoming.membership == .absent else { return false }
        guard incoming.beepThreadProjection == .none else { return false }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return shouldHonorAuthoritativeChannelReadinessMembershipLoss(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )
    }

    func hasChannelMatchedUnattributedSystemSession(contactID: UUID) -> Bool {
        guard case .mismatched(let systemChannelUUID) = systemSessionState else { return false }
        return channelUUID(for: contactID) == systemChannelUUID
    }

    func presenceHeartbeatMinimumInterval(
        backendServices: BackendServices?
    ) -> TimeInterval? {
        guard let backendServices else { return nil }
        if backendServices.shouldSendHTTPPresenceHeartbeat {
            return presenceHeartbeatHTTPFallbackIntervalSeconds
        }
        guard presenceHeartbeatWebSocketIntervalSeconds > 0 else {
            return nil
        }
        return presenceHeartbeatWebSocketIntervalSeconds
    }

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .bootstrapIfNeeded:
            await recoverBackendBootstrapIfNeeded(trigger: "backend-poll")
        case .ensureWebSocketConnected:
            guard shouldMaintainBackgroundControlPlane() else { return }
            backendServices?.ensureWebSocketConnected()
        case .heartbeatPresence:
            guard shouldPublishPresenceHeartbeat() else { return }
            guard let minimumInterval = presenceHeartbeatMinimumInterval(
                backendServices: backendServices
            ) else { return }
            guard backendRuntime.consumePresenceHeartbeatSlot(
                minimumInterval: minimumInterval
            ) else { return }
            _ = try? await backendServices?.heartbeatPresence()
        case .refreshContactSummaries:
            await refreshContactSummaries()
        case .refreshBeeps:
            await refreshBeeps()
        case .refreshChannelState(let contactID):
            await refreshChannelState(for: contactID)
        case .refreshForegroundControlPlane(let selectedContactID):
            await refreshForegroundControlPlane(selectedContactID: selectedContactID)
        }
    }

    func refreshForegroundControlPlane(selectedContactID: UUID?) async {
        let canRefreshSelectedChannelImmediately = selectedContactID.flatMap { contactID in
            contacts.first(where: { $0.id == contactID })?.backendChannelId
        } != nil

        if let selectedContactID, canRefreshSelectedChannelImmediately {
            async let summaries: Void = refreshContactSummaries()
            async let beeps: Void = refreshBeeps()
            async let channel: Void = refreshChannelState(for: selectedContactID)
            _ = await (summaries, beeps, channel)
            return
        }

        async let summaries: Void = refreshContactSummaries()
        async let beeps: Void = refreshBeeps()
        _ = await (summaries, beeps)

        guard let selectedContactID else { return }
        guard contacts.first(where: { $0.id == selectedContactID })?.backendChannelId != nil else {
            return
        }
        await refreshChannelState(for: selectedContactID)
    }


}
