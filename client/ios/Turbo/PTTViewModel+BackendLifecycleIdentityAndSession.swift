//
//  PTTViewModel+BackendLifecycleIdentityAndSession.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import UIKit

enum DiagnosticsUploadMode: String, Equatable {
    case full
    case compact
    case minimal
    case tiny

    fileprivate static let grossOversizeMultiplier = 12

    var timeoutInterval: TimeInterval {
        switch self {
        case .full:
            return 12
        case .compact:
            return 8
        case .minimal:
            return 5
        case .tiny:
            return 4
        }
    }

    var maximumRequestBodyBytes: Int {
        switch self {
        case .full:
            return 900_000
        case .compact:
            return 240_000
        case .minimal:
            return 80_000
        case .tiny:
            return 40_000
        }
    }

    var defaultEngineTraceStepLimit: Int? {
        switch self {
        case .full:
            return nil
        case .compact:
            return 120
        case .minimal:
            return 48
        case .tiny:
            return nil
        }
    }

    var engineTraceStepLimitCandidates: [Int?] {
        switch self {
        case .full:
            return [nil]
        case .compact:
            return [120, 80, 48, 24, 12, 6, 3, 1]
        case .minimal:
            return [48, 24, 12, 6, 3, 1]
        case .tiny:
            return [nil]
        }
    }
}

struct DiagnosticsPublishResult {
    let response: TurboDiagnosticsUploadResponse
    let uploadMode: DiagnosticsUploadMode
    let fallbackFromFullError: String?
    let requestBodySizeBytes: Int
    let engineTraceStepLimit: Int?
}

struct DiagnosticsPreparedUpload {
    let request: TurboDiagnosticsUploadRequest
    let uploadMode: DiagnosticsUploadMode
    let requestBodySizeBytes: Int
    let engineTraceStepLimit: Int?
    let localFallbackReasons: [String]
}

extension PTTViewModel {
    func updateDevUserHandle(_ handle: String) async {
        TurboBackendConfig.setPersistedDevUserHandle(handle)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Reconnecting as \(currentDevUserHandle)...")
        diagnostics.record(.auth, message: "Switching dev identity", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("identity-switch:start")
        await configureBackendIfNeeded()
    }

    func restoreExistingIdentity(from reference: String) async -> Bool {
        guard let publicID = TurboIncomingLink.publicID(from: reference) else {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Restore identity failed to parse reference",
                metadata: ["reference": reference]
            )
            return false
        }

        TurboBackendConfig.setPersistedDevUserHandle(publicID)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Restoring your BeepBeep...")
        backendStatusMessage = "Restoring your BeepBeep..."
        diagnostics.record(.auth, message: "Restoring existing identity", metadata: ["publicId": publicID])
        captureDiagnosticsState("identity-restore:start")
        await configureBackendIfNeeded()

        guard backendRuntime.isReady else {
            captureDiagnosticsState("identity-restore:failed")
            return false
        }

        let restoredProfileName = TurboIdentityProfileStore.storeDraftProfileName(currentProfileName)
        TurboIdentityProfileStore.markOnboardingCompleted()
        storeCurrentProfileName(restoredProfileName)
        captureDiagnosticsState("identity-restore:finished")
        return true
    }

    func createFreshIdentity(handle: String, profileName: String) async -> Bool {
        let normalizedHandle = TurboHandle.normalizedStoredHandle(handle)
        TurboBackendConfig.setPersistedDevUserHandle(normalizedHandle)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Creating your BeepBeep...")
        backendStatusMessage = "Creating your BeepBeep..."
        diagnostics.record(.auth, message: "Creating fresh identity", metadata: ["handle": normalizedHandle])
        captureDiagnosticsState("identity-create:start")
        await configureBackendIfNeeded()

        guard backendRuntime.isReady else {
            captureDiagnosticsState("identity-create:failed")
            return false
        }

        await updateProfileName(profileName, markOnboardingComplete: true)
        captureDiagnosticsState("identity-create:finished")
        return backendRuntime.isReady
    }

