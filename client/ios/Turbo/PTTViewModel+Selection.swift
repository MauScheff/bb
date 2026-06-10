//
//  PTTViewModel+Selection.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit
import TurboEngine

private enum AbsentBackendMembershipRecovery {
    static let invariantID = "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
}

private enum AbsentBackendMembershipRepairAction: String {
    case stalePendingJoin = "stale-pending-join"
    case completedPendingLeave = "completed-pending-leave"
    case stalePendingJoinDuringOutgoingBeep = "stale-pending-join-during-outgoing-beep"

    var message: String {
        switch self {
        case .stalePendingJoinDuringOutgoingBeep:
            return "Recovered stale local join during outgoing Beep"
        case .stalePendingJoin, .completedPendingLeave:
            return "Recovered local Device PTT state after backend membership became absent"
        }
    }
}

private enum AbsentBackendMembershipSuppressionReason: String {
    case backendJoinSettling = "backend-join-settling"
    case unresolvedLocalJoinAttempt = "unresolved-local-join-attempt"

    var message: String {
        switch self {
        case .backendJoinSettling:
            return "Deferred absent backend membership recovery while backend join is settling"
        case .unresolvedLocalJoinAttempt:
            return "Deferred absent backend membership recovery while local join is unresolved"
        }
    }
}

private enum AbsentBackendMembershipRecoveryDecision {
    case repair(AbsentBackendMembershipRepairAction)
    case suppressed(AbsentBackendMembershipSuppressionReason)
}

struct ContactListItem: Identifiable, Equatable {
    let contact: Contact
    let presentation: ContactListPresentation

    var id: UUID { contact.id }
}

struct ContactListSections: Equatable {
    let wantsToTalk: [ContactListItem]
    let readyToTalk: [ContactListItem]
    let outgoingBeep: [ContactListItem]
    let contacts: [ContactListItem]
}

extension PTTViewModel {
    func localTransmitProjection(for contactID: UUID) -> LocalTransmitProjection {
        let snapshot = transmitDomainSnapshot
        if !snapshot.isPressActive,
           snapshot.isSystemTransmitting,
           systemSessionMatches(contactID) {
            return .stopping
        }
        return snapshot.localTransmitProjection(
            for: contactID,
            mediaState: mediaConnectionState,
            pttAudioSessionActive: isPTTAudioSessionActive
        )
    }

