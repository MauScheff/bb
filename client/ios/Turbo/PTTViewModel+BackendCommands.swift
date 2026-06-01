//
//  PTTViewModel+BackendCommands.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation

enum BackendJoinExecutionPlan: Equatable {
    case beepOnly
    case joinConversation
}

private enum BackendJoinCommandOutcome: Equatable {
    case commandReturned
    case membershipVisible
    case visibilityTimedOut
    case commandTimedOut
}

struct ResolvedBackendJoinContact {
    let contact: Contact
    let executionPlan: BackendJoinExecutionPlan
}

extension PTTViewModel {
    func declineIncomingBeepForSelectedContact() async {
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }
        guard let beep = incomingBeepByContactID[contact.id] else {
            statusMessage = "No incoming Beep"
            return
        }

        do {
            markIncomingBeepHandledLocally(
                contactID: contact.id,
                beep: beep,
                relationship: beepThreadProjection(for: contact.id),
                reason: "decline-selected"
            )
            _ = try await backend.declineBeep(beepId: beep.beepId)
            await waitForBeepToDisappear(
                beepID: beep.beepId,
                contactID: contact.id,
                handle: contact.handle,
                label: "Incoming beep decline",
                fetchBeeps: { try await backend.incomingBeeps() }
            )
            await refreshBeeps()
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            diagnostics.record(.backend, message: "Declined incoming Beep", metadata: ["handle": contact.handle])
            captureDiagnosticsState("selected-conversation:decline-beep")
            updateStatusForSelectedContact()
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Decline failed: \(message)"
            statusMessage = "Decline failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Decline Beep failed",
                metadata: ["handle": contact.handle, "error": message]
            )
            captureDiagnosticsState("selected-conversation:decline-beep-failed")
        }
    }

    func cancelOutgoingBeepForSelectedContact() async {
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }
        guard let beep = outgoingBeepByContactID[contact.id] else {
            statusMessage = "No outgoing Beep"
            return
        }

        do {
            _ = try await backend.cancelBeep(beepId: beep.beepId)
            await waitForBeepToDisappear(
                beepID: beep.beepId,
                contactID: contact.id,
                handle: contact.handle,
                label: "Outgoing beep cancel",
                fetchBeeps: { try await backend.outgoingBeeps() }
            )
            await refreshBeeps()
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            selectedConversationCoordinator.send(.senderAutoJoinCancelled(contactID: contact.id))
            diagnostics.record(.backend, message: "Cancelled outgoing Beep", metadata: ["handle": contact.handle])
            captureDiagnosticsState("selected-conversation:cancel-beep")
            updateStatusForSelectedContact()
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Cancel failed: \(message)"
            statusMessage = "Cancel failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Cancel Beep failed",
                metadata: ["handle": contact.handle, "error": message]
            )
            captureDiagnosticsState("selected-conversation:cancel-beep-failed")
        }
    }

    func backendJoinExecutionPlan(
        request: BackendJoinRequest,
        createdBeep: TurboBeepResponse?,
        existingConversationSnapshot: ChannelReadinessSnapshot?
    ) -> BackendJoinExecutionPlan {
        if request.relationship.hasIncomingBeep {
            return request.contactIsOnline ? .joinConversation : .beepOnly
        }
        if createdBeep?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "connected" {
            return .joinConversation
        }
        if createdBeep?.direction == "incoming" {
            return .joinConversation
        }
        if request.intent == .requestConnection {
            return .beepOnly
        }
        if existingConversationSnapshot?.membership.hasLocalMembership == true {
            return .joinConversation
        }
        if request.intent == .joinAcceptedOutgoingBeep {
            return .joinConversation
        }
        if request.intent == .joinReadyFriend {
            guard existingConversationSnapshot?.membership.hasPeerMembership == true,
                  existingConversationSnapshot?.beepThreadProjection == BackendBeepThreadProjection.none else {
                return .beepOnly
            }
            return .joinConversation
        }
        return .beepOnly
    }

    func backendJoinNeedsExistingConversationSnapshot(request: BackendJoinRequest) -> Bool {
        request.intent == .joinReadyFriend
    }

    private func existingConversationSnapshot(
        for contact: Contact,
        backend: BackendServices
    ) async -> ChannelReadinessSnapshot? {
        guard let backendChannelId = contact.backendChannelId else {
            return channelStateByContactID[contact.id].map {
                ChannelReadinessSnapshot(
                    channelState: $0,
                    readiness: channelReadinessByContactID[contact.id]
                )
            }
        }

        do {
            async let channelStateTask = backend.channelState(channelId: backendChannelId)
            async let channelReadinessTask = backend.channelReadiness(channelId: backendChannelId)
            let channelState = try await channelStateTask
            let channelReadiness = try? await channelReadinessTask
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contact.id, channelState: channelState)
            )
            if let channelReadiness {
                applyChannelReadiness(
                    channelReadiness,
                    for: contact.id,
                    reason: "existing-conversation-snapshot"
                )
            }
            return ChannelReadinessSnapshot(channelState: channelState, readiness: channelReadiness)
        } catch {
            diagnostics.record(
                .backend,
                message: "Falling back to cached join visibility after channel-state refresh failed",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "channelId": backendChannelId,
                    "error": error.localizedDescription,
                ]
            )
            return channelStateByContactID[contact.id].map {
                ChannelReadinessSnapshot(
                    channelState: $0,
                    readiness: channelReadinessByContactID[contact.id]
                )
            }
        }
    }

    func openFriend(reference: String) async {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReference = TurboIncomingLink.publicID(from: trimmedReference) ?? trimmedReference
        guard !normalizedReference.isEmpty else { return }
        guard backendServices != nil else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        await ingestBackendCommandEvent(.openFriendRequested(handle: normalizedReference))
    }

    func runBackendCommandEffect(_ effect: BackendCommandEffect) async {
        switch effect {
        case .openFriend(let handle):
            await performOpenFriend(handle: handle)
        case .join(let request):
            await performBackendJoin(request)
        case .leave(let request):
            await performBackendLeave(request)
        }
    }

    func completeLocalBackendJoin(for contact: Contact) {
        conversationActionCoordinator.clearAfterSuccessfulJoin(for: contact.id)
        forceSyncEngineJoinedConversation(contactID: contact.id, reason: "backend-join-complete")
        updateAutomaticAudioRouteMonitoring(reason: "backend-join-complete")
        updateStatusForSelectedContact()
    }

    func startLocalJoinAfterAcceptedBackendJoin(for contact: Contact) {
        backendRuntime.markBackendJoinSettling(for: contact.id)
        joinPTTChannel(for: contact)
    }

    func requestBackendJoin(for contact: Contact, intent: BackendJoinIntent = .requestConnection) {
        let relationship = beepThreadProjection(for: contact.id)
        let incomingBeep = incomingBeepByContactID[contact.id]
        if relationship.hasIncomingBeep {
            markIncomingBeepHandledLocally(
                contactID: contact.id,
                beep: incomingBeep,
                relationship: relationship,
                reason: "accept-\(String(describing: intent))"
            )
        }
        guard backendServices != nil else {
            joinPTTChannel(for: contact)
            return
        }
        let activeJoinRequest: BackendJoinRequest? = {
            guard case .join(let request) = backendCommandCoordinator.state.activeOperation,
                  request.contactID == contact.id,
                  request.intent == intent else {
                return nil
            }
            return request
        }()
        if let activeJoinRequest,
           intent == .requestConnection,
           !activeJoinRequest.relationship.hasIncomingBeep,
           !relationship.hasIncomingBeep {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Coalesced repeated outgoing Beep while backend request is active",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "relationship": String(describing: relationship),
                    "activeRelationship": String(describing: activeJoinRequest.relationship),
                ]
            )
            captureDiagnosticsState("backend-join:coalesced-outgoing-beep")
            return
        }
        let request = BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            intent: intent,
            operationID: activeJoinRequest?.operationID ?? backendConnectOperationID(for: contact, intent: intent),
            joinOperationID: activeJoinRequest?.joinOperationID ?? backendChannelJoinOperationID(for: contact, intent: intent),
            relationship: relationship,
            existingRemoteUserID: contact.remoteUserId,
            existingBackendChannelID: contact.backendChannelId,
            incomingBeep: incomingBeep,
            outgoingBeep: outgoingBeepByContactID[contact.id],
            beepCooldownRemaining: beepCooldownRemaining(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            contactIsOnline: contact.isOnline
        )
        if intent == .requestConnection,
           (!relationship.hasIncomingBeep || !contact.isOnline),
           request.beepCooldownRemaining == nil {
            markOptimisticOutgoingBeepStarted(
                contactID: contact.id,
                relationship: relationship,
                operationID: request.operationID,
                allowsIncomingBeepBack: !contact.isOnline
            )
        }
        Task {
            await ingestBackendCommandEvent(
                .joinRequested(request),
                contactID: contact.id,
                channelID: contact.backendChannelId
            )
        }
    }

    func reassertBackendJoin(
        for contact: Contact,
        intent: BackendJoinIntent = .joinReadyFriend,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) async {
        guard backendServices != nil else { return }
        guard !backendLeaveIsInFlight(for: contact.id) else {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Skipped backend join reassertion while leave is active",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    "activeBackendOperation": String(describing: backendCommandCoordinator.state.activeOperation),
                ]
            )
            return
        }
        let request = backendJoinRequest(
            for: contact,
            intent: intent,
            deviceSessionProof: deviceSessionProof
        )
        if case .join(let activeRequest) = backendCommandCoordinator.state.activeOperation,
           activeRequest.contactID == contact.id {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Forcing backend join reassertion past in-flight join",
                metadata: ["contactId": contact.id.uuidString, "handle": contact.handle]
            )
            backendCommandCoordinator.send(.reset)
        }
        await ingestBackendCommandEvent(
            .joinRequested(request),
            contactID: contact.id,
            channelID: contact.backendChannelId
        )
    }

    func backendJoinRequest(
        for contact: Contact,
        intent: BackendJoinIntent = .joinReadyFriend,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) -> BackendJoinRequest {
        BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            intent: intent,
            operationID: backendConnectOperationID(for: contact, intent: intent),
            joinOperationID: backendChannelJoinOperationID(for: contact, intent: intent),
            relationship: beepThreadProjection(for: contact.id),
            existingRemoteUserID: contact.remoteUserId,
            existingBackendChannelID: contact.backendChannelId,
            incomingBeep: incomingBeepByContactID[contact.id],
            outgoingBeep: outgoingBeepByContactID[contact.id],
            beepCooldownRemaining: beepCooldownRemaining(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            contactIsOnline: contact.isOnline,
            deviceSessionProof: deviceSessionProof
        )
    }

    @discardableResult
    func reassertBackendJoinAndWaitForVisibility(
        for contact: Contact,
        intent: BackendJoinIntent = .joinReadyFriend,
        source: String,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) async -> Bool {
        guard backendServices != nil else { return false }
        guard !backendLeaveIsInFlight(for: contact.id) else {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Skipped synchronous backend join reassertion while leave is active",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "source": source,
                    "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                    "activeBackendOperation": String(describing: backendCommandCoordinator.state.activeOperation),
                ]
            )
            return false
        }

        let request = backendJoinRequest(
            for: contact,
            intent: intent,
            deviceSessionProof: deviceSessionProof
        )
        if case .join(let activeRequest) = backendCommandCoordinator.state.activeOperation,
           activeRequest.contactID == contact.id {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Restarting backend join reassertion before critical operation",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "source": source,
                    "activeIntent": String(describing: activeRequest.intent),
                ]
            )
            backendCommandCoordinator.send(.reset)
        }

        diagnostics.record(
            .backend,
            message: "Synchronously reasserting backend join",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "source": source,
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
        await backendCommandCoordinator.handle(.joinRequested(request))

        let visible = backendJoinIsVisibleForCriticalOperation(contactID: contact.id)
        diagnostics.record(
            .backend,
            level: visible ? .info : .error,
            message: visible
                ? "Synchronous backend join reassertion became visible"
                : "Synchronous backend join reassertion did not become visible",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "source": source,
                "backendMembership": String(describing: selectedChannelSnapshot(for: contact.id)?.membership),
                "localHasActiveDevice": String(selectedChannelSnapshot(for: contact.id)?.localHasActiveDevice ?? false),
            ]
        )
        return visible
    }

    func backendJoinIsVisibleForCriticalOperation(contactID: UUID) -> Bool {
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        guard channel.membership.hasLocalMembership else { return false }
        return channel.localHasActiveDevice || devicePTTEvidenceExists(for: contactID)
    }

    func backendLeaveIsInFlight(for contactID: UUID) -> Bool {
        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            return true
        }
        if case .leave(let activeContactID) = backendCommandCoordinator.state.activeOperation,
           activeContactID == contactID {
            return true
        }
        return false
    }

    private func activeBackendJoinMatches(_ request: BackendJoinRequest) -> Bool {
        guard case .join(let activeRequest) = backendCommandCoordinator.state.activeOperation else {
            return false
        }
        return activeRequest == request
    }

    private func backendJoinSupersededReason(for request: BackendJoinRequest) -> String? {
        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: request.contactID) {
            return "session-leave-in-flight"
        }
        if case .leave(let contactID) = backendCommandCoordinator.state.activeOperation,
           contactID == request.contactID {
            return "backend-leave-active"
        }
        if !activeBackendJoinMatches(request) {
            return "backend-operation-superseded"
        }
        return nil
    }

    @discardableResult
    private func discardSupersededBackendJoinIfNeeded(
        _ request: BackendJoinRequest,
        stage: String,
        contact: Contact? = nil,
        backend: BackendServices? = nil
    ) async -> Bool {
        guard let reason = backendJoinSupersededReason(for: request) else {
            return false
        }

        diagnostics.record(
            .backend,
            level: .notice,
            message: "Discarded superseded backend join",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "stage": stage,
                "reason": reason,
                "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                "activeBackendOperation": String(describing: backendCommandCoordinator.state.activeOperation),
            ]
        )

        if activeBackendJoinMatches(request) {
            backendCommandCoordinator.send(.reset)
        }

        if let contact,
           let backend,
           reason == "session-leave-in-flight" || reason == "backend-leave-active" {
            await compensateBackendLeaveAfterSupersededJoin(
                contact: contact,
                request: request,
                backend: backend,
                reason: reason
            )
        }

        return true
    }

    private func compensateBackendLeaveAfterSupersededJoin(
        contact: Contact,
        request: BackendJoinRequest,
        backend: BackendServices,
        reason: String
    ) async {
        guard let backendChannelId = contact.backendChannelId else { return }

        do {
            _ = try await backend.leaveChannel(
                channelId: backendChannelId,
                operationId: BackendCommandOperationID.make(prefix: "leave-superseded-join")
            )
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            await refreshBeeps()
            diagnostics.record(
                .backend,
                message: "Compensated backend membership after superseded join",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "channelId": backendChannelId,
                    "reason": reason,
                ]
            )
        } catch {
            await refreshChannelState(for: contact.id)
            diagnostics.record(
                .backend,
                level: .error,
                message: "Compensating backend leave after superseded join failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "channelId": backendChannelId,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func applyBeepMetadata(_ beep: TurboBeepResponse, to contact: inout Contact) {
        contact.backendChannelId = beep.channelId
        contact.channelId = ContactDirectory.stableChannelUUID(for: beep.channelId)
        contact.remoteUserId = beep.direction == "incoming" ? beep.fromUserId : beep.toUserId
    }

    func markIncomingBeepHandledLocally(
        contactID: UUID,
        beep: TurboBeepResponse?,
        relationship: BeepThreadProjection,
        reason: String
    ) {
        guard relationship.hasIncomingBeep || beep != nil else { return }
        let requestCount = max(relationship.requestCount ?? 0, beep?.requestCount ?? 0)
        backendSyncCoordinator.send(
            .incomingBeepHandled(
                contactID: contactID,
                beep: beep,
                requestCount: requestCount,
                now: Date()
            )
        )
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .contactOpened(contactID: contactID, beepID: beep?.beepId)
        )
        diagnostics.record(
            .backend,
            message: "Marked incoming Beep handled locally",
            metadata: [
                "contactId": contactID.uuidString,
                "beepId": beep?.beepId ?? "none",
                "requestCount": "\(requestCount)",
                "reason": reason,
            ]
        )
    }

    private func applyDirectChannelMetadata(
        _ channel: TurboDirectChannelResponse,
        currentUserID: String?,
        to contact: inout Contact
    ) {
        contact.backendChannelId = channel.channelId
        contact.channelId = ContactDirectory.stableChannelUUID(for: channel.channelId)
        guard let currentUserID else { return }

        if channel.lowUserId == currentUserID {
            contact.remoteUserId = channel.highUserId
        } else if channel.highUserId == currentUserID {
            contact.remoteUserId = channel.lowUserId
        }
    }

    private func backendPeerIdentityQuery(
        handle: String,
        remoteUserId: String?
    ) -> (otherHandle: String?, otherUserId: String?) {
        if let remoteUserId, !remoteUserId.isEmpty {
            return (nil, remoteUserId)
        }
        return (handle, nil)
    }

    private func performOpenFriend(handle: String) async {
        guard let backend = backendServices else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        do {
            let remoteUser = try await backend.resolveIdentity(reference: handle)
            guard remoteUser.userId != backend.currentUserID else {
                backendCommandCoordinator.send(.operationFailed("cannot open self"))
                statusMessage = "Pick another handle"
                backendStatusMessage = "That handle belongs to this device account"
                return
            }
            let contactID = ensureContactExists(
                handle: remoteUser.publicId,
                remoteUserId: remoteUser.userId,
                channelId: "",
                displayName: remoteUser.profileName
            )
            // Make the new Friend authoritative before any further awaits so background sync
            // cannot prune the selection candidate out from under the open-friend flow.
            trackContact(contactID)
            if let contact = contacts.first(where: { $0.id == contactID }) {
                selectContact(contact)
            }
            do {
                _ = try await backend.rememberContact(otherUserId: remoteUser.userId)
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Remember contact failed",
                    metadata: [
                        "reference": handle,
                        "publicId": remoteUser.publicId,
                        "error": error.localizedDescription,
                    ]
                )
            }
            if let presence = try? await backend.lookupPresence(handle: remoteUser.publicId) {
                updateContact(contactID) { contact in
                    contact.name = remoteUser.profileName
                    contact.handle = Contact.normalizedHandle(remoteUser.publicId)
                    contact.isOnline = presence.isOnline
                    contact.remoteUserId = presence.userId
                }
            }
            await refreshContactSummaries()
            await refreshBeeps()
            backendCommandCoordinator.send(.operationFinished)
            diagnostics.record(
                .state,
                message: "Opened friend identity",
                metadata: ["reference": handle, "publicId": remoteUser.publicId]
            )
        } catch {
            let message = error.localizedDescription
            backendCommandCoordinator.send(.operationFailed(message))
            backendStatusMessage = "Lookup failed: \(message)"
            statusMessage = "Lookup failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Friend lookup failed",
                metadata: ["reference": handle, "error": message]
            )
        }
    }

    func beepMatchesJoinRequest(_ beep: TurboBeepResponse, request: BackendJoinRequest, direction: String) -> Bool {
        guard beep.direction == direction else { return false }

        let normalizedHandle = Contact.normalizedHandle(request.handle)
        let expectedChannelID = request.existingBackendChannelID
        let expectedRemoteUserID = request.existingRemoteUserID

        if let expectedChannelID, beep.channelId == expectedChannelID {
            return true
        }

        switch direction {
        case "incoming":
            if beep.fromHandle.map(Contact.normalizedHandle) == normalizedHandle {
                return true
            }
            if let expectedRemoteUserID, beep.fromUserId == expectedRemoteUserID {
                return true
            }
        case "outgoing":
            if beep.toHandle.map(Contact.normalizedHandle) == normalizedHandle {
                return true
            }
            if let expectedRemoteUserID, beep.toUserId == expectedRemoteUserID {
                return true
            }
        default:
            break
        }

        return false
    }

    func isPendingBeep(_ beep: TurboBeepResponse) -> Bool {
        beep.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
    }

    func freshestMatchingIncomingBeep(
        for request: BackendJoinRequest,
        cachedBeep: TurboBeepResponse?,
        fetchedBeeps: [TurboBeepResponse],
        excludingBeepIDs: Set<String> = []
    ) -> TurboBeepResponse? {
        let fetched = fetchedBeeps
            .filter { beep in
                !excludingBeepIDs.contains(beep.beepId)
                    && isPendingBeep(beep)
                    && beepMatchesJoinRequest(beep, request: request, direction: "incoming")
            }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
            .first
        if let fetched {
            return fetched
        }

        guard let cachedBeep,
              !excludingBeepIDs.contains(cachedBeep.beepId),
              isPendingBeep(cachedBeep),
              beepMatchesJoinRequest(cachedBeep, request: request, direction: "incoming") else {
            return nil
        }
        return cachedBeep
    }

    func cachedIncomingBeepForFastAccept(
        for request: BackendJoinRequest,
        excludingBeepIDs: Set<String> = []
    ) -> TurboBeepResponse? {
        guard request.relationship.hasIncomingBeep,
              let cachedBeep = request.incomingBeep,
              !excludingBeepIDs.contains(cachedBeep.beepId),
              isPendingBeep(cachedBeep),
              beepMatchesJoinRequest(cachedBeep, request: request, direction: "incoming") else {
            return nil
        }
        return cachedBeep
    }

    private func resolveIncomingBeep(
        for request: BackendJoinRequest,
        backend: BackendServices,
        excludingBeepIDs: Set<String> = []
    ) async throws -> TurboBeepResponse? {
        guard request.relationship.hasIncomingBeep else { return nil }

        if let cachedBeep = cachedIncomingBeepForFastAccept(
            for: request,
            excludingBeepIDs: excludingBeepIDs
        ) {
            diagnostics.record(
                .backend,
                message: "Using cached incoming beep for fast accept",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "beepId": cachedBeep.beepId,
                ]
            )
            return cachedBeep
        }

        do {
            let incomingBeeps = try await backend.incomingBeeps()
            let beep = freshestMatchingIncomingBeep(
                for: request,
                cachedBeep: request.incomingBeep,
                fetchedBeeps: incomingBeeps,
                excludingBeepIDs: excludingBeepIDs
            )
            if let cachedBeep = request.incomingBeep,
               let beep,
               cachedBeep.beepId != beep.beepId {
                diagnostics.record(
                    .backend,
                    message: "Using fresher incoming beep instead of cached beep",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "cachedBeepId": cachedBeep.beepId,
                        "freshBeepId": beep.beepId,
                    ]
                )
            }
            return beep
        } catch {
            guard let cachedBeep = freshestMatchingIncomingBeep(
                for: request,
                cachedBeep: request.incomingBeep,
                fetchedBeeps: [],
                excludingBeepIDs: excludingBeepIDs
            ) else {
                throw error
            }
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Falling back to cached incoming beep after refresh failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "beepId": cachedBeep.beepId,
                    "error": error.localizedDescription,
                ]
            )
            return cachedBeep
        }
    }

    private func acceptIncomingBeepForJoinRequest(
        _ request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> TurboBeepResponse? {
        guard request.relationship.hasIncomingBeep else { return nil }
        var attemptedBeepIDs: Set<String> = []

        for _ in 0 ..< 2 {
            guard let beep = try await resolveIncomingBeep(
                for: request,
                backend: backend,
                excludingBeepIDs: attemptedBeepIDs
            ) else {
                return nil
            }
            attemptedBeepIDs.insert(beep.beepId)

            let acceptedBeep: TurboBeepResponse
            do {
                acceptedBeep = try await backend.acceptBeep(beepId: beep.beepId)
            } catch {
                guard shouldIgnoreIncomingBeepAcceptFailure(error) else {
                    throw error
                }
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Ignoring stale incoming beep accept failure; retrying with current pending beep",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "beepId": beep.beepId,
                        "error": error.localizedDescription,
                    ]
                )
                continue
            }
            if acceptedBeep.pendingJoin != false {
                Task(priority: .userInitiated) { @MainActor [weak self] in
                    await self?.publishJoinAcceptedControlSignalIfPossible(
                        request: request,
                        acceptedBeep: acceptedBeep,
                        backend: backend
                    )
                }
                Task { @MainActor [weak self] in
                    await self?.waitForAcceptedIncomingBeepToDisappear(
                        acceptedBeep,
                        request: request,
                        backend: backend
                    )
                }
                return acceptedBeep
            }

            diagnostics.record(
                .backend,
                level: .notice,
                message: "Accepted stale incoming beep; retrying with current pending beep",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "beepId": beep.beepId,
                    "status": acceptedBeep.status,
                ]
            )
        }

        return nil
    }

    func publishJoinAcceptedControlSignalIfPossible(
        request: BackendJoinRequest,
        acceptedBeep: TurboBeepResponse,
        backend: BackendServices
    ) async {
        guard backend.supportsWebSocket else { return }
        guard let currentUserID = backend.currentUserID else { return }

        let remoteUserID: String
        if currentUserID == acceptedBeep.toUserId {
            remoteUserID = acceptedBeep.fromUserId
        } else if currentUserID == acceptedBeep.fromUserId {
            remoteUserID = acceptedBeep.toUserId
        } else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Join accepted control signal skipped because beep ownership is inconsistent",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "beepId": acceptedBeep.beepId,
                    "currentUserId": currentUserID,
                    "fromUserId": acceptedBeep.fromUserId,
                    "toUserId": acceptedBeep.toUserId,
                ]
            )
            return
        }

        let peerDeviceID = directQuicPeerDeviceID(for: request.contactID) ?? ""
        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: acceptedBeep.beepId,
            channelId: acceptedBeep.channelId,
            fromDeviceId: backend.deviceID,
            toDeviceId: peerDeviceID,
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric,
            debugBypass: false
        )

        do {
            let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
                channelId: acceptedBeep.channelId,
                fromUserId: currentUserID,
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Published join accepted control signal",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": acceptedBeep.channelId,
                    "beepId": acceptedBeep.beepId,
                    "targetUserId": remoteUserID,
                    "targetDeviceId": peerDeviceID.isEmpty ? "prejoin-fresh-device" : peerDeviceID,
                    "targetDeviceSource": peerDeviceID.isEmpty ? "fresh-presence" : "readiness-or-recent-peer-device",
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Join accepted control signal send failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": acceptedBeep.channelId,
                    "beepId": acceptedBeep.beepId,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func resolveOutgoingBeep(
        for request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> TurboBeepResponse? {
        guard request.relationship.hasOutgoingBeep else { return nil }
        if let beep = request.outgoingBeep {
            return beep
        }

        let outgoingBeeps = try await backend.outgoingBeeps()
        return outgoingBeeps.first { beepMatchesJoinRequest($0, request: request, direction: "outgoing") }
    }

    func shouldReplaceExistingOutgoingBeep(for request: BackendJoinRequest) -> Bool {
        guard request.intent == .requestConnection else { return false }
        guard !request.relationship.hasIncomingBeep else { return false }
        guard request.relationship.hasOutgoingBeep else { return false }
        return request.beepCooldownRemaining == nil
    }

    func shouldCreateOutgoingBeepWithoutMetadataPrefetch(for request: BackendJoinRequest) -> Bool {
        guard request.intent == .requestConnection else { return false }
        guard !request.relationship.hasIncomingBeep else { return false }
        guard !request.relationship.hasOutgoingBeep else { return false }
        guard request.outgoingBeep == nil else { return false }
        return request.beepCooldownRemaining == nil
    }

    func shouldResolveOutgoingBeepBeforeJoin(
        for request: BackendJoinRequest,
        contact: Contact
    ) -> Bool {
        guard request.relationship.hasOutgoingBeep else { return false }
        guard request.intent == .joinAcceptedOutgoingBeep else { return true }

        let hasKnownChannel = contact.backendChannelId != nil || request.existingBackendChannelID != nil
        let hasKnownPeer = contact.remoteUserId != nil || request.existingRemoteUserID != nil
        return !(hasKnownChannel && hasKnownPeer)
    }

    private func resolveBackendJoinContact(_ request: BackendJoinRequest) async throws -> ResolvedBackendJoinContact {
        guard let backend = backendServices else {
            throw TurboBackendError.invalidConfiguration
        }
        guard let index = contacts.firstIndex(where: { $0.id == request.contactID }) else {
            throw TurboBackendError.invalidResponse
        }

        var contact = contacts[index]
        var createdBeep: TurboBeepResponse?
        let shouldReplaceOutgoingBeep = shouldReplaceExistingOutgoingBeep(for: request)
        let shouldCreateOutgoingBeepWithoutMetadataPrefetch =
            shouldCreateOutgoingBeepWithoutMetadataPrefetch(for: request)

        if contact.remoteUserId == nil,
           !shouldCreateOutgoingBeepWithoutMetadataPrefetch {
            let remoteUser = try await backend.resolveIdentity(reference: request.handle)
            contact.remoteUserId = remoteUser.userId
            contact.handle = remoteUser.publicId
            contact.name = remoteUser.profileName
        }

        if request.relationship.hasIncomingBeep,
           request.relationship.hasOutgoingBeep,
           let outgoingBeep = try await resolveOutgoingBeep(for: request, backend: backend) {
            do {
                _ = try await backend.cancelBeep(beepId: outgoingBeep.beepId)
                diagnostics.record(
                    .backend,
                    message: "Cancelled superseded outgoing Beep before incoming join",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            } catch {
                guard shouldIgnoreBeepNotFoundFailure(error) else {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Cancel superseded outgoing Beep failed",
                        metadata: ["contactId": request.contactID.uuidString, "handle": request.handle, "error": error.localizedDescription]
                    )
                    throw error
                }
                diagnostics.record(
                    .backend,
                    message: "Ignoring stale superseded outgoing Beep cancel failure",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            }
        }

        if shouldReplaceOutgoingBeep,
           let outgoingBeep = try await resolveOutgoingBeep(for: request, backend: backend) {
            do {
                _ = try await backend.cancelBeep(beepId: outgoingBeep.beepId)
                diagnostics.record(
                    .backend,
                    message: "Cancelled stale outgoing Beep before sending Beep again",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            } catch {
                guard shouldIgnoreBeepNotFoundFailure(error) else {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Cancel outgoing Beep before Beep Again failed",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "error": error.localizedDescription,
                        ]
                    )
                    throw error
                }
                diagnostics.record(
                    .backend,
                    message: "Ignoring stale outgoing Beep cancel failure during Beep Again",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            }
        }

        let shouldAcceptIncomingBeep = request.relationship.hasIncomingBeep && request.contactIsOnline
        if shouldAcceptIncomingBeep,
           let beep = try await acceptIncomingBeepForJoinRequest(request, backend: backend) {
            applyBeepMetadata(beep, to: &contact)
        } else if request.relationship.hasIncomingBeep && request.contactIsOnline {
            diagnostics.record(
                .backend,
                message: "Proceeding without incoming beep metadata",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
            )
        } else if request.relationship.hasIncomingBeep {
            diagnostics.record(
                .backend,
                message: "Treating offline incoming Beep as ask-back",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
            )
        }

        if !shouldCreateOutgoingBeepWithoutMetadataPrefetch,
           contact.backendChannelId == nil || shouldAcceptIncomingBeep {
            let identityQuery = backendPeerIdentityQuery(
                handle: request.handle,
                remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
            )
            let channel = try await backend.directChannel(
                otherHandle: identityQuery.otherHandle,
                otherUserId: identityQuery.otherUserId
            )
            applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &contact)
        }

        let existingBackendConversationSnapshot = backendJoinNeedsExistingConversationSnapshot(request: request)
            ? await existingConversationSnapshot(for: contact, backend: backend)
            : nil

        if !shouldReplaceOutgoingBeep,
           shouldResolveOutgoingBeepBeforeJoin(for: request, contact: contact),
           let beep = try await resolveOutgoingBeep(for: request, backend: backend) {
            applyBeepMetadata(beep, to: &contact)
        } else if request.intent == .requestConnection,
                  (!request.relationship.hasIncomingBeep || !request.contactIsOnline),
                  request.beepCooldownRemaining == nil {
            let identityQuery = backendPeerIdentityQuery(
                handle: request.handle,
                remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
            )
            let beep = try await backend.createBeep(
                friendHandle: identityQuery.otherHandle,
                friendUserId: identityQuery.otherUserId,
                operationId: request.operationID
            )
            createdBeep = beep
            applyBeepMetadata(beep, to: &contact)
            if beep.direction == "outgoing" {
                recentOutgoingJoinAcceptedTokensByContactID[request.contactID] =
                    RecentOutgoingJoinAcceptedToken(
                        beepId: beep.beepId,
                        channelId: beep.channelId,
                        createdAt: Date()
                    )
                recentOutgoingBeepEvidenceByContactID[request.contactID] =
                    RecentOutgoingBeepEvidence(
                        channelId: beep.channelId,
                        requestCount: max(beep.requestCount, request.relationship.requestCount ?? 0),
                        observedAt: Date()
                    )
                backendSyncCoordinator.send(
                    .outgoingBeepSeeded(
                        contactID: request.contactID,
                        beep: beep,
                        now: Date()
                    )
                )
            }
            clearOptimisticOutgoingBeep(
                contactID: request.contactID,
                reason: "backend-beep-resolved"
            )
        }

        contacts[index] = contact
        return ResolvedBackendJoinContact(
            contact: contact,
            executionPlan: backendJoinExecutionPlan(
                request: request,
                createdBeep: createdBeep,
                existingConversationSnapshot: existingBackendConversationSnapshot
            )
        )
    }

    private func refreshJoinChannelMetadata(
        for contact: Contact,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> Contact {
        let identityQuery = backendPeerIdentityQuery(
            handle: request.handle,
            remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
        )
        let channel = try await backend.directChannel(
            otherHandle: identityQuery.otherHandle,
            otherUserId: identityQuery.otherUserId
        )

        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else {
            throw TurboBackendError.invalidResponse
        }

        var refreshedContact = contacts[index]
        applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &refreshedContact)
        contacts[index] = refreshedContact

        diagnostics.record(
            .backend,
            message: "Refreshed backend channel metadata after join drift",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "channelId": channel.channelId,
            ]
        )

        return refreshedContact
    }

    private func refreshJoinContactMetadata(
        for request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> BackendJoinRequest {
        guard let index = contacts.firstIndex(where: { $0.id == request.contactID }) else {
            throw TurboBackendError.invalidResponse
        }

        var refreshedContact = contacts[index]
        let remoteUser = try await backend.resolveIdentity(reference: request.handle)
        refreshedContact.remoteUserId = remoteUser.userId
        refreshedContact.handle = remoteUser.publicId
        refreshedContact.name = remoteUser.profileName

        let identityQuery = backendPeerIdentityQuery(
            handle: request.handle,
            remoteUserId: remoteUser.userId
        )
        let channel = try await backend.directChannel(
            otherHandle: identityQuery.otherHandle,
            otherUserId: identityQuery.otherUserId
        )
        applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &refreshedContact)

        contacts[index] = refreshedContact

        await refreshContactSummaries()
        await refreshBeeps()
        await refreshChannelState(for: refreshedContact.id)

        diagnostics.record(
            .backend,
            message: "Refreshed join contact metadata after backend drift",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "channelId": refreshedContact.backendChannelId ?? "none",
            ]
        )

        return BackendJoinRequest(
            contactID: refreshedContact.id,
            handle: refreshedContact.handle,
            intent: request.intent,
            operationID: request.operationID,
            joinOperationID: backendChannelJoinOperationID(for: refreshedContact, intent: request.intent),
            relationship: beepThreadProjection(for: refreshedContact.id),
            existingRemoteUserID: refreshedContact.remoteUserId,
            existingBackendChannelID: refreshedContact.backendChannelId,
            incomingBeep: incomingBeepByContactID[refreshedContact.id],
            outgoingBeep: outgoingBeepByContactID[refreshedContact.id],
            beepCooldownRemaining: beepCooldownRemaining(for: refreshedContact.id),
            usesLocalHTTPBackend: request.usesLocalHTTPBackend,
            contactIsOnline: refreshedContact.isOnline
        )
    }

    func backendConnectOperationID(for contact: Contact, intent: BackendJoinIntent) -> String? {
        guard intent == .requestConnection else { return nil }
        let stablePeerKey = contact.remoteUserId ?? Contact.normalizedHandle(contact.handle)
        let channelKey = contact.backendChannelId ?? "no-channel"
        let deviceKey = backendServices?.deviceID ?? backendConfig?.deviceID ?? "no-device"
        return [
            "connect",
            deviceKey,
            contact.id.uuidString.lowercased(),
            stablePeerKey,
            channelKey,
            UUID().uuidString.lowercased(),
        ].joined(separator: ":")
    }

    func backendChannelJoinOperationID(for contact: Contact, intent: BackendJoinIntent) -> String? {
        let channelKey = contact.backendChannelId ?? "no-channel"
        let deviceKey = backendServices?.deviceID ?? backendConfig?.deviceID ?? "no-device"
        return [
            "join",
            deviceKey,
            contact.id.uuidString.lowercased(),
            channelKey,
            String(describing: intent),
            UUID().uuidString.lowercased(),
        ].joined(separator: ":")
    }

    func prepareBackendJoinControlPlaneIfNeeded(
        _ backend: BackendServices,
        request: BackendJoinRequest
    ) async throws {
        if shouldRefreshBackendJoinConversationEvidenceBeforeJoin(
            request: request,
            supportsWebSocket: backend.supportsWebSocket,
            isWebSocketConnected: backend.isWebSocketConnected
        ) {
            await refreshBackendJoinConversationEvidence(backend, request: request)
        } else {
            diagnostics.record(
                .backend,
                message: "Skipped backend Conversation evidence refresh before accepted join",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "intent": String(describing: request.intent),
                ]
            )
        }
        guard backend.supportsWebSocket else { return }
        guard !backend.isWebSocketConnected else { return }

        diagnostics.record(
            .backend,
            message: "Waiting for backend WebSocket before join",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
            ]
        )
        do {
            try await backend.waitForWebSocketConnection()
        } catch {
            if request.deviceSessionProof != nil {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Continuing backend join with HTTP fallback after WebSocket remained unavailable",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "error": error.localizedDescription,
                        "deviceSessionProof": request.deviceSessionProof?.rawValue ?? "none",
                    ]
                )
                return
            }
            diagnostics.record(
                .backend,
                level: .error,
                message: "Aborting backend join while WebSocket remains unavailable",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    func shouldRefreshBackendJoinConversationEvidenceBeforeJoin(
        request: BackendJoinRequest,
        supportsWebSocket: Bool,
        isWebSocketConnected: Bool
    ) -> Bool {
        !(request.intent == .joinAcceptedOutgoingBeep
            && supportsWebSocket
            && isWebSocketConnected)
    }

    func backendJoinVisibilityIsAuthoritative(
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse?,
        localDevicePTTEvidenceEstablished: Bool = false,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) -> Bool {
        guard channelState.membership.hasLocalMembership else { return false }
        if readiness?.selfHasActiveDevice == true {
            return true
        }
        return deviceSessionProof == .pttSystem && localDevicePTTEvidenceEstablished
    }

    func refreshBackendJoinConversationEvidence(
        _ backend: BackendServices,
        request: BackendJoinRequest
    ) async {
        do {
            _ = try await backend.heartbeatPresence()
            diagnostics.record(
                .backend,
                message: "Refreshed backend Conversation evidence before join",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "intent": String(describing: request.intent),
                ]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Backend Conversation evidence refresh before join failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "intent": String(describing: request.intent),
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func performRecoverableBackendJoin(
        contact: Contact,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> Contact {
        guard let backendChannelId = contact.backendChannelId else {
            throw TurboBackendError.invalidResponse
        }

        do {
            try await prepareBackendJoinControlPlaneIfNeeded(backend, request: request)
            try await performBackendJoinCommand(
                channelId: backendChannelId,
                request: request,
                backend: backend
            )
            return contact
        } catch {
            guard shouldTreatBackendJoinChannelNotFoundAsRecoverable(error) else {
                if await waitForBackendJoinMembershipVisibility(
                    channelId: backendChannelId,
                    contactID: contact.id,
                    request: request,
                    backend: backend,
                    attempts: 4,
                    intervalNanoseconds: 250_000_000
                ) {
                    diagnostics.record(
                        .backend,
                        message: "Backend join command failed after membership became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": backendChannelId,
                            "error": error.localizedDescription,
                        ]
                    )
                    return contact
                }
                throw error
            }

            diagnostics.record(
                .backend,
                message: "Recovering backend join after channel drift",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "channelId": backendChannelId,
                ]
            )

            let refreshedContact = try await refreshJoinChannelMetadata(for: contact, request: request, backend: backend)
            guard let refreshedChannelId = refreshedContact.backendChannelId else {
                throw TurboBackendError.invalidResponse
            }
            try await prepareBackendJoinControlPlaneIfNeeded(backend, request: request)
            try await performBackendJoinCommand(
                channelId: refreshedChannelId,
                request: request,
                backend: backend,
                operationId: backendChannelJoinOperationID(for: refreshedContact, intent: request.intent) ?? request.joinOperationID
            )
            return refreshedContact
        }
    }

    private func performBackendJoinCommand(
        channelId: String,
        request: BackendJoinRequest,
        backend: BackendServices,
        operationId: String? = nil
    ) async throws {
        let joinOperationID = operationId ?? request.joinOperationID
        diagnostics.record(
            .backend,
            message: "Backend join command started",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "channelId": channelId,
                "operationId": joinOperationID ?? "none",
                "intent": String(describing: request.intent),
            ]
        )
        try await withThrowingTaskGroup(of: BackendJoinCommandOutcome.self) { group in
            group.addTask { @MainActor in
                _ = try await backend.joinChannel(
                    channelId: channelId,
                    operationId: joinOperationID,
                    deviceSessionProof: request.deviceSessionProof
                )
                return .commandReturned
            }
            group.addTask { @MainActor in
                await self.waitForBackendJoinMembershipVisibility(
                    channelId: channelId,
                    contactID: request.contactID,
                    request: request,
                    backend: backend,
                    attempts: 16,
                    intervalNanoseconds: 250_000_000
                ) ? .membershipVisible : .visibilityTimedOut
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return .commandTimedOut
            }

            var commandReturned = false
            while let outcome = try await group.next() {
                switch outcome {
                case .commandReturned:
                    commandReturned = true
                    diagnostics.record(
                        .backend,
                        message: "Backend join command response returned",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": channelId,
                            "operationId": joinOperationID ?? "none",
                        ]
                    )
                    continue
                case .membershipVisible:
                    group.cancelAll()
                    diagnostics.record(
                        .backend,
                        message: "Backend join membership became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": channelId,
                        ]
                    )
                    return
                case .visibilityTimedOut:
                    guard !commandReturned else {
                        group.cancelAll()
                        diagnostics.record(
                            .backend,
                            level: .error,
                            message: "Backend join command returned before authoritative membership became visible",
                            metadata: [
                                "contactId": request.contactID.uuidString,
                                "handle": request.handle,
                                "channelId": channelId,
                                "operationId": joinOperationID ?? "none",
                            ]
                        )
                        throw TurboBackendError.server("backend join membership not visible after accepted command")
                    }
                    continue
                case .commandTimedOut:
                    group.cancelAll()
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Backend join command timed out",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": channelId,
                            "operationId": joinOperationID ?? "none",
                        ]
                    )
                    throw TurboBackendError.server("backend join command timed out")
                }
            }
        }
    }

    private func refreshBackendJoinVisibility(for contactID: UUID) async {
        await refreshChannelState(for: contactID)
        await refreshContactSummaries()
        await refreshBeeps()
        updateStatusForSelectedContact()
    }

    func applyAcceptedBackendJoinProjection(for contact: Contact, backend: BackendServices) {
        guard let backendChannelId = contact.backendChannelId else { return }

        let existing = backendSyncCoordinator.state.syncState.channelStates[contact.id]
        let peerMembership = existing?.membership
        let peerJoined = peerMembership?.hasPeerMembership ?? false
        let peerDeviceConnected = peerMembership?.peerDeviceConnected ?? false
        let membership: TurboChannelMembership = peerJoined
            ? .both(peerDeviceConnected: peerDeviceConnected)
            : .selfOnly
        let preservesLiveStatus =
            existing?.conversationStatus == .ready
            || existing?.conversationStatus == .transmitting
            || existing?.conversationStatus == .receiving
        let projectedState: TurboChannelStateResponse = {
            if let existing {
                if preservesLiveStatus {
                    return existing.settingMembership(membership)
                }
                return TurboChannelStateResponse(
                    channelId: existing.channelId,
                    selfUserId: existing.selfUserId,
                    peerUserId: existing.peerUserId,
                    peerHandle: existing.peerHandle,
                    selfOnline: existing.selfOnline,
                    peerOnline: existing.peerOnline,
                    selfJoined: true,
                    peerJoined: peerJoined,
                    peerDeviceConnected: peerDeviceConnected,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: existing.activeTransmitterUserId,
                    activeTransmitId: existing.activeTransmitId,
                    transmitLeaseExpiresAt: existing.transmitLeaseExpiresAt,
                    stateEpoch: existing.stateEpoch,
                    serverTimestamp: existing.serverTimestamp,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                )
            }
            return TurboChannelStateResponse(
                channelId: backendChannelId,
                selfUserId: backend.currentUserID ?? "",
                peerUserId: contact.remoteUserId ?? "",
                peerHandle: contact.handle,
                selfOnline: true,
                peerOnline: contact.isOnline,
                selfJoined: true,
                peerJoined: false,
                peerDeviceConnected: false,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                activeTransmitId: nil,
                transmitLeaseExpiresAt: nil,
                stateEpoch: nil,
                serverTimestamp: nil,
                status: ConversationState.waitingForPeer.rawValue,
                canTransmit: false
            )
        }()

        backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contact.id, channelState: projectedState)
        )
        diagnostics.record(
            .backend,
            message: "Applied accepted backend join projection",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "channelId": backendChannelId,
                "membership": String(describing: projectedState.membership),
                "status": projectedState.status,
            ]
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("backend-join:accepted-projection")
    }

    private func waitForBackendJoinMembershipVisibility(
        channelId: String,
        contactID: UUID,
        request: BackendJoinRequest,
        backend: BackendServices,
        attempts: Int,
        intervalNanoseconds: UInt64
    ) async -> Bool {
        guard attempts > 0 else { return false }

        for attempt in 1 ... attempts {
            if Task.isCancelled {
                return false
            }
            if await discardSupersededBackendJoinIfNeeded(
                request,
                stage: "membership-visibility"
            ) {
                return false
            }

            do {
                async let channelStateTask = backend.channelState(channelId: channelId)
                async let readinessTask = backend.channelReadiness(channelId: channelId)
                let channelState = try await channelStateTask
                let readiness = try? await readinessTask
                if await discardSupersededBackendJoinIfNeeded(
                    request,
                    stage: "membership-visibility-response"
                ) {
                    return false
                }
                let authoritativeVisibility = backendJoinVisibilityIsAuthoritative(
                    channelState: channelState,
                    readiness: readiness,
                    localDevicePTTEvidenceEstablished: devicePTTEvidenceExists(for: contactID),
                    deviceSessionProof: request.deviceSessionProof
                )
                if !channelState.membership.hasLocalMembership || authoritativeVisibility {
                    backendSyncCoordinator.send(.channelStateUpdated(contactID: contactID, channelState: channelState))
                    if let readiness {
                        applyChannelReadiness(readiness, for: contactID, reason: "backend-join-visibility")
                    }
                } else {
                    diagnostics.record(
                        .backend,
                        level: .notice,
                        message: "Ignored stale backend join membership while active device readiness is missing",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": channelId,
                            "attempt": "\(attempt)",
                            "channelStatus": channelState.statusKind,
                            "readinessStatus": readiness?.statusKind ?? "none",
                            "selfHasActiveDevice": String(readiness?.selfHasActiveDevice ?? false),
                        ]
                    )
                }
                if authoritativeVisibility {
                    if attempt > 1 {
                        diagnostics.record(
                            .backend,
                            message: "Backend join visibility converged before command response",
                            metadata: [
                                "contactId": request.contactID.uuidString,
                                "handle": request.handle,
                                "channelId": channelId,
                                "attempt": "\(attempt)",
                                "status": channelState.status,
                            ]
                        )
                    }
                    return true
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Backend join visibility check failed while command was pending",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "channelId": channelId,
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                    ]
                )
            }

            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        return false
    }

    private func executeBackendJoin(_ request: BackendJoinRequest) async throws {
        guard !(await discardSupersededBackendJoinIfNeeded(request, stage: "start")) else {
            return
        }

        let resolution = try await resolveBackendJoinContact(request)
        var contact = resolution.contact
        guard !(await discardSupersededBackendJoinIfNeeded(
            request,
            stage: "resolved",
            contact: contact,
            backend: backendServices
        )) else {
            return
        }

        switch resolution.executionPlan {
        case .beepOnly:
            conversationActionCoordinator.clearPendingConnect(for: request.contactID)
            updateStatusForSelectedContact()
        case .joinConversation:
            if let backend = backendServices {
                contact = try await performRecoverableBackendJoin(
                    contact: contact,
                    request: request,
                    backend: backend
                )
                guard !(await discardSupersededBackendJoinIfNeeded(
                    request,
                    stage: "join-command-returned",
                    contact: contact,
                    backend: backend
                )) else {
                    return
                }
                diagnostics.record(
                    .backend,
                    message: "Backend join completed",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "channelId": contact.backendChannelId ?? "none",
                    ]
                )
                applyAcceptedBackendJoinProjection(for: contact, backend: backend)
            }
            if request.usesLocalHTTPBackend {
                completeLocalBackendJoin(for: contact)
            } else {
                startLocalJoinAfterAcceptedBackendJoin(for: contact)
            }
            Task { @MainActor [weak self, contactID = contact.id] in
                guard let self,
                      self.desiredLocalReceiverAudioReadiness(for: contactID),
                      self.peerIsRoutableForReceiverAudioReadiness(for: contactID) else {
                    return
                }
                await self.syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .channelRefresh
                )
            }
        }

        if activeBackendJoinMatches(request) {
            backendCommandCoordinator.send(.operationFinished)
        } else {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Skipped backend join completion for superseded operation",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "activeBackendOperation": String(describing: backendCommandCoordinator.state.activeOperation),
                ]
            )
        }
        Task { @MainActor [weak self, contactID = contact.id] in
            await self?.refreshBackendJoinVisibility(for: contactID)
        }
    }

    private func performBackendJoin(_ request: BackendJoinRequest) async {
        do {
            do {
                try await executeBackendJoin(request)
            } catch {
                if shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(error),
                   let backend = backendServices,
                   backend.supportsWebSocket {
                    diagnostics.record(
                        .backend,
                        message: "Recovering backend join after disconnected Device session drift",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                        ]
                    )
                    await reconnectBackendControlPlane()
                    try await executeBackendJoin(request)
                } else {
                    guard let backend = backendServices,
                          shouldTreatBackendJoinMetadataFailureAsRecoverable(error) else {
                        throw error
                    }

                    diagnostics.record(
                        .backend,
                        message: "Recovering backend join after metadata drift",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                        ]
                    )

                    let refreshedRequest = try await refreshJoinContactMetadata(for: request, backend: backend)
                    try await executeBackendJoin(refreshedRequest)
                }
            }
        } catch {
            if await discardSupersededBackendJoinIfNeeded(request, stage: "failed") {
                return
            }
            let message = error.localizedDescription
            let failedActiveJoin =
                conversationActionCoordinator.pendingAction.pendingConnectContactID == request.contactID
                || conversationActionCoordinator.pendingAction.pendingJoinContactID == request.contactID
            if activeBackendJoinMatches(request) {
                backendCommandCoordinator.send(.operationFailed(message))
            }
            clearOptimisticOutgoingBeep(
                contactID: request.contactID,
                reason: "backend-join-failed"
            )
            conversationActionCoordinator.clearPendingConnect(for: request.contactID)
            if failedActiveJoin {
                backendSyncCoordinator.send(.channelStateCleared(contactID: request.contactID))
            }
            statusMessage = "Join failed: \(message)"
            captureDiagnosticsState("backend-join:failed")
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend join failed",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle, "error": message]
            )
        }
    }

    private func performBackendLeave(_ request: BackendLeaveRequest) async {
        guard let backend = backendServices else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            return
        }

        do {
            _ = try await backend.leaveChannel(
                channelId: request.backendChannelID,
                operationId: request.operationID
            )
            await refreshChannelState(for: request.contactID)
            await refreshContactSummaries()
            await refreshBeeps()
            completeSuccessfulBackendLeaveProjection(request)
            backendCommandCoordinator.send(.operationFinished)
        } catch {
            let message = error.localizedDescription
            await refreshChannelState(for: request.contactID)
            let leaveAlreadyApplied =
                selectedChannelSnapshot(for: request.contactID)?.membership.hasLocalMembership == false

            if leaveAlreadyApplied {
                await refreshContactSummaries()
                await refreshBeeps()
                backendCommandCoordinator.send(.operationFinished)
                diagnostics.record(
                    .backend,
                    message: "Backend leave request failed after membership was already absent",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "error": message,
                    ]
                )
                return
            }

            backendCommandCoordinator.send(.operationFailed(message))
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend leave failed",
                metadata: ["contactId": request.contactID.uuidString, "channelId": request.backendChannelID, "error": message]
            )
        }
    }

    private func completeSuccessfulBackendLeaveProjection(_ request: BackendLeaveRequest) {
        guard conversationActionCoordinator.pendingAction.isLeaveInFlight(for: request.contactID) else {
            return
        }
        guard !devicePTTEvidenceExists(for: request.contactID) else {
            return
        }

        conversationActionCoordinator.clearLeaveAction(for: request.contactID)
        replaceDisconnectRecoveryTask(with: nil)
        backendSyncCoordinator.send(.channelStateCleared(contactID: request.contactID))
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: request.contactID))
        syncEngineDisconnect(contactID: request.contactID, reason: "backend-leave-complete")
        updateStatusForSelectedContact()
        diagnostics.record(
            .backend,
            message: "Completed local projection after successful backend leave",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
            ]
        )
        captureDiagnosticsState("backend-leave:local-projection-complete")
    }
}
