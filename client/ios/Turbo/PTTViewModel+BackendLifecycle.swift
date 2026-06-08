//
//  PTTViewModel+BackendLifecycle.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    func isTransientBackendBootstrapFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)

        switch code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    func shouldAutoRetryBackendBootstrapFailure(
        _ error: Error,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        guard hasBackendConfig else { return false }
        guard !backendRuntime.isReady else { return false }
        guard (applicationState ?? currentApplicationState()) == .active else { return false }
        return isTransientBackendBootstrapFailure(error)
    }

    func shouldRecoverBackendControlPlaneAfterSyncFailure(
        _ error: Error,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        guard backendRuntime.isReady else { return false }
        guard (applicationState ?? currentApplicationState()) == .active else { return false }
        guard backendRuntime.isWebSocketConnected else { return false }
        if shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(error) {
            return true
        }
        if isTransientBackendBootstrapFailure(error) {
            return !selectedLocalSessionAppearsActive()
        }
        return false
    }

    func selectedLocalSessionAppearsActive() -> Bool {
        guard let contactID = selectedContactId else { return false }
        return devicePTTOrEngineConversationEvidenceExists(for: contactID)
    }

    func recoverBackendBootstrapIfNeeded(trigger: String) async {
        guard hasBackendConfig else { return }
        guard !backendRuntime.isReady else { return }
        guard shouldMaintainBackgroundControlPlane() else { return }
        if Self.shouldSuppressSharedAppBackendBootstrapForAutomatedTests {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Suppressed shared app backend bootstrap recovery for automated hosted probe",
                metadata: ["trigger": trigger]
            )
            captureDiagnosticsState("backend-bootstrap:recovery-suppressed-for-hosted-probe")
            return
        }

        diagnostics.record(.backend, message: "Retrying backend bootstrap", metadata: ["trigger": trigger])
        captureDiagnosticsState("backend-bootstrap:retry")
        await configureBackendIfNeeded()
    }

    func recoverBackendControlPlaneAfterSyncFailureIfNeeded(
        scope: String,
        error: Error
    ) async -> Bool {
        guard shouldRecoverBackendControlPlaneAfterSyncFailure(error) else { return false }

        diagnostics.record(
            .backend,
            message: "Recovering backend control plane after sync failure",
            metadata: [
                "scope": scope,
                "error": error.localizedDescription,
            ]
        )
        captureDiagnosticsState("backend-sync:control-plane-recovery")
        await reconnectBackendControlPlane()
        return true
    }

    func scheduleBackendBootstrapRetryIfNeeded(trigger: String, error: Error) {
        guard shouldAutoRetryBackendBootstrapFailure(error) else { return }
        guard backendRuntime.bootstrapRetryTask == nil else { return }

        let delaySeconds = Double(backendBootstrapRetryDelayNanoseconds) / 1_000_000_000
        backendStatusMessage = "Reconnecting backend..."
        updatePrimaryStatusAfterBackendBootstrapFailure(retrying: true)
        diagnostics.record(
            .backend,
            message: "Scheduling backend bootstrap retry",
            metadata: [
                "trigger": trigger,
                "delaySeconds": String(format: "%.1f", delaySeconds),
                "error": error.localizedDescription,
            ]
        )
        captureDiagnosticsState("backend-bootstrap:retry-scheduled")

        replaceBackendBootstrapRetryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.backendBootstrapRetryDelayNanoseconds)
                guard !Task.isCancelled else { return }
                self.replaceBackendBootstrapRetryTask(with: nil)
                await self.recoverBackendBootstrapIfNeeded(trigger: "\(trigger)-scheduled")
            }
        )
    }

    func disconnectBackendWebSocket() {
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "Disconnecting WebSocket for control-plane test")
        backend.suspendWebSocket()
        Task { @MainActor [weak self, backend] in
            guard let self else { return }
            do {
                _ = try await backend.backgroundPresence()
            } catch {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Failed to publish background presence after WebSocket disconnect",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
        captureDiagnosticsState("websocket:forced-disconnect")
    }

    func reconnectBackendControlPlane() async {
        diagnostics.record(.backend, message: "Reconnecting backend control plane")
        resetBackendRuntimeForReconnect()
        captureDiagnosticsState("backend:reconnect-start")
        await configureBackendIfNeeded()
        if let selectedContact = selectedContact {
            if selectedLocalSessionAppearsActive() {
                diagnostics.record(
                    .backend,
                    message: "Reasserting backend join after control-plane reconnect",
                    metadata: ["contactId": selectedContact.id.uuidString, "handle": selectedContact.handle]
                )
                await reassertBackendJoin(for: selectedContact)
            }
        }
        if let selectedContactId {
            await refreshChannelState(for: selectedContactId)
            await reconcileSelectedConversationIfNeeded()
        await syncLocalReceiverAudioReadinessSignal(
            for: selectedContactId,
            reason: .backendReconnect
        )
        }
        captureDiagnosticsState("backend:reconnect-finished")
    }

    func reassertBackendJoinAfterWebSocketReconnectIfNeeded() async {
        guard backendRuntime.isReady else { return }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return }
        guard let contact = signalingJoinRecoveryContact() else { return }

        diagnostics.record(
            .backend,
            message: "Reasserting backend join after WebSocket reconnect",
            metadata: ["contactId": contact.id.uuidString, "handle": contact.handle]
        )
        captureDiagnosticsState("websocket:join-reassertion")
        await reassertBackendJoin(for: contact)
    }

    func handleBackendServerNotice(_ message: String) {
        backendStatusMessage = message
        diagnostics.record(.websocket, message: "Backend server notice", metadata: ["message": message])

        if shouldRecoverReceiverAudioReadinessDeliveryRejection(from: message),
           let contact = signalingJoinRecoveryContact() {
            if backendRuntime.reserveReceiverAudioReadinessDeliveryRecovery(for: contact.id) {
                controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contact.id))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshChannelState(
                        for: contact.id,
                        receiverReadinessReason: .backendSignalingRecovery
                    )
                    await self.syncLocalReceiverAudioReadinessSignal(
                        for: contact.id,
                        reason: .backendSignalingRecovery
                    )
                }
            } else {
                diagnostics.record(
                    .backend,
                    message: "Coalesced receiver audio readiness delivery recovery",
                    metadata: [
                        "contactId": contact.id.uuidString,
                        "handle": contact.handle,
                        "notice": message,
                    ]
                )
            }
        }

        let shouldRecoverJoinDrift = shouldRecoverBackendSignalingJoinDrift(from: message)
        if shouldRecoverJoinDrift,
           let contact = signalingJoinRecoveryContact() {
            controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contact.id))
        }

        guard shouldRecoverJoinDrift,
              let contact = signalingJoinRecoveryContact(),
              backendRuntime.signalingJoinRecoveryTask == nil else {
            return
        }

        if shouldDeferBackendSignalingJoinDriftRecoveryToInFlightJoin(for: contact.id) {
            diagnostics.record(
                .backend,
                message: "Deferred backend signaling drift recovery to in-flight join",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "notice": message,
                ]
            )
            return
        }

        diagnostics.record(
            .backend,
            message: "Validating backend join drift before recovery",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "notice": message,
            ]
        )
        let contactID = contact.id
        replaceBackendSignalingJoinRecoveryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.backendRuntime.signalingJoinRecoveryTask = nil
                    self.updateStatusForSelectedContact()
                }
                if self.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil,
                   self.shouldReassertBackendJoinAfterSignalingDrift(for: contactID) {
                    self.diagnostics.record(
                        .backend,
                        message: "Reasserting backend join after signaling drift notice without cached channel state",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": contact.handle,
                            "notice": message,
                        ]
                    )
                    await self.reassertBackendJoinAndWaitForVisibility(
                        for: contact,
                        source: "backend-signaling-drift:no-cached-channel"
                    )
                    await self.refreshChannelState(for: contactID)
                    await self.refreshContactSummaries()
                    await self.syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: .backendSignalingRecovery
                    )
                    self.captureDiagnosticsState("backend-signaling:recovered")
                    return
                }
                if self.shouldReassertBackendJoinAfterSignalingDrift(for: contactID) {
                    self.diagnostics.record(
                        .backend,
                        message: "Reasserting backend join after signaling drift notice",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": contact.handle,
                            "notice": message,
                        ]
                    )
                    await self.reassertBackendJoinAndWaitForVisibility(
                        for: contact,
                        source: "backend-signaling-drift:backend-conversation"
                    )
                    await self.refreshChannelState(for: contactID)
                    await self.refreshContactSummaries()
                    await self.syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: .backendSignalingRecovery
                    )
                    self.captureDiagnosticsState("backend-signaling:recovered")
                    return
                }
                await self.refreshChannelState(for: contactID)
                let shouldReassertAfterRefresh =
                    self.shouldReassertBackendJoinAfterSignalingDrift(for: contactID)
                    || self.shouldPreferBackendJoinReassertionForLocalConversationEvidenceAfterSignalingDrift(
                        for: contactID
                    )
                guard shouldReassertAfterRefresh else {
                    self.diagnostics.record(
                        .backend,
                        message: "Self-healing stale backend join drift by reconciling Device PTT session",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": contact.handle,
                            "notice": message,
                        ]
                    )
                    await self.reconcileSelectedConversationIfNeeded()
                    await self.refreshContactSummaries()
                    self.captureDiagnosticsState("backend-signaling:self-healed")
                    return
                }
                self.diagnostics.record(
                    .backend,
                    message: "Reasserting backend join after signaling drift notice",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": contact.handle,
                        "notice": message,
                    ]
                )
                await self.reassertBackendJoinAndWaitForVisibility(
                    for: contact,
                    source: "backend-signaling-drift:post-refresh"
                )
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
                await self.syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .backendSignalingRecovery
                )
                self.captureDiagnosticsState("backend-signaling:recovered")
            }
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("backend-signaling:recovery-scheduled")
    }

    func handleBackendWebSocketStatusNotice(_ notice: TurboWebSocketStatusNotice) {
        switch notice.status {
        case "connected":
            return
        case "peer-left":
            handleBackendPeerLeftStatusNotice(notice)
        default:
            handleBackendServerNotice("WebSocket \(notice.status)")
        }
    }

    func handleBackendPeerLeftStatusNotice(_ notice: TurboWebSocketStatusNotice) {
        guard let channelId = notice.channelId,
              let fromUserId = notice.fromUserId,
              let fromDeviceId = notice.fromDeviceId else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected peer left websocket notice because fields were missing",
                metadata: [
                    "status": notice.status,
                    "channelId": notice.channelId ?? "none",
                    "fromUserId": notice.fromUserId ?? "none",
                    "fromDeviceId": notice.fromDeviceId ?? "none",
                ]
            )
            return
        }
        guard let contact = contacts.first(where: { $0.backendChannelId == channelId }) else {
            diagnostics.record(
                .websocket,
                message: "Ignored peer left websocket notice for unknown channel",
                metadata: [
                    "channelId": channelId,
                    "fromUserId": fromUserId,
                    "fromDeviceId": fromDeviceId,
                ]
            )
            return
        }
        if let remoteUserId = contact.remoteUserId,
           remoteUserId != fromUserId {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected peer left websocket notice from unexpected peer user",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelId": channelId,
                    "fromUserId": fromUserId,
                    "expectedRemoteUserId": remoteUserId,
                    "fromDeviceId": fromDeviceId,
                ]
            )
            return
        }

        let contactID = contact.id
        diagnostics.record(
            .websocket,
            message: "Peer left websocket notice received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelId,
                "fromUserId": fromUserId,
                "fromDeviceId": fromDeviceId,
                "reason": notice.reason ?? "none",
                "leftAt": notice.leftAt ?? "none",
            ]
        )
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        if selectedContactId == contactID {
            backendStatusMessage = "Peer disconnected"
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-status:peer-left")
        }

        let devicePTTEvidenceTouchesContact =
            devicePTTEvidenceExists(for: contactID)
            || mediaSessionContactID == contactID
        let shouldStartReconciledTeardown =
            devicePTTEvidenceTouchesContact
            && !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
        if shouldStartReconciledTeardown {
            prepareReconciledTeardownState(for: contactID)
            diagnostics.record(
                .state,
                message: "Marked reconciled teardown from peer left websocket notice",
                metadata: ["contactId": contactID.uuidString, "channelId": channelId]
            )
            captureDiagnosticsState("backend-status:peer-left-reconciled")
            performReconciledTeardown(for: contactID)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshContactSummaries()
            await self.refreshChannelState(for: contactID)
        }
    }

    func shouldRecoverBackendSignalingJoinDrift(from message: String) -> Bool {
        guard backendRuntime.isReady else { return false }
        guard currentApplicationState() == .active else { return false }
        let stripped = normalizedBackendServerNotice(message)
        return stripped == "sender device is not joined to this channel"
    }

    func shouldRecoverReceiverAudioReadinessDeliveryRejection(from message: String) -> Bool {
        guard backendRuntime.isReady else { return false }
        guard currentApplicationState() == .active else { return false }
        return normalizedBackendServerNotice(message) == "target user has no connected receiving device in this channel"
    }

    func normalizedBackendServerNotice(_ message: String) -> String {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("signaling ")
            ? String(normalized.dropFirst("signaling ".count))
            : normalized
    }

    func shouldReassertBackendJoinAfterSignalingDrift(for contactID: UUID) -> Bool {
        guard signalingJoinRecoveryContact()?.id == contactID else { return false }
        guard let channelState = backendSyncCoordinator.state.syncState.channelStates[contactID] else {
            return true
        }

        switch channelState.conversationStatus {
        case nil:
            return false
        case .idle:
            return false
        case .outgoingBeep, .incomingBeep, .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        }
    }

    func shouldPreferBackendJoinReassertionForLocalConversationEvidenceAfterSignalingDrift(
        for contactID: UUID
    ) -> Bool {
        guard signalingJoinRecoveryContact()?.id == contactID else { return false }
        guard !conversationActionCoordinator.pendingAction.isExplicitLeaveInFlight(for: contactID) else { return false }
        return devicePTTOrEngineConversationEvidenceExists(for: contactID)
    }

    func shouldDeferBackendSignalingJoinDriftRecoveryToInFlightJoin(for contactID: UUID) -> Bool {
        guard backendRuntime.isBackendJoinSettling(for: contactID) else { return false }
        guard case .join(let activeRequest) = backendCommandCoordinator.state.activeOperation else {
            return false
        }
        return activeRequest.contactID == contactID
    }

    func signalingJoinRecoveryContact() -> Contact? {
        let candidateContactID = activeChannelId ?? selectedContactId
        guard let contactID = candidateContactID,
              let contact = contacts.first(where: { $0.id == contactID }),
              contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return nil
        }

        let localSessionAppearsActive =
            devicePTTOrEngineConversationEvidenceExists(for: contactID)
            || conversationActionCoordinator.pendingAction.pendingJoinContactID == contactID

        guard localSessionAppearsActive else {
            return nil
        }

        return contact
    }

    func shouldResetTransmitSessionOnWebSocketIdle(
        hasPendingBeginOrActiveTransmit: Bool,
        systemIsTransmitting: Bool
    ) -> Bool {
        let _ = hasPendingBeginOrActiveTransmit
        let _ = systemIsTransmitting
        // A transient control-plane reconnect should not forcibly end an
        // active system transmit. Lease renewal is HTTP-backed and audio sends
        // already wait briefly for the websocket to reconnect.
        return false
    }

    func runSelfCheckEffect(_ effect: DevSelfCheckEffect) async {
        switch effect {
        case .run(let request):
            await performSelfCheck(request)
        }
    }

    func runPTTSystemPolicyEffect(_ effect: PTTSystemPolicyEffect) async {
        switch effect {
        case .uploadEphemeralToken(let request):
            guard let backend = backendServices else {
                pttSystemPolicyCoordinator.send(.tokenUploadFailed("Backend unavailable"))
                return
            }
            diagnostics.record(
                .pushToTalk,
                message: "Uploading ephemeral PTT token",
                metadata: [
                    "backendChannelId": request.backendChannelID,
                    "tokenPrefix": String(request.tokenHex.prefix(8)),
                    "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                ]
            )
            do {
                let apnsEnvironment = TurboAPNSEnvironmentResolver.current()
                _ = try await backend.uploadEphemeralToken(
                    channelId: request.backendChannelID,
                    token: request.tokenHex,
                    apnsEnvironment: apnsEnvironment
                )
                pttSystemPolicyCoordinator.send(.tokenUploadFinished(request))
                diagnostics.record(
                    .pushToTalk,
                    message: "Uploaded ephemeral PTT token",
                    metadata: [
                        "backendChannelId": request.backendChannelID,
                        "tokenPrefix": String(request.tokenHex.prefix(8)),
                        "apnsEnvironment": apnsEnvironment.rawValue,
                        "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                    ]
                )
            } catch {
                let message = error.localizedDescription
                if shouldTreatEphemeralTokenUploadFailureAsStaleMembership(
                    error,
                    request: request
                ) {
                    pttSystemPolicyCoordinator.send(.reset)
                    diagnostics.record(
                        .pushToTalk,
                        message: "Ignored stale ephemeral PTT token upload failure after membership loss",
                        metadata: [
                            "backendChannelId": request.backendChannelID,
                            "tokenPrefix": String(request.tokenHex.prefix(8)),
                            "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                            "error": message,
                        ]
                    )
                    syncPTTSystemPolicyState()
                    captureDiagnosticsState("ptt-token-upload:stale-membership-ignored")
                    return
                }
                pttSystemPolicyCoordinator.send(.tokenUploadFailed(message))
                statusMessage = "Token upload failed: \(message)"
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Ephemeral PTT token upload failed",
                    metadata: [
                        "backendChannelId": request.backendChannelID,
                        "tokenPrefix": String(request.tokenHex.prefix(8)),
                        "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                        "error": message,
                    ]
                )
            }
        }
    }

    func shouldTreatEphemeralTokenUploadFailureAsStaleMembership(
        _ error: Error,
        request: PTTTokenUploadRequest
    ) -> Bool {
        guard case let TurboBackendError.server(message) = error,
              message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not a channel member" else {
            return false
        }

        guard let contact = contacts.first(where: { $0.backendChannelId == request.backendChannelID }) else {
            return false
        }

        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contact.id) {
            return true
        }

        return backendSyncCoordinator.state.syncState.channelStates[contact.id]?.membership == .absent
    }

    func backendConfigurationKey(for config: TurboBackendConfig) -> String {
        [
            config.baseURL.absoluteString,
            config.devUserHandle,
            config.deviceID,
            String(config.httpTransport.waitsForConnectivity),
            String(config.httpTransport.requestTimeoutSeconds),
            String(config.httpTransport.resourceTimeoutSeconds),
            config.controlCommandTransportPolicy.rawValue,
        ].joined(separator: "|")
    }

    func configureBackendIfNeeded() async {
        guard let backendConfig = backendConfig else {
            backendStatusMessage = "Backend not configured"
            diagnostics.record(.backend, level: .error, message: "Backend configuration missing")
            captureDiagnosticsState("backend-config:missing")
            return
        }
        let key = backendConfigurationKey(for: backendConfig)
        if let task = backendConfigurationTask,
           backendConfigurationKey == key {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Coalesced backend bootstrap with in-flight configuration",
                metadata: ["handle": backendConfig.devUserHandle]
            )
            await task.value
            return
        }
        if let task = backendConfigurationTask {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Cancelling superseded backend bootstrap",
                metadata: [
                    "previousKey": backendConfigurationKey ?? "none",
                    "nextHandle": backendConfig.devUserHandle,
                ]
            )
            task.cancel()
        }
        let token = UUID()
        backendConfigurationKey = key
        backendConfigurationToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runBackendConfiguration(backendConfig, key: key)
        }
        backendConfigurationTask = task
        await task.value
        if backendConfigurationToken == token {
            backendConfigurationTask = nil
            backendConfigurationKey = nil
            backendConfigurationToken = nil
        }
    }

    private func backendConfigurationIsCurrent(key: String) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let config = backendConfig else { return false }
        return backendConfigurationKey(for: config) == key
    }

    private func runBackendConfiguration(_ backendConfig: TurboBackendConfig, key: String) async {
        let client = TurboBackendClient(config: backendConfig)
        client.onSignal = { [weak self] envelope in
            self?.scheduleIncomingSignalDelivery(envelope)
        }
        client.onServerNotice = { [weak self] message in
            self?.handleBackendServerNotice(message)
        }
        client.onWebSocketStatusNotice = { [weak self] notice in
            self?.handleBackendWebSocketStatusNotice(notice)
        }
        client.onControlCommandTrace = { [weak self] event in
            self?.handleBackendControlCommandTrace(event)
        }
        client.onWebSocketStateChange = { [weak self] state in
            self?.handleWebSocketStateChange(state)
        }

        var bootstrapStep = "runtime-config"
        do {
            let runtimeConfig = try await client.fetchRuntimeConfig()
            let localRelayOnlyOverride = TurboDirectPathDebugOverride.isRelayOnlyForced()
            bootstrapStep = "auth-session"
            let authSession = try await client.authenticate()
            bootstrapStep = "profile-sync"
            let session = try await synchronizedProfileSessionIfNeeded(
                authSession,
                using: client
            )
            guard backendConfigurationIsCurrent(key: key) else {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Discarded superseded backend bootstrap before device registration",
                    metadata: ["handle": backendConfig.devUserHandle]
                )
                return
            }
            let directQuicIdentity = provisionDirectQuicProductionIdentityForRegistration(
                deviceID: client.deviceID
            )
            let mediaEncryptionIdentity = provisionMediaEncryptionIdentityForRegistration(
                deviceID: client.deviceID
            )
            bootstrapStep = "device-registration"
            _ = try await client.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: directQuicIdentity,
                mediaEncryptionIdentity: mediaEncryptionIdentity
            )
            if let directQuicIdentity {
                directQuicRegisteredFingerprint = directQuicIdentity.fingerprint
            }
            bootstrapStep = "presence-keepalive"
            _ = try await client.heartbeatPresence()
            backendRuntime.markPresenceHeartbeatSent()
            guard backendConfigurationIsCurrent(key: key) else {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Discarded superseded backend bootstrap before applying session",
                    metadata: ["handle": backendConfig.devUserHandle]
                )
                return
            }
            applyAuthenticatedBackendSession(
                client: client,
                userID: session.userId,
                mode: runtimeConfig.mode,
                telemetryEnabled: runtimeConfig.telemetryEnabled ?? false,
                publicID: session.publicId,
                profileName: session.profileName,
                shareCode: session.shareCode,
                shareLink: session.shareLink
            )
            client.connectWebSocket()
            backendSyncCoordinator.send(.bootstrapCompleted(mode: runtimeConfig.mode, handle: session.handle))
            Task { @MainActor [weak self] in
                guard let self else { return }
                async let contactSummaries: Void = self.refreshContactSummaries()
                async let beeps: Void = self.refreshBeeps()
                _ = await (contactSummaries, beeps)
                await self.openPendingBeepNotificationIfNeeded()
                self.captureDiagnosticsState("backend-config:post-login-refresh-finished")
            }
            startBackendPollingIfNeeded()
            statusMessage = selectedContact == nil ? "Ready to connect" : statusMessage
            diagnostics.record(
                .backend,
                message: "Backend connected",
                metadata: [
                    "mode": runtimeConfig.mode,
                    "controlCommandTransportPolicy": client.controlCommandTransportPolicy.rawValue,
                    "handle": session.handle,
                    "deviceId": client.deviceID,
                    "supportsDirectQuicUpgrade": String(runtimeConfig.supportsDirectQuicUpgrade),
                    "supportsDirectQuicProvisioning": String(runtimeConfig.supportsDirectQuicProvisioning),
                    "supportsMediaEndToEndEncryption": String(runtimeConfig.supportsMediaEndToEndEncryption),
                    "supportsSignalSessionIds": String(runtimeConfig.supportsSignalSessionIds),
                    "supportsTransmitIds": String(runtimeConfig.supportsTransmitIds),
                    "supportsProjectionEpochs": String(runtimeConfig.supportsProjectionEpochs),
                    "directQuicProvisioningStatus": directQuicProvisioningStatus,
                    "directQuicFingerprint": directQuicIdentity?.fingerprint ?? "none",
                    "mediaEncryptionProvisioningStatus": mediaEncryptionProvisioningStatus,
                    "mediaEncryptionFingerprint": mediaEncryptionIdentity?.fingerprint ?? "none",
                    "localRelayOnlyOverride": String(localRelayOnlyOverride),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.backend.connected",
                severity: .info,
                reason: runtimeConfig.mode,
                message: "Backend connected",
                metadata: [
                    "deviceId": client.deviceID,
                    "handle": session.handle,
                    "controlCommandTransportPolicy": client.controlCommandTransportPolicy.rawValue,
                    "telemetryEnabled": String(runtimeConfig.telemetryEnabled ?? false),
                    "supportsDirectQuicUpgrade": String(runtimeConfig.supportsDirectQuicUpgrade),
                    "supportsMediaEndToEndEncryption": String(runtimeConfig.supportsMediaEndToEndEncryption),
                    "localRelayOnlyOverride": String(localRelayOnlyOverride),
                ]
            )
            flushPendingDirectQuicIdentityProvisioningFailureTelemetry(reason: "backend-connected")
            if runtimeConfig.supportsDirectQuicUpgrade, localRelayOnlyOverride {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC upgrade disabled by local debug override",
                    metadata: ["deviceId": client.deviceID]
                )
            }
            replaceBackendBootstrapRetryTask(with: nil)
            lastBackendBootstrapFailureMessage = nil
            syncPTTServiceStatus(reason: "backend-connected")
            captureDiagnosticsState("backend-config:connected")
        } catch {
            let failureMessage = backendBootstrapFailureMessage(
                step: bootstrapStep,
                error: error,
                baseURL: backendConfig.baseURL
            )
            lastBackendBootstrapFailureMessage = failureMessage
            resetBackendRuntimeForReconnect()
            backendSyncCoordinator.send(.bootstrapFailed(failureMessage))
            scheduleBackendBootstrapRetryIfNeeded(trigger: "configure", error: error)
            updatePrimaryStatusAfterBackendBootstrapFailure(
                retrying: statusMessage == "Reconnecting..."
            )
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend connection failed",
                metadata: [
                    "step": bootstrapStep,
                    "baseURL": backendConfig.baseURL.absoluteString,
                    "failure": failureMessage,
                    "error": error.localizedDescription,
                    "errorDomain": (error as NSError).domain,
                    "errorCode": String((error as NSError).code),
                ]
            )
            syncPTTServiceStatus(reason: "backend-connect-failed")
            captureDiagnosticsState("backend-config:failed")
        }
    }

    var shouldProjectBackendConnectivityInPrimaryStatus: Bool {
        if conversationActionCoordinator.pendingAction != .none { return true }
        if isJoined || isTransmitting { return true }
        if activeChannelId != nil { return true }
        if systemSessionState != .none { return true }
        if transmitCoordinator.state.isPressingTalk { return true }
        if pttCoordinator.state.isTransmitting { return true }
        if pttWakeRuntime.pendingIncomingPush != nil { return true }
        return false
    }

    private func updatePrimaryStatusAfterBackendBootstrapFailure(retrying: Bool) {
        if shouldProjectBackendConnectivityInPrimaryStatus {
            statusMessage = retrying ? "Reconnecting..." : "Backend unavailable"
        } else {
            updateStatusForSelectedContact()
        }
    }


}
