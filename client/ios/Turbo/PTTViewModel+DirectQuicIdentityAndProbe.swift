import Foundation
import UIKit

extension PTTViewModel {
    private var defaultDirectQuicPromotionTimeoutMilliseconds: Int { 15_000 }
    private var defaultDirectQuicRetryBackoffMilliseconds: Int { 15_000 }
    private var foregroundDirectQuicPathLostRetryBackoffMilliseconds: Int { 1_000 }
    private var foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds: Int { 1_000 }
    private var foregroundDirectQuicSelectedConnectivityRetryBackoffCapMilliseconds: Int { 3_000 }
    private var foregroundDirectQuicInitialConnectivityRetryLimit: Int { 2 }
    var directQuicFirstTalkGraceMilliseconds: Int { 5_000 }
    var directQuicAudioFreshnessMilliseconds: Int { 30_000 }
    var directQuicUpgradeRequestThrottleMilliseconds: Int { 5_000 }

    func directQuicAttemptRole(
        localDeviceID: String,
        peerDeviceID: String
    ) -> DirectQuicAttemptRole {
        DirectQuicAttemptRole.resolve(
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
    }

    func directQuicPeerDeviceID(
        for contactID: UUID,
        fallback: String? = nil
    ) -> String? {
        if let evidence = recentPeerDeviceEvidence(for: contactID) {
            return evidence.deviceId
        }
        if let readiness = channelReadinessByContactID[contactID] {
            if let peerTargetDeviceId = readiness.peerTargetDeviceId,
               !peerTargetDeviceId.isEmpty {
                return peerTargetDeviceId
            }
            if case .wakeCapable(let targetDeviceId) = readiness.remoteWakeCapability,
               !targetDeviceId.isEmpty {
                return targetDeviceId
            }
        }
        return fallback
    }

    func recentPeerDeviceEvidence(for contactID: UUID) -> RecentPeerDeviceEvidence? {
        guard let evidence = recentPeerDeviceEvidenceByContactID[contactID] else { return nil }
        let channelID =
            contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId
            ?? contactSummaryByContactID[contactID]?.channelId
        return evidence.isFresh(for: channelID) ? evidence : nil
    }

    func applyChannelReadiness(
        _ readiness: TurboChannelReadinessResponse,
        for contactID: UUID,
        reason: String
    ) {
        guard backendSyncCoordinator.state.syncState.shouldAcceptChannelReadiness(
            readiness,
            for: contactID
        ) else {
            diagnostics.record(
                .backend,
                message: "Dropped stale channel readiness projection",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": readiness.channelId,
                    "reason": reason,
                    "readinessEpoch": readiness.stateEpoch ?? "none",
                    "channelStateEpoch": channelStateByContactID[contactID]?.stateEpoch ?? "none",
                ]
            )
            return
        }
        recordRecentPeerDeviceEvidenceIfPresent(
            contactID: contactID,
            readiness: readiness,
            reason: reason
        )
        backendSyncCoordinator.send(
            .channelReadinessUpdated(contactID: contactID, readiness: readiness)
        )
        triggerSelectedContactDirectQuicPrewarmAfterReadinessUpdateIfNeeded(
            readiness,
            contactID: contactID,
            reason: reason
        )
    }

    func triggerSelectedContactDirectQuicPrewarmAfterReadinessUpdateIfNeeded(
        _ readiness: TurboChannelReadinessResponse,
        contactID: UUID,
        reason: String
    ) {
        guard selectedContactDirectQuicPrewarmEnabled else { return }
        guard selectedContactId == contactID else { return }
        let hasPeerWakeDevice: Bool = {
            if case .wakeCapable(let targetDeviceId) = readiness.remoteWakeCapability {
                return !targetDeviceId.isEmpty
            }
            return false
        }()
        guard readiness.peerTargetDeviceId != nil
            || readiness.peerDirectQuicFingerprint != nil
            || hasPeerWakeDevice
        else { return }

        Task { @MainActor [weak self] in
            await self?.maybeStartSelectedContactDirectQuicPrewarm(
                for: contactID,
                reason: "readiness-\(reason)"
            )
        }
    }

    func recordRecentPeerDeviceEvidenceIfPresent(
        contactID: UUID,
        readiness: TurboChannelReadinessResponse,
        reason: String
    ) {
        let peerDeviceID: String? = {
            if let peerTargetDeviceId = readiness.peerTargetDeviceId,
               !peerTargetDeviceId.isEmpty {
                return peerTargetDeviceId
            }
            if case .wakeCapable(let targetDeviceId) = readiness.remoteWakeCapability,
               !targetDeviceId.isEmpty {
                return targetDeviceId
            }
            return nil
        }()
        guard let peerDeviceID else { return }

        recordRecentPeerDeviceEvidence(
            contactID: contactID,
            channelID: readiness.channelId,
            peerDeviceID: peerDeviceID,
            reason: reason,
            diagnosticSubsystem: .backend
        )
    }