    func updateProfileName(_ profileName: String, markOnboardingComplete: Bool = false) async {
        let normalizedProfileName = TurboIdentityProfileStore.storeDraftProfileName(profileName)
        if markOnboardingComplete {
            TurboIdentityProfileStore.markOnboardingCompleted()
        }
        storeCurrentProfileName(normalizedProfileName)

        guard let backend = backendServices else {
            diagnostics.record(
                .auth,
                message: "Stored local profile name while backend was unavailable",
                metadata: ["profileName": normalizedProfileName]
            )
            captureDiagnosticsState("profile-name:stored-local")
            return
        }

        do {
            let session = try await backend.client.updateProfileName(normalizedProfileName)
            let storedProfileName = TurboIdentityProfileStore.storeDraftProfileName(session.profileName)
            storeCurrentProfileName(storedProfileName)
            applyAuthenticatedBackendSession(
                client: backend.client,
                userID: session.userId,
                mode: backend.mode,
                telemetryEnabled: backend.telemetryEnabled,
                publicID: session.publicId,
                profileName: session.profileName,
                shareCode: session.shareCode,
                shareLink: session.shareLink
            )
            diagnostics.record(
                .auth,
                message: "Updated profile name",
                metadata: ["profileName": storedProfileName]
            )
            await refreshContactSummaries()
            captureDiagnosticsState("profile-name:updated")
        } catch {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Profile name update failed",
                metadata: ["error": error.localizedDescription]
            )
            captureDiagnosticsState("profile-name:update-failed")
        }
    }

    func signOutToFreshIdentity() async {
        diagnostics.record(.auth, message: "Signing out to fresh identity", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("identity-sign-out:start")

        if selectedContactId != nil || isJoined || pttCoordinator.state.systemChannelUUID != nil {
            await requestDisconnectSelectedConversation()
        }

        TurboIdentityProfileStore.resetForFreshIdentity()
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Creating your new BeepBeep...")
        backendStatusMessage = "Creating your new BeepBeep..."
        captureDiagnosticsState("identity-sign-out:local-cleared")
        await configureBackendIfNeeded()
    }

    func restartLocalAppSession() async {
        diagnostics.record(.app, message: "Restarting local app session", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("local-restart:start")

        if selectedContactId != nil || isJoined || pttCoordinator.state.systemChannelUUID != nil {
            await requestDisconnectSelectedConversation()
        }

        resetLocalDevState(backendStatus: "Reconnecting as \(currentDevUserHandle)...")
        backendStatusMessage = "Reconnecting as \(currentDevUserHandle)..."
        captureDiagnosticsState("local-restart:local-cleared")
        await configureBackendIfNeeded()
    }

    func resetDevEnvironment() async {
        statusMessage = "Resetting dev world..."
        diagnostics.record(.app, message: "Resetting dev world", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("dev-reset:start")
        do {
            if let backend = backendServices {
                let response = try await backend.resetAllDevState()
                let seeded = try await backend.seedDevUsers()
                diagnostics.record(
                    .backend,
                    message: "Backend dev world reset",
                    metadata: [
                        "clearedBeeps": "\(response.clearedBeeps)",
                        "clearedPresenceEntries": "\(response.clearedPresenceEntries)",
                        "clearedChannels": "\(response.clearedChannels ?? 0)",
                        "clearedUsers": "\(response.clearedUsers ?? 0)",
                        "seededUsers": "\(seeded.users.count)"
                    ]
                )
            }
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend dev world reset failed",
                metadata: ["error": error.localizedDescription]
            )
        }

        resetLocalDevState(backendStatus: "Resetting as \(currentDevUserHandle)...")
        backendStatusMessage = "Reconnecting as \(currentDevUserHandle)..."
        captureDiagnosticsState("dev-reset:local-cleared")
        await configureBackendIfNeeded()
    }

    func runSelfCheck() async {
        refreshMicrophonePermission()
        let startedAt = Date()
        diagnostics.record(
            .selfCheck,
            message: "Running self-check",
            metadata: ["selectedContact": selectedContact?.handle ?? "none"]
        )
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: hasBackendConfig,
            isBackendClientReady: backendServices != nil,
            microphonePermission: microphonePermission,
            selectedTarget: selectedContact.map { DevSelfCheckTarget(contactID: $0.id, handle: $0.handle) }
        )
        await selfCheckCoordinator.handle(.runRequested(request))
    }

    func publishDiagnostics() async throws -> TurboDiagnosticsUploadResponse {
        try await publishDiagnosticsIfPossible(
            trigger: "manual-upload",
            recordSuccess: true,
            preferredUploadMode: .compact
        ).response
    }

    func publishDiagnosticsIfPossible(
        trigger: String,
        recordSuccess: Bool,
        preferredUploadMode: DiagnosticsUploadMode = .full
    ) async throws -> DiagnosticsPublishResult {
        guard let backend = backendServices, let backendConfig else {
            throw TurboBackendError.invalidConfiguration
        }

        var fallbackErrors: [String] = []
        var attemptedMode = preferredUploadMode

        while true {
            if trigger.hasPrefix("automatic:"),
               let deferralReason = automaticDiagnosticsPublishDeferralReason {
                diagnostics.record(
                    .app,
                    level: .debug,
                    message: "Deferred automatic diagnostics publish before preparing upload",
                    metadata: [
                        "trigger": trigger,
                        "reason": deferralReason.rawValue,
                    ]
                )
                throw AutomaticDiagnosticsPublishDeferredError(reason: deferralReason)
            }

            let preparedUpload = try diagnosticsPreparedUploadRequest(
                deviceID: backend.deviceID,
                backendBaseURL: backendConfig.baseURL.absoluteString,
                preferredUploadMode: attemptedMode
            )
            if !preparedUpload.localFallbackReasons.isEmpty {
                fallbackErrors.append(contentsOf: preparedUpload.localFallbackReasons)
                for reason in preparedUpload.localFallbackReasons {
                    diagnostics.record(
                        .app,
                        level: .notice,
                        message: "Diagnostics upload payload exceeded local budget; using smaller diagnostics",
                        metadata: [
                            "trigger": trigger,
                            "fallbackUploadMode": preparedUpload.uploadMode.rawValue,
                            "reason": reason,
                            "requestBodySizeBytes": String(preparedUpload.requestBodySizeBytes),
                        ]
                    )
                }
            }
            attemptedMode = preparedUpload.uploadMode
            do {
                let response = try await backend.uploadDiagnostics(
                    preparedUpload.request,
                    timeoutInterval: attemptedMode.timeoutInterval
                )
                let fallbackError = fallbackErrors.isEmpty ? nil : fallbackErrors.joined(separator: " | ")
                if recordSuccess {
                    recordDiagnosticsPublishSuccess(
                        response: response,
                        trigger: trigger,
                        uploadMode: attemptedMode,
                        fallbackError: fallbackError,
                        requestBodySizeBytes: preparedUpload.requestBodySizeBytes,
                        engineTraceStepLimit: preparedUpload.engineTraceStepLimit
                    )
                }
                return DiagnosticsPublishResult(
                    response: response,
                    uploadMode: attemptedMode,
                    fallbackFromFullError: fallbackError,
                    requestBodySizeBytes: preparedUpload.requestBodySizeBytes,
                    engineTraceStepLimit: preparedUpload.engineTraceStepLimit
                )
            } catch {
                fallbackErrors.append("\(attemptedMode.rawValue): \(error.localizedDescription)")
                guard let nextMode = nextDiagnosticsUploadMode(after: attemptedMode) else {
                    throw error
                }
                diagnostics.record(
                    .app,
                    level: .notice,
                    message: "Diagnostics upload failed; retrying smaller diagnostics",
                    metadata: [
                        "trigger": trigger,
                        "uploadMode": attemptedMode.rawValue,
                        "fallbackUploadMode": nextMode.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
                attemptedMode = nextMode
            }
        }
    }

    private func nextDiagnosticsUploadMode(after mode: DiagnosticsUploadMode) -> DiagnosticsUploadMode? {
        switch mode {
        case .full:
            return .compact
        case .compact:
            return .minimal
        case .minimal:
            return .tiny
        case .tiny:
            return nil
        }
    }

    private func recordDiagnosticsPublishSuccess(
        response: TurboDiagnosticsUploadResponse,
        trigger: String,
        uploadMode: DiagnosticsUploadMode,
        fallbackError: String?,
        requestBodySizeBytes: Int,
        engineTraceStepLimit: Int?
    ) {
        var metadata = [
            "deviceId": response.report.deviceId,
            "uploadedAt": response.report.uploadedAt,
            "trigger": trigger,
            "uploadMode": uploadMode.rawValue,
            "requestBodySizeBytes": String(requestBodySizeBytes),
        ]
        if let engineTraceStepLimit {
            metadata["engineTraceStepLimit"] = String(engineTraceStepLimit)
        }
        if let fallbackError {
            metadata["fallbackFromFullError"] = fallbackError
        }
        diagnostics.record(.app, message: "Published diagnostics", metadata: metadata)
    }

    func diagnosticsUploadCompact(_ uploadMode: DiagnosticsUploadMode) -> Bool {
        uploadMode != .full
    }

    func diagnosticsUploadMinimal(_ uploadMode: DiagnosticsUploadMode) -> Bool {
        uploadMode == .minimal || uploadMode == .tiny
    }

    func diagnosticsUploadTiny(_ uploadMode: DiagnosticsUploadMode) -> Bool {
        uploadMode == .tiny
    }

    func diagnosticsUploadRequest(
        deviceID: String,
        backendBaseURL: String,
        uploadMode: DiagnosticsUploadMode = .full,
        engineTraceStepLimit: Int? = nil
    ) throws -> TurboDiagnosticsUploadRequest {
        let structuredEnvelopeJSON = diagnosticsUploadTiny(uploadMode)
            ? nil
            : try diagnosticsStructuredEnvelopeJSON(
                appVersion: appVersionDescription,
                compact: diagnosticsUploadCompact(uploadMode),
                minimal: diagnosticsUploadMinimal(uploadMode),
                engineTraceStepLimit: engineTraceStepLimit ?? uploadMode.defaultEngineTraceStepLimit
            )
        return TurboDiagnosticsUploadRequest(
            deviceId: deviceID,
            appVersion: appVersionDescription,
            backendBaseURL: backendBaseURL,
            selectedHandle: selectedContact?.handle,
            snapshot: diagnosticsSnapshot,
            transcript: diagnosticsTranscriptText(
                structuredEnvelopeJSON: structuredEnvelopeJSON,
                includePersistedLogTail: uploadMode == .full,
                compact: diagnosticsUploadCompact(uploadMode),
                minimal: diagnosticsUploadMinimal(uploadMode),
                tiny: diagnosticsUploadTiny(uploadMode)
            )
        )
    }

    func diagnosticsPreparedUploadRequest(
        deviceID: String,
        backendBaseURL: String,
        preferredUploadMode: DiagnosticsUploadMode = .full
    ) throws -> DiagnosticsPreparedUpload {
        var localFallbackReasons: [String] = []
        var uploadMode: DiagnosticsUploadMode? = preferredUploadMode

        while let mode = uploadMode {
            if let prepared = try diagnosticsPreparedUploadRequestFittingMode(
                deviceID: deviceID,
                backendBaseURL: backendBaseURL,
                uploadMode: mode,
                localFallbackReasons: localFallbackReasons
            ) {
                return prepared
            }

            localFallbackReasons.append(
                "\(mode.rawValue): local request body exceeded \(mode.maximumRequestBodyBytes) bytes"
            )
            uploadMode = nextDiagnosticsUploadMode(after: mode)
        }

        throw TurboBackendError.invalidResponseDetails(
            "diagnostics upload request exceeded local size budgets: \(localFallbackReasons.joined(separator: " | "))"
        )
    }

    private func diagnosticsPreparedUploadRequestFittingMode(
        deviceID: String,
        backendBaseURL: String,
        uploadMode: DiagnosticsUploadMode,
        localFallbackReasons: [String]
    ) throws -> DiagnosticsPreparedUpload? {
        var largestBodySizeBytes = 0
        for traceStepLimit in uploadMode.engineTraceStepLimitCandidates {
            let request = try diagnosticsUploadRequest(
                deviceID: deviceID,
                backendBaseURL: backendBaseURL,
                uploadMode: uploadMode,
                engineTraceStepLimit: traceStepLimit
            )
            let bodySizeBytes = try diagnosticsUploadRequestBodySize(request)
            largestBodySizeBytes = max(largestBodySizeBytes, bodySizeBytes)
            guard bodySizeBytes <= uploadMode.maximumRequestBodyBytes else {
                if bodySizeBytes > uploadMode.maximumRequestBodyBytes * DiagnosticsUploadMode.grossOversizeMultiplier {
                    break
                }
                continue
            }
            return DiagnosticsPreparedUpload(
                request: request,
                uploadMode: uploadMode,
                requestBodySizeBytes: bodySizeBytes,
                engineTraceStepLimit: traceStepLimit,
                localFallbackReasons: localFallbackReasons
            )
        }

        diagnostics.record(
            .app,
            level: .notice,
            message: "Diagnostics upload mode exceeded local size budget",
            metadata: [
                "uploadMode": uploadMode.rawValue,
                "maximumRequestBodyBytes": String(uploadMode.maximumRequestBodyBytes),
                "largestRequestBodySizeBytes": String(largestBodySizeBytes),
            ]
        )
        return nil
    }

    func diagnosticsUploadRequestBodySize(_ request: TurboDiagnosticsUploadRequest) throws -> Int {
        try JSONEncoder().encode(request).count
    }

    func resetLocalDevState(backendStatus: String) {
        cancelAutomaticDiagnosticsPublish()
        resetBackendRuntimeForReconnect()
        pttCoordinator.reset()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        mediaRuntime.resetMediaEncryptionState()
        receiveExecutionCoordinator.send(.reset)
        isPTTAudioSessionActive = false
        selectedContactId = nil
        selectedConversationCoordinator.reset()
        syncPTTState()
        conversationActionCoordinator.reset()
        backendSyncCoordinator.send(.reset(statusMessage: backendStatus))
        backendCommandCoordinator.send(.reset)
        selfCheckCoordinator.send(.reset)
        pttSystemPolicyCoordinator.send(.reset)
        pttWakeRuntime.clearAll()
        controlPlaneCoordinator.send(.reset)
        localConversationParticipantTelemetry = nil
        lastPublishedConversationParticipantTelemetryByContactID = [:]
        lastPublishedConversationParticipantTelemetryAtByContactID = [:]
        conversationParticipantTelemetryByContactID = [:]
        clearTrackedContacts()
        resetTransportFaults()
        contacts = []
        diagnostics.clear()
        statusMessage = "Initializing..."
        captureDiagnosticsState("local-state-reset")
    }

    func startBackendPollingIfNeeded() {
        guard !hasPendingBackendPollTask else { return }
        replaceBackendPollTask(with: Task { [weak self] in
            while let self, !Task.isCancelled {
                let (selectedContactId, shouldPoll) = await MainActor.run { @MainActor in
                    (self.selectedContactId, self.shouldMaintainBackgroundControlPlane())
                }
                if shouldPoll {
                    await self.backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        })
    }

    func handleWebSocketStateChange(_ state: TurboBackendClient.WebSocketConnectionState) {
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "WebSocket state changed", metadata: ["state": String(describing: state)])

        let shouldForceBackgroundSuspension =
            currentApplicationState() != .active
            && !shouldMaintainBackgroundControlPlane()
        if shouldForceBackgroundSuspension {
            diagnostics.record(
                .websocket,
                message: "Suspending unexpected background WebSocket activity",
                metadata: ["state": String(describing: state)]
            )
            backend.suspendWebSocket()
            if state != .idle {
                captureDiagnosticsState("websocket:background-suspended")
                return
            }
        }

        switch state {
        case .idle:
            noteLiveCallControlPlaneReconnectGraceIfNeeded(reason: "websocket-idle")
            if shouldForceBackgroundSuspension {
                backendStatusMessage = "WebSocket suspended"
            } else {
                backendStatusMessage = backendRuntime.isReady ? "Reconnecting WebSocket..." : "WebSocket disconnected"
            }
            backendSyncCoordinator.send(.webSocketStateChanged(.idle, selectedContactID: selectedContactId))
            controlPlaneCoordinator.send(.webSocketStateChanged(.idle))
            syncSelectedConversationProjection()
            syncPTTServiceStatus(reason: "websocket-idle")
            let shouldResetTransmitSession = shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: hasPendingBeginOrActiveTransmit,
                systemIsTransmitting: pttCoordinator.state.isTransmitting
            )
            if shouldResetTransmitSession {
                Task {
                    await transmitCoordinator.handle(.websocketDisconnected)
                    resetTransmitSession(closeMediaSession: false)
                    updateStatusForSelectedContact()
                }
            }
            captureDiagnosticsState("websocket:idle")
        case .connecting:
            noteLiveCallControlPlaneReconnectGraceIfNeeded(reason: "websocket-connecting")
            backendStatusMessage = "Connecting WebSocket..."
            syncSelectedConversationProjection()
            syncPTTServiceStatus(reason: "websocket-connecting")
            captureDiagnosticsState("websocket:connecting")
        case .connected:
            if liveCallControlPlaneReconnectGraceStartedAt != nil {
                diagnostics.record(
                    .websocket,
                    message: "Preserving live call control-plane reconnect grace until backend Conversation refresh confirms membership",
                    metadata: ["reason": "websocket-connected"]
                )
            }
            if backendStatusMessage.hasPrefix("WebSocket")
                || backendStatusMessage == "Connected (retrying sync)" {
                backendStatusMessage = "Connected"
            }
            syncPTTServiceStatus(reason: "websocket-connected")
            captureDiagnosticsState("websocket:connected")
            Task {
                await backendSyncCoordinator.handle(.webSocketStateChanged(state, selectedContactID: selectedContactId))
                await controlPlaneCoordinator.handle(.webSocketStateChanged(state))
                await reassertBackendJoinAfterWebSocketReconnectIfNeeded()
                let readinessContactIDs = Set([selectedContactId, activeChannelId, mediaSessionContactID].compactMap { $0 })
                for contactID in readinessContactIDs {
                    await syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: .websocketConnected
                    )
                }
                if let selectedContactId {
                    await runSelectedContactPrewarmPipeline(
                        for: selectedContactId,
                        reason: "websocket-connected-selected-contact"
                    )
                }
            }
        }
    }

    private func noteLiveCallControlPlaneReconnectGraceIfNeeded(reason: String) {
        guard let contactID = selectedContactId,
              isJoined,
              activeChannelId == contactID,
              selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity,
              selectedConversationSystemSessionMatches(contactID) else {
            liveCallControlPlaneReconnectGraceStartedAt = nil
            return
        }

        if liveCallControlPlaneReconnectGraceStartedAt == nil {
            liveCallControlPlaneReconnectGraceStartedAt = Date()
            diagnostics.record(
                .websocket,
                message: "Started live call control-plane reconnect grace",
                metadata: [
                    "reason": reason,
                    "contactId": contactID.uuidString,
                    "graceSeconds": String(liveCallControlPlaneReconnectGraceSeconds),
                ]
            )
        }
    }

    func clearLiveCallControlPlaneReconnectGrace(reason: String) {
        guard liveCallControlPlaneReconnectGraceStartedAt != nil else { return }
        liveCallControlPlaneReconnectGraceStartedAt = nil
        diagnostics.record(
            .websocket,
            message: "Cleared live call control-plane reconnect grace",
            metadata: ["reason": reason]
        )
    }

    func handleBackendControlCommandTrace(_ event: TurboBackendClient.ControlCommandTraceEvent) {
        var metadata: [String: String] = [
            "commandKind": event.commandKind,
            "transport": event.transport.rawValue,
            "phase": event.phase.rawValue,
        ]
        if let operationId = event.operationId {
            metadata["operationId"] = operationId
        }
        if let channelId = event.channelId {
            metadata["channelId"] = channelId
        }
        if let requestId = event.requestId {
            metadata["requestId"] = requestId
        }
        if let elapsedMs = event.elapsedMs {
            metadata["elapsedMs"] = String(elapsedMs)
        }
        if let detail = event.detail, !detail.isEmpty {
            metadata["detail"] = detail
        }
        diagnostics.record(.backend, message: "Backend control command trace", metadata: metadata)
    }

    internal func performSelfCheck(_ request: DevSelfCheckRequest) async {
        guard let backend = backendServices else {
            let outcome = DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: request.selectedTarget?.handle,
                    steps: [DevSelfCheckStep(.runtimeConfig, status: .failed, detail: "Backend client is not initialized")]
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
            selfCheckCoordinator.send(.runCompleted(outcome.report))
            diagnostics.record(.selfCheck, level: .error, message: outcome.report.summary)
            return
        }

        let services = DevSelfCheckServices(
            fetchRuntimeConfig: { try await backend.fetchRuntimeConfig() },
            authenticate: { try await backend.authenticate() },
            heartbeatPresence: { try await backend.heartbeatPresence() },
            ensureWebSocketConnected: { backend.ensureWebSocketConnected() },
            waitForWebSocketConnection: { try await backend.waitForWebSocketConnection() },
            lookupUser: { handle in try await backend.lookupUser(handle: handle) },
            directChannel: { handle in try await backend.directChannel(otherHandle: handle) },
            channelState: { channelID in try await backend.channelState(channelId: channelID) },
            alignmentAction: { [weak self] contactUpdate in
                guard let self,
                      let existingContact = self.contacts.first(where: { $0.id == contactUpdate.contactID }) else {
                    return .none
                }
                var contact = existingContact
                contact.remoteUserId = contactUpdate.remoteUserID
                contact.backendChannelId = contactUpdate.backendChannelID
                contact.channelId = contactUpdate.channelUUID
                return ConversationStateMachine.reconciliationAction(for: self.conversationContext(for: contact))
            }
        )

        let outcome = await DevSelfCheckRunner.run(request: request, services: services)

        if let authenticatedUserID = outcome.authenticatedUserID {
            storeAuthenticatedUserID(authenticatedUserID)
        }
        if let contactUpdate = outcome.contactUpdate {
            updateContact(contactUpdate.contactID) { mutableContact in
                mutableContact.remoteUserId = contactUpdate.remoteUserID
                mutableContact.backendChannelId = contactUpdate.backendChannelID
                mutableContact.channelId = contactUpdate.channelUUID
            }
        }
        if let channelStateUpdate = outcome.channelStateUpdate {
            backendSyncCoordinator.send(
                .channelStateUpdated(
                    contactID: channelStateUpdate.contactID,
                    channelState: channelStateUpdate.channelState
                )
            )
        }

        selfCheckCoordinator.send(.runCompleted(outcome.report))
        diagnostics.record(
            .selfCheck,
            level: outcome.report.isPassing ? .info : .error,
            message: outcome.report.summary,
            metadata: ["target": outcome.report.targetHandle ?? "none"]
        )
    }

    internal func synchronizedProfileSessionIfNeeded(
        _ session: TurboAuthSessionResponse,
        using client: TurboBackendClient
    ) async throws -> TurboAuthSessionResponse {
        let remoteProfileName = session.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let localProfileName = TurboIdentityProfileStore.storeDraftProfileName(
            TurboIdentityProfileStore.draftProfileName()
        )
        let remoteLooksDefault = remoteProfileName.isEmpty
            || remoteProfileName == session.publicId
            || remoteProfileName == session.handle

        if !TurboIdentityProfileStore.hasCompletedOnboarding() {
            if !remoteLooksDefault {
                let storedRemoteName = TurboIdentityProfileStore.storeDraftProfileName(remoteProfileName)
                TurboIdentityProfileStore.markOnboardingCompleted()
                storeCurrentProfileName(storedRemoteName)
                return sessionWithProfileName(session, profileName: storedRemoteName)
            }

            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }

        guard localProfileName != remoteProfileName else {
            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }

        do {
            let updatedSession = try await client.updateProfileName(localProfileName)
            let storedRemoteName = TurboIdentityProfileStore.storeDraftProfileName(updatedSession.profileName)
            storeCurrentProfileName(storedRemoteName)
            diagnostics.record(
                .auth,
                message: "Synchronized profile name on backend connect",
                metadata: ["profileName": storedRemoteName]
            )
            return sessionWithProfileName(updatedSession, profileName: storedRemoteName)
        } catch {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Deferred profile sync failed during backend bootstrap",
                metadata: ["error": error.localizedDescription]
            )
            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }
    }

    private func sessionWithProfileName(
        _ session: TurboAuthSessionResponse,
        profileName: String
    ) -> TurboAuthSessionResponse {
        TurboAuthSessionResponse(
            userId: session.userId,
            handle: session.handle,
            publicId: session.publicId,
            displayName: session.displayName,
            profileName: profileName,
            shareCode: session.shareCode,
            shareLink: session.shareLink,
            did: session.did,
            subjectKind: session.subjectKind
        )
    }
}
