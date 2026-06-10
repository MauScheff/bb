//
//  PTTViewModel+PTTActions.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import UIKit

extension PTTViewModel {
    struct LocalOnlySystemLeaveSuppression {
        let contactID: UUID
        let createdAt: Date
        let reason: String
    }

    struct StaleSystemRejoinSuppression {
        let contactID: UUID
        let createdAt: Date
        let reason: String
    }

    func markRestoredSystemSessionQuarantined(channelUUID: UUID, reason: String) {
        restoredSystemSessionQuarantineChannelUUIDs.insert(channelUUID)
        diagnostics.record(
            .pushToTalk,
            message: "Quarantined restored PTT session",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "reason": reason,
            ]
        )
    }

    func clearRestoredSystemSessionQuarantine(channelUUID: UUID, reason: String) {
        guard restoredSystemSessionQuarantineChannelUUIDs.remove(channelUUID) != nil else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Cleared restored PTT session quarantine",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "reason": reason,
            ]
        )
    }

    func isRestoredSystemSessionQuarantined(channelUUID: UUID) -> Bool {
        restoredSystemSessionQuarantineChannelUUIDs.contains(channelUUID)
    }

    func markLocalOnlySystemLeave(
        channelUUID: UUID,
        contactID: UUID,
        reason: String,
        now: Date = Date()
    ) {
        pruneExpiredLocalOnlySystemLeaveSuppressions(now: now)
        localOnlySystemLeaveSuppressions[channelUUID] = LocalOnlySystemLeaveSuppression(
            contactID: contactID,
            createdAt: now,
            reason: reason
        )
    }

    func consumeLocalOnlySystemLeave(
        channelUUID: UUID,
        contactID: UUID?,
        now: Date = Date()
    ) -> LocalOnlySystemLeaveSuppression? {
        pruneExpiredLocalOnlySystemLeaveSuppressions(now: now)
        guard let suppression = localOnlySystemLeaveSuppressions[channelUUID] else { return nil }
        guard contactID == nil || contactID == suppression.contactID else { return nil }
        localOnlySystemLeaveSuppressions[channelUUID] = nil
        return suppression
    }

    private func pruneExpiredLocalOnlySystemLeaveSuppressions(now: Date) {
        localOnlySystemLeaveSuppressions = localOnlySystemLeaveSuppressions.filter { _, suppression in
            now.timeIntervalSince(suppression.createdAt) < 10
        }
    }

    func markStaleSystemRejoinSuppression(
        channelUUID: UUID,
        contactID: UUID,
        reason: String,
        now: Date = Date()
    ) {
        pruneExpiredStaleSystemRejoinSuppressions(now: now)
        staleSystemRejoinSuppressions[channelUUID] = StaleSystemRejoinSuppression(
            contactID: contactID,
            createdAt: now,
            reason: reason
        )
    }

    func consumeStaleSystemRejoinSuppression(
        channelUUID: UUID,
        contactID: UUID?,
        now: Date = Date()
    ) -> StaleSystemRejoinSuppression? {
        pruneExpiredStaleSystemRejoinSuppressions(now: now)
        guard let suppression = staleSystemRejoinSuppressions[channelUUID] else { return nil }
        guard contactID == nil || contactID == suppression.contactID else { return nil }
        staleSystemRejoinSuppressions[channelUUID] = nil
        return suppression
    }

    func hasStaleSystemRejoinSuppression(
        channelUUID: UUID,
        contactID: UUID?,
        now: Date = Date()
    ) -> Bool {
        pruneExpiredStaleSystemRejoinSuppressions(now: now)
        guard let suppression = staleSystemRejoinSuppressions[channelUUID] else { return false }
        return contactID == nil || contactID == suppression.contactID
    }

    private func pruneExpiredStaleSystemRejoinSuppressions(now: Date) {
        staleSystemRejoinSuppressions = staleSystemRejoinSuppressions.filter { _, suppression in
            now.timeIntervalSince(suppression.createdAt) < 10
        }
    }

    func shouldBlockAppInitiatedPTTJoinInCurrentLifecycle(for contactID: UUID) -> Bool {
        guard currentApplicationState() != .active else { return false }
        guard !pttWakeRuntime.hasPendingWake(for: contactID),
              pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil else {
            return false
        }
        return true
    }

    func desiredPTTServiceStatus() -> PTServiceStatus? {
        guard pttCoordinator.state.systemChannelUUID != nil else { return nil }

        if usesLocalHTTPBackend {
            return .ready
        }

        guard backendRuntime.isReady else {
            return .unavailable
        }

        if currentApplicationState() != .active {
            return .ready
        }

        if shouldKeepForegroundPTTServiceReadyDuringControlPlaneReconnect() {
            return .ready
        }

        return backendRuntime.isWebSocketConnected ? .ready : .connecting
    }

    private func shouldKeepForegroundPTTServiceReadyDuringControlPlaneReconnect() -> Bool {
        guard backendRuntime.isReady else { return false }
        guard isJoined, pttCoordinator.state.isJoined else { return false }

        if transmitRuntime.isPressingTalk
            || transmitCoordinator.state.isPressingTalk
            || pttCoordinator.state.isTransmitting
            || hasPendingBeginOrActiveTransmit {
            return true
        }

        return selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity
    }

    func systemDescriptorName(for channelUUID: UUID) -> String {
        PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: contacts,
            fallbackName: channelName
        )
    }

    func syncPTTSystemChannelDescriptor(_ channelUUID: UUID, reason: String) {
        let descriptorName = systemDescriptorName(for: channelUUID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.updateChannelDescriptor(name: descriptorName, channelUUID: channelUUID)
                lastReportedPTTDescriptorName = descriptorName
                lastReportedPTTDescriptorChannelUUID = channelUUID
                lastReportedPTTDescriptorReason = reason
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT channel descriptor",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "name": descriptorName,
                        "reason": reason,
                    ]
                )
            } catch {
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT channel descriptor",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "name": descriptorName,
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTServiceStatus(reason: String, force: Bool = false) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
            return
        }

        guard let status = desiredPTTServiceStatus() else {
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
            return
        }

        guard force
            || lastReportedPTTServiceStatus != status
            || lastReportedPTTServiceStatusChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTServiceStatus = status
        lastReportedPTTServiceStatusChannelUUID = channelUUID
        lastReportedPTTServiceStatusReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setServiceStatus(status, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT service status",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "status": String(describing: status),
                        "reason": reason,
                    ]
                )
            } catch {
                if lastReportedPTTServiceStatusChannelUUID == channelUUID {
                    lastReportedPTTServiceStatus = nil
                    lastReportedPTTServiceStatusChannelUUID = nil
                    lastReportedPTTServiceStatusReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT service status",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "status": String(describing: status),
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTTransmissionMode(reason: String, force: Bool = false) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTTransmissionMode = nil
            lastReportedPTTTransmissionModeChannelUUID = nil
            lastReportedPTTTransmissionModeReason = nil
            return
        }

        let mode = PTTransmissionMode.halfDuplex
        guard force
            || lastReportedPTTTransmissionMode != mode
            || lastReportedPTTTransmissionModeChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTTransmissionMode = mode
        lastReportedPTTTransmissionModeChannelUUID = channelUUID
        lastReportedPTTTransmissionModeReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setTransmissionMode(mode, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT transmission mode",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "mode": String(describing: mode),
                        "reason": reason,
                        "applicationState": String(describing: UIApplication.shared.applicationState),
                    ]
                )
            } catch {
                if lastReportedPTTTransmissionModeChannelUUID == channelUUID {
                    lastReportedPTTTransmissionMode = nil
                    lastReportedPTTTransmissionModeChannelUUID = nil
                    lastReportedPTTTransmissionModeReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT transmission mode",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "mode": String(describing: mode),
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTAccessoryButtonEvents(reason: String, force: Bool = false) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTAccessoryButtonEventsChannelUUID = nil
            lastReportedPTTAccessoryButtonEventsReason = nil
            return
        }

        guard force || lastReportedPTTAccessoryButtonEventsChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTAccessoryButtonEventsChannelUUID = channelUUID
        lastReportedPTTAccessoryButtonEventsReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Enabled PTT accessory button events",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                    ]
                )
            } catch {
                if lastReportedPTTAccessoryButtonEventsChannelUUID == channelUUID {
                    lastReportedPTTAccessoryButtonEventsChannelUUID = nil
                    lastReportedPTTAccessoryButtonEventsReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to enable PTT accessory button events",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func reassertPTTTalkReadinessIfNeeded(for contactID: UUID, reason: String) {
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else { return }

        syncPTTSystemChannelDescriptor(channelUUID, reason: reason)
        syncPTTTransmissionMode(reason: reason, force: true)
        syncPTTServiceStatus(reason: reason, force: true)
        syncPTTAccessoryButtonEvents(reason: reason, force: true)
        diagnostics.record(
            .pushToTalk,
            message: "Reasserted PTT talk readiness",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID.uuidString,
                "reason": reason,
                "serviceStatus": desiredPTTServiceStatus().map(String.init(describing:)) ?? "none",
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
    }

    @discardableResult
    func setSystemActiveRemoteParticipant(
        name: String?,
        channelUUID: UUID,
        contactID: UUID?,
        reason: String,
        allowStaleClearReassert: Bool = true
    ) async throws -> Bool {
        if name == nil,
           systemActiveRemoteParticipantNameByChannelUUID[channelUUID] == nil,
           !isPTTAudioSessionActive {
            diagnostics.record(
                .pushToTalk,
                message: "Skipped active remote participant clear because no active participant was present",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": "none",
                    "reason": reason,
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                ]
            )
            return false
        }

        if let name,
           systemActiveRemoteParticipantNameByChannelUUID[channelUUID] == name,
           isPTTAudioSessionActive
                || pttAudioSessionRuntime.pendingActivationOwner?.channelUUID == channelUUID {
            diagnostics.record(
                .pushToTalk,
                message: "Skipped duplicate active remote participant set",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": name,
                    "reason": reason,
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                ]
            )
            return false
        }

        let startedAt = Date()
        if let contactID, name != nil {
            recordWakeReceiveTiming(
                stage: "active-remote-participant-requested",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "participant": name ?? "none",
                    "reason": reason,
                ],
                ifAbsent: true
            )
        }
        diagnostics.record(
            .pushToTalk,
            message: name == nil
                ? "Requesting active remote participant clear"
                : "Requesting active remote participant set",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "participant": name ?? "none",
                "reason": reason,
                "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )
        var armedActivationOwner: PTTAudioSessionOwner?
        if name != nil,
           !isPTTAudioSessionActive {
            if let wake = pttWakeRuntime.pendingIncomingPush,
               wake.channelUUID == channelUUID,
               contactID == nil || wake.contactID == contactID {
                armedActivationOwner = armPTTAudioSessionActivation(
                    owner: .wakeReceive(
                        channelUUID: wake.channelUUID,
                        contactID: wake.contactID,
                        channelID: wake.payload.channelId
                    ),
                    source: "active-remote-participant-set:\(reason)"
                )
            } else {
                armedActivationOwner = armPTTAudioSessionActivation(
                    owner: .remoteReceive(
                        channelUUID: channelUUID,
                        contactID: contactID,
                        channelID: contactID.flatMap { contactID in
                            contacts.first(where: { $0.id == contactID })?.backendChannelId
                                ?? channelStateByContactID[contactID]?.channelId
                        }
                    ),
                    source: "active-remote-participant-set:\(reason)"
                )
            }
        }

        do {
            try await pttSystemClient.setActiveRemoteParticipant(name: name, channelUUID: channelUUID)
            if allowStaleClearReassert,
               name == nil,
               let contactID,
               shouldReassertRemoteParticipantAfterClearCompletion(
                channelUUID: channelUUID,
                contactID: contactID
               ),
               let participantName = systemRemoteParticipantName(for: contactID) {
                systemActiveRemoteParticipantNameByChannelUUID.removeValue(forKey: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Reasserting active remote participant after stale clear completion",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "contactId": contactID.uuidString,
                        "participant": participantName,
                        "reason": reason,
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    ]
                )
                return try await setSystemActiveRemoteParticipant(
                    name: participantName,
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: "\(reason)-stale-clear-reassert",
                    allowStaleClearReassert: allowStaleClearReassert
                )
            }
            if let name {
                systemActiveRemoteParticipantNameByChannelUUID[channelUUID] = name
            } else {
                systemActiveRemoteParticipantNameByChannelUUID.removeValue(forKey: channelUUID)
            }
            if let contactID, name != nil {
                recordWakeReceiveTiming(
                    stage: "active-remote-participant-completed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "participant": name ?? "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ],
                    ifAbsent: true
                )
            }
            diagnostics.record(
                .pushToTalk,
                message: name == nil
                    ? "Completed active remote participant clear"
                    : "Completed active remote participant set",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": name ?? "none",
                    "reason": reason,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                ]
            )
            return true
        } catch {
            if name == nil && isExpectedPTTRemoteParticipantClearFailure(error) {
                systemActiveRemoteParticipantNameByChannelUUID.removeValue(forKey: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Active remote participant clear found no active participant",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "contactId": contactID?.uuidString ?? "none",
                        "participant": "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "error": error.localizedDescription,
                    ]
                )
                throw error
            }
            if name == nil {
                systemActiveRemoteParticipantNameByChannelUUID.removeValue(forKey: channelUUID)
            }
            if let armedActivationOwner {
                _ = pttAudioSessionRuntime.clearPendingActivationOwner(armedActivationOwner)
            }
            if let contactID, name != nil {
                recordWakeReceiveTiming(
                    stage: "active-remote-participant-failed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "participant": name ?? "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "error": error.localizedDescription,
                    ]
                )
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: name == nil
                    ? "Active remote participant clear failed"
                    : "Active remote participant set failed",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": name ?? "none",
                    "reason": reason,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    private func systemRemoteParticipantName(for contactID: UUID) -> String? {
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return nil
        }
        return contact.name.isEmpty ? contact.handle : contact.name
    }

    private func shouldReassertRemoteParticipantAfterClearCompletion(
        channelUUID: UUID,
        contactID: UUID
    ) -> Bool {
        guard self.channelUUID(for: contactID) == channelUUID else { return false }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return false }
        guard !pttCoordinator.state.isTransmitting else { return false }
        guard backendAuthorizesRemoteParticipantReassert(for: contactID) else {
            diagnostics.record(
                .pushToTalk,
                message: "Skipped active remote participant reassert because backend is not peer-transmitting",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID.uuidString,
                    "backendChannelStatus": selectedChannelSnapshot(for: contactID)?.status?.rawValue ?? "none",
                    "backendReadiness": selectedChannelSnapshot(for: contactID)?.readinessStatus?.kind ?? "none",
                ]
            )
            return false
        }
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        guard let channelID =
            contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId else {
            return false
        }
        return hasActiveOrPreparedRemoteReceiveEpoch(channelID: channelID)
    }

    private func backendAuthorizesRemoteParticipantReassert(for contactID: UUID) -> Bool {
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        let backendShowsPeerTransmit =
            channelSnapshot.status == .receiving
            || channelSnapshot.readinessStatus?.isPeerTransmitting == true
        guard backendShowsPeerTransmit else { return false }
        return !selectedPeerTransmitLeaseExpired(for: contactID)
    }

    func performReconciledTeardown(for contactID: UUID) {
        let backendChannelID = contacts.first { $0.id == contactID }?.backendChannelId
        let backendLeaveAlreadyActive = isBackendLeaveCommandActive(for: contactID)
        let shouldPropagateBackendLeave =
            reconciledTeardownRequiresBackendLeave(for: contactID)
            && !backendLeaveAlreadyActive
        let backendLeaveRequest: BackendLeaveRequest? = {
            guard shouldPropagateBackendLeave,
                  let backendChannelID else {
                return nil
            }
            return BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelID)
        }()
        scheduleDisconnectRecovery(
            contactID: contactID,
            channelUUID: pttCoordinator.state.systemChannelUUID ?? channelUUID(for: contactID),
            backendChannelID: backendChannelID
        )
        if selectedContactId == contactID {
            clearRemoteAudioActivity(for: contactID)
        }
        resetTransmitRuntimeOnly()
        closeMediaSession()
        diagnostics.record(
            .channel,
            message: "Ending Device PTT session after friend departure",
            metadata: ["contactId": contactID.uuidString]
        )
        captureDiagnosticsState("device-ptt-teardown:start")

        if backendLeaveAlreadyActive {
            diagnostics.record(
                .backend,
                message: "Suppressed duplicate backend leave for reconciled Device PTT teardown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": backendChannelID ?? "none",
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    "backendMembership": selectedChannelSnapshot(for: contactID)
                        .map { String(describing: $0.membership) } ?? "none",
                ]
            )
        }

        if let backendLeaveRequest {
            diagnostics.record(
                .backend,
                message: "Backend leave requested for reconciled Device PTT teardown",
                metadata: [
                    "contactId": backendLeaveRequest.contactID.uuidString,
                    "channelId": backendLeaveRequest.backendChannelID,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    "backendMembership": selectedChannelSnapshot(for: contactID)
                        .map { String(describing: $0.membership) } ?? "none",
                ]
            )
            Task {
                await ingestBackendCommandEvent(
                    .leaveRequested(backendLeaveRequest),
                    contactID: backendLeaveRequest.contactID,
                    channelID: backendLeaveRequest.backendChannelID
                )
            }
        }

        if usesLocalHTTPBackend {
            Task {
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                conversationActionCoordinator.clearLeaveAction(for: contactID)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("device-ptt-teardown:local-finished")
            }
            return
        }

        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID else {
            pttCoordinator.reset()
            syncPTTState()
            resetTransmitSession(closeMediaSession: false)
            conversationActionCoordinator.clearLeaveAction(for: contactID)
            if selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership != true {
                selectedConversationCoordinator.send(.devicePTTTeardownCompleted(contactID: contactID))
            }
            replaceDisconnectRecoveryTask(with: nil)
            updateStatusForSelectedContact()
            captureDiagnosticsState("device-ptt-teardown:local-reset")
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: systemChannelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: systemChannelUUID)
        statusMessage = "Peer disconnected"
        captureDiagnosticsState("device-ptt-teardown:ptt-leave-requested")
    }

    func reconciledTeardownRequiresBackendLeave(for contactID: UUID) -> Bool {
        if conversationActionCoordinator.pendingAction.isExplicitLeaveInFlight(for: contactID) {
            return true
        }
        return selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership == true
    }

    func prepareReconciledTeardownState(for contactID: UUID) {
        conversationActionCoordinator.markReconciledTeardown(contactID: contactID)
        backendRuntime.clearBackendJoinSettling(for: contactID)
        recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: contactID)
        recentOutgoingBeepEvidenceByContactID.removeValue(forKey: contactID)
        recentPeerDeviceEvidenceByContactID.removeValue(forKey: contactID)
    }

    func initializeIfNeeded() async {
        guard !pttSystemClient.isReady else { return }
        guard !pttInitializationInFlight else {
            diagnostics.record(.app, message: "Skipped duplicate PTT initialization")
            return
        }
        pttInitializationInFlight = true
        defer { pttInitializationInFlight = false }
        refreshMicrophonePermission()
        diagnostics.record(.app, message: "Initializing app")
        recordPhysicalBoundaryLaunchProfileIfPresent()
        captureDiagnosticsState("app-initialize:start")

        do {
            try await pttSystemClient.configure(callbacks: pttSystemCallbacks)
            diagnostics.record(.pushToTalk, message: "PTT channel manager ready")
            if let restoredChannelUUID = pttCoordinator.state.systemChannelUUID,
               isRestoredSystemSessionQuarantined(channelUUID: restoredChannelUUID) {
                if pttCoordinator.state.activeContactID != nil {
                    syncPTTSystemChannelDescriptor(restoredChannelUUID, reason: "restored-channel-ready")
                    syncPTTTransmissionMode(reason: "restored-channel-ready")
                    syncPTTServiceStatus(reason: "restored-channel-ready")
                    syncPTTAccessoryButtonEvents(reason: "restored-channel-ready")
                } else {
                    diagnostics.record(
                        .pushToTalk,
                        message: "Skipped restored PTT channel policy sync for unresolved quarantined channel",
                        metadata: [
                            "channelUUID": restoredChannelUUID.uuidString,
                            "reason": "restored-channel-ready",
                        ]
                    )
                }
            }
            captureDiagnosticsState("app-initialize:ptt-ready")
        } catch {
            statusMessage = "Failed to init: \(error.localizedDescription)"
            diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("app-initialize:ptt-failed")
            return
        }

        if Self.shouldSuppressSharedAppBackendBootstrapForAutomatedTests {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Suppressed shared app backend bootstrap for automated hosted probe"
            )
            captureDiagnosticsState("backend-config:suppressed-for-hosted-probe")
            return
        }

        await configureBackendIfNeeded()
        if backendRuntime.isReady, selectedContact == nil {
            statusMessage = "Ready to connect"
        }
    }

    private func recordPhysicalBoundaryLaunchProfileIfPresent() {
        guard let metadata = TurboPhysicalBoundaryLaunchProfile.diagnosticsMetadata() else { return }
        diagnostics.record(.app, message: "Physical boundary launch profile", metadata: metadata)
    }

    func endSystemSession() {
        guard let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID else { return }
        conversationActionCoordinator.markExplicitLeave(contactID: selectedContactId)
        if let selectedContactId {
            backendRuntime.clearBackendJoinSettling(for: selectedContactId)
        }
        if let selectedContactId {
            clearRemoteAudioActivity(for: selectedContactId)
        }
        diagnostics.record(.channel, message: "Ending system session", metadata: ["channelUUID": activeSystemChannelUUID.uuidString])

        if let contactID = contactId(for: activeSystemChannelUUID),
           let contact = contacts.first(where: { $0.id == contactID }),
           let backendChannelId = contact.backendChannelId {
            Task {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await ingestBackendCommandEvent(
                    .leaveRequested(request),
                    contactID: contactID,
                    channelID: backendChannelId
                )
            }
        }

        try? pttSystemClient.leaveChannel(channelUUID: activeSystemChannelUUID)
        clearRestoredSystemSessionQuarantine(
            channelUUID: activeSystemChannelUUID,
            reason: "end-system-session"
        )
        pttCoordinator.reset()
        syncPTTState()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        updateStatusForSelectedContact()
        captureDiagnosticsState("system-session:end")
    }

    func joinChannel() {
        guard selectedContact != nil else {
            statusMessage = "Pick a contact"
            return
        }
        Task {
            await requestJoinSelectedConversation()
        }
    }

    func disconnect() {
        Task {
            await requestDisconnectSelectedConversation()
        }
    }

    func disconnectAndReturnToContactList(from contact: Contact) {
        Task {
            await disconnectSelectedConversationAndReturnToContactList(from: contact)
        }
    }

    func disconnectSelectedConversationAndReturnToContactList(from contact: Contact) async {
        if selectedContactId != contact.id {
            selectContact(
                contact,
                reason: "call-screen-leave",
                opensIncomingBeepSurface: false
            )
        }

        await requestDisconnectSelectedConversation()
        clearSelectionAfterCallLeave(contactID: contact.id)
    }

    private func clearSelectionAfterCallLeave(contactID: UUID) {
        guard selectedContactId == contactID else { return }
        selectedContactId = nil
        syncEngineSelectedFriend(nil, reason: "call-screen-leave")
        selectedContactPrewarmedSelectionContactID = nil
        selectedConversationCoordinator.send(.selectedContactChanged(nil))
        updateStatusForSelectedContact()
        diagnostics.record(
            .state,
            message: "Returned to contact list after call leave",
            metadata: ["contactId": contactID.uuidString]
        )
        captureDiagnosticsState("call-screen-leave:return-home")
    }

    func performDisconnect() {
        let disconnectContactID = selectedContactId
        let disconnectChannelUUID = activeChannelId.flatMap { channelUUID(for: $0) }
        let disconnectBackendChannelID = selectedContact?.backendChannelId
        let immediateBackendLeaveRequest: BackendLeaveRequest? = {
            guard let disconnectContactID,
                  let disconnectBackendChannelID else {
                return nil
            }
            return BackendLeaveRequest(
                contactID: disconnectContactID,
                backendChannelID: disconnectBackendChannelID
            )
        }()
        stopAutomaticAudioRouteMonitoring(reason: "disconnect")
        conversationActionCoordinator.markExplicitLeave(contactID: disconnectContactID)
        if let disconnectContactID {
            backendRuntime.clearBackendJoinSettling(for: disconnectContactID)
            recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: disconnectContactID)
            recentOutgoingBeepEvidenceByContactID.removeValue(forKey: disconnectContactID)
            recentPeerDeviceEvidenceByContactID.removeValue(forKey: disconnectContactID)
        }
        scheduleDisconnectRecovery(
            contactID: disconnectContactID,
            channelUUID: disconnectChannelUUID,
            backendChannelID: disconnectBackendChannelID
        )
        if let disconnectContactID {
            clearRemoteAudioActivity(for: disconnectContactID)
            _ = retireDirectQuicPathImmediately(
                for: disconnectContactID,
                reason: "explicit-disconnect",
                sendHangup: true,
                configureActiveRoute: false
            )
        }
        resetTransmitRuntimeOnly()
        diagnostics.record(.channel, message: "Disconnect requested", metadata: ["selectedContactId": disconnectContactID?.uuidString ?? "none"])
        captureDiagnosticsState("selected-conversation-disconnect:start")
        if usesLocalHTTPBackend {
            closeMediaSession()
            Task {
                if let contact = selectedContact,
                   let backendChannelId = contact.backendChannelId {
                    let request = BackendLeaveRequest(contactID: contact.id, backendChannelID: backendChannelId)
                    await ingestBackendCommandEvent(
                        .leaveRequested(request),
                        contactID: contact.id,
                        channelID: backendChannelId
                    )
                }
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                conversationActionCoordinator.clearLeaveAction(for: disconnectContactID)
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("selected-conversation-disconnect:local-finished")
            }
            return
        }

        if let immediateBackendLeaveRequest {
            diagnostics.record(
                .backend,
                message: "Backend leave requested immediately for explicit disconnect",
                metadata: [
                    "contactId": immediateBackendLeaveRequest.contactID.uuidString,
                    "channelId": immediateBackendLeaveRequest.backendChannelID,
                ]
            )
            Task {
                await ingestBackendCommandEvent(
                    .leaveRequested(immediateBackendLeaveRequest),
                    contactID: immediateBackendLeaveRequest.contactID,
                    channelID: immediateBackendLeaveRequest.backendChannelID
                )
            }
        }

        guard let activeChannelId,
              let channelUUID = channelUUID(for: activeChannelId) else {
            closeMediaSession()
            statusMessage = "Disconnected"
            if let disconnectContactID {
                syncEngineDisconnect(contactID: disconnectContactID, reason: "no-active-channel")
            }
            conversationActionCoordinator.clearLeaveAction(for: disconnectContactID)
            replaceDisconnectRecoveryTask(with: nil)
            captureDiagnosticsState("selected-conversation-disconnect:no-active-channel")
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        closeMediaSession(deactivateAudioSession: false)
        statusMessage = "Disconnecting..."
        captureDiagnosticsState("selected-conversation-disconnect:ptt-leave-requested")
    }

    private func scheduleDisconnectRecovery(
        contactID: UUID?,
        channelUUID: UUID?,
        backendChannelID: String?,
        delayNanoseconds: UInt64? = nil,
        startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard let contactID else { return }
        let delayNanoseconds = delayNanoseconds ?? disconnectRecoveryDelayNanoseconds
        replaceDisconnectRecoveryTask(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            guard self.conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return }

            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAtNanoseconds
            if self.isBackendLeaveCommandActive(for: contactID),
               elapsedNanoseconds < self.disconnectRecoveryMaxWaitNanoseconds {
                self.diagnostics.record(
                    .state,
                    message: "Deferred disconnect recovery while backend leave command is still active",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "backendChannelId": backendChannelID ?? "none",
                        "elapsedMs": String(elapsedNanoseconds / 1_000_000),
                        "maxWaitMs": String(self.disconnectRecoveryMaxWaitNanoseconds / 1_000_000),
                    ]
                )
                self.scheduleDisconnectRecovery(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    backendChannelID: backendChannelID,
                    delayNanoseconds: self.disconnectRecoveryRetryDelayNanoseconds,
                    startedAtNanoseconds: startedAtNanoseconds
                )
                return
            }

            let selectedState = self.selectedConversationState(for: contactID)
            self.diagnostics.recordInvariantViolation(
                invariantID: "selected.disconnecting_timeout",
                scope: .local,
                message: "selected Conversation remained disconnecting after pending leave timeout",
                metadata: [
                    "contactId": contactID.uuidString,
                    "selectedConversationPhase": String(describing: selectedState.phase),
                    "selectedConversationPhaseDetail": String(describing: selectedState.detail),
                    "pendingAction": String(describing: self.conversationActionCoordinator.pendingAction),
                    "systemSession": String(describing: self.systemSessionState),
                    "backendChannelId": backendChannelID ?? "none",
                ]
            )
            self.diagnostics.record(
                .state,
                message: "Recovering stuck disconnect",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID?.uuidString ?? "none",
                    "backendChannelId": backendChannelID ?? "none",
                ]
            )

            if let retryChannelUUID = channelUUID ?? self.channelUUID(for: contactID) {
                try? self.pttSystemClient.leaveChannel(channelUUID: retryChannelUUID)
            }
            self.tearDownTransmitRuntime(resetCoordinator: true)
            self.closeMediaSession()
            self.pttCoordinator.reset()
            self.syncPTTState()
            self.conversationActionCoordinator.clearLeaveAction(for: contactID)
            self.backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            self.updateStatusForSelectedContact()
            self.captureDiagnosticsState("selected-conversation-disconnect:self-healed")

            if let backendChannelID {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelID)
                await self.ingestBackendCommandEvent(
                    .leaveRequested(request),
                    contactID: contactID,
                    channelID: backendChannelID
                )
            } else {
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
            }
        })
    }

    func isBackendLeaveCommandActive(for contactID: UUID) -> Bool {
        guard case .leave(let activeContactID) = backendCommandCoordinator.state.activeOperation else {
            return false
        }
        return activeContactID == contactID
    }

    func shouldBlockSelectedConversationConnectionEffectInCurrentLifecycle(
        contactID: UUID,
        effectName: String
    ) -> Bool {
        let applicationState = currentApplicationState()
        guard applicationState != .active else { return false }
        diagnostics.record(
            .state,
            message: "Ignored selected conversation connection effect while application is not active",
            metadata: [
                "contactId": contactID.uuidString,
                "effect": effectName,
                "applicationState": String(describing: applicationState),
            ]
        )
        captureDiagnosticsState("selected-conversation-effect:\(effectName)-blocked-by-lifecycle")
        return true
    }

    func performConnect(to contact: Contact, intent: BackendJoinIntent) {
        let relationship = beepThreadProjection(for: contact.id)
        let connectOrigin: PendingConnectOrigin =
            relationship.hasIncomingBeep ? .acceptingIncomingBeep : .neutral
        if let suppression = consumeStaleSystemRejoinSuppression(
            channelUUID: contact.channelId,
            contactID: contact.id
        ) {
            diagnostics.record(
                .state,
                message: "Cleared recent system leave barrier for explicit connect",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                    "intent": String(describing: intent),
                    "origin": String(describing: connectOrigin),
                    "suppressionReason": suppression.reason,
                ]
            )
        }
        let incomingBeepIsLiveConnectable =
            !relationship.hasIncomingBeep || contact.isOnline
        let friendReadyJoinIsAuthoritative =
            intent == .joinReadyFriend && canQueueReadyFriendLocalConnect(for: contact.id)
        let shouldQueueLocalConnect =
            backendServices == nil
            || (relationship.hasIncomingBeep && incomingBeepIsLiveConnectable)
            || friendReadyJoinIsAuthoritative

        if backendServices != nil,
           intent == .joinReadyFriend,
           !friendReadyJoinIsAuthoritative {
            diagnostics.record(
                .state,
                message: "Downgrading stale friend-ready connect to Beep-only",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "relationship": String(describing: relationship),
                    "backendMembership": selectedChannelSnapshot(for: contact.id)
                        .map { String(describing: $0.membership) } ?? "none",
                    "backendBeepThreadProjection": selectedChannelSnapshot(for: contact.id)
                        .map { String(describing: $0.beepThreadProjection) } ?? "none",
                ]
            )
            captureDiagnosticsState("selected-conversation-connect:stale-friend-ready-downgraded")
            requestBackendJoin(for: contact, intent: .requestConnection)
            return
        }

        if usesLocalHTTPBackend {
            if isJoined, activeChannelId == contact.id {
                return
            }
            if shouldQueueLocalConnect {
                conversationActionCoordinator.queueConnect(contactID: contact.id, origin: connectOrigin)
                syncSelectedConversationProjection()
                captureDiagnosticsState("selected-conversation-connect:queued-local")
            } else {
                captureDiagnosticsState("selected-conversation-connect:beep-only-local")
            }
            requestBackendJoin(for: contact, intent: intent)
            return
        }

        if isJoined, activeChannelId == contact.id {
            return
        }

        guard shouldQueueLocalConnect else {
            captureDiagnosticsState("selected-conversation-connect:beep-only")
            requestBackendJoin(for: contact, intent: intent)
            return
        }

        conversationActionCoordinator.queueConnect(contactID: contact.id, origin: connectOrigin)
        syncSelectedConversationProjection()
        captureDiagnosticsState("selected-conversation-connect:queued")

        if isJoined, let activeChannelId, let channelUUID = channelUUID(for: activeChannelId) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Connecting..."
            captureDiagnosticsState("selected-conversation-connect:switching-channel")
        } else {
            requestBackendJoin(for: contact, intent: intent)
        }
    }

    func canQueueReadyFriendLocalConnect(for contactID: UUID) -> Bool {
        guard backendServices != nil else { return true }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.membership.hasPeerMembership else { return false }
        guard channelSnapshot.beepThreadProjection == .none else { return false }
        return peerIsRoutableForReceiverAudioReadiness(for: contactID)
    }

    func refreshStaleOutgoingRequestBeforeConnectIfNeeded(contactID: UUID) async {
        let relationship = beepThreadProjection(for: contactID)
        guard relationship.hasOutgoingBeep, !relationship.hasIncomingBeep else { return }
        guard backendServices != nil else { return }

        diagnostics.record(
            .backend,
            level: .notice,
            message: "Refreshing outgoing Beep before reconnect attempt",
            metadata: [
                "contactId": contactID.uuidString,
                "relationship": String(describing: relationship),
            ]
        )

        async let summaries: Void = refreshContactSummaries()
        async let beeps: Void = refreshBeeps()
        _ = await (summaries, beeps)

        let refreshedRelationship = beepThreadProjection(for: contactID)
        guard refreshedRelationship != relationship else { return }

        diagnostics.record(
            .backend,
            level: .notice,
            message: "Outgoing Beep projection changed before reconnect attempt",
            metadata: [
                "contactId": contactID.uuidString,
                "previousRelationship": String(describing: relationship),
                "refreshedRelationship": String(describing: refreshedRelationship),
                "willJoin": refreshedRelationship.hasIncomingBeep ? "true" : "false",
            ]
        )
    }

    func requestJoinSelectedConversation() async {
        cancelSelectedConnectionAttemptTimeout()
        syncSelectedConversationProjection()
        captureDiagnosticsState("selected-conversation:join-requested")
        await selectedConversationCoordinator.handle(.joinRequested)
    }

    func requestDisconnectSelectedConversation() async {
        cancelSelectedConnectionAttemptTimeout()
        syncSelectedConversationProjection()
        captureDiagnosticsState("selected-conversation:disconnect-requested")
        await selectedConversationCoordinator.handle(.disconnectRequested)
    }

    func reconcileSelectedConversationIfNeeded() async {
        guard selectedContact != nil else { return }
        syncSelectedConversationProjection()
        await selectedConversationCoordinator.handle(.reconcileRequested)
    }

    func runSelectedConversationEffect(_ effect: SelectedConversationEffect) async {
        switch effect {
        case .requestConnection(let contactID):
            guard !shouldBlockSelectedConversationConnectionEffectInCurrentLifecycle(
                contactID: contactID,
                effectName: "request-connection"
            ) else { return }
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            captureDiagnosticsState("selected-conversation-effect:request-connection")
            let relationship = beepThreadProjection(for: contactID)
            if relationship.hasOutgoingBeep, !relationship.hasIncomingBeep {
                await refreshStaleOutgoingRequestBeforeConnectIfNeeded(contactID: contactID)
            }
            let refreshedContact = contacts.first(where: { $0.id == contactID }) ?? contact
            performConnect(to: refreshedContact, intent: .requestConnection)
        case .joinReadyFriend(let contactID):
            guard !shouldBlockSelectedConversationConnectionEffectInCurrentLifecycle(
                contactID: contactID,
                effectName: "join-ready-friend"
            ) else { return }
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            captureDiagnosticsState("selected-conversation-effect:join-ready-friend")
            performConnect(to: contact, intent: .joinReadyFriend)
        case .disconnect:
            captureDiagnosticsState("selected-conversation-effect:disconnect")
            performDisconnect()
        case .restoreDevicePTTSession(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
                diagnostics.record(
                    .state,
                    message: "Ignored automatic Device PTT restore while leave is in flight",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    ]
                )
                captureDiagnosticsState("selected-conversation-effect:restore-device-ptt-blocked-by-leave")
                return
            }
            if hasStaleSystemRejoinSuppression(
                channelUUID: contact.channelId,
                contactID: contactID
            ) {
                diagnostics.record(
                    .state,
                    message: "Ignored automatic Device PTT restore after recent system leave",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": contact.channelId.uuidString,
                    ]
                )
                captureDiagnosticsState("selected-conversation-effect:restore-device-ptt-blocked-by-recent-leave")
                return
            }
            guard !shouldBlockSelectedConversationConnectionEffectInCurrentLifecycle(
                contactID: contactID,
                effectName: "restore-device-ptt"
            ) else { return }
            diagnostics.record(
                .state,
                message: "Restoring Device PTT session to match backend-ready Conversation",
                metadata: ["contactId": contactID.uuidString, "handle": contact.handle]
            )
            captureDiagnosticsState("selected-conversation-effect:restore-device-ptt")
            joinPTTChannel(for: contact)
        case .teardownDevicePTTSession(let contactID):
            guard selectedContactId == contactID else { return }
            prepareReconciledTeardownState(for: contactID)
            diagnostics.record(
                .state,
                message: "Tearing down invalid Device PTT session after selected Conversation reconciliation",
                metadata: ["contactId": contactID.uuidString]
            )
            captureDiagnosticsState("selected-conversation-effect:teardown-device-ptt")
            performReconciledTeardown(for: contactID)
        case .clearStaleBackendMembership(let contactID):
            guard selectedContactId == contactID else { return }
            let backendChannelId = contacts.first(where: { $0.id == contactID })?.backendChannelId ?? "none"
            backendRuntime.clearBackendJoinSettling(for: contactID)
            recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: contactID)
            recentOutgoingBeepEvidenceByContactID.removeValue(forKey: contactID)
            recentPeerDeviceEvidenceByContactID.removeValue(forKey: contactID)
            conversationActionCoordinator.clearPendingJoin(for: contactID)
            conversationActionCoordinator.clearLeaveAction(for: contactID)
            replaceDisconnectRecoveryTask(with: nil)
            diagnostics.record(
                .state,
                message: "Cleared local stale backend membership projection without propagating backend leave",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": backendChannelId,
                ]
            )
            backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
            updateStatusForSelectedContact()
            if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                diagnostics.record(
                    .state,
                    message: "Suppressed reconciled teardown after clearing stale backend membership",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    ]
                )
                conversationActionCoordinator.clearLeaveAction(for: contactID)
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
            }
            captureDiagnosticsState("selected-conversation-effect:clear-stale-backend-membership")
        }
    }

    func runPTTEffect(_ effect: PTTEffect) async {
        switch effect {
        case .syncJoinedChannel(let contactID):
            if let contactID {
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
                if let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId {
                    await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
                    syncPTTSystemPolicyState()
                }
            } else {
                updateStatusForSelectedContact()
            }
        case .syncLeftChannel(let contactID, let autoRejoinContactID, let shouldPropagateBackendLeave):
            tearDownTransmitRuntime(resetCoordinator: true)
            closeMediaSession()

            if !shouldPropagateBackendLeave,
               let contactID,
               currentApplicationState() != .active {
                diagnostics.record(
                    .pushToTalk,
                    message: "Publishing receiver not-ready after background PTT system leave",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "reason": "system-channel-left-background",
                    ]
                )
                await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .appBackgroundMediaClosed)
            }

            if shouldPropagateBackendLeave,
               let contactID,
               let contact = contacts.first(where: { $0.id == contactID }),
               let backendChannelId = contact.backendChannelId {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await ingestBackendCommandEvent(
                    .leaveRequested(request),
                    contactID: contactID,
                    channelID: backendChannelId
                )
                if currentApplicationState() != .active {
                    conversationActionCoordinator.clearExplicitLeave(for: contactID)
                }
            } else if let contactID {
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
            }
            if let autoRejoinContactID,
               let contact = contacts.first(where: { $0.id == autoRejoinContactID }) {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    requestBackendJoin(for: contact)
                }
            } else if shouldPropagateBackendLeave {
                backendSyncCoordinator.send(.clearAllChannelStates)
            }
            updateStatusForSelectedContact()
        case .closeMediaSession:
            closeMediaSession()
        case .handleSystemTransmitFailure(let message):
            await transmitCoordinator.handle(.systemBeginFailed(message))
            syncTransmitState()
        }
    }

    func joinPTTChannel(for contact: Contact) {
        guard pttSystemClient.isReady else {
            statusMessage = "Not ready"
            captureDiagnosticsState("ptt-join:not-ready")
            return
        }

        if shouldBlockAppInitiatedPTTJoinInCurrentLifecycle(for: contact.id) {
            conversationActionCoordinator.clearPendingJoin(for: contact.id)
            updateStatusForSelectedContact()
            diagnostics.record(
                .pushToTalk,
                message: "Ignored app-initiated PTT join while application is backgrounded",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                    "applicationState": String(describing: currentApplicationState()),
                ]
            )
            captureDiagnosticsState("ptt-join:blocked-by-background")
            return
        }

        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contact.id) else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored local PTT join while explicit leave is in flight",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                ]
            )
            statusMessage = "Disconnecting..."
            captureDiagnosticsState("ptt-join:blocked-by-leave")
            return
        }

        let devicePTTEvidenceAlreadyActive = devicePTTEvidenceExists(
            for: contact.id,
            expectedChannelUUID: contact.channelId
        )
        let stalePendingJoinWithoutDevicePTTEvidence =
            conversationActionCoordinator.localJoinAttempt?.contactID == contact.id
            && !devicePTTEvidenceAlreadyActive

        if conversationActionCoordinator.pendingJoinContactID == contact.id,
           !stalePendingJoinWithoutDevicePTTEvidence {
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-pending")
            return
        }

        if stalePendingJoinWithoutDevicePTTEvidence {
            diagnostics.record(
                .pushToTalk,
                message: "Retrying stale pending local join",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                ]
            )
            // Preserve the pending local-join projection while we retry so the
            // selected UI cannot briefly fall back to friendReady/connectable.
            captureDiagnosticsState("ptt-join:retry-stale-pending")
        }

        if devicePTTEvidenceAlreadyActive {
            conversationActionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-active")
            return
        }

        conversationActionCoordinator.queueJoin(contactID: contact.id, channelUUID: contact.channelId)
        do {
            try pttSystemClient.joinChannel(channelUUID: contact.channelId, name: "Chat with \(contact.name)")
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:requested")
        } catch {
            conversationActionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = error.localizedDescription
            captureDiagnosticsState("ptt-join:failed-immediate")
        }
    }

    func channelUUID(for contactId: UUID) -> UUID? {
        contacts.first { $0.id == contactId }?.channelId
    }

    func contactId(for channelUUID: UUID) -> UUID? {
        contacts.first { $0.channelId == channelUUID }?.id
    }

    func formatPTTError(_ error: Error) -> String {
        if let channelError = error as? PTChannelError {
            return String(describing: channelError.code)
        }

        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code))"
    }

    func isExpectedPTTStopFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 5 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 5
        }

        return false
    }

    func isExpectedPTTRemoteParticipantClearFailure(_ error: Error) -> Bool {
        isExpectedPTTStopFailure(error)
    }

    func isRecoverablePTTChannelUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 1 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 1
        }

        return false
    }

    func isRecoverablePTTTransmissionInProgress(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 4 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 4
        }

        return false
    }

    func recoverStaleSystemChannel(for channelUUID: UUID, contactID: UUID, reason: String) {
        let shouldRetryTransmitAfterRejoin =
            reason == "transmit-begin-failed"
            && hasLocalTransmitStartupOrActiveIntent(for: contactID)
            && !transmitRuntime.explicitStopRequested
        if shouldRetryTransmitAfterRejoin {
            pendingSystemTransmitRetryAfterRejoinByContactID[contactID] = channelUUID
        } else {
            pendingSystemTransmitRetryAfterRejoinByContactID[contactID] = nil
        }

        diagnostics.record(
            .pushToTalk,
            message: "Recovering stale system channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactID": contactID.uuidString,
                "reason": reason,
                "retryTransmitAfterRejoin": String(shouldRetryTransmitAfterRejoin),
            ]
        )
        if shouldRetryTransmitAfterRejoin {
            cancelPendingTransmitWork()
            localTransmitStopProjectionGraceStartedAtNanosecondsByContactID.removeAll()
            clearFirstAudioPlaybackAckExpectations()
            pendingBeginTransmitAfterSettlingTask?.cancel()
            pendingBeginTransmitAfterSettlingTask = nil
        } else {
            tearDownTransmitRuntime(resetCoordinator: true)
        }
        let preserveDirectQuic = shouldUseDirectQuicTransport(for: contactID)
        closeMediaSession(
            preserveDirectQuic: preserveDirectQuic,
            preserveMediaRelay: !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: contactID)
        )
        markLocalOnlySystemLeave(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: reason
        )
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        conversationActionCoordinator.queueJoin(contactID: contactID, channelUUID: channelUUID)
        pttCoordinator.reset()
        syncPTTState()
        statusMessage = "Reconnecting..."
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-recover-stale-channel")

        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.joinPTTChannel(for: contact)
        }
    }

    func classifyPTTJoinFailure(_ error: Error) -> PTTJoinFailureReason {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain, nsError.code == 2 {
            return .channelLimitReached
        }
        return .other(message: formatPTTError(error))
    }
}