    func recordRecentPeerDeviceEvidence(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        reason: String,
        diagnosticSubsystem: DiagnosticsSubsystem
    ) {
        guard !peerDeviceID.isEmpty else { return }
        let existing = recentPeerDeviceEvidenceByContactID[contactID]
        recentPeerDeviceEvidenceByContactID[contactID] = RecentPeerDeviceEvidence(
            deviceId: peerDeviceID,
            channelId: channelID,
            reason: reason,
            observedAt: Date()
        )

        guard existing?.deviceId != peerDeviceID || existing?.channelId != channelID else {
            return
        }
        diagnostics.record(
            diagnosticSubsystem,
            message: "Recorded recent peer device evidence",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
            ]
        )
    }

    func shouldUseDirectQuicTransport(for contactID: UUID) -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard !TurboMediaRelayDebugOverride.isForced() else { return false }
        guard mediaRuntime.directQuicProbeController != nil else { return false }
        return mediaRuntime.directQuicUpgrade.attempt(for: contactID)?.isDirectActive == true
    }

    func shouldUseDirectQuicAudioTransport(for contactID: UUID) -> Bool {
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        if currentApplicationState() == .active,
           selectedChannelSnapshot(for: contactID)?.remoteAudioReadyForLiveTransmit == true {
            return true
        }
        let maximumAge = TimeInterval(directQuicAudioFreshnessMilliseconds) / 1_000
        return mediaRuntime.receiverPrewarmRequestIsAcknowledged(
            for: contactID,
            maximumAge: maximumAge
        ) || mediaRuntime.directQuicWarmPongIsFresh(
            for: contactID,
            maximumAge: maximumAge
        )
    }

    func hasActiveBackgroundPTTFlowOwningDirectQuic(for contactID: UUID) -> Bool {
        if isTransmitting || transmitCoordinator.state.isPressingTalk || pttCoordinator.state.isTransmitting {
            return true
        }
        if isPTTAudioSessionActive {
            return true
        }
        if pttWakeRuntime.pendingIncomingPush?.contactID == contactID {
            return true
        }
        if pttWakeRuntime.incomingWakeActivationState(for: contactID) != nil {
            return true
        }
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        return false
    }

    func shouldRetireIdleDirectQuicForBackgroundTransition(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        return !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
    }

    @discardableResult
    func retireDirectQuicPath(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        configureActiveRoute: Bool
    ) async -> Bool {
        retireDirectQuicPathImmediately(
            for: contactID,
            reason: reason,
            sendHangup: sendHangup,
            configureActiveRoute: configureActiveRoute
        )
    }

    @discardableResult
    func retireDirectQuicPathImmediately(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        configureActiveRoute: Bool
    ) -> Bool {
        guard let attempt = directQuicAttempt(for: contactID) else {
            return false
        }
        let controller = mediaRuntime.directQuicProbeController

        diagnostics.record(
            .media,
            message: "Retiring Direct QUIC media path",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "reason": reason,
                "wasDirectActive": String(attempt.isDirectActive),
            ]
        )

        let didBeginPathClosing = sendHangup && beginDirectQuicPathClosingIfPossible(
            for: contactID,
            attempt: attempt,
            reason: reason,
            controller: controller
        )

        cancelDirectQuicPromotionTimeout()
        mediaRuntime.clearReceiverPrewarmState(for: contactID)
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: reason
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
        if !didBeginPathClosing {
            controller?.cancel(reason: reason)
        }
        mediaRuntime.directQuicProbeController = nil

        if configureActiveRoute,
           let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }

        if sendHangup {
            Task { @MainActor [weak self] in
                await self?.sendDirectQuicHangup(
                    for: contactID,
                    attempt: attempt,
                    reason: reason
                )
            }
        }

        return true
    }

    @discardableResult
    func retireIdleDirectQuicForBackgroundTransitionIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State
    ) async -> Bool {
        guard shouldRetireIdleDirectQuicForBackgroundTransition(
            for: contactID,
            applicationState: applicationState
        ) else {
            return false
        }

        return await retireDirectQuicPath(
            for: contactID,
            reason: reason,
            sendHangup: true,
            configureActiveRoute: false
        )
    }

    func directQuicAttempt(
        for contactID: UUID,
        matching attemptID: String? = nil
    ) -> DirectQuicUpgradeAttempt? {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return nil
        }
        guard let attemptID else { return attempt }
        return attempt.attemptId == attemptID ? attempt : nil
    }

    func directQuicExpectedPeerCertificateFingerprint(
        for attempt: DirectQuicUpgradeAttempt
    ) -> String? {
        if let answerFingerprint = attempt.remoteAnswer?.certificateFingerprint,
           !answerFingerprint.isEmpty {
            return answerFingerprint
        }
        if let offerFingerprint = attempt.remoteOffer?.certificateFingerprint,
           !offerFingerprint.isEmpty {
            return offerFingerprint
        }
        return nil
    }

    func directQuicCandidateBatchToProbe(
        for attempt: DirectQuicUpgradeAttempt,
        payload: TurboDirectQuicCandidatePayload
    ) -> [TurboDirectQuicCandidate] {
        if let candidate = payload.candidate {
            return [candidate]
        }
        if payload.endOfCandidates {
            return attempt.remoteCandidates
        }
        return []
    }

    func directQuicProbeController() -> DirectQuicProbeController {
        if let existing = mediaRuntime.directQuicProbeController {
            return existing
        }
        let controller = DirectQuicProbeController(
            reportEvent: { [weak self] message, metadata in
                guard let self else { return }
                await MainActor.run {
                    self.diagnostics.record(.media, message: message, metadata: metadata)
                }
            }
        )
        mediaRuntime.directQuicProbeController = controller
        return controller
    }

    func directQuicPromotionTimeoutMilliseconds() -> Int {
        guard let configured = backendServices?.directQuicPolicy?.promotionTimeoutMs else {
            return defaultDirectQuicPromotionTimeoutMilliseconds
        }
        return max(configured, defaultDirectQuicPromotionTimeoutMilliseconds)
    }

    func directQuicRetryBackoffMilliseconds() -> Int {
        let configured = backendServices?.directQuicPolicy?.retryBackoffMs
            ?? defaultDirectQuicRetryBackoffMilliseconds
        return max(configured, 0)
    }

    func directQuicRetryBackoffRequest(
        reason: String,
        attemptID: String? = nil,
        preferredMilliseconds: Int? = nil,
        priorFailureCount: Int = 0
    ) -> DirectQuicRetryBackoffRequest? {
        let baseMilliseconds = directQuicRetryBackoffMilliseconds()
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        let resolvedMilliseconds = DirectQuicRetryBackoffPolicy.milliseconds(
            baseMilliseconds: baseMilliseconds,
            category: category,
            priorFailureCount: priorFailureCount
        )
        let milliseconds = preferredMilliseconds.map { min(max($0, 0), resolvedMilliseconds) }
            ?? resolvedMilliseconds
        guard milliseconds > 0 else { return nil }
        return DirectQuicRetryBackoffRequest(
            milliseconds: milliseconds,
            reason: reason,
            category: category,
            attemptId: attemptID
        )
    }

    func directQuicPathLostRetryBackoffRequest(
        for contactID: UUID,
        reason: String,
        attemptID: String
    ) -> DirectQuicRetryBackoffRequest? {
        let isActiveTransmitPath = transmitProjection.activeTarget?.contactID == contactID
        let isForegroundSelectedPath =
            currentApplicationState() == .active
            && selectedContactId == contactID
        let preferredMilliseconds =
            (isActiveTransmitPath || isForegroundSelectedPath)
            ? foregroundDirectQuicPathLostRetryBackoffMilliseconds
            : nil
        return directQuicRetryBackoffRequest(
            reason: reason,
            attemptID: attemptID,
            preferredMilliseconds: preferredMilliseconds
        )
    }

    func directQuicPromotionRetryBackoffRequest(
        for contactID: UUID,
        reason: String,
        attemptID: String?
    ) -> DirectQuicRetryBackoffRequest? {
        let isForegroundSelectedPath =
            currentApplicationState() == .active
            && selectedContactId == contactID
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        let isConnectivityFailure =
            category == .connectivity
        let priorFailureCount =
            isConnectivityFailure
            ? max(
                mediaRuntime.directQuicUpgrade.retryFailureCount(
                    for: contactID,
                    category: .connectivity
                ) - (isForegroundSelectedPath ? foregroundDirectQuicInitialConnectivityRetryLimit : 0),
                0
            )
            : mediaRuntime.directQuicUpgrade.retryFailureCount(
                for: contactID,
                category: category
            )
        let fastRetryNumber =
            (isForegroundSelectedPath && isConnectivityFailure)
            ? mediaRuntime.directQuicUpgrade.consumeFastConnectivityRetry(
                for: contactID,
                maxAttempts: foregroundDirectQuicInitialConnectivityRetryLimit
            )
            : nil
        let preferredMilliseconds: Int? = {
            if fastRetryNumber != nil {
                return foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds
            }
            guard isForegroundSelectedPath && isConnectivityFailure else { return nil }
            return foregroundDirectQuicSelectedConnectivityRetryBackoffCapMilliseconds
        }()
        if let fastRetryNumber {
            diagnostics.record(
                .media,
                message: "Using fast direct QUIC promotion retry",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "attemptId": attemptID ?? "",
                    "fastRetryNumber": String(fastRetryNumber),
                    "fastRetryLimit": String(foregroundDirectQuicInitialConnectivityRetryLimit),
                    "retryBackoffMs": String(foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds),
                ]
            )
        }
        return directQuicRetryBackoffRequest(
            reason: reason,
            attemptID: attemptID,
            preferredMilliseconds: preferredMilliseconds,
            priorFailureCount: priorFailureCount
        )
    }

    func clearDirectQuicConnectivityBackoffForSelectedPrewarmRequestIfNeeded(
        for contactID: UUID,
        requestID: String,
        reason: String,
        peerDeviceID: String
    ) -> Bool {
        guard let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID),
              retryBackoff.category == .connectivity else {
            return false
        }
        guard selectedContactId == contactID else { return false }
        guard currentApplicationState() == .active
            || hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
        else {
            return false
        }

        let retryRemainingMilliseconds = mediaRuntime.directQuicUpgrade
            .retryBackoffRemaining(for: contactID)
            .map { max(Int($0 * 1_000), 0) } ?? 0
        diagnostics.recordContractViolation(
            DiagnosticsContracts.DirectQuic.selectedPrewarmRequestBlockedByConnectivityBackoff(
                contactID: contactID,
                requestID: requestID,
                reason: reason,
                peerDeviceID: peerDeviceID,
                retryReason: retryBackoff.reason,
                retryAttemptID: retryBackoff.attemptId,
                retryBackoffMilliseconds: retryBackoff.milliseconds,
                retryRemainingMilliseconds: retryRemainingMilliseconds
            )
        )
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: contactID)
        diagnostics.record(
            .media,
            message: "Cleared Direct QUIC connectivity retry backoff for selected prewarm request",
            metadata: [
                "contactId": contactID.uuidString,
                "requestId": requestID,
                "reason": reason,
                "peerDeviceId": peerDeviceID,
                "previousRetryReason": retryBackoff.reason,
                "previousRetryAttemptId": retryBackoff.attemptId ?? "none",
                "previousRetryBackoffMs": "\(retryBackoff.milliseconds)",
                "previousRetryRemainingMs": "\(retryRemainingMilliseconds)",
            ]
        )
        return true
    }

    func clearDirectQuicConnectivityBackoffForSelectedNetworkChangeIfNeeded(
        for contactID: UUID,
        generation: UInt64,
        interface: ConversationNetworkInterface
    ) -> Bool {
        guard let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID),
              retryBackoff.category == .connectivity else {
            return false
        }
        guard selectedContactId == contactID else { return false }
        guard currentApplicationState() == .active
            || hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
        else {
            return false
        }

        let retryRemainingMilliseconds = mediaRuntime.directQuicUpgrade
            .retryBackoffRemaining(for: contactID)
            .map { max(Int($0 * 1_000), 0) } ?? 0
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: contactID)
        diagnostics.record(
            .media,
            message: "Cleared Direct QUIC connectivity retry backoff for selected network change",
            metadata: [
                "contactId": contactID.uuidString,
                "networkPathGeneration": "\(generation)",
                "interface": interface.rawValue,
                "previousRetryReason": retryBackoff.reason,
                "previousRetryAttemptId": retryBackoff.attemptId ?? "none",
                "previousRetryBackoffMs": "\(retryBackoff.milliseconds)",
                "previousRetryRemainingMs": "\(retryRemainingMilliseconds)",
            ]
        )
        return true
    }

    func clearDirectQuicFreshSessionGuards(
        for contactID: UUID,
        reason: String
    ) {
        let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID)
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: contactID)
        mediaRuntime.clearDirectQuicUpgradeRequestThrottle(for: contactID)
        if selectedContactPrewarmedSelectionContactID == contactID {
            selectedContactPrewarmedSelectionContactID = nil
        }
        diagnostics.record(
            .media,
            message: "Cleared Direct QUIC fresh-session guards",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "clearedRetryBackoff": String(retryBackoff != nil),
                "previousRetryReason": retryBackoff?.reason ?? "none",
                "previousRetryAttemptId": retryBackoff?.attemptId ?? "none",
                "previousRetryBackoffMs": retryBackoff.map { String($0.milliseconds) } ?? "none",
            ]
        )
    }

    func isOrderlyDirectQuicClosureReason(_ reason: String) -> Bool {
        switch reason {
        case "media-session-closed",
             "app-background-media-closed",
             "application-will-resign-active",
             "application-did-enter-background",
             "debug-force-relay-only",
             "media-relay-forced":
            return true
        default:
            return false
        }
    }

    func directQuicStunServers() -> [TurboDirectQuicStunServer] {
        backendServices?.directQuicPolicy?.effectiveStunServers ?? []
    }

    func preferredDirectQuicIdentityLabel() -> String {
        DirectQuicIdentityConfiguration.preferredLabel(
            deviceID: backendServices?.deviceID,
            fallbackHandle: currentIdentityHandle
        )
    }

    func provisionDirectQuicProductionIdentityForRegistration(
        deviceID: String
    ) -> DirectQuicIdentityRegistrationMetadata? {
        let label = DirectQuicIdentityConfiguration.preferredLabel(
            deviceID: deviceID,
            fallbackHandle: currentIdentityHandle
        )
        directQuicProvisioningStatus = "provisioning"
        do {
            let identity = try DirectQuicIdentityConfiguration.provisionProductionIdentity(
                label: label,
                deviceID: deviceID
            )
            directQuicProvisioningStatus = "ready"
            directQuicRegisteredFingerprint = identity.certificateFingerprint
            diagnostics.record(
                .media,
                message: "Direct QUIC production identity provisioned",
                metadata: [
                    "label": label,
                    "fingerprint": identity.certificateFingerprint,
                    "source": identity.source.rawValue,
                ]
            )
            return DirectQuicIdentityRegistrationMetadata(
                fingerprint: identity.certificateFingerprint
            )
        } catch {
            directQuicProvisioningStatus = "failed"
            let statusAfterFailure = DirectQuicIdentityConfiguration.status()
            pendingDirectQuicIdentityProvisioningFailureTelemetry = [
                "label": label,
                "deviceId": deviceID,
                "error": error.localizedDescription,
                "identityStatus": statusAfterFailure.diagnosticsText,
                "identitySource": statusAfterFailure.source.rawValue,
                "fingerprint": statusAfterFailure.fingerprint ?? "none",
                "provisioningStatus": directQuicProvisioningStatus,
            ]
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity provisioning failed",
                metadata: [
                    "label": label,
                    "deviceId": deviceID,
                    "error": error.localizedDescription,
                    "identityStatus": statusAfterFailure.diagnosticsText,
                    "identitySource": statusAfterFailure.source.rawValue,
                ]
            )
            flushPendingDirectQuicIdentityProvisioningFailureTelemetry(reason: "provisioning-failed")
            return nil
        }
    }

    func currentDirectQuicIdentityRegistrationMetadata() -> DirectQuicIdentityRegistrationMetadata? {
        let label = preferredDirectQuicIdentityLabel()
        return DirectQuicIdentityConfiguration.productionIdentityRegistrationMetadata(label: label)
    }

    func repairDirectQuicProductionIdentityRegistrationIfPossible(
        contactID: UUID,
        channelID: String,
        reason: String
    ) async -> Bool {
        guard let backend = backendServices else { return false }
        let status = DirectQuicIdentityConfiguration.status()
        if status.source == .production,
           let fingerprint = status.fingerprint,
           fingerprint == directQuicRegisteredFingerprint || directQuicRegisteredFingerprint == nil {
            return true
        }
        guard !directQuicIdentityRepairAttemptedDeviceIDs.contains(backend.deviceID) else {
            return false
        }
        directQuicIdentityRepairAttemptedDeviceIDs.insert(backend.deviceID)
        diagnostics.record(
            .media,
            message: "Repairing Direct QUIC production identity registration",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "deviceId": backend.deviceID,
                "reason": reason,
                "identityStatus": status.diagnosticsText,
                "provisioningStatus": directQuicProvisioningStatus,
                "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
            ]
        )
        guard let identity = provisionDirectQuicProductionIdentityForRegistration(
            deviceID: backend.deviceID
        ) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity repair failed during provisioning",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "reason": reason,
                ]
            )
            return false
        }
        do {
            _ = try await backend.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: identity,
                mediaEncryptionIdentity: currentMediaEncryptionIdentityRegistrationMetadata()
            )
            directQuicRegisteredFingerprint = identity.fingerprint
            diagnostics.record(
                .media,
                message: "Direct QUIC production identity registration repaired",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "fingerprint": identity.fingerprint,
                    "reason": reason,
                ]
            )
            await refreshContactSummaries()
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity repair registration failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "fingerprint": identity.fingerprint,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    func backendPeerDirectQuicFingerprint(for contactID: UUID) -> String? {
        channelReadinessByContactID[contactID]?.peerDirectQuicFingerprint
    }

    func directQuicProductionSignalAuthorizationFailure(
        signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> String? {
        if case .offer(let payload) = signal,
           payload.debugBypass == true,
           developerIdentityControlsEnabled {
            return nil
        }
        guard effectiveDirectQuicUpgradeEnabled else {
            return nil
        }
        let signaledFingerprint: String? = {
            switch signal {
            case .offer(let payload):
                return payload.certificateFingerprint
            case .answer(let payload):
                return payload.certificateFingerprint
            case .candidate, .hangup:
                return nil
            }
        }()
        guard let signaledFingerprint else { return nil }
        guard let normalizedSignaled = DirectQuicProductionIdentityManager.normalizedFingerprint(signaledFingerprint) else {
            return "invalid-signaled-peer-fingerprint"
        }
        guard let backendFingerprint = backendPeerDirectQuicFingerprint(for: contactID) else {
            return "backend-peer-fingerprint-missing"
        }
        guard normalizedSignaled == backendFingerprint else {
            return "backend-peer-fingerprint-mismatch"
        }
        recordRecentPeerDeviceEvidence(
            contactID: contactID,
            channelID: envelope.channelId,
            peerDeviceID: envelope.fromDeviceId,
            reason: "direct-quic-\(envelope.type.rawValue)",
            diagnosticSubsystem: .websocket
        )
        guard envelope.fromDeviceId == directQuicPeerDeviceID(for: contactID, fallback: envelope.fromDeviceId) else {
            return "peer-device-id-mismatch"
        }
        return nil
    }

    func cancelDirectQuicPromotionTimeout() {
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: nil)
        mediaRuntime.replaceDirectQuicSetupLivenessTask(with: nil)
    }

    func cancelDirectQuicAutoProbe() {
        mediaRuntime.replaceDirectQuicAutoProbeTask(with: nil)
    }

    func shouldAllowDirectQuicDebugBypassForAutomaticProbe() -> Bool {
        developerIdentityControlsEnabled && !backendAdvertisesDirectQuicUpgrade
    }

    func automaticDirectQuicProbeBlockReason(for contactID: UUID) -> String? {
        if isDirectPathRelayOnlyForced {
            return "relay-only-forced"
        }
        if TurboMediaRelayDebugOverride.isForced() {
            return "media-relay-forced"
        }
        if isDirectQuicAutoUpgradeDisabledForDebug {
            return "auto-upgrade-disabled"
        }
        recoverStaleDirectQuicAttemptBlockingProbeIfNeeded(
            for: contactID,
            trigger: "automatic-probe-block-check"
        )
        if directQuicActiveAttemptAlreadyOwnsPath(for: contactID, trigger: "automatic-probe-block-check") {
            return "direct-active"
        }
        if backendRuntime.signalingJoinRecoveryTask != nil {
            return "signaling-join-recovery-active"
        }
        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            return "leave-in-flight"
        }
        if !backendAdvertisesDirectQuicUpgrade,
           !shouldAllowDirectQuicDebugBypassForAutomaticProbe() {
            return "backend-capability-disabled"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        guard let backend = backendServices else {
            return "backend-unavailable"
        }
        guard selectedContactId == contactID else {
            return "not-selected-contact"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        guard contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        guard mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil else {
            return "attempt-active"
        }
        guard mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID) == nil else {
            return "retry-backoff"
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return "peer-device-missing"
        }
        guard directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        ) == .listenerOfferer else {
            return "not-listener-offerer"
        }
        guard systemSessionMatches(contactID),
              isJoined,
              activeChannelId == contactID else {
            return "local-session-not-aligned"
        }
        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return "channel-snapshot-missing"
        }
        guard case .both(let peerDeviceConnected) = channel.membership,
              peerDeviceConnected else {
            return "peer-device-not-connected"
        }
        guard channel.canTransmit,
              channel.readinessStatus == .ready else {
            return "channel-not-ready"
        }
        return nil
    }

    func shouldRequestAutomaticDirectQuicProbe(for contactID: UUID) -> Bool {
        automaticDirectQuicProbeBlockReason(for: contactID) == nil
    }

    func selectedContactDirectQuicPrewarmBlockReason(for contactID: UUID) -> String? {
        guard selectedContactDirectQuicPrewarmEnabled else {
            return "selected-prewarm-disabled"
        }
        return directQuicSelectionPrewarmBlockReason(
            for: contactID,
            requireSelectedContact: true
        )
    }

    func shouldRequestSelectedContactDirectQuicPrewarm(for contactID: UUID) -> Bool {
        selectedContactDirectQuicPrewarmBlockReason(for: contactID) == nil
    }

    func directQuicSelectionLifecycleBlockReason(for contactID: UUID) -> String? {
        let projection = selectedConversationProjection(for: contactID)
        if case .waitingForPeer(reason: .disconnecting) = projection.selectedConversationState.detail {
            return "selected-disconnecting"
        }
        if projection.devicePTTContinuity == .disconnecting {
            return "selected-disconnecting"
        }

        guard !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) else {
            return nil
        }
        guard conversationActionCoordinator.pendingAction == .none else {
            return nil
        }
        guard !backendJoinIsSettling(for: contactID) else {
            return nil
        }
        guard !devicePTTEvidenceExists(for: contactID) else {
            return nil
        }
        guard projection.selectedConversationState.relationship == .none else {
            return nil
        }
        guard let channel = selectedChannelSnapshot(for: contactID),
              channel.beepThreadProjection == .none,
              channel.membership.hasLocalMembership,
              channel.membership.hasPeerMembership else {
            return nil
        }
        return "stale-backend-membership"
    }

    func directQuicPeerDirectWarmabilityBlockReason(for contactID: UUID) -> String? {
        let projection = selectedConversationProjection(for: contactID)
        if projection.selectedConversationState.phase == .wakeReady {
            return "peer-wake-capable"
        }

        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return nil
        }
        if channel.remoteAudioReadiness == .wakeCapable {
            return "peer-wake-capable"
        }
        if channel.membership.hasLocalMembership,
           channel.membership.hasPeerMembership,
           !channel.membership.peerDeviceConnected,
           case .wakeCapable = channel.remoteWakeCapability {
            return "peer-device-not-connected"
        }
        return nil
    }

    func directQuicSelectionPrewarmBlockReason(
        for contactID: UUID,
        requireSelectedContact: Bool
    ) -> String? {
        if isDirectPathRelayOnlyForced {
            return "relay-only-forced"
        }
        if TurboMediaRelayDebugOverride.isForced() {
            return "media-relay-forced"
        }
        if isDirectQuicAutoUpgradeDisabledForDebug {
            return "auto-upgrade-disabled"
        }
        if let lifecycleBlockReason = directQuicSelectionLifecycleBlockReason(for: contactID) {
            return lifecycleBlockReason
        }
        if let warmabilityBlockReason = directQuicPeerDirectWarmabilityBlockReason(for: contactID) {
            return warmabilityBlockReason
        }
        recoverStaleDirectQuicAttemptBlockingProbeIfNeeded(
            for: contactID,
            trigger: "selection-prewarm-block-check"
        )
        if directQuicActiveAttemptAlreadyOwnsPath(for: contactID, trigger: "selection-prewarm-block-check") {
            return "direct-active"
        }
        if backendRuntime.signalingJoinRecoveryTask != nil {
            return "signaling-join-recovery-active"
        }
        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            return "leave-in-flight"
        }
        if !backendAdvertisesDirectQuicUpgrade {
            return "backend-capability-disabled"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        guard let backend = backendServices else {
            return "backend-unavailable"
        }
        if requireSelectedContact, selectedContactId != contactID {
            return "not-selected-contact"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        guard contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        if mediaRuntime.directQuicUpgrade.attempt(for: contactID) != nil {
            return "attempt-active"
        }
        if mediaRuntime.directQuicUpgrade.attemptByContactID.contains(where: { activeContactID, _ in
            activeContactID != contactID
        }) {
            return "other-attempt-active"
        }
        guard mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID) == nil else {
            return "retry-backoff"
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return "peer-device-missing"
        }
        guard directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        ) == .listenerOfferer else {
            return "not-listener-offerer"
        }
        guard backendPeerDirectQuicFingerprint(for: contactID) != nil else {
            return "peer-identity-missing"
        }
        return nil
    }

    func recoverStaleDirectQuicAttemptBlockingProbeIfNeeded(
        for contactID: UUID,
        trigger: String,
        now: Date = Date()
    ) {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return
        }
        guard mediaTransportPathState == .relay || mediaTransportPathState.isFastRelay else {
            return
        }
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            return
        }

        let staleAgeMilliseconds = Int(now.timeIntervalSince(attempt.lastUpdatedAt) * 1_000)
        guard staleAgeMilliseconds >= 5_000 else {
            return
        }

        let hadProbeController = mediaRuntime.directQuicProbeController != nil
        mediaRuntime.directQuicProbeController?.cancel(reason: "stale-attempt-blocking-reprobe")
        mediaRuntime.directQuicProbeController = nil
        diagnostics.recordInvariantViolation(
            invariantID: "direct-quic.stale_attempt_blocks_reprobe",
            scope: .local,
            message: "Direct QUIC attempt remained active after fallback, blocking reprobe",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "isDirectActive": String(attempt.isDirectActive),
                "transportPath": mediaTransportPathState.rawValue,
                "probeControllerActive": String(hadProbeController),
                "staleAgeMilliseconds": "\(staleAgeMilliseconds)",
                "trigger": trigger,
            ]
        )
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: "stale-attempt-blocking-reprobe",
            retryBackoff: nil,
            now: now
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
    }

    func directQuicActiveAttemptAlreadyOwnsPath(
        for contactID: UUID,
        trigger: String
    ) -> Bool {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              attempt.isDirectActive,
              mediaRuntime.directQuicProbeController != nil else {
            return false
        }

        switch mediaTransportPathState {
        case .direct:
            return true
        case .relay, .fastRelay, .fastRelayTcp, .promoting, .recovering:
            diagnostics.recordInvariantViolation(
                invariantID: "direct-quic.active_path_surfaced_as_relay",
                scope: .local,
                message: "Active Direct QUIC path was surfaced as a relay path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "transportPath": mediaTransportPathState.rawValue,
                    "trigger": trigger,
                ]
            )
            mediaRuntime.updateTransportPathState(.direct)
            captureDiagnosticsState("direct-quic:active-path-surface-repair")
            return true
        }
    }

    func maybeStartSelectedContactDirectQuicPrewarm(
        for contactID: UUID,
        reason: String
    ) async {
        let prewarmReason = "selection-direct-quic-prewarm-\(reason)"
        if let blockReason = selectedContactDirectQuicPrewarmBlockReason(for: contactID) {
            if blockReason == "relay-only-forced"
                || blockReason == "direct-active"
                || blockReason == "selected-prewarm-disabled" {
                return
            }
            diagnostics.record(
                .media,
                message: "Selection Direct QUIC prewarm skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": blockReason,
                ]
            )
            if blockReason == "not-listener-offerer" {
                await requestRemoteDirectQuicOfferIfPossible(
                    for: contactID,
                    reason: prewarmReason
                )
            }
            return
        }

        diagnostics.record(
            .media,
            message: "Selection Direct QUIC prewarm requested",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
        await maybeStartDirectQuicProbe(for: contactID)
    }

    func directQuicFirstTalkWarmupBlockReason(for contactID: UUID) -> String? {
        if isDirectPathRelayOnlyForced {
            return "relay-only-forced"
        }
        if TurboMediaRelayDebugOverride.isForced() {
            return "media-relay-forced"
        }
        if isDirectQuicAutoUpgradeDisabledForDebug {
            return "auto-upgrade-disabled"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        let existingAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID)
        if existingAttempt == nil,
           !backendAdvertisesDirectQuicUpgrade {
            return "backend-capability-disabled"
        }
        guard let backend = backendServices else {
            return "backend-unavailable"
        }
        guard selectedContactId == contactID else {
            return "not-selected-contact"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        guard contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return "peer-device-missing"
        }
        if existingAttempt == nil,
           directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
           ) != .listenerOfferer {
            return "not-listener-offerer"
        }
        guard systemSessionMatches(contactID),
              isJoined,
              activeChannelId == contactID else {
            return "local-session-not-aligned"
        }
        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return "channel-snapshot-missing"
        }
        guard case .both(let peerDeviceConnected) = channel.membership,
              peerDeviceConnected else {
            return "peer-device-not-connected"
        }
        guard channel.canTransmit,
              channel.readinessStatus == .ready else {
            return "channel-not-ready"
        }
        if existingAttempt != nil {
            return nil
        }
        if !shouldAllowDirectQuicDebugBypassForAutomaticProbe() {
            let localIdentityStatus = DirectQuicIdentityConfiguration.status()
            guard localIdentityStatus.source == .production,
                  let localFingerprint = localIdentityStatus.fingerprint,
                  localFingerprint == directQuicRegisteredFingerprint
                    || directQuicRegisteredFingerprint == nil else {
                return "identity-unavailable"
            }
            guard backendPeerDirectQuicFingerprint(for: contactID) != nil else {
                return "peer-identity-missing"
            }
        }
        if let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID) {
            let isFastConnectivityRetry =
                retryBackoff.category == .connectivity
                && retryBackoff.milliseconds <= foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds
            return isFastConnectivityRetry ? nil : "retry-backoff"
        }
        return nil
    }

    func maybeStartAutomaticDirectQuicProbe(
        for contactID: UUID,
        reason: String
    ) async {
        if let blockReason = automaticDirectQuicProbeBlockReason(for: contactID) {
            if blockReason == "direct-active" {
                return
            }
            diagnostics.record(
                .media,
                message: "Automatic Direct QUIC probe skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": blockReason,
                    "debugBypass": String(shouldAllowDirectQuicDebugBypassForAutomaticProbe()),
                ]
            )
            if blockReason == "not-listener-offerer" {
                await requestRemoteDirectQuicOfferIfPossible(
                    for: contactID,
                    reason: reason
                )
            }
            return
        }

        diagnostics.record(
            .media,
            message: "Automatic Direct QUIC probe requested",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "debugBypass": String(shouldAllowDirectQuicDebugBypassForAutomaticProbe()),
            ]
        )
        await maybeStartDirectQuicProbe(
            for: contactID,
            allowDebugBypassWithoutBackendAdvertisement: shouldAllowDirectQuicDebugBypassForAutomaticProbe()
        )
    }

    func requestRemoteDirectQuicOfferIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard backendAdvertisesDirectQuicUpgrade else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request skipped because backend capability is disabled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard let backend = backendServices else {
            diagnostics.record(
                .backend,
                message: "Direct QUIC upgrade request skipped because backend is unavailable",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request skipped because peer routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        ) == .dialerAnswerer else {
            return
        }
        let throttleInterval = TimeInterval(directQuicUpgradeRequestThrottleMilliseconds) / 1_000
        guard mediaRuntime.reserveDirectQuicUpgradeRequestSend(
            for: contactID,
            minimumInterval: throttleInterval
        ) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC upgrade request throttled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "throttleMs": "\(directQuicUpgradeRequestThrottleMilliseconds)",
                ]
            )
            return
        }

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: UUID().uuidString.lowercased(),
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            toDeviceId: peerDeviceID,
            reason: reason,
            roleIntent: .listener,
            debugBypass: false
        )

        do {
            let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: payload
            )
            _ = try await backend.sendDirectQuicSignal(envelope)
            diagnostics.record(
                .backend,
                message: "Direct QUIC upgrade request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "requestId": payload.requestId,
                    "reason": reason,
                    "localRole": DirectQuicAttemptRole.dialerAnswerer.rawValue,
                    "peerDeviceId": peerDeviceID,
                ]
            )
        } catch {
            mediaRuntime.clearDirectQuicUpgradeRequestThrottle(for: contactID)
            diagnostics.record(
                .backend,
                level: .error,
                message: "Direct QUIC upgrade request send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func scheduleAutomaticDirectQuicProbe(
        for contactID: UUID,
        reason: String
    ) {
        if isDirectQuicAutoUpgradeDisabledForDebug {
            diagnostics.record(
                .media,
                message: "Automatic Direct QUIC reprobe not scheduled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": "auto-upgrade-disabled",
                ]
            )
            return
        }

        let retryRemainingMilliseconds = mediaRuntime.directQuicUpgrade
            .retryBackoffRemaining(for: contactID)
            .map { max(Int($0 * 1_000), 0) } ?? 0
        let delayMilliseconds = max(retryRemainingMilliseconds, 250)

        mediaRuntime.replaceDirectQuicAutoProbeTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "\(reason)-scheduled"
            )
            await MainActor.run {
                self.mediaRuntime.directQuicAutoProbeTask = nil
            }
        })

        diagnostics.record(
            .media,
            message: "Scheduled automatic Direct QUIC reprobe",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "delayMilliseconds": "\(delayMilliseconds)",
            ]
        )
    }

    func importDirectQuicIdentityForDebug(
        from fileURL: URL,
        password: String
    ) async {
        let resolvedLabel = preferredDirectQuicIdentityLabel()
        let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let pkcs12Data = try Data(contentsOf: fileURL)
            try DirectQuicIdentityConfiguration.importPKCS12Identity(
                data: pkcs12Data,
                password: password,
                label: resolvedLabel
            )
            DirectQuicIdentityConfiguration.setResolvedLabel(resolvedLabel)
            diagnostics.record(
                .media,
                message: "Direct QUIC identity imported from diagnostics",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "selectedContact": selectedContact?.handle ?? "none",
                ]
            )
            statusMessage = "Direct QUIC identity imported"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC identity import failed",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-import")
    }

    func adoptInstalledDirectQuicIdentityForDebug() {
        let resolvedLabel = preferredDirectQuicIdentityLabel()

        do {
            let fingerprint = try DirectQuicIdentityConfiguration.adoptInstalledIdentity(
                label: resolvedLabel
            )
            diagnostics.record(
                .media,
                message: "Direct QUIC installed identity adopted from diagnostics",
                metadata: [
                    "label": resolvedLabel,
                    "fingerprint": fingerprint,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = "Direct QUIC installed identity adopted"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC installed identity adoption failed",
                metadata: [
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-adopt-installed")
    }

    func setDirectPathRelayOnlyForcedForDebug(_ isForced: Bool) async {
        let previousValue = isDirectPathRelayOnlyForced
        TurboDirectPathDebugOverride.setRelayOnlyForced(isForced)

        diagnostics.record(
            .media,
            message: "Direct QUIC relay-only override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isForced),
            ]
        )

        if isForced {
            await cancelSelectedDirectQuicAttemptForDebug(reason: "debug-force-relay-only")
        }

        statusMessage = isForced
            ? "Direct path upgrade disabled for debugging"
            : "Direct path upgrade enabled"
        captureDiagnosticsState("direct-quic:debug-relay-only")
    }

    func setDirectQuicAutoUpgradeDisabledForDebug(_ isDisabled: Bool) async {
        let previousValue = isDirectQuicAutoUpgradeDisabledForDebug
        TurboDirectPathDebugOverride.setAutoUpgradeDisabled(isDisabled)

        diagnostics.record(
            .media,
            message: "Direct QUIC auto-upgrade override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isDisabled),
            ]
        )

        if isDisabled {
            cancelDirectQuicAutoProbe()
        }

        statusMessage = isDisabled
            ? "Direct path auto-upgrade disabled"
            : "Direct path auto-upgrade enabled"
        captureDiagnosticsState("direct-quic:debug-auto-upgrade")
    }

    func setMediaRelayEnabledForDebug(_ isEnabled: Bool) {
        let previousValue = TurboMediaRelayDebugOverride.isEnabled()
        TurboMediaRelayDebugOverride.setEnabled(isEnabled)

        diagnostics.record(
            .media,
            message: "Media relay override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isEnabled),
                "configured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
            ]
        )

        if !isEnabled {
            TurboMediaRelayDebugOverride.setForced(false)
            mediaRuntime.replaceMediaRelayClient(with: nil)
        }

        statusMessage = isEnabled ? "Media relay enabled" : "Media relay disabled"
        captureDiagnosticsState("media-relay:debug-enabled")
    }

    func setMediaRelayForcedForDebug(_ isForced: Bool) {
        let previousValue = TurboMediaRelayDebugOverride.isForced()
        TurboMediaRelayDebugOverride.setForced(isForced)
        if isForced {
            TurboMediaRelayDebugOverride.setEnabled(true)
            mediaRuntime.updateTransportPathState(.relay)
        }

        diagnostics.record(
            .media,
            message: "Media relay force override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isForced),
                "configured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
            ]
        )

        if isForced {
            Task {
                await cancelSelectedDirectQuicAttemptForDebug(reason: "media-relay-forced")
            }
        } else {
            mediaRuntime.replaceMediaRelayClient(with: nil)
        }

        statusMessage = isForced ? "Media relay forced" : "Media relay force disabled"
        captureDiagnosticsState("media-relay:debug-forced")
    }

    func setMediaRelayConfigForDebug(
        host: String,
        quicPort: UInt16,
        tcpPort: UInt16,
        token: String
    ) {
        let sanitizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        TurboMediaRelayDebugOverride.setConfig(
            host: sanitizedHost,
            quicPort: quicPort,
            tcpPort: tcpPort,
            token: sanitizedToken
        )
        mediaRuntime.replaceMediaRelayClient(with: nil)
        diagnostics.record(
            .media,
            message: "Media relay config updated from diagnostics",
            metadata: [
                "host": sanitizedHost,
                "quicPort": String(quicPort),
                "tcpPort": String(tcpPort),
                "hasToken": String(!sanitizedToken.isEmpty),
            ]
        )
        statusMessage = "Media relay config saved"
        captureDiagnosticsState("media-relay:debug-config")
    }

    func setAudioPacketDiagnosticsEnabledForDebug(_ isEnabled: Bool) {
        let previousValue = TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()
        TurboAudioDiagnosticsDebugOverride.setPacketMetadataEnabled(isEnabled)
        if let selectedContactId {
            mediaRuntime.resetIncomingRelayAudioDiagnostics(
                for: selectedContactId,
                detailedReportLimit: incomingAudioDiagnosticDetailedReportLimit()
            )
        }

        diagnostics.record(
            .media,
            message: "Audio packet metadata diagnostics updated",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isEnabled),
                "rawAudioCaptured": "false",
            ]
        )
        statusMessage = isEnabled ? "Audio packet metadata enabled" : "Audio packet metadata disabled"
        captureDiagnosticsState("media-audio:packet-diagnostics")
    }

    func setLiveAudioDiagnosticsEnabledForDebug(_ isEnabled: Bool) {
        let previousValue = TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled()
        TurboAudioDiagnosticsDebugOverride.setLiveAudioDiagnosticsEnabled(isEnabled)
        if let selectedContactId {
            mediaRuntime.resetIncomingRelayAudioDiagnostics(
                for: selectedContactId,
                detailedReportLimit: incomingAudioDiagnosticDetailedReportLimit()
            )
            mediaRuntime.resetDirectQuicIncomingAudioQueueDelayDiagnostics(for: selectedContactId)
        }

        diagnostics.record(
            .media,
            message: "Live audio diagnostics updated",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isEnabled),
            ]
        )
        statusMessage = isEnabled ? "Live audio diagnostics enabled" : "Live audio diagnostics disabled"
        captureDiagnosticsState("media-audio:live-diagnostics")
    }

    func setVoiceMediaCoreModeForDebug(_ mode: VoiceMediaCoreMode) {
        let previousValue = TurboVoiceMediaCoreDebugOverride.liveMode()
        TurboVoiceMediaCoreDebugOverride.setLiveMode(mode)

        diagnostics.record(
            .media,
            message: "Voice media core mode updated",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": previousValue.rawValue,
                "newValue": mode.rawValue,
            ]
        )
        statusMessage = "Voice media core: \(mode.rawValue)"
        captureDiagnosticsState("media-audio:voice-media-core")
    }

    func setBinaryVoicePacketV1EnabledForDebug(_ isEnabled: Bool) {
        let previousValue = TurboBinaryVoicePacketDebugOverride.isEnabled()
        TurboBinaryVoicePacketDebugOverride.setEnabled(isEnabled)

        diagnostics.record(
            .media,
            message: "Binary voice packet v1 advertisement updated",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isEnabled),
            ]
        )
        statusMessage = isEnabled ? "Binary voice packet enabled" : "Binary voice packet disabled"
        captureDiagnosticsState("media-audio:binary-voice-packet")
    }

    func setDirectQuicTransmitStartupPolicyForDebug(
        _ policy: DirectQuicTransmitStartupPolicy
    ) {
        let previousValue = directQuicTransmitStartupPolicy
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(policy)

        diagnostics.record(
            .media,
            message: "Direct QUIC transmit startup policy updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": previousValue.rawValue,
                "newValue": policy.rawValue,
            ]
        )
        statusMessage = "Direct transmit waits for Apple PTT"
        captureDiagnosticsState("direct-quic:debug-transmit-startup-policy")
    }

    func setMediaLaneOverrideForDebug(_ override: TurboMediaLaneOverride) async {
        let previousValue = TurboMediaLaneDebugOverride.mediaLaneOverride()
        TurboMediaLaneDebugOverride.setMediaLaneOverride(override)

        switch override {
        case .automatic:
            break
        case .forceDirectQuic:
            mediaRuntime.replaceMediaRelayClient(with: nil)
            mediaRuntime.updateTransportPathState(.direct)
        case .forceFastRelayQuic:
            mediaRuntime.updateTransportPathState(.fastRelay)
            await cancelSelectedDirectQuicAttemptForDebug(reason: "debug-force-fast-relay-quic")
        case .forceFastRelayTls:
            mediaRuntime.updateTransportPathState(.fastRelayTcp)
            await cancelSelectedDirectQuicAttemptForDebug(reason: "debug-force-fast-relay-tls")
        }

        diagnostics.record(
            .media,
            message: "Media lane override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": previousValue.rawValue,
                "newValue": override.rawValue,
                "effectiveTransportPath": mediaRuntime.transportPathState.diagnosticsValue,
                "configured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
            ]
        )

        statusMessage = "Media lane: \(override.label)"
        captureDiagnosticsState("media-lane:debug-override")
    }

    func setControlCommandTransportPolicyForDebug(_ policy: TurboControlCommandTransportPolicy) {
        let previousValue = backendServices?.controlCommandTransportPolicy
            ?? TurboControlCommandTransportDebugOverride.policy()
            ?? .automatic
        TurboControlCommandTransportDebugOverride.setPolicy(policy)
        let selection = backendServices?.runtimeControlSelection
            ?? TurboRuntimeControlSelection(
                requestedPolicy: policy,
                effectiveLane: .runtimeHttpRequest,
                fallbackReason: "backend-unavailable"
            )

        diagnostics.record(
            .backend,
            message: "Runtime control transport policy updated from diagnostics",
            metadata: [
                "previousValue": previousValue.rawValue,
                "newValue": policy.rawValue,
                "effectiveLane": selection.effectiveLane.rawValue,
                "fallbackReason": selection.fallbackReason ?? "none",
                "persistent": String(selection.usesPersistentTransport),
            ]
        )
        statusMessage = "Runtime control: \(policy.label)"
        captureDiagnosticsState("runtime-control:debug-policy")
    }

    func forceSelectedDirectQuicProbeForDebug() async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug probe skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-force-probe:no-selection")
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC debug probe requested",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "relayOnlyOverride": String(isDirectPathRelayOnlyForced),
                "backendAdvertised": String(backendAdvertisesDirectQuicUpgrade),
                "directQuicEnabled": String(effectiveDirectQuicUpgradeEnabled),
                "existingAttempt": String(
                    mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) != nil
                ),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:requested")
        await maybeStartDirectQuicProbe(
            for: selectedContact.id,
            allowDebugBypassWithoutBackendAdvertisement: true
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:completed")
    }

    func clearSelectedDirectQuicRetryBackoffForDebug() {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC retry backoff clear skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-clear-backoff:no-selection")
            return
        }

        let previousBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: selectedContact.id)
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: selectedContact.id)
        diagnostics.record(
            .media,
            message: previousBackoff == nil
                ? "Direct QUIC retry backoff was already clear"
                : "Direct QUIC retry backoff cleared from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "previousReason": previousBackoff?.reason ?? "none",
                "previousCategory": previousBackoff?.category.rawValue ?? "none",
                "previousAttemptId": previousBackoff?.attemptId ?? "none",
                "previousBackoffMs": previousBackoff.map { String($0.milliseconds) } ?? "none",
            ]
        )
        captureDiagnosticsState("direct-quic:debug-clear-backoff")
    }

    func cancelSelectedDirectQuicAttemptForDebug(
        reason: String = "debug-cancel"
    ) async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug cancel skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-selection")
            return
        }
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug cancel skipped because there is no active attempt",
                metadata: [
                    "contactId": selectedContact.id.uuidString,
                    "handle": selectedContact.handle,
                    "reason": reason,
                ]
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-attempt")
            return
        }

        cancelDirectQuicPromotionTimeout()
        await sendDirectQuicHangup(
            for: selectedContact.id,
            attempt: attempt,
            reason: reason
        )
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: selectedContact.id,
            fallbackReason: reason,
            retryBackoff: nil
        )
        applyDirectQuicUpgradeTransition(fallback, for: selectedContact.id)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == selectedContact.id {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC attempt cancelled from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "attemptId": attempt.attemptId,
                "reason": reason,
                "wasDirectActive": String(attempt.isDirectActive),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-cancel")
    }

}
