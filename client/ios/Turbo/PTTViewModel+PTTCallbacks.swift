//
//  PTTViewModel+PTTCallbacks.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

enum TurboIncomingPTTPushBoundaryDiagnostics {
    static func metadata(
        applicationState: UIApplication.State,
        protectedDataAvailable: Bool
    ) -> [String: String] {
        [
            "applicationState": applicationStateDescription(applicationState),
            "receiverState": receiverState(
                applicationState: applicationState,
                protectedDataAvailable: protectedDataAvailable
            ),
            "lockState": protectedDataAvailable ? "unlocked" : "locked",
            "protectedDataAvailable": String(protectedDataAvailable),
            "protectedDataState": protectedDataAvailable
                ? "available"
                : "protected-data-will-become-unavailable",
        ]
    }

    private static func applicationStateDescription(_ applicationState: UIApplication.State) -> String {
        switch applicationState {
        case .active:
            return "active"
        case .background:
            return "background"
        case .inactive:
            return "inactive"
        @unknown default:
            return "unknown"
        }
    }

    private static func receiverState(
        applicationState: UIApplication.State,
        protectedDataAvailable: Bool
    ) -> String {
        if !protectedDataAvailable {
            return "locked"
        }
        switch applicationState {
        case .active:
            return "foreground"
        case .background:
            return "background"
        case .inactive:
            return "inactive"
        @unknown default:
            return "unknown"
        }
    }
}

extension PTTViewModel {
    func resolvedSystemSessionContactID() -> UUID? {
        if let activeContactID = pttCoordinator.state.activeContactID {
            return activeContactID
        }
        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID else { return nil }
        return contactId(for: systemChannelUUID)
    }

    func resolvedSystemSessionBackendChannelID() -> String? {
        guard let contactID = resolvedSystemSessionContactID() else { return nil }
        return contacts.first(where: { $0.id == contactID })?.backendChannelId
    }

    private var shouldArmWakeFlowForIncomingPush: Bool {
        currentApplicationState() != .active
    }

    func resumeWebSocketForIncomingPTTPushIfNeeded(
        backendServices: BackendServices,
        contactID: UUID,
        channelUUID: UUID,
        payload: TurboPTTPushPayload
    ) {
        guard backendServices.supportsWebSocket else { return }
        diagnostics.record(
            .websocket,
            message: "Resuming WebSocket for incoming PTT push",
            metadata: [
                "contactId": contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "webSocketConnected": String(backendServices.isWebSocketConnected),
            ]
        )
        backendServices.resumeWebSocket()
    }