    func localRelayTransportReadinessForTransmit(for contactID: UUID) -> MediaTransportFallbackState {
        guard let backend = backendServices else {
            return usesLocalHTTPBackend
                ? .ready(path: .relay, evidence: .localHTTPBackend)
                : .unavailable(reason: .backendUnavailable)
        }
        guard backend.supportsWebSocket else {
            return .ready(path: .relay, evidence: .webSocketUnsupportedBackend)
        }
        if backend.isWebSocketConnected {
            return .ready(
                path: mediaRuntime.hasActiveMediaRelayClient ? .fastRelay : .relay,
                evidence: mediaRuntime.hasActiveMediaRelayClient ? .mediaRelayClient : .webSocketConnected
            )
        }
        if shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) {
            return .ready(path: .relay, evidence: .controlPlaneReconnectGrace)
        }
        return .unavailable(reason: .webSocketDisconnected)
    }

    func localRelayTransportReadyForTransmit(for contactID: UUID) -> Bool {
        localRelayTransportReadinessForTransmit(for: contactID).isReady
    }

    func selectedMediaTransportState(for contactID: UUID) -> SelectedMediaTransportState {
        SelectedMediaTransportState(
            pathState: mediaTransportPathState,
            directActive: shouldUseDirectQuicTransport(for: contactID),
            fallback: localRelayTransportReadinessForTransmit(for: contactID),
            recoveryReason: mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID)?.reason
        )
    }

    func shouldUseLiveCallControlPlaneReconnectGrace(
        for contactID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard let startedAt = liveCallControlPlaneReconnectGraceStartedAt else {
            return false
        }
        guard now.timeIntervalSince(startedAt) <= liveCallControlPlaneReconnectGraceSeconds else {
            return false
        }
        guard selectedContactId == contactID,
              isJoined,
              activeChannelId == contactID,
              selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity,
              selectedConversationSystemSessionMatches(contactID) else {
            return false
        }
        return true
    }

    func selectedConversationSystemSessionMatches(_ contactID: UUID) -> Bool {
        if systemSessionMatches(contactID) {
            return true
        }

        let state = selectedConversationCoordinator.state
        return state.selection?.contactID == contactID
            && state.devicePTT.systemSessionMatchesContact
    }

    var contactSummaryByContactID: [UUID: TurboContactSummaryResponse] {
        backendSyncCoordinator.state.syncState.contactSummaries
    }

    var channelStateByContactID: [UUID: TurboChannelStateResponse] {
        backendSyncCoordinator.state.syncState.channelStates
    }

    var channelReadinessByContactID: [UUID: TurboChannelReadinessResponse] {
        backendSyncCoordinator.state.syncState.channelReadiness
    }

    var incomingBeepByContactID: [UUID: TurboBeepResponse] {
        backendSyncCoordinator.state.syncState.visibleIncomingBeepsByContactID()
    }

    var rawIncomingBeepByContactID: [UUID: TurboBeepResponse] {
        backendSyncCoordinator.state.syncState.incomingBeeps
    }

    var outgoingBeepByContactID: [UUID: TurboBeepResponse] {
        backendSyncCoordinator.state.syncState.outgoingBeeps
    }

    var beepCooldownDeadlineByContactID: [UUID: Date] {
        backendSyncCoordinator.state.syncState.beepCooldownDeadlines
    }

    var requestContactIDs: Set<UUID> {
        backendSyncCoordinator.state.syncState.requestContactIDs
    }

    func systemSessionMatches(_ contactID: UUID) -> Bool {
        switch systemSessionState {
        case .active(let activeContactID, let channelUUID):
            guard !isRestoredSystemSessionQuarantined(channelUUID: channelUUID) else {
                return false
            }
            return activeContactID == contactID
        case .mismatched(let channelUUID):
            guard !isRestoredSystemSessionQuarantined(channelUUID: channelUUID) else {
                return false
            }
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
            return contact.channelId == channelUUID
        case .none:
            return false
        }
    }

    func engineJoinedConversationMatches(_ contactID: UUID, backendChannelID: String? = nil) -> Bool {
        guard let joined = engine.snapshot.conversation.joinedEvidence,
              joined.friend.contactID.rawValue == contactID.uuidString else {
            return false
        }
        guard let backendChannelID else { return true }
        return joined.channelID.rawValue == backendChannelID
    }

    func devicePTTEvidenceExists(for contactID: UUID, expectedChannelUUID: UUID? = nil) -> Bool {
        let expectedChannelUUID = expectedChannelUUID ?? channelUUID(for: contactID)
        return systemSessionMatches(contactID)
            || (
                expectedChannelUUID != nil
                && pttCoordinator.state.systemChannelUUID == expectedChannelUUID
            )
    }

    func devicePTTOrEngineConversationEvidenceExists(for contactID: UUID) -> Bool {
        if devicePTTEvidenceExists(for: contactID) {
            return true
        }

        let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId
            ?? contactSummaryByContactID[contactID]?.channelId
        return engineJoinedConversationMatches(contactID, backendChannelID: backendChannelID)
    }

    func unresolvedLocalJoinAttemptExists(for contactID: UUID) -> Bool {
        guard let attempt = conversationActionCoordinator.localJoinAttempt,
              attempt.contactID == contactID else {
            return false
        }
        guard attempt.issuedCount < maxUnresolvedLocalJoinAttempts else {
            return false
        }
        return !devicePTTEvidenceExists(
            for: contactID,
            expectedChannelUUID: attempt.channelUUID
        )
    }

    func backendJoinIsSettling(for contactID: UUID) -> Bool {
        if backendRuntime.isBackendJoinSettling(for: contactID) {
            return true
        }
        if let optimisticOutgoingBeep = optimisticOutgoingBeepEvidenceByContactID[contactID],
           optimisticOutgoingBeep.isActive(),
           optimisticOutgoingBeep.phase == .joinTransition,
           beepThreadProjection(for: contactID).hasOutgoingBeep,
           !devicePTTEvidenceExists(for: contactID) {
            return true
        }
        if conversationActionCoordinator.pendingJoinContactID == contactID {
            return false
        }
        guard case .join(let request) = backendCommandCoordinator.state.activeOperation else {
            return false
        }
        guard request.contactID == contactID else { return false }
        switch request.intent {
        case .joinAcceptedOutgoingBeep, .joinReadyFriend:
            return true
        case .requestConnection:
            return request.relationship.hasIncomingBeep
        }
    }

    func shouldPreservePendingLocalJoinDuringBackendJoinSettling(for contactID: UUID) -> Bool {
        conversationActionCoordinator.pendingJoinContactID == contactID
            && (
                backendJoinIsSettling(for: contactID)
                || unresolvedLocalJoinAttemptExists(for: contactID)
            )
    }

    func conversationContext(for contact: Contact) -> ConversationDerivationContext {
        return ConversationDerivationContext(
            contactID: contact.id,
            selectedContactID: selectedContactId,
            baseState: selectedContactId == contact.id
                ? selectedConversationBaseState(for: contact.id, relationship: beepThreadProjection(for: contact.id))
                : listConversationState(for: contact.id),
            relationship: beepThreadProjection(for: contact.id),
            contactName: contact.name,
            contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
            contactPresence: contactPresencePresentation(for: contact.id),
            isJoined: isJoined,
            localTransmit: localTransmitProjection(for: contact.id),
            remoteParticipantSignalIsTransmitting: remoteReceiveProjectsRemoteTalkTurn(for: contact.id),
            activeChannelID: activeChannelId,
            systemSessionMatchesContact: systemSessionMatches(contact.id),
            systemSessionState: systemSessionState,
            pendingAction: conversationActionCoordinator.pendingAction,
            pendingConnectAcceptedIncomingBeep:
                conversationActionCoordinator.pendingConnectAcceptedIncomingBeepContactID == contact.id,
            localJoinFailure: pttCoordinator.state.lastJoinFailure,
            mediaState: mediaConnectionState,
            localMediaWarmupState: localMediaWarmupState(for: contact.id),
            mediaTransport: selectedMediaTransportState(for: contact.id),
            firstTalkStartupProfile: firstTalkStartupProfile(for: contact.id, startGraceIfNeeded: false),
            firstTalkReadiness: firstTalkReadiness(for: contact.id),
            incomingWakeActivationState: pttWakeRuntime.incomingWakeActivationState(for: contact.id),
            backendConvergence: BackendConversationConvergenceState(
                joinSettling: backendJoinIsSettling(for: contact.id),
                signalingJoinRecoveryActive: backendRuntime.signalingJoinRecoveryTask != nil,
                controlPlaneReconnectGraceActive:
                    shouldUseLiveCallControlPlaneReconnectGrace(for: contact.id)
            ),
            devicePTTRestoreBarrier: devicePTTRestoreBarrier(for: contact),
            hadConnectedDevicePTTContinuity: selectedContactId == contact.id
                ? selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity
                : false,
            channel: selectedChannelSnapshot(for: contact.id)
        )
    }

    func beepThreadProjection(for contactID: UUID) -> BeepThreadProjection {
        let incomingBeepCount = incomingBeepByContactID[contactID]?.requestCount
        let outgoingBeepCount = outgoingBeepByContactID[contactID]?.requestCount
        let optimisticOutgoingBeepCount = optimisticOutgoingBeepCount(for: contactID)
        let summary = contactSummaryByContactID[contactID]
        let summaryRelationship =
            backendSyncCoordinator.state.syncState.summaryIncomingBeepIsHandled(for: contactID)
                ? summary?.beepThreadProjection.removingIncomingBeep ?? .none
                : summary?.beepThreadProjection ?? .none

        let hasIncomingBeep = incomingBeepCount != nil || summaryRelationship.hasIncomingBeep
        let hasOutgoingBeep =
            outgoingBeepCount != nil
            || summaryRelationship.hasOutgoingBeep
            || optimisticOutgoingBeepCount != nil
        let requestCount =
            [
                incomingBeepCount,
                outgoingBeepCount,
                optimisticOutgoingBeepCount,
                summaryRelationship.requestCount,
            ]
            .compactMap { $0 }
            .max() ?? 0

        return ConversationStateMachine.beepThreadProjection(
            hasIncomingBeep: hasIncomingBeep,
            hasOutgoingBeep: hasOutgoingBeep,
            requestCount: requestCount
        )
    }

    func optimisticOutgoingBeepCount(for contactID: UUID, now: Date = Date()) -> Int? {
        guard let evidence = optimisticOutgoingBeepEvidenceByContactID[contactID],
              evidence.isActive(now: now) else {
            return nil
        }
        return max(evidence.requestCount, 1)
    }

    func markOptimisticOutgoingBeepStarted(
        contactID: UUID,
        relationship: BeepThreadProjection,
        operationID: String?,
        now: Date = Date(),
        allowsIncomingBeepBack: Bool = false
    ) {
        guard !relationship.hasIncomingBeep || allowsIncomingBeepBack else { return }
        let requestCount =
            relationship.hasOutgoingBeep
            ? max((relationship.requestCount ?? 0) + 1, 1)
            : max(relationship.requestCount ?? 0, 1)
        optimisticOutgoingBeepEvidenceByContactID[contactID] =
            OptimisticOutgoingBeepEvidence(
                requestCount: requestCount,
                startedAt: now,
                cooldownDeadline: now.addingTimeInterval(30),
                operationID: operationID,
                phase: .cooldownOnly
            )
        diagnostics.record(
            .state,
            message: "Projected outgoing Beep optimistically",
            metadata: [
                "contactId": contactID.uuidString,
                "requestCount": "\(requestCount)",
                "operationId": operationID ?? "none",
            ]
        )
        updateStatusForSelectedContact()
    }

    func promoteOptimisticOutgoingBeepToJoinTransition(
        contactID: UUID,
        now: Date = Date()
    ) {
        guard let evidence = optimisticOutgoingBeepEvidenceByContactID[contactID],
              evidence.isActive(now: now) else {
            return
        }
        guard evidence.phase != .joinTransition else { return }
        optimisticOutgoingBeepEvidenceByContactID[contactID] = OptimisticOutgoingBeepEvidence(
            requestCount: evidence.requestCount,
            startedAt: evidence.startedAt,
            cooldownDeadline: max(evidence.cooldownDeadline, now.addingTimeInterval(30)),
            operationID: evidence.operationID,
            phase: .joinTransition
        )
        diagnostics.record(
            .state,
            message: "Promoted optimistic outgoing Beep to join transition",
            metadata: [
                "contactId": contactID.uuidString,
                "requestCount": "\(evidence.requestCount)",
                "operationId": evidence.operationID ?? "none",
            ]
        )
        updateStatusForSelectedContact()
    }

    func clearOptimisticOutgoingBeep(
        contactID: UUID,
        reason: String,
        refreshSelection: Bool = true
    ) {
        guard optimisticOutgoingBeepEvidenceByContactID.removeValue(forKey: contactID) != nil else {
            return
        }
        diagnostics.record(
            .state,
            message: "Cleared optimistic outgoing Beep projection",
            metadata: ["contactId": contactID.uuidString, "reason": reason]
        )
        if refreshSelection {
            updateStatusForSelectedContact()
        }
    }

    func selectedConversationBaseState(for contactID: UUID, relationship: BeepThreadProjection) -> ConversationState {
        if let state = selectedChannelState(for: contactID)?.conversationStatus {
            if state == .incomingBeep,
               backendSyncCoordinator.state.syncState.summaryIncomingBeepIsHandled(for: contactID) {
                return relationship.fallbackConversationState
            }
            return state
        }
        return relationship.fallbackConversationState
    }

    func syncSelectedConversationProjection() {
        guard let contact = selectedContact else {
            selectedConversationCoordinator.send(.selectedContactChanged(nil))
            return
        }
        completeReconciledTeardownIfSystemSessionEnded(for: contact.id)
        completeAbsentBackendMembershipRecoveryIfDevicePTTEvidenceEnded(for: contact.id)
        completeStaleBackendConnectIfJoinIsEstablished(for: contact.id)
        let localTransmit = localTransmitProjection(for: contact.id)
        let selectedSystemSessionMatches = systemSessionMatches(contact.id)

        let relationship = beepThreadProjection(for: contact.id)
        recordRecentOutgoingBeepEvidenceIfNeeded(
            contactID: contact.id,
            relationship: relationship
        )
        selectedConversationCoordinator.send(
            .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection:
                        SelectedConversationSelection(
                            contactID: contact.id,
                            contactName: contact.name,
                            contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
                            contactPresence: contactPresencePresentation(for: contact.id)
                        ),
                    relationship: relationship,
                    baseState: selectedConversationBaseState(for: contact.id, relationship: relationship),
                    channel: selectedChannelSnapshot(for: contact.id),
                    localSession: DevicePTTLocalSession(
                        selectedContactID: contact.id,
                        isJoined: selectedSystemSessionMatches,
                        activeChannelID: selectedSystemSessionMatches ? contact.id : nil
                    ),
                    pendingAction: conversationActionCoordinator.pendingAction,
                    pendingConnectAcceptedIncomingBeep:
                        conversationActionCoordinator.pendingConnectAcceptedIncomingBeepContactID == contact.id,
                    senderAutoJoinOnBeepAcceptanceEnabled:
                        conversationShortcutPolicy.senderAutoJoinOnBeepAcceptance,
                    localTransmit: localTransmit,
                    remoteParticipantSignalIsTransmitting: remoteReceiveProjectsRemoteTalkTurn(for: contact.id),
                    remotePlaybackContinuity: RemotePlaybackContinuityState(
                        drainBlocksTransmit: remotePlaybackDrainBlocksLocalTransmit(for: contact.id),
                        stopObserved:
                            receiveExecutionCoordinator
                                .state
                                .remoteTransmitStoppedContactIDs
                                .contains(contact.id),
                        stopProjectionGraceActive:
                            remoteTransmitStopProjectionGraceIsActive(for: contact.id)
                    ),
                    systemSessionState: systemSessionState,
                    systemSessionMatchesContact: systemSessionMatches(contact.id),
                    mediaState: mediaConnectionState,
                    mediaTransport: selectedMediaTransportState(for: contact.id),
                    firstTalkStartupProfile: firstTalkStartupProfile(for: contact.id, startGraceIfNeeded: false),
                    firstTalkReadiness: firstTalkReadiness(for: contact.id),
                    incomingWakeActivationState:
                        pttWakeRuntime.incomingWakeActivationState(for: contact.id),
                    backendConvergence: BackendConversationConvergenceState(
                        joinSettling: backendJoinIsSettling(for: contact.id),
                        signalingJoinRecoveryActive: backendRuntime.signalingJoinRecoveryTask != nil,
                        controlPlaneReconnectGraceActive:
                            shouldUseLiveCallControlPlaneReconnectGrace(for: contact.id)
                    ),
                    devicePTTRestoreBarrier: devicePTTRestoreBarrier(for: contact),
                    localJoinFailure: pttCoordinator.state.lastJoinFailure
                )
            )
        )
    }

    func devicePTTRestoreBarrier(for contact: Contact) -> DevicePTTRestoreBarrier {
        guard hasStaleSystemRejoinSuppression(
            channelUUID: contact.channelId,
            contactID: contact.id
        ), let suppression = staleSystemRejoinSuppressions[contact.channelId] else {
            return .none
        }
        return .recentSystemLeave(
            contactID: suppression.contactID,
            channelUUID: contact.channelId,
            reason: suppression.reason
        )
    }

    func recordRecentOutgoingBeepEvidenceIfNeeded(
        contactID: UUID,
        relationship: BeepThreadProjection,
        now: Date = Date()
    ) {
        guard relationship.hasOutgoingBeep else { return }
        guard let channelID = contacts.first(where: { $0.id == contactID })?.backendChannelId,
              !channelID.isEmpty else { return }
        recentOutgoingBeepEvidenceByContactID[contactID] =
            RecentOutgoingBeepEvidence(
                channelId: channelID,
                requestCount: relationship.requestCount ?? 0,
                observedAt: now
            )
    }

    private func completeReconciledTeardownIfSystemSessionEnded(for contactID: UUID) {
        guard conversationActionCoordinator.pendingAction.pendingTeardownContactID == contactID else { return }
        guard systemSessionState == .none else { return }
        guard selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership != true else { return }

        conversationActionCoordinator.clearLeaveAction(for: contactID)
        selectedConversationCoordinator.send(.devicePTTTeardownCompleted(contactID: contactID))
        diagnostics.record(
            .state,
            message: "Completing reconciled teardown after local system session ended",
            metadata: [
                "contactId": contactID.uuidString,
                "backendMembership": selectedChannelSnapshot(for: contactID).map { String(describing: $0.membership) } ?? "none",
            ]
        )
        replaceDisconnectRecoveryTask(with: nil)
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        pttCoordinator.reset()
        syncPTTState()
        updateStatusForSelectedContact()
        captureDiagnosticsState("device-ptt-teardown:reconciled-complete")
    }

    private func completeStaleBackendConnectIfJoinIsEstablished(for contactID: UUID) {
        guard case .connect(.requestingBackend(let pendingContactID)) = conversationActionCoordinator.pendingAction,
              pendingContactID == contactID else {
            return
        }
        guard devicePTTOrEngineConversationEvidenceExists(for: contactID) else { return }
        let selectedChannel: ChannelReadinessSnapshot? = {
            if let channelState = channelStateByContactID[contactID] {
                return ChannelReadinessSnapshot(
                    channelState: channelState,
                    readiness: channelReadinessByContactID[contactID]
                )
            }
            return selectedChannelSnapshot(for: contactID)
        }()
        guard selectedChannel?.membership.hasLocalMembership == true else { return }

        conversationActionCoordinator.clearAfterSuccessfulJoin(for: contactID)
        diagnostics.record(
            .state,
            message: "Recovered stale backend connect after local join was established",
            metadata: [
                "contactId": contactID.uuidString,
                "invariantID": "selected.backend_ready_stale_backend_connect",
                "backendMembership": selectedChannel.map { String(describing: $0.membership) } ?? "none",
                "backendStatus": selectedChannel?.status?.rawValue ?? "none",
            ]
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("session-recovery:backend-connect-established")
    }

    private func completeAbsentBackendMembershipRecoveryIfDevicePTTEvidenceEnded(for contactID: UUID) {
        let selectedChannel: ChannelReadinessSnapshot? = {
            if let channelState = channelStateByContactID[contactID] {
                return ChannelReadinessSnapshot(
                    channelState: channelState,
                    readiness: channelReadinessByContactID[contactID]
                )
            }
            return selectedChannelSnapshot(for: contactID)
        }()
        guard selectedChannel?.membership.hasLocalMembership != true else { return }
        let beepThread = beepThreadProjection(for: contactID)
        let beepThreadIsNone =
            selectedChannel.map { $0.beepThreadProjection == .none }
            ?? (beepThread == .none)
        let beepThreadIsOutgoing =
            selectedChannel.map { $0.beepThreadProjection.hasOutgoingBeep }
            ?? beepThread.hasOutgoingBeep

        let contactBackendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId
        let summaryBackendChannelID = contactSummaryByContactID[contactID]?.channelId
        let backendChannelReferenceAbsent =
            selectedChannel == nil
            && ((contactBackendChannelID?.isEmpty ?? true)
                && (summaryBackendChannelID?.isEmpty ?? true))
        let backendShowsLocalMembershipAbsent =
            selectedChannel?.membership.hasLocalMembership == false
        let backendHasNoObservedLocalMembership =
            backendShowsLocalMembershipAbsent || selectedChannel == nil

        let devicePTTEvidenceTouchesContact =
            devicePTTEvidenceExists(for: contactID)
        guard !devicePTTEvidenceTouchesContact else { return }

        let backendLeaveCommandInFlight: Bool = {
            guard case .leave(let pendingContactID) = backendCommandCoordinator.state.activeOperation else {
                return false
            }
            return pendingContactID == contactID
        }()
        let pendingJoinIsStale = selectedChannel != nil && conversationActionCoordinator.pendingJoinContactID == contactID
        let pendingJoinContradictsOutgoingBeep =
            pendingJoinIsStale
            && beepThreadIsOutgoing
            && !devicePTTEvidenceTouchesContact
            && !backendJoinIsSettling(for: contactID)
        let recentSystemLeaveIsAwaitingBackendConvergence =
            staleSystemRejoinSuppressions.values.contains { suppression in
                suppression.contactID == contactID
            }
        let pendingLeaveIsComplete =
            conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            && !backendLeaveCommandInFlight
            && !recentSystemLeaveIsAwaitingBackendConvergence
            && (backendHasNoObservedLocalMembership || backendChannelReferenceAbsent)
        guard beepThreadIsNone || pendingJoinContradictsOutgoingBeep else { return }
        guard pendingJoinIsStale || pendingLeaveIsComplete else { return }

        let recoveryDecision: AbsentBackendMembershipRecoveryDecision
        if pendingJoinIsStale,
           !pendingJoinContradictsOutgoingBeep,
           shouldPreservePendingLocalJoinDuringBackendJoinSettling(for: contactID) {
            let suppressionReason: AbsentBackendMembershipSuppressionReason =
                backendJoinIsSettling(for: contactID)
                ? .backendJoinSettling
                : .unresolvedLocalJoinAttempt
            recoveryDecision = .suppressed(suppressionReason)
            let noticeKey = [
                contactID.uuidString,
                suppressionReason.rawValue,
                selectedChannel.map { String(describing: $0.membership) } ?? "none",
                selectedChannel?.status?.rawValue ?? "none",
                String(conversationActionCoordinator.localJoinAttempt?.issuedCount ?? 0),
            ].joined(separator: "|")
            if !deferredAbsentMembershipRecoveryNoticeKeys.contains(noticeKey) {
                deferredAbsentMembershipRecoveryNoticeKeys.insert(noticeKey)
                diagnostics.record(
                    .state,
                    message: suppressionReason.message,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "invariantID": AbsentBackendMembershipRecovery.invariantID,
                        "repairDecision": "suppressed",
                        "repairSuppressionReason": suppressionReason.rawValue,
                        "backendMembership": selectedChannel.map { String(describing: $0.membership) } ?? "none",
                        "backendStatus": selectedChannel?.status?.rawValue ?? "none",
                        "preserveReason": suppressionReason.rawValue,
                        "localJoinAttemptIssuedCount": String(conversationActionCoordinator.localJoinAttempt?.issuedCount ?? 0),
                    ]
                )
            }
            return
        }

        if pendingJoinContradictsOutgoingBeep {
            recoveryDecision = .repair(.stalePendingJoinDuringOutgoingBeep)
        } else if pendingJoinIsStale {
            recoveryDecision = .repair(.stalePendingJoin)
        } else {
            recoveryDecision = .repair(.completedPendingLeave)
        }

        guard case .repair(let repairAction) = recoveryDecision else { return }
        let recoveryMetadata = absentBackendMembershipRecoveryMetadata(
            contactID: contactID,
            selectedChannel: selectedChannel,
            beepThread: beepThread,
            pendingJoinIsStale: pendingJoinIsStale,
            pendingLeaveIsComplete: pendingLeaveIsComplete,
            repairAction: repairAction
        )
        diagnostics.record(
            .state,
            message: "Planned absent backend membership recovery",
            metadata: recoveryMetadata.merging([
                "repairDecision": "planned"
            ]) { _, new in new }
        )
        conversationActionCoordinator.clearPendingJoin(for: contactID)
        conversationActionCoordinator.clearLeaveAction(for: contactID)
        deferredAbsentMembershipRecoveryNoticeKeys = deferredAbsentMembershipRecoveryNoticeKeys.filter {
            !$0.hasPrefix(contactID.uuidString)
        }
        replaceDisconnectRecoveryTask(with: nil)
        diagnostics.record(
            .state,
            message: repairAction.message,
            metadata: recoveryMetadata.merging([
                "repairDecision": "executed"
            ]) { _, new in new }
        )
        updateStatusForSelectedContact()
        diagnostics.record(
            .state,
            message: "Converged absent backend membership recovery",
            metadata: recoveryMetadata.merging([
                "repairDecision": "converged",
                "pendingActionAfterRepair": String(describing: conversationActionCoordinator.pendingAction),
            ]) { _, new in new }
        )
        captureDiagnosticsState("session-recovery:backend-membership-absent")
    }

    private func absentBackendMembershipRecoveryMetadata(
        contactID: UUID,
        selectedChannel: ChannelReadinessSnapshot?,
        beepThread: BeepThreadProjection,
        pendingJoinIsStale: Bool,
        pendingLeaveIsComplete: Bool,
        repairAction: AbsentBackendMembershipRepairAction
    ) -> [String: String] {
        [
            "contactId": contactID.uuidString,
            "invariantID": AbsentBackendMembershipRecovery.invariantID,
            "repairAction": repairAction.rawValue,
            "pendingJoinWasStale": String(pendingJoinIsStale),
            "pendingLeaveWasComplete": String(pendingLeaveIsComplete),
            "backendMembership": selectedChannel.map { String(describing: $0.membership) } ?? "none",
            "beepThreadProjection": selectedChannel
                .map { String(describing: $0.beepThreadProjection) }
                ?? String(describing: beepThread),
        ]
    }

    func selectedConversationState(for contactID: UUID) -> SelectedConversationState {
        selectedConversationProjection(for: contactID).selectedConversationState
    }

    func selectedConversationProjection(for contactID: UUID) -> SelectedConversationProjection {
        if selectedContactId == contactID {
            let state = selectedConversationCoordinator.state
            return SelectedConversationProjection(
                devicePTTContinuity: state.devicePTTContinuityProjection,
                connectedExecution: state.connectedExecutionProjection,
                connectedControlPlane: state.connectedControlPlaneProjection,
                selectedConversationState: state.selectedConversationState,
                reconciliationAction: state.reconciliationAction
            )
        }

        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            let selectedConversationState = SelectedConversationState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Ready to connect",
                canTransmitNow: false
            )
            return SelectedConversationProjection(
                devicePTTContinuity: .inactive,
                connectedExecution: nil,
                connectedControlPlane: .unavailable,
                selectedConversationState: selectedConversationState,
                reconciliationAction: .none
            )
        }
        return ConversationStateMachine.projection(
            for: conversationContext(for: contact),
            relationship: beepThreadProjection(for: contactID)
        )
    }

    // List decoration only. Selected-screen truth must come from selectedConversationState.
    func listConversationState(for contactID: UUID) -> ConversationState {
        if selectedContactId == contactID,
           let status = channelStateByContactID[contactID]?.status,
           let state = ConversationState(rawValue: status) {
            return state
        }
        if let summary = contactSummaryByContactID[contactID] {
            return ConversationStateMachine.listConversationState(for: summary)
        }
        return .idle
    }

    func incomingBeep(for contactID: UUID) -> TurboBeepResponse? {
        incomingBeepByContactID[contactID]
    }

    func outgoingBeep(for contactID: UUID) -> TurboBeepResponse? {
        outgoingBeepByContactID[contactID]
    }

    func contactSummary(for contactID: UUID) -> TurboContactSummaryResponse? {
        contactSummaryByContactID[contactID]
    }

    func contact(for contactID: UUID) -> Contact? {
        contacts.first(where: { $0.id == contactID })
    }

    func contactName(for contactID: UUID) -> String? {
        contact(for: contactID)?.name
    }

    func contactProfileName(for contactID: UUID) -> String? {
        contact(for: contactID)?.profileName
    }

    func contactLocalName(for contactID: UUID) -> String? {
        contact(for: contactID)?.localName
    }

    func contactSubtitle(for contact: Contact, requestCount: Int? = nil) -> String {
        let base: String
        if contact.hasLocalNameOverride {
            base = "\(contact.profileName) • \(contact.handle)"
        } else {
            base = contact.handle
        }

        guard let requestCount, requestCount > 1 else { return base }
        return "\(base) • \(requestCount)x"
    }

    func contactShareLink(for contactID: UUID) -> String? {
        guard let handle = contact(for: contactID)?.handle else { return nil }
        let pathComponent = TurboHandle.sharePathComponent(from: handle)
        let encodedHandle = pathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pathComponent
        return "https://beepbeep.to/\(encodedHandle)"
    }

    func contactDID(for contactID: UUID) -> String? {
        guard let handle = contact(for: contactID)?.handle else { return nil }
        return "did:web:beepbeep.to:id:\(handle)"
    }

    func updateLocalContactName(_ localName: String?, for contactID: UUID) {
        let stored = TurboContactAliasStore.storeLocalName(localName, for: contactID, ownerKey: currentContactAliasOwnerKey)
        updateContact(contactID) { contact in
            contact.localName = stored
        }
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
        }
    }

    func deleteContact(_ contactID: UUID) async -> Bool {
        guard let existingContact = contact(for: contactID) else { return true }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Delete contact failed: backend unavailable",
                metadata: ["contactId": contactID.uuidString, "handle": existingContact.handle]
            )
            return false
        }

        if selectedContactId != contactID {
            selectContact(existingContact)
        }

        let requiresDisconnect =
            selectedContactId == contactID
            || activeConversationContactID == contactID
            || mediaSessionContactID == contactID
            || systemSessionMatches(contactID)
            || isJoined
            || pttCoordinator.state.systemChannelUUID != nil

        if requiresDisconnect {
            await requestDisconnectSelectedConversation()
        }

        do {
            try await deletePendingBeepProjection(
                for: existingContact,
                contactID: contactID,
                backend: backend
            )
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Delete failed: \(message)"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Delete contact failed while clearing Beep",
                metadata: [
                    "contactId": contactID.uuidString,
                    "handle": existingContact.handle,
                    "error": message,
                ]
            )
            return false
        }

        var forgetOtherHandle: String? = existingContact.remoteUserId == nil ? existingContact.handle : nil
        var forgetOtherUserId: String? = existingContact.remoteUserId
        do {
            let remoteUser = try await backend.resolveIdentity(reference: existingContact.handle)
            if let remoteUserId = existingContact.remoteUserId,
               remoteUserId != remoteUser.userId {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Repaired stale contact identity before delete",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": existingContact.handle,
                        "staleRemoteUserId": remoteUserId,
                        "resolvedRemoteUserId": remoteUser.userId,
                    ]
                )
            }
            forgetOtherHandle = nil
            forgetOtherUserId = remoteUser.userId
        } catch {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Delete contact using cached identity after resolve failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "handle": existingContact.handle,
                    "error": error.localizedDescription,
                ]
            )
        }

        do {
            _ = try await backend.forgetContact(
                otherHandle: forgetOtherHandle,
                otherUserId: forgetOtherUserId
            )
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Delete failed: \(message)"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Delete contact failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "handle": existingContact.handle,
                    "error": message,
                ]
            )
            return false
        }

        _ = TurboContactAliasStore.storeLocalName(nil, for: contactID, ownerKey: currentContactAliasOwnerKey)
        let retainedSummaries = contactSummaryByContactID
            .filter { $0.key != contactID }
            .map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
        let retainedIncomingBeeps = incomingBeepByContactID
            .filter { $0.key != contactID }
            .map { BackendBeepUpdate(contactID: $0.key, beep: $0.value) }
        let retainedOutgoingBeeps = outgoingBeepByContactID
            .filter { $0.key != contactID }
            .map { BackendBeepUpdate(contactID: $0.key, beep: $0.value) }

        backendSyncCoordinator.send(.contactSummariesUpdated(retainedSummaries))
        backendSyncCoordinator.send(.beepsUpdated(
            incoming: retainedIncomingBeeps,
            outgoing: retainedOutgoingBeeps,
            now: .now
        ))
        backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
        clearRemoteAudioActivity(for: contactID)
        pttWakeRuntime.clear(for: contactID)
        untrackContact(contactID)
        if selectedContactId == contactID {
            resetSelection()
        }
        contacts.removeAll { $0.id == contactID }
        pruneContactsToAuthoritativeState()
        reconcileContactSelectionIfNeeded(
            reason: "contact-deleted",
            allowSelectingFallbackContact: false
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("contact-deleted")
        await refreshContactSummaries()
        await refreshBeeps()
        return contact(for: contactID) == nil
    }

    private func deletePendingBeepProjection(
        for contact: Contact,
        contactID: UUID,
        backend: BackendServices
    ) async throws {
        if let outgoingBeep = outgoingBeepByContactID[contactID] {
            do {
                _ = try await backend.cancelBeep(beepId: outgoingBeep.beepId)
                await waitForBeepToDisappear(
                    beepID: outgoingBeep.beepId,
                    contactID: contactID,
                    handle: contact.handle,
                    label: "Deleted contact outgoing Beep cancel",
                    fetchBeeps: { try await backend.outgoingBeeps() }
                )
            } catch {
                guard shouldIgnoreBeepNotFoundFailure(error) else { throw error }
            }
        }

        if let incomingBeep = rawIncomingBeepByContactID[contactID] {
            do {
                markIncomingBeepHandledLocally(
                    contactID: contactID,
                    beep: incomingBeep,
                    relationship: beepThreadProjection(for: contactID),
                    reason: "delete-contact"
                )
                _ = try await backend.declineBeep(beepId: incomingBeep.beepId)
                await waitForBeepToDisappear(
                    beepID: incomingBeep.beepId,
                    contactID: contactID,
                    handle: contact.handle,
                    label: "Deleted contact incoming Beep decline",
                    fetchBeeps: { try await backend.incomingBeeps() }
                )
            } catch {
                guard shouldIgnoreBeepNotFoundFailure(error) else { throw error }
            }
        }
    }

    func beepCooldownRemaining(for contactID: UUID, now: Date = .now) -> Int? {
        let deadline =
            beepCooldownDeadlineByContactID[contactID]
            ?? optimisticOutgoingBeepEvidenceByContactID[contactID]?.cooldownDeadline
        guard let deadline else { return nil }
        let remaining = Int(ceil(deadline.timeIntervalSince(now)))
        guard remaining > 0 else { return nil }
        return remaining
    }

    func contactPresencePresentation(for contactID: UUID) -> ContactPresencePresentation {
        let summary = contactSummaryByContactID[contactID]
        let rawPresenceOnline = summary?.isOnline
            ?? contacts.first(where: { $0.id == contactID })?.isOnline
            ?? false
        let summaryReachability = summary.map { contactPresencePresentation(for: $0) }

        if let channelSnapshot = selectedChannelSnapshot(for: contactID) {
            if case .absent = channelSnapshot.membership {
                return summaryReachability ?? FriendAvailability(isOnline: rawPresenceOnline)
            }
            if channelSnapshot.membership.peerDeviceConnected {
                return .foreground
            }
            if let summaryReachability {
                return summaryReachability
            }
            return rawPresenceOnline ? .wakeCapable : .unavailable
        }

        if let summaryReachability {
            return summaryReachability
        }

        return FriendAvailability(isOnline: rawPresenceOnline)
    }

    private func contactPresencePresentation(
        for summary: TurboContactSummaryResponse
    ) -> ContactPresencePresentation {
        if summary.membership.peerDeviceConnected {
            return .foreground
        }
        switch summary.beepReachability {
        case .foreground:
            return .foreground
        case .wakeCapable:
            return .wakeCapable
        case .notReachable:
            return .unavailable
        }
    }

    func selectedConversationPresenceIsOnline(for contactID: UUID) -> Bool {
        contactPresencePresentation(for: contactID).isForeground
    }

    var activeConversationContactID: UUID? {
        if case .active(let contactID, _) = systemSessionState,
           contacts.contains(where: { $0.id == contactID }) {
            return contactID
        }
        if case .mismatched(let channelUUID) = systemSessionState,
           let contactID = contactId(for: channelUUID) {
            return contactID
        }
        return activeChannelId
    }

    var activeConversationContact: Contact? {
        guard let activeConversationContactID else { return nil }
        return contacts.first(where: { $0.id == activeConversationContactID })
    }

    var transportPathBadgeState: MediaTransportPathState? {
        if let activeMediaEpochPathState = mediaRuntime.activeMediaEpochPathState,
           activeConversationContactID ?? mediaSessionContactID ?? selectedContactId != nil {
            return activeMediaEpochPathState
        }

        guard let contactID = activeConversationContactID ?? mediaSessionContactID else {
            return nil
        }

        let phase = selectedConversationProjection(for: contactID).selectedConversationState.phase
        guard phase.showsTransportPathBadge else {
            return nil
        }

        switch mediaTransportPathState {
        case .direct:
            return .direct
        case .fastRelay:
            if TurboMediaLaneDebugOverride.mediaLaneOverride() == .forceFastRelayTls {
                return .fastRelayTcp
            }
            return .fastRelay
        case .fastRelayTcp:
            return .fastRelayTcp
        case .relay, .promoting, .recovering:
            return .relay
        }
    }

    private var listEligibleContacts: [Contact] {
        contacts.filter { contact in
            contact.handle != currentDevUserHandle
                && !(activeConversationContactID == contact.id)
        }
    }

    func contactListItem(for contact: Contact) -> ContactListItem {
        let relationship = beepThreadProjection(for: contact.id)
        let presence = contactPresencePresentation(for: contact.id)
        let presentation = ConversationStateMachine.contactListPresentation(
            for: listConversationState(for: contact.id),
            requestCount: relationship.requestCount,
            presence: presence,
            // Reserve the busy case in the product model until the backend exposes
            // a dedicated peer-busy fact we can trust.
            isBusy: false
        )
        return ContactListItem(contact: contact, presentation: presentation)
    }

    var contactListSections: ContactListSections {
        let items = listEligibleContacts.map(contactListItem(for:))

        return ContactListSections(
            wantsToTalk: sortContactListItems(items.filter { $0.presentation.section == .wantsToTalk }),
            readyToTalk: sortContactListItems(items.filter { $0.presentation.section == .readyToTalk }),
            outgoingBeep: sortContactListItems(items.filter { $0.presentation.section == .outgoingBeep }),
            contacts: sortContactListItems(items.filter { $0.presentation.section == .contacts })
        )
    }

    private func sortContactListItems(_ items: [ContactListItem]) -> [ContactListItem] {
        items.sorted { lhs, rhs in
            if lhs.presentation.section == rhs.presentation.section {
                switch lhs.presentation.section {
                case .wantsToTalk, .outgoingBeep:
                    let lhsRequestCount = lhs.presentation.requestCount ?? 1
                    let rhsRequestCount = rhs.presentation.requestCount ?? 1
                    if lhsRequestCount != rhsRequestCount {
                        return lhsRequestCount > rhsRequestCount
                    }
                case .readyToTalk:
                    let lhsRank = readyToTalkSortRank(lhs.presentation.displayStatus)
                    let rhsRank = readyToTalkSortRank(rhs.presentation.displayStatus)
                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }
                case .contacts:
                    break
                }
            }

            let lhsPresence = contactPresencePresentation(for: lhs.contact.id)
            let rhsPresence = contactPresencePresentation(for: rhs.contact.id)
            if lhsPresence != rhsPresence {
                return presenceSortRank(lhsPresence) < presenceSortRank(rhsPresence)
            }

            return lhs.contact.name.localizedCaseInsensitiveCompare(rhs.contact.name) == .orderedAscending
        }
    }

    private func presenceSortRank(_ presence: ContactPresencePresentation) -> Int {
        switch presence {
        case .foreground:
            return 0
        case .wakeCapable:
            return 1
        case .unavailable:
            return 2
        }
    }

    private func readyToTalkSortRank(_ displayStatus: ConversationDisplayStatus) -> Int {
        switch displayStatus {
        case .live:
            return 0
        case .ready:
            return 1
        case .offline, .online, .beep:
            return 2
        }
    }

    func ensureContactExists(
        handle: String,
        remoteUserId: String,
        channelId: String,
        displayName: String? = nil
    ) -> UUID {
        let stableID = Contact.stableID(remoteUserId: remoteUserId, fallbackHandle: Contact.normalizedHandle(handle))
        let result = ContactDirectory.ensureContact(
            handle: handle,
            remoteUserId: remoteUserId,
            channelId: channelId,
            displayName: displayName,
            localName: TurboContactAliasStore.localName(for: stableID, ownerKey: currentContactAliasOwnerKey),
            existingContacts: contacts
        )
        contacts = result.contacts
        return result.contactID
    }

    func selectedChannelState(for contactID: UUID) -> TurboChannelStateResponse? {
        guard let channelState = channelStateByContactID[contactID] else { return nil }

        let devicePTTEvidenceAligned =
            devicePTTEvidenceExists(for: contactID)

        if devicePTTEvidenceAligned {
            return channelState
        }

        if let joined = engine.snapshot.conversation.joinedEvidence,
           joined.friend.contactID.rawValue == contactID.uuidString,
           joined.channelID.rawValue == channelState.channelId {
            return channelState
        }

        if let contact = contacts.first(where: { $0.id == contactID }),
           contact.backendChannelId == channelState.channelId {
            return channelState
        }

        guard let summary = contactSummaryByContactID[contactID],
              let summaryChannelID = summary.channelId,
              !summaryChannelID.isEmpty,
              summaryChannelID == channelState.channelId else {
            return nil
        }

        return channelState
    }

    func selectedChannelSnapshot(for contactID: UUID) -> ChannelReadinessSnapshot? {
        selectedChannelState(for: contactID).map { channelState in
            let snapshot = ChannelReadinessSnapshot(
                channelState: channelState,
                readiness: channelReadinessByContactID[contactID]
            )
            guard backendSyncCoordinator.state.syncState.summaryIncomingBeepIsHandled(for: contactID),
                  snapshot.beepThreadProjection.hasIncomingBeep else {
                return snapshot
            }
            return snapshot.replacingBeepThreadProjection(
                snapshot.beepThreadProjection.removingIncomingBeep,
                status: snapshot.status == .incomingBeep ? nil : snapshot.status
            )
        }
    }

    func selectContact(
        _ contact: Contact,
        reason: String = "selected-contact",
        opensIncomingBeepSurface: Bool = true
    ) {
        let selectionChanged = selectedContactId != contact.id
        trackContact(contact.id)
        if opensIncomingBeepSurface {
            markIncomingBeepSurfaceOpened(
                for: contact.id,
                beepID: incomingBeepByContactID[contact.id]?.beepId
            )
        }
        if selectionChanged {
            selectedContactPrewarmedSelectionContactID = nil
        }
        selectedContactId = contact.id
        syncEngineSelectedFriend(contact, reason: reason)
        conversationActionCoordinator.select(contactID: contact.id)
        diagnostics.record(
            .state,
            message: "Selected contact",
            metadata: [
                "handle": contact.handle,
                "reason": reason,
            ]
        )
        updateStatusForSelectedContact()
        guard selectionChanged || selectedContactPrewarmedSelectionContactID != contact.id else {
            diagnostics.record(
                .media,
                message: "Skipped selected contact prewarm pipeline",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "blockReason": "already-prewarmed-for-selected-contact",
                ]
            )
            return
        }
        Task {
            await runSelectedContactPrewarmPipeline(
                for: contact.id,
                reason: reason
            )
        }
    }

    func runSelectedContactPrewarmPipeline(
        for contactID: UUID,
        reason: String
    ) async {
        guard selectedContactPrewarmPipelineEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped selected contact prewarm pipeline",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": "feature-disabled"
                ]
            )
            return
        }
        guard selectedContactId == contactID else { return }
        guard !selectedContactPrewarmInFlight.contains(contactID) else {
            diagnostics.record(
                .media,
                message: "Coalesced selected contact prewarm pipeline",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        selectedContactPrewarmInFlight.insert(contactID)
        defer {
            selectedContactPrewarmInFlight.remove(contactID)
        }

        let startedAt = Date()
        diagnostics.record(
            .media,
            message: "Selected contact prewarm pipeline started",
            metadata: selectedContactPrewarmMetadata(
                for: contactID,
                reason: reason,
                startedAt: startedAt
            )
        )
        captureDiagnosticsState("selected-contact-prewarm:start")

        await runSelectedContactPrewarmStage(
            "media-shell",
            contactID: contactID,
            reason: reason
        ) {
            precreateSelectedContactMediaShellIfNeeded(
                for: contactID,
                reason: reason
            )
        }

        let friendPrewarmHintBlockReason =
            reason.hasPrefix("friend-hint-")
                ? "friend-hint-loop-suppressed"
                : selectedFriendPrewarmHintBlockReason(for: contactID)
                    ?? selectedFriendPrewarmPublishBlockReason(for: contactID)
        async let friendPrewarmHint: Void = runSelectedContactPrewarmStage(
            "friend-prewarm-hint",
            contactID: contactID,
            reason: reason,
            initialBlockReason: friendPrewarmHintBlockReason
        ) {
            guard friendPrewarmHintBlockReason == nil else { return }
            await publishSelectedFriendPrewarmHintIfPossible(for: contactID, reason: reason)
        }
        async let directQuicPrewarm: Void = runSelectedContactPrewarmStage(
            "direct-quic-prewarm",
            contactID: contactID,
            reason: reason,
            initialBlockReason: selectedContactDirectQuicPrewarmBlockReason(for: contactID)
        ) {
            await ingestSelectedContactDirectQuicPrewarm(
                contactID: contactID,
                reason: reason
            )
        }
        async let foregroundTalkPrewarm: Void = runSelectedContactPrewarmStage(
            "foreground-talk-prewarm",
            contactID: contactID,
            reason: reason
        ) {
            await prewarmForegroundTalkPathIfNeeded(
                for: contactID,
                reason: reason
            )
        }
        async let relayPrejoin: Void = runSelectedContactPrewarmStage(
            "media-relay-prejoin",
            contactID: contactID,
            reason: reason
        ) {
            guard await canScheduleReadyChannelMediaRelayPrejoin(contactID: contactID) else { return }
            await prejoinMediaRelayForReadyChannelIfNeeded(
                contactID: contactID,
                channelReadiness: channelReadinessByContactID[contactID]
            )
        }
        _ = await (friendPrewarmHint, directQuicPrewarm, foregroundTalkPrewarm, relayPrejoin)

        diagnostics.record(
            .media,
            message: "Selected contact prewarm pipeline completed",
            metadata: selectedContactPrewarmMetadata(
                for: contactID,
                reason: reason,
                startedAt: startedAt
            )
        )
        captureDiagnosticsState("selected-contact-prewarm:completed")
        if selectedContactId == contactID {
            selectedContactPrewarmedSelectionContactID = contactID
        }
    }

    private func runSelectedContactPrewarmStage(
        _ stage: String,
        contactID: UUID,
        reason: String,
        initialBlockReason: String? = nil,
        operation: () async -> Void
    ) async {
        guard selectedContactId == contactID else { return }
        let startedAt = Date()
        var metadata = selectedContactPrewarmMetadata(
            for: contactID,
            reason: reason,
            startedAt: startedAt
        )
        metadata["stage"] = stage
        if let initialBlockReason {
            metadata["initialBlockReason"] = initialBlockReason
        }
        diagnostics.record(
            .media,
            message: "Selected contact prewarm stage started",
            metadata: metadata
        )
        await operation()
        metadata = selectedContactPrewarmMetadata(
            for: contactID,
            reason: reason,
            startedAt: startedAt
        )
        metadata["stage"] = stage
        if let initialBlockReason {
            metadata["initialBlockReason"] = initialBlockReason
        }
        diagnostics.record(
            .media,
            message: "Selected contact prewarm stage completed",
            metadata: metadata
        )
    }

    private func selectedContactPrewarmMetadata(
        for contactID: UUID,
        reason: String,
        startedAt: Date
    ) -> [String: String] {
        let contact = contacts.first(where: { $0.id == contactID })
        return [
            "contactId": contactID.uuidString,
            "handle": contact?.handle ?? "none",
            "reason": reason,
            "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
            "selectedContactCurrent": String(selectedContactId == contactID),
            "applicationState": String(describing: currentApplicationState()),
            "backendChannelId": contact?.backendChannelId ?? "none",
            "remoteUserIdPresent": String(contact?.remoteUserId != nil),
            "webSocketConnected": String(backendServices?.isWebSocketConnected == true),
            "localMediaWarmupState": String(describing: localMediaWarmupState(for: contactID)),
            "directQuicPrewarmBlockReason": selectedContactDirectQuicPrewarmBlockReason(for: contactID) ?? "none",
            "mediaSessionContactId": mediaSessionContactID?.uuidString ?? "none",
            "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
        ]
    }

    func reconcileContactSelectionIfNeeded(
        reason: String,
        allowSelectingFallbackContact: Bool
    ) {
        if let selectedContactId,
           contacts.contains(where: { $0.id == selectedContactId }) {
            return
        }

        if selectedContactId != nil {
            selectedContactId = nil
            syncEngineSelectedFriend(nil, reason: reason)
            selectedConversationCoordinator.send(.selectedContactChanged(nil))
        }

        guard let contact = preferredContactForAutomaticSelection(
            allowSelectingFallbackContact: allowSelectingFallbackContact
        ) else {
            updateStatusForSelectedContact()
            return
        }

        diagnostics.record(
            .state,
            message: "Auto-selected contact",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact, reason: reason, opensIncomingBeepSurface: false)
    }

    @discardableResult
    func selectContactMatchingNotificationHandle(_ handle: String, reason: String) -> Bool {
        let normalizedHandle = Contact.normalizedHandle(handle)
        guard let contact = contacts.first(where: { Contact.normalizedHandle($0.handle) == normalizedHandle }) else {
            return false
        }

        diagnostics.record(
            .pushToTalk,
            message: "Selected contact from Beep notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact)
        return true
    }

    private func preferredContactForAutomaticSelection(
        allowSelectingFallbackContact: Bool
    ) -> Contact? {
        if let incomingBeepContact = contacts
            .filter({ incomingBeepByContactID[$0.id] != nil })
            .max(by: { lhs, rhs in
                let lhsBeep = incomingBeepByContactID[lhs.id]
                let rhsBeep = incomingBeepByContactID[rhs.id]
                return beepRecencyKey(lhsBeep) < beepRecencyKey(rhsBeep)
            }) {
            return incomingBeepContact
        }

        if let incomingRelationshipContact = contacts
            .filter({ beepThreadProjection(for: $0.id).hasIncomingBeep })
            .max(by: { lhs, rhs in
                (beepThreadProjection(for: lhs.id).requestCount ?? 1)
                    < (beepThreadProjection(for: rhs.id).requestCount ?? 1)
            }) {
            return incomingRelationshipContact
        }

        if let activeChannelId,
           let activeContact = contacts.first(where: { $0.id == activeChannelId }) {
            return activeContact
        }

        guard allowSelectingFallbackContact else { return nil }
        return contacts.first
    }

    private func beepRecencyKey(_ beep: TurboBeepResponse?) -> String {
        beep?.updatedAt ?? beep?.createdAt ?? ""
    }

    func resetSelection() {
        selectedContactId = nil
        syncEngineSelectedFriend(nil, reason: "reset-selection")
        selectedContactPrewarmedSelectionContactID = nil
        captureDiagnosticsState("selection-reset")
    }

    func updateStatusForSelectedContact() {
        if selectedContact != nil {
            syncSelectedConversationProjection()
            statusMessage = selectedConversationCoordinator.state.selectedConversationState.statusMessage
            reconcileSelectedConnectionAttemptTimeout()
        } else {
            cancelSelectedConnectionAttemptTimeout()
            statusMessage = ConversationStateMachine.statusMessage(
                for: ConversationDerivationContext(
                    contactID: UUID(),
                    selectedContactID: nil,
                    baseState: .idle,
                    contactName: "",
                    contactIsOnline: false,
                    isJoined: isJoined,
                    activeChannelID: activeChannelId,
                    systemSessionMatchesContact: false,
                    systemSessionState: systemSessionState,
                    pendingAction: conversationActionCoordinator.pendingAction,
                    localJoinFailure: pttCoordinator.state.lastJoinFailure,
                    localMediaWarmupState: .cold,
                    channel: nil
                )
            )
        }
        reconcileLiveConversationActivity()
    }

    func reconcileLiveConversationActivity() {
        guard let contact = selectedContact else {
            liveConversationActivityController.endActiveActivity()
            return
        }

        let selectedState = selectedConversationCoordinator.state.selectedConversationState
        let projection = LiveConversationActivityProjection(
            contact: contact,
            selectedConversationState: selectedState,
            localDisplayName: currentProfileName,
            hasDevicePTTSession: devicePTTEvidenceExists(
                for: contact.id,
                expectedChannelUUID: contact.channelId
            )
        )
        liveConversationActivityController.reconcile(projection)
    }

    func reconcileSelectedConnectionAttemptTimeout() {
        guard let contactID = selectedContactId else {
            cancelSelectedConnectionAttemptTimeout()
            return
        }
        let selectedConversationState = selectedConversationCoordinator.state.selectedConversationState
        guard selectedConversationState.contactID == contactID,
              shouldTimeoutSelectedConnectionAttempt(selectedConversationState, contactID: contactID) else {
            cancelSelectedConnectionAttemptTimeout()
            return
        }

        let key = "\(contactID.uuidString)|\(selectedConversationState.detail)"
        guard selectedConnectionAttemptTimeoutKey != key else { return }
        cancelSelectedConnectionAttemptTimeout()
        selectedConnectionAttemptTimeoutKey = key
        selectedConnectionAttemptTimeoutTask = Task { [weak self] in
            let timeout = await MainActor.run {
                self?.selectedConnectionAttemptTimeoutNanoseconds ?? 15_000_000_000
            }
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.selectedConnectionAttemptTimeoutKey == key else { return }
                if let contact = self.contacts.first(where: { $0.id == contactID }),
                   let attempt = self.conversationActionCoordinator.localJoinAttempt,
                   attempt.contactID == contactID,
                   attempt.channelUUID == contact.channelId,
                   !self.devicePTTEvidenceExists(for: contactID, expectedChannelUUID: contact.channelId) {
                    if self.hasStaleSystemRejoinSuppression(
                        channelUUID: contact.channelId,
                        contactID: contactID
                    ) {
                        self.conversationActionCoordinator.clearPendingJoin(for: contactID)
                        self.updateStatusForSelectedContact()
                        self.diagnostics.record(
                            .pushToTalk,
                            message: "Suppressed stale local PTT join retry after recent system leave",
                            metadata: [
                                "contactId": contactID.uuidString,
                                "channelUUID": contact.channelId.uuidString,
                                "issuedCount": String(attempt.issuedCount),
                                "selectedConversationPhase": String(describing: self.selectedConversationCoordinator.state.selectedConversationState.phase),
                            ]
                        )
                        self.captureDiagnosticsState("selected-connection-attempt:retry-blocked-by-recent-leave")
                        self.cancelSelectedConnectionAttemptTimeout()
                        return
                    }
                    self.diagnostics.record(
                        .pushToTalk,
                        level: .notice,
                        message: "Retrying stale local PTT join after connection timeout",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelUUID": contact.channelId.uuidString,
                            "issuedCount": String(attempt.issuedCount),
                            "selectedConversationPhase": String(describing: self.selectedConversationCoordinator.state.selectedConversationState.phase),
                        ]
                    )
                    self.selectedConnectionAttemptTimeoutKey = nil
                    self.selectedConnectionAttemptTimeoutTask = nil
                    self.joinPTTChannel(for: contact)
                    self.reconcileSelectedConnectionAttemptTimeout()
                    return
                }
                self.selectedConversationCoordinator.send(.connectionAttemptTimedOut(contactID: contactID))
                self.statusMessage = self.selectedConversationCoordinator.state.selectedConversationState.statusMessage
                self.diagnostics.record(
                    .state,
                    level: .notice,
                    message: "Selected connection attempt timed out",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "selectedConversationPhase": String(describing: self.selectedConversationCoordinator.state.selectedConversationState.phase),
                    ]
                )
                self.captureDiagnosticsState("selected-connection-attempt:timed-out")
                self.cancelSelectedConnectionAttemptTimeout()
            }
        }
    }

    func cancelSelectedConnectionAttemptTimeout() {
        selectedConnectionAttemptTimeoutTask?.cancel()
        selectedConnectionAttemptTimeoutTask = nil
        selectedConnectionAttemptTimeoutKey = nil
    }

    func shouldTimeoutSelectedConnectionAttempt(
        _ selectedConversationState: SelectedConversationState,
        contactID: UUID? = nil
    ) -> Bool {
        if let contactID,
           devicePTTOrEngineConversationEvidenceExists(for: contactID) {
            return false
        }

        if let contactID,
           case .connect(.requestingBackend(let pendingContactID)) = conversationActionCoordinator.pendingAction,
           pendingContactID == contactID {
            return false
        }

        switch selectedConversationState.detail {
        case .waitingForPeer(reason: .pendingJoin),
             .waitingForPeer(reason: .backendConversationTransition),
             .waitingForPeer(reason: .devicePTTTransition),
             .waitingForPeer(reason: .friendReadyToConnect):
            return true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .wakeReady,
             .waitingForPeer, .localJoinFailed, .ready, .readyHoldToTalkDisabled,
             .startingTransmit, .transmitting, .receiving, .blockedByOtherSession,
             .systemMismatch:
            return false
        }
    }

    func localMediaWarmupState(for contactID: UUID) -> LocalMediaWarmupState {
        guard mediaSessionContactID == contactID else { return .cold }
        switch mediaConnectionState {
        case .idle, .closed:
            return .cold
        case .preparing:
            return .prewarming
        case .connected:
            return .ready
        case .failed:
            return .failed
        }
    }

    func updateContact(_ id: UUID, mutate: (inout Contact) -> Void) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        var contact = contacts[index]
        mutate(&contact)
        contacts[index] = contact
    }

    var authoritativeContactIDs: Set<UUID> {
        ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: trackedContactIDs,
            summaryContactIDs: Set(contactSummaryByContactID.keys),
            selectedContactID: selectedContactId,
            activeChannelID: activeChannelId,
            mediaSessionContactID: mediaSessionContactID,
            pendingJoinContactID: pendingJoinContactId,
            beepContactIDs: requestContactIDs
        )
    }

    func pruneContactsToAuthoritativeState() {
        contacts = ContactDirectory.retainedContacts(
            existingContacts: contacts,
            authoritativeContactIDs: authoritativeContactIDs
        )
    }
}