    var pttSystemCallbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.handleReceivedEphemeralPushToken(token)
            },
            receivedIncomingPush: { [weak self] channelUUID, payload in
                self?.handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
            },
            willReturnIncomingPushResult: { [weak self] channelUUID, payload, result in
                self?.handleWillReturnIncomingPushResult(
                    channelUUID: channelUUID,
                    payload: payload,
                    result: result
                )
            },
            didJoinChannel: { [weak self] channelUUID, reason in
                self?.handleDidJoinChannel(channelUUID, reason: reason)
            },
            didLeaveChannel: { [weak self] channelUUID, reason in
                self?.handleDidLeaveChannel(channelUUID, reason: reason)
            },
            failedToJoinChannel: { [weak self] channelUUID, error in
                self?.handleFailedToJoinChannel(channelUUID, error: error)
            },
            failedToLeaveChannel: { [weak self] channelUUID, error in
                self?.handleFailedToLeaveChannel(channelUUID, error: error)
            },
            didBeginTransmitting: { [weak self] channelUUID, source in
                self?.handleDidBeginTransmitting(channelUUID, source: source)
            },
            didEndTransmitting: { [weak self] channelUUID, source in
                self?.handleDidEndTransmitting(channelUUID, source: source)
            },
            failedToBeginTransmitting: { [weak self] channelUUID, error in
                self?.handleFailedToBeginTransmitting(channelUUID, error: error)
            },
            failedToStopTransmitting: { [weak self] channelUUID, error in
                self?.handleFailedToStopTransmitting(channelUUID, error: error)
            },
            didActivateAudioSession: { [weak self] audioSession in
                self?.handleDidActivateAudioSession(audioSession)
            },
            didDeactivateAudioSession: { [weak self] audioSession in
                self?.handleDidDeactivateAudioSession(audioSession)
            },
            willRequestRestoredChannelDescriptor: { [weak self] channelUUID in
                self?.handleWillRequestRestoredChannelDescriptor(channelUUID)
            },
            descriptorForRestoredChannel: { [weak self] channelUUID in
                self?.channelDescriptorForRestoredChannel(channelUUID)
                    ?? PTChannelDescriptor(name: "Restored session", image: nil)
            },
            restoredChannel: { [weak self] channelUUID in
                self?.handleRestoredChannel(channelUUID)
            }
        )
    }

    func handleReceivedEphemeralPushToken(_ token: Data) {
        let tokenHex = PTTSystemDisplayPolicy.pushTokenHex(from: token)
        let backendChannelID = resolvedSystemSessionBackendChannelID()
        pushTokenHex = tokenHex
        diagnostics.record(
            .pushToTalk,
            message: "Received ephemeral PTT token",
            metadata: [
                "backendChannelId": backendChannelID ?? "none",
                "tokenPrefix": String(tokenHex.prefix(8)),
                "activeContactId": activeChannelId?.uuidString ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
            ]
        )
        Task {
            await pttSystemPolicyCoordinator.handle(
                .ephemeralTokenReceived(tokenHex: tokenHex, backendChannelID: backendChannelID)
            )
            syncPTTSystemPolicyState()
            captureDiagnosticsState("ptt-callback:token")
        }
    }

    @discardableResult
    func resolveRestoredSystemSessionIfPossible(trigger: String) async -> UUID? {
        guard case .mismatched(let channelUUID) = pttCoordinator.state.systemSessionState else {
            return nil
        }
        guard let contactID = contactId(for: channelUUID),
              let contact = contacts.first(where: { $0.id == contactID }) else {
            return nil
        }

        if !isRestoredSystemSessionQuarantined(channelUUID: channelUUID) {
            markRestoredSystemSessionQuarantined(
                channelUUID: channelUUID,
                reason: "resolve-restored-channel"
            )
        }
        if selectedContactId == nil {
            selectContact(
                contact,
                reason: "restored-system-session",
                opensIncomingBeepSurface: false
            )
        }
        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactID))
        syncPTTState()
        diagnostics.record(
            .pushToTalk,
            message: "Resolved restored PTT channel contact without live transmit authority",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "trigger": trigger,
            ]
        )
        if pttSystemClient.isReady {
            syncPTTSystemChannelDescriptor(channelUUID, reason: "resolved-restored-channel")
            syncPTTTransmissionMode(reason: "resolved-restored-channel")
            syncPTTServiceStatus(reason: "resolved-restored-channel")
        }
        if let backendChannelID = contact.backendChannelId {
            await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
            syncPTTSystemPolicyState()
        }
        captureDiagnosticsState("ptt-callback:restored-resolved")
        return contactID
    }

    func clearUnresolvedRestoredSystemSessionIfNeeded(trigger: String) {
        guard case .mismatched(let channelUUID) = pttCoordinator.state.systemSessionState else {
            return
        }
        guard contactId(for: channelUUID) == nil else { return }

        diagnostics.recordInvariantViolation(
            invariantID: "ptt.restored_channel_without_backend_contact",
            scope: .local,
            message: "restored PTT channel has no contact after authoritative backend refresh",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "trigger": trigger,
                "selectedContactId": selectedContactId?.uuidString ?? "none",
                "contactCount": "\(contacts.count)",
            ]
        )
        diagnostics.record(
            .pushToTalk,
            message: "Clearing unresolved restored PTT channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "trigger": trigger,
            ]
        )

        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        clearRestoredSystemSessionQuarantine(
            channelUUID: channelUUID,
            reason: "restored-unresolved-cleared"
        )
        pttCoordinator.reset()
        syncPTTState()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        statusMessage = selectedContact == nil ? "Ready to connect" : "Disconnected"
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:restored-unresolved-cleared")
    }

    func handleWillReturnIncomingPushResult(
        channelUUID: UUID,
        payload: TurboPTTPushPayload,
        result: String
    ) {
        let contactID =
            contactId(for: channelUUID)
            ?? contacts.first(where: { $0.backendChannelId == payload.channelId })?.id
        if payload.event == .transmitStart,
           result == "activeRemoteParticipant",
           let contactID {
            pttWakeRuntime.beginTiming(
                contactID: contactID,
                channelUUID: channelUUID,
                channelID: payload.channelId,
                source: "incoming-push-result"
            )
            recordWakeReceiveTiming(
                stage: "incoming-push-result-active-participant-returned",
                contactID: contactID,
                channelUUID: channelUUID,
                channelID: payload.channelId,
                subsystem: .pushToTalk,
                metadata: [
                    "event": payload.event.rawValue,
                    "result": result,
                    "senderDeviceId": payload.senderDeviceId ?? "none",
                ],
                ifAbsent: true
            )
        }
        diagnostics.record(
            .pushToTalk,
            message: "Returning incoming PTT push result",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "result": result,
                "applicationState": String(describing: UIApplication.shared.applicationState),
                "contactId": contactID?.uuidString ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
            ]
        )
    }

    func handleReceivedIncomingPTTPush(channelUUID: UUID, payload: TurboPTTPushPayload) {
        let contactID =
            contactId(for: channelUUID)
            ?? contacts.first(where: { $0.backendChannelId == payload.channelId })?.id

        let incomingPushBoundaryMetadata =
            TurboIncomingPTTPushBoundaryDiagnostics.metadata(
                applicationState: currentApplicationState(),
                protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
            )
        diagnostics.record(
            .pushToTalk,
            message: "Incoming PTT push received",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "channelId": payload.channelId ?? "none",
                "activeSpeaker": payload.activeSpeaker ?? "none",
                "senderDeviceId": payload.senderDeviceId ?? "none",
            ].merging(incomingPushBoundaryMetadata) { existing, _ in existing }
        )
        sendTelemetryEvent(
            eventName: "ios.ptt.incoming_push_received",
            severity: .notice,
            reason: payload.event.rawValue,
            message: "Incoming PTT push received",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "activeSpeaker": payload.activeSpeaker ?? "none",
                "senderDeviceId": payload.senderDeviceId ?? "none",
            ],
            peerHandle: payload.activeSpeaker,
            channelId: payload.channelId
        )

        guard let contactID else {
            captureDiagnosticsState("ptt-callback:incoming-push-unmatched")
            return
        }

        if shouldArmWakeFlowForIncomingPush,
           payload.event == .transmitStart,
           pttWakeRuntime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: payload
           ) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored duplicate incoming PTT push while wake is already pending",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "event": payload.event.rawValue,
                ]
            )
            captureDiagnosticsState("ptt-callback:incoming-push-duplicate")
            return
        }

        switch payload.event {
        case .transmitStart:
            pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
            markRemoteAudioActivity(for: contactID, source: .incomingPush)
            if shouldArmWakeFlowForIncomingPush {
                if pttWakeRuntime.hasPendingWake(for: contactID) {
                    pttWakeRuntime.confirmIncomingPush(for: channelUUID, payload: payload)
                } else {
                    pttWakeRuntime.store(
                        PendingIncomingPTTPush(
                            contactID: contactID,
                            channelUUID: channelUUID,
                            payload: payload,
                            hasConfirmedIncomingPush: true,
                            activationState: .awaitingSystemActivation
                        )
                    )
                }
                recordWakeReceiveTiming(
                    stage: "incoming-push-confirmed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    channelID: payload.channelId,
                    subsystem: .pushToTalk,
                    metadata: [
                        "event": payload.event.rawValue,
                        "senderDeviceId": payload.senderDeviceId ?? "none",
                    ],
                    ifAbsent: true
                )
                pttWakeRuntime.clearPlaybackFallbackTask(for: contactID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Awaiting system PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
                scheduleWakePlaybackFallback(for: contactID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Reinforcing active remote participant during incoming push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "participant": payload.participantName,
                    ]
                )
                Task { [weak self] in
                    await self?.reinforceIncomingPushRemoteParticipant(
                        channelUUID: channelUUID,
                        contactID: contactID,
                        payload: payload
                    )
                }
            } else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored foreground wake flow for incoming PTT push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
                pttWakeRuntime.clear(for: contactID)
                Task { [weak self] in
                    await self?.prepareForegroundReceivePathForIncomingPush(contactID: contactID)
                }
            }
            if selectedContactId == nil {
                selectedContactId = contactID
            }
        case .leaveChannel:
            let devicePTTEvidenceTouchesContact =
                devicePTTEvidenceExists(for: contactID)
                || mediaSessionContactID == contactID
            if devicePTTEvidenceTouchesContact,
               !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                conversationActionCoordinator.markExplicitLeave(contactID: contactID)
                backendRuntime.clearBackendJoinSettling(for: contactID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Armed explicit leave barrier for incoming PTT leave push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
            }
            pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)
            clearRemoteAudioActivity(for: contactID)
            pttWakeRuntime.clear(for: contactID)
        }

        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:incoming-push")

        if shouldArmWakeFlowForIncomingPush {
            switch payload.event {
            case .transmitStart:
                if let backendServices,
                   backendServices.supportsWebSocket {
                    resumeWebSocketForIncomingPTTPushIfNeeded(
                        backendServices: backendServices,
                        contactID: contactID,
                        channelUUID: channelUUID,
                        payload: payload
                    )
                }
                diagnostics.record(
                    .pushToTalk,
                    message: "Deferring incoming-push backend sync until PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
            case .leaveChannel:
                diagnostics.record(
                    .pushToTalk,
                    message: "Synchronizing backend state for incoming PTT leave push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
                Task { [weak self] in
                    await self?.refreshChannelState(for: contactID)
                    await self?.refreshContactSummaries()
                    await self?.reconcileSelectedConversationIfNeeded()
                    self?.captureDiagnosticsState("ptt-callback:incoming-leave-push-sync")
                }
            }
        }
    }

    private func prepareForegroundReceivePathForIncomingPush(contactID: UUID) async {
        guard currentApplicationState() == .active else { return }
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Preparing foreground receive path from incoming PTT push",
            metadata: ["contactId": contactID.uuidString]
        )
        await reassertBackendJoinAfterWakeIfNeeded(for: contactID)
        await prewarmLocalMediaIfNeeded(for: contactID, applicationState: .active)
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .incomingPushForeground
        )
    }

    private func reinforceIncomingPushRemoteParticipant(
        channelUUID: UUID,
        contactID: UUID,
        payload: TurboPTTPushPayload
    ) async {
        do {
            let didApplySystemParticipant = try await setSystemActiveRemoteParticipant(
                name: payload.participantName,
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "incoming-push-reinforcement"
            )
            guard didApplySystemParticipant else { return }
            diagnostics.record(
                .pushToTalk,
                message: "Reinforced active remote participant from incoming push",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "participant": payload.participantName,
                ]
            )
        } catch {
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Deferred incoming-push participant reinforcement until system channel is available",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "participant": payload.participantName,
                        "error": error.localizedDescription,
                    ]
                )
                return
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Failed to reinforce active remote participant from incoming push",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "participant": payload.participantName,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func handleDidJoinChannel(_ channelUUID: UUID, reason: String) {
        let contactID = contactId(for: channelUUID)
        if contactID == nil,
           isRestoredSystemSessionQuarantined(channelUUID: channelUUID) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring unresolved restored PTT join",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "applicationState": String(describing: currentApplicationState()),
                    "systemSession": String(describing: pttCoordinator.state.systemSessionState),
                ]
            )
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            pttCoordinator.send(
                .didLeaveChannel(
                    channelUUID: channelUUID,
                    contactID: nil,
                    reason: "unresolved-restored-did-join",
                    autoRejoinContactID: nil,
                    shouldPropagateBackendLeave: false
                )
            )
            clearRestoredSystemSessionQuarantine(
                channelUUID: channelUUID,
                reason: "unresolved-restored-did-join"
            )
            syncPTTState()
            statusMessage = selectedContact == nil ? "Ready to connect" : "Disconnected"
            captureDiagnosticsState("ptt-callback:joined-unresolved-restored-ignored")
            return
        }
        if let staleSystemRejoinSuppression = consumeStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID
        ) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring stale PTT join after recent system leave",
                metadata: [
                    "contactId": staleSystemRejoinSuppression.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "suppressionReason": staleSystemRejoinSuppression.reason,
                ]
            )
            markLocalOnlySystemLeave(
                channelUUID: channelUUID,
                contactID: staleSystemRejoinSuppression.contactID,
                reason: "stale-join-after-recent-system-leave"
            )
            conversationActionCoordinator.clearRejectedLocalJoin(
                for: staleSystemRejoinSuppression.contactID
            )
            cancelSelectedConnectionAttemptTimeout()
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Disconnecting..."
            captureDiagnosticsState("ptt-callback:joined-blocked-by-recent-system-leave")
            return
        }
        if let contactID,
           conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring stale PTT join while explicit leave is in flight",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                ]
            )
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Disconnecting..."
            captureDiagnosticsState("ptt-callback:joined-blocked-by-leave")
            return
        }

        if let contactID,
           shouldIgnoreDidJoinAfterBackendMembershipLoss(contactID: contactID) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring stale PTT join after backend membership loss",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    "backendChannelStatus": backendSyncCoordinator.state.syncState.channelStates[contactID]?.status ?? "none",
                ]
            )
            markLocalOnlySystemLeave(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "stale-join-after-backend-membership-loss"
            )
            conversationActionCoordinator.clearRejectedLocalJoin(for: contactID)
            cancelSelectedConnectionAttemptTimeout()
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Disconnecting..."
            captureDiagnosticsState("ptt-callback:joined-blocked-by-membership-loss")
            return
        }

        if shouldIgnoreDuplicateDidJoinForActiveChannel(channelUUID: channelUUID, contactID: contactID) {
            if let contactID,
               conversationActionCoordinator.pendingJoinContactID == contactID {
                conversationActionCoordinator.clearAfterSuccessfulJoin(for: contactID)
                updateStatusForSelectedContact()
                diagnostics.record(
                    .pushToTalk,
                    message: "Cleared pending local join after duplicate PTT join callback",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                    ]
                )
            }
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring duplicate PTT join for active channel",
                metadata: [
                    "contactId": contactID?.uuidString ?? "none",
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "systemSession": String(describing: pttCoordinator.state.systemSessionState),
                ]
            )
            captureDiagnosticsState("ptt-callback:joined-duplicate")
            return
        }

        Task {
            await pttCoordinator.handle(
                .didJoinChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reason
                ),
                afterStateUpdate: { [weak self] in
                    guard let self else { return }
                    self.clearRestoredSystemSessionQuarantine(
                        channelUUID: channelUUID,
                        reason: "did-join"
                    )
                    self.syncPTTState()
                    self.syncSelectedConversationProjection()
                    if let contactID {
                        self.clearDirectQuicFreshSessionGuards(
                            for: contactID,
                            reason: "ptt-did-join"
                        )
                        if self.conversationActionCoordinator.pendingJoinContactID == contactID {
                            self.conversationActionCoordinator.clearAfterSuccessfulJoin(for: contactID)
                            self.updateStatusForSelectedContact()
                            self.diagnostics.record(
                                .pushToTalk,
                                message: "Cleared pending local join after PTT join callback",
                                metadata: [
                                    "contactId": contactID.uuidString,
                                    "channelUUID": channelUUID.uuidString,
                                    "reason": reason,
                                ]
                            )
                        }
                        Task(priority: .userInitiated) { [weak self] in
                            await self?.prewarmLocalMediaIfNeeded(for: contactID)
                        }
                    }
                }
            )
            syncPTTSystemChannelDescriptor(channelUUID, reason: "did-join")
            syncPTTTransmissionMode(reason: "did-join")
            syncPTTServiceStatus(reason: "did-join")
            syncPTTAccessoryButtonEvents(reason: "did-join")
            diagnostics.record(
                .pushToTalk,
                message: "Joined channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": reason]
            )
            if let contactID {
                await retrySystemTransmitAfterStaleChannelRejoinIfNeeded(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: reason
                )
            }
            captureDiagnosticsState("ptt-callback:joined")
        }
    }

    func retrySystemTransmitAfterStaleChannelRejoinIfNeeded(
        contactID: UUID,
        channelUUID: UUID,
        reason: String
    ) async {
        guard pendingSystemTransmitRetryAfterRejoinByContactID[contactID] == channelUUID else {
            return
        }
        guard hasActiveTransmitPressIntent() else {
            pendingSystemTransmitRetryAfterRejoinByContactID[contactID] = nil
            diagnostics.record(
                .pushToTalk,
                message: "Skipped stale channel transmit retry after local release",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard let request = systemOriginatedTransmitRequest(for: channelUUID) else {
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Skipped stale channel transmit retry without request context",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }

        pendingSystemTransmitRetryAfterRejoinByContactID[contactID] = nil
        transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        diagnostics.record(
            .pushToTalk,
            message: "Retrying system transmit after stale channel rejoin",
            metadata: [
                "contactId": contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "channelId": request.backendChannelID,
                "reason": reason,
            ]
        )
        armPTTLocalTransmitAudioActivation(
            request: request,
            channelUUID: channelUUID,
            source: "stale-channel-rejoin-retry"
        )
        do {
            try pttSystemClient.beginTransmitting(channelUUID: channelUUID)
        } catch {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            clearPendingLocalPTTAudioActivation(
                channelUUID: channelUUID,
                source: "stale-channel-rejoin-retry-failed"
            )
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit retry after stale channel rejoin failed immediately",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "error": formatPTTError(error),
                ]
            )
            handleFailedToBeginTransmitting(channelUUID, error: error)
        }
    }

    func shouldIgnoreDidJoinAfterBackendMembershipLoss(contactID: UUID) -> Bool {
        guard !shouldPreservePendingLocalJoinDuringBackendJoinSettling(for: contactID) else {
            return false
        }
        guard conversationActionCoordinator.pendingAction.pendingJoinContactID != contactID,
              conversationActionCoordinator.pendingAction.pendingConnectContactID != contactID else {
            return false
        }

        return backendSyncCoordinator.state.syncState.channelStates[contactID]?.membership == .absent
    }

    func shouldIgnoreDuplicateDidJoinForActiveChannel(channelUUID: UUID, contactID: UUID?) -> Bool {
        let state = pttCoordinator.state
        guard state.isJoined,
              state.systemChannelUUID == channelUUID else {
            return false
        }
        guard !isRestoredSystemSessionQuarantined(channelUUID: channelUUID) else {
            return false
        }

        switch (state.activeContactID, contactID) {
        case (nil, nil):
            return true
        case (let activeContactID?, let contactID?):
            return activeContactID == contactID
        default:
            return false
        }
    }

    func handleDidLeaveChannel(_ channelUUID: UUID, reason: String) {
        handleDidLeaveChannel(channelUUID, reason: PTTSystemLeaveReason(rawDescription: reason))
    }

    func handleDidLeaveChannel(_ channelUUID: UUID, reason: PTTSystemLeaveReason) {
        let reasonDescription = reason.description
        let contactID = contactId(for: channelUUID)
        let localOnlySuppression = consumeLocalOnlySystemLeave(
            channelUUID: channelUUID,
            contactID: contactID
        )
        if let localOnlySuppression {
            diagnostics.record(
                .pushToTalk,
                message: "Suppressing backend leave for local-only system channel recovery",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": localOnlySuppression.contactID.uuidString,
                    "reason": localOnlySuppression.reason,
                    "leaveReason": reasonDescription,
                ]
            )
            if !reason.isUserInitiated,
               case .active(let activeContactID, let activeChannelUUID) = pttCoordinator.state.systemSessionState,
               activeContactID == localOnlySuppression.contactID,
               activeChannelUUID == channelUUID {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored stale local-only PTT leave after session restored",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "contactID": localOnlySuppression.contactID.uuidString,
                        "reason": localOnlySuppression.reason,
                        "leaveReason": reasonDescription,
                    ]
                )
                captureDiagnosticsState("ptt-callback:left-local-only-stale-ignored")
                return
            }
        }
        systemActiveRemoteParticipantNameByChannelUUID.removeValue(forKey: channelUUID)
        let autoRejoinContactID =
            localOnlySuppression == nil
            ? conversationActionCoordinator.autoRejoinContactID(afterLeaving: contactID)
            : nil
        let applicationState = currentApplicationState()
        let systemLeaveWasUserInitiated = reason.isUserInitiated
        let explicitLeaveWasPending =
            contactID.map { conversationActionCoordinator.pendingAction.isExplicitLeaveInFlight(for: $0) } ?? false
        let shouldTreatLocalSystemLeaveAsExplicitTeardown: Bool = {
            guard applicationState == .active else {
                return false
            }
            guard autoRejoinContactID == nil,
                  let contactID,
                  !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
                return false
            }

            switch pttCoordinator.state.systemSessionState {
            case .active(let activeContactID, let activeChannelUUID):
                return activeChannelUUID == channelUUID && activeContactID == contactID
            case .none, .mismatched:
                return false
            }
        }()
        let shouldPropagateBackendLeave =
            (autoRejoinContactID != nil && autoRejoinContactID != contactID)
            || explicitLeaveWasPending
            || shouldTreatLocalSystemLeaveAsExplicitTeardown
            || contactID.map { reconciledTeardownRequiresBackendLeave(for: $0) } == true
        let shouldTreatBackgroundSystemLeaveAsLocalInterruption =
            applicationState != .active
            && !systemLeaveWasUserInitiated
            && !explicitLeaveWasPending
            && !shouldPropagateBackendLeave
        if applicationState != .active,
           systemLeaveWasUserInitiated,
           !explicitLeaveWasPending,
           !shouldPropagateBackendLeave {
            diagnostics.record(
                .pushToTalk,
                message: "Treating background PTT leave as local-only continuity interruption",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID?.uuidString ?? "none",
                    "leaveReason": reasonDescription,
                    "applicationState": String(describing: applicationState),
                ]
            )
        }
        if shouldTreatBackgroundSystemLeaveAsLocalInterruption,
           let contactID {
            markStaleSystemRejoinSuppression(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "background-system-leave"
            )
            conversationActionCoordinator.clearPendingJoin(for: contactID)
            cancelSelectedConnectionAttemptTimeout()
            diagnostics.record(
                .pushToTalk,
                message: "Treating background system PTT leave as local-only continuity interruption",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "leaveReason": reasonDescription,
                    "applicationState": String(describing: applicationState),
                ]
            )
        }
        if let contactID,
           autoRejoinContactID == nil,
           (shouldPropagateBackendLeave || conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)) {
            markStaleSystemRejoinSuppression(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "recent-system-leave"
            )
        }
        Task {
            if shouldTreatLocalSystemLeaveAsExplicitTeardown {
                conversationActionCoordinator.markExplicitLeave(contactID: contactID)
            }
            await pttCoordinator.handle(
                .didLeaveChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reasonDescription,
                    autoRejoinContactID: autoRejoinContactID,
                    shouldPropagateBackendLeave: shouldPropagateBackendLeave
                ),
                afterStateUpdate: { [weak self] in
                    guard let self else { return }
                    if (shouldTreatLocalSystemLeaveAsExplicitTeardown || explicitLeaveWasPending)
                        && !shouldPropagateBackendLeave {
                        self.conversationActionCoordinator.clearExplicitLeave(for: contactID)
                    }
                    if let contactID,
                       self.conversationActionCoordinator.pendingAction.pendingTeardownContactID == contactID,
                       !shouldPropagateBackendLeave {
                        self.conversationActionCoordinator.clearLeaveAction(for: contactID)
                    }
                    if let contactID,
                       !self.conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                        self.replaceDisconnectRecoveryTask(with: nil)
                    }
                    self.syncPTTState()
                    self.reconcileLiveConversationActivity()
                }
            )
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
            lastReportedPTTTransmissionMode = nil
            lastReportedPTTTransmissionModeChannelUUID = nil
            lastReportedPTTTransmissionModeReason = nil
            diagnostics.record(
                .pushToTalk,
                message: "Left channel",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "reason": reasonDescription,
                    "applicationState": String(describing: applicationState),
                    "systemLeaveWasUserInitiated": String(systemLeaveWasUserInitiated),
                ]
            )
            captureDiagnosticsState("ptt-callback:left")
        }
    }

    func handleFailedToJoinChannel(_ channelUUID: UUID, error: any Error) {
        let contactID = contactId(for: channelUUID)
        let joinFailure = classifyPTTJoinFailure(error)
        if joinFailure == .channelLimitReached,
           let contactID {
            diagnostics.record(
                .pushToTalk,
                message: "System join hit stale channel limit; rejoining",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "error": joinFailure.message,
                ]
            )
            recoverStaleSystemChannel(
                for: channelUUID,
                contactID: contactID,
                reason: "join-failed-channel-limit"
            )
            return
        }
        Task {
            await pttCoordinator.handle(
                .failedToJoinChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: joinFailure
                )
            )
            if let contactID {
                conversationActionCoordinator.clearPendingJoin(for: contactID)
                backendRuntime.clearBackendJoinSettling(for: contactID)
            }
            syncPTTState()
            updateStatusForSelectedContact()
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Join failed",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID?.uuidString ?? "none",
                    "error": joinFailure.message,
                    "recovery": joinFailure.recoveryMessage
                ]
            )
            captureDiagnosticsState("ptt-callback:join-failed")
        }
    }

    func handleFailedToLeaveChannel(_ channelUUID: UUID, error: any Error) {
        let message = formatPTTError(error)
        Task {
            if shouldSuppressStaleLeaveFailure(for: channelUUID) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored stale PTT leave failure after teardown completed",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "error": message,
                    ]
                )
                captureDiagnosticsState("ptt-callback:leave-failed-stale-ignored")
                return
            }
            await pttCoordinator.handle(.failedToLeaveChannel(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Leave failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Leave failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:leave-failed")
        }
    }

    private func shouldSuppressStaleLeaveFailure(for channelUUID: UUID) -> Bool {
        let systemStillTracksChannel: Bool
        switch systemSessionState {
        case .active(_, let activeChannelUUID), .mismatched(let activeChannelUUID):
            systemStillTracksChannel = activeChannelUUID == channelUUID
        case .none:
            systemStillTracksChannel = false
        }
        guard !systemStillTracksChannel else { return false }
        guard !conversationActionCoordinator.pendingAction.hasAnyLeaveInFlight else { return false }
        return true
    }

    func handleDidBeginTransmitting(_ channelUUID: UUID, source: String) {
        Task {
            let hadPendingSystemBegin = transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID)
            guard !transmitRuntime.isSystemTransmitting || hadPendingSystemBegin else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored duplicate system transmit begin callback",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                    ]
                )
                return
            }
            let callbackTarget = activeTransmitTarget(for: channelUUID)
            let beginOrigin = SystemTransmitBeginOrigin.classify(
                applicationIsActive: currentApplicationState() == .active,
                hadPendingSystemBegin: hadPendingSystemBegin,
                hasCallbackTarget: callbackTarget != nil,
                hasPendingLifecycle: hasPendingTransmitLifecycle(for: channelUUID),
                runtimeIsPressingTalk: transmitRuntime.isPressingTalk,
                coordinatorIsPressingTalk: transmitCoordinator.state.isPressingTalk,
                hasPendingBeginOrActiveTransmit: hasPendingBeginOrActiveTransmit
            )
            if await rejectSystemTransmitBeginIfPeerIsActive(
                channelUUID: channelUUID,
                source: source,
                origin: beginOrigin,
                callbackTarget: callbackTarget
            ) {
                return
            }
            if await rejectForegroundSystemTransmitBeginWithoutLocalIntentIfNeeded(
                channelUUID: channelUUID,
                source: source,
                origin: beginOrigin,
                callbackTarget: callbackTarget
            ) {
                return
            }
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            transmitRuntime.noteSystemTransmitBegan()
            if let callbackTarget {
                armPTTLocalTransmitAudioActivation(
                    channelUUID: channelUUID,
                    target: callbackTarget,
                    source: "ptt-system-began:\(source)"
                )
            } else if let pendingRequest = transmitCoordinator.state.pendingRequest,
                      pendingRequest.channelUUID == channelUUID {
                armPTTLocalTransmitAudioActivation(
                    request: pendingRequest,
                    channelUUID: channelUUID,
                    source: "ptt-system-began:\(source)"
                )
            }
            systemTransmitBeginRecoveryAttemptsByChannelUUID.removeValue(forKey: channelUUID)
            await pttCoordinator.handle(
                .didBeginTransmitting(
                    channelUUID: channelUUID,
                    origin: beginOrigin
                )
            )
            if let callbackTarget {
                syncEngineSystemTransmitBegan(
                    target: callbackTarget,
                    source: "ptt-system-began"
                )
            }
            if callbackTarget == nil, beginOrigin.isSystemOriginated {
                await handleSystemOriginatedBeginTransmitIfNeeded(
                    channelUUID: channelUUID,
                    source: source,
                    origin: beginOrigin
                )
            }
            syncPTTState()
            recordTransmitStartupTiming(
                stage: "system-transmit-began",
                contactID: callbackTarget?.contactID ?? contactId(for: channelUUID),
                channelUUID: channelUUID,
                channelID: callbackTarget?.channelID,
                subsystem: .pushToTalk,
                metadata: ["callbackSource": source]
            )
            diagnostics.record(
                .pushToTalk,
                message: "System transmit began",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "origin": beginOrigin.rawValue,
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                    "activeContactId": (callbackTarget?.contactID ?? contactId(for: channelUUID))?.uuidString ?? "none",
                    "activeChannelId": callbackTarget?.channelID ?? "none",
                    "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                    "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                    "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                    "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                    "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.transmit.system_began",
                severity: .notice,
                reason: source,
                message: "System transmit began",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "origin": beginOrigin.rawValue,
                    "activeContactId": (callbackTarget?.contactID ?? contactId(for: channelUUID))?.uuidString ?? "none",
                    "activeChannelId": callbackTarget?.channelID ?? "none",
                    "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                ],
                channelId: callbackTarget?.channelID
            )
            if isPTTAudioSessionActive, let callbackTarget {
                if ensurePTTAudioSessionIsOwnedByLocalTransmit(
                    channelUUID: channelUUID,
                    target: callbackTarget,
                    stage: "system-transmit-began"
                ) {
                    syncEnginePTTAudioActivated(
                        contactID: callbackTarget.contactID,
                        channelID: callbackTarget.channelID,
                        source: "system-transmit-began"
                    )
                    await completeSystemTransmitActivation(channelUUID: channelUUID)
                }
            }
            scheduleAppleGatedAudioActivationTimeoutAfterSystemBeginIfNeeded(
                channelUUID: channelUUID,
                source: source
            )
            captureDiagnosticsState("ptt-callback:transmit-began")
        }
    }

    func rejectForegroundSystemTransmitBeginWithoutLocalIntentIfNeeded(
        channelUUID: UUID,
        source: String,
        origin: SystemTransmitBeginOrigin,
        callbackTarget: TransmitTarget?
    ) async -> Bool {
        guard callbackTarget == nil else { return false }
        guard origin.isRejectedForegroundUnownedBegin else { return false }

        let contactID = contactId(for: channelUUID)
        diagnostics.recordInvariantViolation(
            invariantID: "ptt.foreground_system_begin_without_local_press",
            scope: .local,
            message: "foreground system-originated transmit begin arrived without a local hold or pending transmit lifecycle",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "source": source,
                "origin": origin.rawValue,
                "applicationState": String(describing: currentApplicationState()),
                "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
            ]
        )
        diagnostics.record(
            .pushToTalk,
            message: "Rejected foreground system transmit begin without local hold",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "source": source,
                "origin": origin.rawValue,
            ]
        )
        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        transmitRuntime.markPressEnded()
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        await transmitCoordinator.handle(.systemEnded)
        syncTransmitState()
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:transmit-began-rejected-foreground-unowned")
        return true
    }

    private func rejectSystemTransmitBeginIfPeerIsActive(
        channelUUID: UUID,
        source: String,
        origin: SystemTransmitBeginOrigin,
        callbackTarget: TransmitTarget?
    ) async -> Bool {
        guard callbackTarget == nil else { return false }
        guard let contactID = contactId(for: channelUUID) else { return false }

        let channelSnapshot = selectedChannelSnapshot(for: contactID)
        let backendPeerIsTransmitting = channelSnapshot?.readinessStatus?.conversationState == .receiving
            || channelSnapshot?.status == .receiving
        let remoteActivityBlocksTransmit = remoteReceiveBlocksLocalTransmit(for: contactID)
        guard backendPeerIsTransmitting || remoteActivityBlocksTransmit else { return false }

        diagnostics.recordInvariantViolation(
            invariantID: "ptt.system_begin_while_peer_transmitting",
            scope: .local,
            message: "system-originated transmit begin was rejected because peer transmit is authoritative",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID.uuidString,
                "source": source,
                "origin": origin.rawValue,
                "backendChannelStatus": channelSnapshot?.status?.rawValue ?? "none",
                "backendReadiness": channelSnapshot?.readinessStatus?.kind ?? "none",
                "backendCanTransmit": String(channelSnapshot?.canTransmit ?? false),
                "backendPeerIsTransmitting": String(backendPeerIsTransmitting),
                "remoteActivityBlocksTransmit": String(remoteActivityBlocksTransmit),
            ]
        )
        diagnostics.record(
            .pushToTalk,
            message: "Rejected system transmit begin while peer is active",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID.uuidString,
                "source": source,
                "origin": origin.rawValue,
                "backendChannelStatus": channelSnapshot?.status?.rawValue ?? "none",
                "backendReadiness": channelSnapshot?.readinessStatus?.kind ?? "none",
                "backendCanTransmit": String(channelSnapshot?.canTransmit ?? false),
                "backendPeerIsTransmitting": String(backendPeerIsTransmitting),
                "remoteActivityBlocksTransmit": String(remoteActivityBlocksTransmit),
            ]
        )

        systemTransmitBeginRecoveryAttemptsByChannelUUID.removeValue(forKey: channelUUID)
        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        transmitRuntime.markPressEnded()
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        await transmitCoordinator.handle(.systemEnded)
        syncTransmitState()
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:transmit-began-rejected-peer-active")
        return true
    }

    func handleDidEndTransmitting(_ channelUUID: UUID, source: String) {
        Task {
            let matchingActiveTarget = activeTransmitTarget(for: channelUUID)
            let hasPendingLifecycle = hasPendingTransmitLifecycle(for: channelUUID)
            let runtimeHadSystemLifecycle = transmitRuntime.hasSystemTransmitLifecycle
            let systemWasTransmitting =
                pttCoordinator.state.isTransmitting
                && pttCoordinator.state.systemChannelUUID == channelUUID
            let transmitDurationMilliseconds = transmitRuntime.currentSystemTransmitDurationMilliseconds()
            let applicationState = currentApplicationState()
            guard runtimeHadSystemLifecycle || systemWasTransmitting else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored duplicate system transmit end callback",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                        "hasMatchingActiveTarget": String(matchingActiveTarget != nil),
                        "hasPendingLifecycle": String(hasPendingLifecycle),
                        "runtimeHadSystemLifecycle": String(runtimeHadSystemLifecycle),
                        "systemWasTransmitting": String(systemWasTransmitting),
                        "applicationState": String(describing: applicationState),
                    ]
                )
                return
            }
            let endOrigin = SystemTransmitEndOrigin.systemCallback(source: source)
            let endDisposition = transmitRuntime.handleSystemTransmitEnded(
                applicationStateIsActive: applicationState == .active,
                matchingActiveTarget: matchingActiveTarget
            )
            await pttCoordinator.handle(
                .didEndTransmitting(
                    channelUUID: channelUUID,
                    origin: endOrigin
                )
            )
            if let matchingActiveTarget {
                syncEngineSystemTransmitEnded(
                    target: matchingActiveTarget,
                    source: "ptt-system-ended"
                )
            }
            syncPTTState()
            recordTransmitStartupTiming(
                stage: "system-transmit-ended",
                contactID: matchingActiveTarget?.contactID ?? contactId(for: channelUUID),
                channelUUID: channelUUID,
                channelID: matchingActiveTarget?.channelID,
                subsystem: .pushToTalk,
                metadata: [
                    "callbackSource": source,
                    "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                ]
            )
            diagnostics.record(
                .pushToTalk,
                message: "System transmit ended",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "origin": endOrigin.kind,
                    "transmitPressActive": String(transmitRuntime.isPressingTalk),
                    "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                    "hasMatchingActiveTarget": String(matchingActiveTarget != nil),
                    "hasPendingLifecycle": String(hasPendingLifecycle),
                    "runtimeHadSystemLifecycle": String(runtimeHadSystemLifecycle),
                    "systemWasTransmitting": String(systemWasTransmitting),
                    "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                    "applicationState": String(describing: applicationState),
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                    "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                    "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                    "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                    "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                    "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                    "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.transmit.system_ended",
                severity: .notice,
                reason: source,
                message: "System transmit ended",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "origin": endOrigin.kind,
                    "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                    "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                    "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                ],
                channelId: matchingActiveTarget?.channelID
            )
            recordTransmitStartupTimingSummary(
                reason: "system-transmit-ended",
                contactID: matchingActiveTarget?.contactID ?? contactId(for: channelUUID),
                channelUUID: channelUUID,
                channelID: matchingActiveTarget?.channelID,
                metadata: [
                    "callbackSource": source,
                    "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                ]
            )
            switch endDisposition {
            case .implicitRelease:
                diagnostics.record(
                    .pushToTalk,
                    message: "Treating background system transmit end as implicit release",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                        "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                        "applicationState": String(describing: applicationState),
                        "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                        "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                        "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                        "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                        "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                        "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                        "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                    ]
                )
            case .requireFreshPress:
                diagnostics.record(
                    .pushToTalk,
                    message: "Unexpected system transmit end requires fresh press",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                        "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                        "applicationState": String(describing: applicationState),
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                        "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                        "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                        "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                        "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                        "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                        "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                    ]
                )
                syncTransmitState()
            case .none:
                break
            }
            if hasPendingLifecycle {
                await transmitCoordinator.handle(.systemEnded)
                syncTransmitState()
            }
            captureDiagnosticsState("ptt-callback:transmit-ended")
        }
    }

    func handleFailedToBeginTransmitting(_ channelUUID: UUID, error: any Error) {
        if isRecoverablePTTTransmissionInProgress(error),
           let contactID = contactId(for: channelUUID),
           transmitRuntime.isPressingTalk,
            systemTransmitBeginRecoveryAttemptsByChannelUUID[channelUUID, default: 0] == 0 {
            let channelSnapshot = selectedChannelSnapshot(for: contactID)
            let backendPeerIsTransmitting = channelSnapshot?.readinessStatus?.conversationState == .receiving
                || channelSnapshot?.status == .receiving
            let remoteActivityBlocksTransmit = remoteReceiveBlocksLocalTransmit(for: contactID)
            if backendPeerIsTransmitting || remoteActivityBlocksTransmit {
                systemTransmitBeginRecoveryAttemptsByChannelUUID.removeValue(forKey: channelUUID)
                transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
                transmitRuntime.markPressEnded()
                cancelPendingTransmitWork()
                diagnostics.record(
                    .pushToTalk,
                    message: "Rejected system transmit begin failure retry while peer is active",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "contactId": contactID.uuidString,
                        "error": formatPTTError(error),
                        "backendChannelStatus": channelSnapshot?.status?.rawValue ?? "none",
                        "backendReadiness": channelSnapshot?.readinessStatus?.kind ?? "none",
                        "backendCanTransmit": String(channelSnapshot?.canTransmit ?? false),
                        "backendPeerIsTransmitting": String(backendPeerIsTransmitting),
                        "remoteActivityBlocksTransmit": String(remoteActivityBlocksTransmit),
                    ]
                )
                Task {
                    await transmitCoordinator.handle(.systemEnded)
                    syncTransmitState()
                    updateStatusForSelectedContact()
                    captureDiagnosticsState("ptt-callback:transmit-begin-failed-peer-active")
                }
                return
            }
            systemTransmitBeginRecoveryAttemptsByChannelUUID[channelUUID, default: 0] += 1
            diagnostics.record(
                .pushToTalk,
                message: "System transmit begin hit active remote participant; clearing and retrying",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "error": formatPTTError(error),
                ]
            )
            Task {
                await clearSystemRemoteParticipantBeforeLocalTransmit(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: "transmit-begin-transmission-in-progress"
                )
                guard transmitRuntime.isPressingTalk else {
                    diagnostics.record(
                        .pushToTalk,
                        message: "Skipped system transmit begin retry after local release",
                        metadata: ["channelUUID": channelUUID.uuidString]
                    )
                    return
                }
                transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
                if let target = activeTransmitTarget(for: channelUUID) {
                    armPTTLocalTransmitAudioActivation(
                        channelUUID: channelUUID,
                        target: target,
                        source: "transmit-begin-retry"
                    )
                } else if let contact = contacts.first(where: { $0.id == contactID }),
                          let backendChannelID = contact.backendChannelId {
                    armPTTAudioSessionActivation(
                        owner: .pendingLocalTransmit(
                            channelUUID: channelUUID,
                            contactID: contactID,
                            channelID: backendChannelID
                        ),
                        source: "transmit-begin-retry"
                    )
                }
                do {
                    try pttSystemClient.beginTransmitting(channelUUID: channelUUID)
                } catch {
                    clearPendingLocalPTTAudioActivation(
                        channelUUID: channelUUID,
                        source: "transmit-begin-retry-failed"
                    )
                    diagnostics.record(
                        .pushToTalk,
                        level: .error,
                        message: "System transmit begin retry failed immediately",
                        metadata: [
                            "channelUUID": channelUUID.uuidString,
                            "error": formatPTTError(error),
                        ]
                    )
                    handleFailedToBeginTransmitting(channelUUID, error: error)
                }
            }
            return
        }

        systemTransmitBeginRecoveryAttemptsByChannelUUID.removeValue(forKey: channelUUID)
        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        cancelPendingTransmitWork()
        if isRecoverablePTTChannelUnavailable(error),
           let contactID = contactId(for: channelUUID) {
            diagnostics.record(
                .pushToTalk,
                message: "System transmit begin hit stale channel; rejoining",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "error": formatPTTError(error)
                ]
            )
            recoverStaleSystemChannel(
                for: channelUUID,
                contactID: contactID,
                reason: "transmit-begin-failed"
            )
            return
        }
        let message = formatPTTError(error)
        Task {
            syncEngineSystemTransmitBeginFailed(message: message, source: "ptt-callback")
            await pttCoordinator.handle(.failedToBeginTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit begin failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:transmit-begin-failed")
        }
    }

    func handleFailedToStopTransmitting(_ channelUUID: UUID, error: any Error) {
        if isExpectedPTTStopFailure(error) && !pttCoordinator.state.isTransmitting {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring expected transmit stop failure",
                metadata: ["channelUUID": channelUUID.uuidString, "error": formatPTTError(error)]
            )
            captureDiagnosticsState("ptt-callback:transmit-stop-ignored")
            return
        }
        let message = formatPTTError(error)
        Task {
            await pttCoordinator.handle(.failedToStopTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Stop failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit stop failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:transmit-stop-failed")
        }
    }

    func handleRestoredChannel(_ channelUUID: UUID) {
        let contactID = contactId(for: channelUUID)
        markRestoredSystemSessionQuarantined(
            channelUUID: channelUUID,
            reason: "apple-restored-channel"
        )
        diagnostics.record(
            .pushToTalk,
            message: "Restored PTT channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )
        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactID))
        syncPTTState()
        if pttSystemClient.isReady {
            if contactID != nil {
                syncPTTSystemChannelDescriptor(channelUUID, reason: "restored-channel")
                syncPTTTransmissionMode(reason: "restored-channel")
                syncPTTServiceStatus(reason: "restored-channel")
                syncPTTAccessoryButtonEvents(reason: "restored-channel")
            } else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Skipped restored PTT channel policy sync for unresolved channel",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "reason": "restored-channel",
                    ]
                )
            }
        } else {
            diagnostics.record(
                .pushToTalk,
                message: "Deferred restored PTT channel policy sync until manager ready",
                metadata: ["channelUUID": channelUUID.uuidString]
            )
        }
        if let contactID {
            Task {
                if let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId {
                    await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
                    syncPTTSystemPolicyState()
                }
            }
        }
        captureDiagnosticsState("ptt-callback:restored")
    }

    func handleDidActivateAudioSession(_ audioSession: AVAudioSession) {
        isPTTAudioSessionActive = true
        let audioEpoch = notePTTAudioSessionActivatedForCurrentContext(source: "ptt-callback")
        transmitTaskRuntime.cancelCaptureReassertionTask()
        var metadata = audioSessionDiagnostics(audioSession)
        metadata.merge(
            [
                "applicationState": String(describing: UIApplication.shared.applicationState),
                "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                "pendingWakeContactId": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
            ],
            uniquingKeysWith: { _, new in new }
        )
        metadata.merge(audioEpoch.diagnosticsMetadata, uniquingKeysWith: { _, new in new })
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session activated",
            metadata: metadata
        )
        Task {
            await handleActivatedAudioSession(audioSession)
            captureDiagnosticsState("ptt-callback:audio-activated")
        }
    }

    func handleDidDeactivateAudioSession(_ audioSession: AVAudioSession) {
        let deactivatedEpoch = pttAudioSessionRuntime.deactivate()
        isPTTAudioSessionActive = false
        var metadata = audioSessionDiagnostics(audioSession)
        metadata.merge(
            [
                "applicationState": String(describing: UIApplication.shared.applicationState),
                "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                "pendingWakeContactId": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
            ],
            uniquingKeysWith: { _, new in new }
        )
        if let deactivatedEpoch {
            metadata.merge(deactivatedEpoch.diagnosticsMetadata, uniquingKeysWith: { _, new in new })
        }
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session deactivated",
            metadata: metadata
        )
        Task {
            await handleDeactivatedAudioSession(audioSession, deactivatedEpoch: deactivatedEpoch)
            captureDiagnosticsState("ptt-callback:audio-deactivated")
        }
    }

    func audioSessionDiagnostics(_ audioSession: AVAudioSession) -> [String: String] {
        let outputs = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let inputs = audioSession.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputNames = audioSession.currentRoute.outputs.map(\.portName).joined(separator: ",")
        let inputNames = audioSession.currentRoute.inputs.map(\.portName).joined(separator: ",")
        let availableInputs =
            audioSession.availableInputs?
                .map { "\($0.portName):\($0.portType.rawValue)" }
                .joined(separator: ",")
            ?? ""
        return [
            "category": audioSession.category.rawValue,
            "mode": audioSession.mode.rawValue,
            "categoryOptions": String(audioSession.categoryOptions.rawValue),
            "sampleRate": String(audioSession.sampleRate),
            "outputs": outputs.isEmpty ? "none" : outputs,
            "outputNames": outputNames.isEmpty ? "none" : outputNames,
            "inputs": inputs.isEmpty ? "none" : inputs,
            "inputNames": inputNames.isEmpty ? "none" : inputNames,
            "availableInputs": availableInputs.isEmpty ? "none" : availableInputs
        ]
    }

    func audioSessionDiagnostics() -> [String: String] {
        audioSessionDiagnostics(AVAudioSession.sharedInstance())
    }

    func handleWillRequestRestoredChannelDescriptor(_ channelUUID: UUID) {
        diagnostics.record(
            .pushToTalk,
            message: "PTT restored channel descriptor requested",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactId(for: channelUUID)?.uuidString ?? "none",
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )
    }

    func channelDescriptorForRestoredChannel(_ channelUUID: UUID) -> PTChannelDescriptor {
        let name = systemDescriptorName(for: channelUUID)
        // TODO: Return a cached per-channel image once we persist it locally.
        return PTChannelDescriptor(name: name, image: nil)
    }

    func debugInjectIncomingPTTPush(_ payload: TurboPTTPushPayload, channelUUID: UUID) {
        handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
    }
}
