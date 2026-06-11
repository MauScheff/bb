import Foundation
import UIKit

extension PTTViewModel {
    var directQuicNetworkMigrationDeadlineMilliseconds: Int { 2_500 }

    func scheduleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String
    ) {
        if let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
           attempt.attemptId == attemptID,
           attempt.isDirectActive {
            diagnostics.record(
                .media,
                message: "Skipped Direct QUIC promotion timeout for active path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                ]
            )
            cancelDirectQuicPromotionTimeout()
            return
        }
        let timeoutMilliseconds = directQuicPromotionTimeoutMilliseconds()
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.handleDirectQuicPromotionTimeout(
                contactID: contactID,
                attemptID: attemptID,
                timeoutMilliseconds: timeoutMilliseconds
            )
        })
    }

    func scheduleDirectQuicSetupLivenessResends(
        contactID: UUID,
        attemptID: String,
        peerDeviceID: String
    ) {
        let resendDelaysNanoseconds: [UInt64] = [
            1_500_000_000,
            1_500_000_000,
            3_000_000_000,
            4_000_000_000,
        ]
        mediaRuntime.replaceDirectQuicSetupLivenessTask(with: Task { [weak self] in
            guard let self else { return }
            for (index, delay) in resendDelaysNanoseconds.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self.resendActiveDirectQuicOfferForLivenessIfNeeded(
                    contactID: contactID,
                    attemptID: attemptID,
                    peerDeviceID: peerDeviceID,
                    livenessStep: index + 1
                )
            }
        })
    }

    func beginDirectQuicNetworkMigrationLivenessProbe(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        generation: UInt64,
        interface: ConversationNetworkInterface,
        source: String
    ) async {
        let deadlineMilliseconds = directQuicNetworkMigrationDeadlineMilliseconds
        let probe = DirectQuicNetworkMigrationProbe(
            contactID: contactID,
            attemptID: attempt.attemptId,
            generation: generation,
            interface: interface
        )
        mediaRuntime.replaceDirectQuicNetworkMigrationProbe(
            probe,
            with: Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(deadlineMilliseconds) * 1_000_000)
                guard !Task.isCancelled else { return }
                await self.handleDirectQuicNetworkMigrationLivenessDeadline(
                    for: contactID,
                    attemptID: attempt.attemptId,
                    generation: generation
                )
            }
        )
        diagnostics.record(
            .media,
            message: "Trying Direct QUIC network migration",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "interface": interface.rawValue,
                "networkPathGeneration": "\(generation)",
                "deadlineMilliseconds": "\(deadlineMilliseconds)",
                "source": source,
            ]
        )
        startMediaRelayStandbyForDirectQuicNetworkMigration(
            contactID: contactID,
            attempt: attempt,
            generation: generation,
            source: source
        )
        await sendDirectQuicWarmPingIfPossible(
            for: contactID,
            reason: "network-migration"
        )
    }

    func startMediaRelayStandbyForDirectQuicNetworkMigration(
        contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        generation: UInt64,
        source: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            await self.ensureMediaRelayStandbyForDirectQuicNetworkMigration(
                contactID: contactID,
                attempt: attempt,
                generation: generation,
                source: source
            )
        }
    }

    func ensureMediaRelayStandbyForDirectQuicNetworkMigration(
        contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        generation: UInt64,
        source: String
    ) async {
        guard shouldSurfaceDirectTransportPath(for: contactID) else { return }
        guard !isDirectPathRelayOnlyForced else { return }
        guard TurboMediaRelayDebugOverride.isEnabled()
            || TurboMediaRelayDebugOverride.isForced() else {
            return
        }

        if mediaRuntime.hasActiveMediaRelayClient {
            syncEngineActiveMediaRelayLaneAvailable(
                source: "direct-quic-network-migration-standby-existing"
            )
            diagnostics.record(
                .media,
                message: "Fast relay standby already active for Direct QUIC network migration",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "networkPathGeneration": "\(generation)",
                    "source": source,
                ]
            )
            return
        }

        let resolvedChannelID =
            attempt.channelID.isEmpty
                ? contacts.first(where: { $0.id == contactID })?.backendChannelId
                    ?? channelStateByContactID[contactID]?.channelId
                    ?? contactSummaryByContactID[contactID]?.channelId
                : attempt.channelID
        let resolvedPeerDeviceID = attempt.peerDeviceID
            ?? directQuicPeerDeviceID(for: contactID)

        guard let resolvedChannelID,
              !resolvedChannelID.isEmpty,
              let resolvedPeerDeviceID,
              !resolvedPeerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Fast relay standby skipped for Direct QUIC network migration because routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attempt.attemptId,
                    "networkPathGeneration": "\(generation)",
                    "source": source,
                    "hasChannelId": String(resolvedChannelID?.isEmpty == false),
                    "hasPeerDeviceId": String(resolvedPeerDeviceID?.isEmpty == false),
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Prewarming fast relay standby for Direct QUIC network migration",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": resolvedChannelID,
                "attemptId": attempt.attemptId,
                "peerDeviceId": resolvedPeerDeviceID,
                "networkPathGeneration": "\(generation)",
                "source": source,
            ]
        )
        await connectMediaRelayForReceiveIfNeeded(
            contactID: contactID,
            channelID: resolvedChannelID,
            peerDeviceID: resolvedPeerDeviceID
        )
    }

    func handleDirectQuicNetworkMigrationLivenessDeadline(
        for contactID: UUID,
        attemptID: String,
        generation: UInt64
    ) async {
        guard let probe = mediaRuntime.clearDirectQuicNetworkMigrationProbe(
            contactID: contactID,
            attemptID: attemptID,
            generation: generation
        ) else {
            return
        }
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID),
              attempt.isDirectActive,
              mediaTransportPathState == .direct else {
            return
        }
        diagnostics.record(
            .media,
            level: .notice,
            message: "Direct QUIC network migration liveness deadline missed",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "interface": probe.interface.rawValue,
                "networkPathGeneration": "\(generation)",
            ]
        )
        await handleDirectQuicMediaPathLost(
            for: contactID,
            attemptID: attemptID,
            reason: "network-migration-timeout"
        )
    }

    @discardableResult
    func confirmDirectQuicNetworkMigrationIfNeeded(
        for contactID: UUID,
        attemptID: String,
        reason: String
    ) -> Bool {
        guard let probe = mediaRuntime.clearDirectQuicNetworkMigrationProbe(
            contactID: contactID,
            attemptID: attemptID
        ) else {
            return false
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC network migration preserved",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "interface": probe.interface.rawValue,
                "networkPathGeneration": "\(probe.generation)",
                "reason": reason,
            ]
        )
        return true
    }

    func resendActiveDirectQuicOfferForLivenessIfNeeded(
        contactID: UUID,
        attemptID: String,
        peerDeviceID: String,
        livenessStep: Int
    ) async {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              attempt.attemptId == attemptID,
              attempt.peerDeviceID == peerDeviceID,
              !attempt.isDirectActive,
              attempt.remoteAnswer == nil else {
            return
        }

        await resendActiveDirectQuicOfferIfPossible(
            for: contactID,
            requestedBy: peerDeviceID,
            requestId: "setup-liveness-\(livenessStep)",
            reason: "direct-quic-setup-liveness"
        )
    }

    func handleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String,
        timeoutMilliseconds: Int
    ) async {
        guard let activeAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              activeAttempt.attemptId == attemptID else {
            return
        }
        if activeAttempt.isDirectActive {
            diagnostics.record(
                .media,
                message: "Ignored Direct QUIC promotion timeout after activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": activeAttempt.channelID,
                    "attemptId": attemptID,
                    "timeoutMilliseconds": "\(timeoutMilliseconds)",
                ]
            )
            cancelDirectQuicPromotionTimeout()
            return
        }
        let conversationStillActive = selectedContactId == contactID
            || selectedContact?.id == contactID
            || activeChannelId == contactID
        if !conversationStillActive {
            diagnostics.record(
                .media,
                message: "Ignored Direct QUIC promotion timeout after conversation ended",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": activeAttempt.channelID,
                    "attemptId": attemptID,
                    "timeoutMilliseconds": "\(timeoutMilliseconds)",
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "promotion-timeout-stale-conversation",
                sendHangup: false,
                applyRetryBackoff: false
            )
            return
        }
        let elapsedSinceProgressMilliseconds = Int(Date().timeIntervalSince(activeAttempt.lastUpdatedAt) * 1_000)
        if elapsedSinceProgressMilliseconds < max(timeoutMilliseconds - 250, 0) {
            diagnostics.record(
                .media,
                message: "Direct QUIC promotion timeout extended after recent progress",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": activeAttempt.channelID,
                    "attemptId": attemptID,
                    "timeoutMilliseconds": "\(timeoutMilliseconds)",
                    "elapsedSinceProgressMilliseconds": "\(elapsedSinceProgressMilliseconds)",
                ]
            )
            scheduleDirectQuicPromotionTimeout(contactID: contactID, attemptID: attemptID)
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC promotion timed out",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": activeAttempt.channelID,
                "attemptId": attemptID,
                "timeoutMilliseconds": "\(timeoutMilliseconds)",
            ]
        )
        await finishDirectQuicAttempt(
            for: contactID,
            reason: "promotion-timeout",
            sendHangup: true,
            applyRetryBackoff: true
        )
    }

    func finishDirectQuicAttempt(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        applyRetryBackoff: Bool
    ) async {
        cancelDirectQuicPromotionTimeout()

        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            mediaRuntime.directQuicProbeController?.cancel(reason: reason)
            mediaRuntime.directQuicProbeController = nil
            clearDirectAudioPlaybackVerification(contactID: contactID)
            return
        }
        clearDirectAudioPlaybackVerification(contactID: contactID, channelID: attempt.channelID)

        if sendHangup {
            await sendDirectQuicHangup(
                for: contactID,
                attempt: attempt,
                reason: reason
            )
        }

        let retryBackoff = applyRetryBackoff
            ? directQuicPromotionRetryBackoffRequest(
                for: contactID,
                reason: reason,
                attemptID: attempt.attemptId
            )
            : nil

        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: reason,
            retryBackoff: retryBackoff
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
        if retryBackoff?.category == .connectivity {
            scheduleAutomaticDirectQuicProbe(
                for: contactID,
                reason: reason
            )
        }
    }

    func activateDirectQuicMediaPath(
        for contactID: UUID,
        attemptID: String
    ) async {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }
        guard let nominatedPath = controller.nominatedPath(matching: attemptID) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC activation deferred because no nominated path is available yet",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                ]
            )
            return
        }
        let channelID = attempt.channelID
        let fromDeviceID = attempt.peerDeviceID ?? "direct-quic"
        let fromUserID = contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""

        if shouldHoldBackgroundWakeReceiveLane(for: contactID) {
            diagnostics.record(
                .media,
                message: "Deferred Direct QUIC media activation during background wake receive",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                    "activeMediaEpochPath": mediaRuntime.activeMediaEpochPathState?.rawValue ?? "none",
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "background-wake-receive-lane-held",
                sendHangup: true,
                applyRetryBackoff: false
            )
            return
        }

        do {
            try await controller.activateMediaTransport(
                onIncomingAudioPayload: { [weak self] payload in
                    guard let self, !Task.isCancelled else { return }
                    await self.handleIncomingDirectQuicPacketAudioPayload(
                        payload,
                        contactID: contactID,
                        channelID: channelID,
                        fromUserID: fromUserID,
                        fromDeviceID: fromDeviceID
                    )
                },
                onExpiredIncomingAudioPayload: { [weak self] payload, localQueueDelayNanoseconds, thresholdNanoseconds in
                    guard let self, !Task.isCancelled else { return }
                    await self.handleExpiredDirectQuicIncomingAudioPayloadBeforeAppHandler(
                        payload,
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: fromDeviceID,
                        localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                        thresholdNanoseconds: thresholdNanoseconds
                    )
                },
                onReceiverPrewarmRequest: { [weak self] payload in
                    guard let self, !Task.isCancelled else { return }
                    await self.ingestDirectQuicReceiverPrewarmRequest(
                        payload,
                        contactID: contactID,
                        attemptID: attemptID
                    )
                },
                onReceiverPrewarmAck: { [weak self] payload in
                    guard let self, !Task.isCancelled else { return }
                    await self.ingestDirectQuicReceiverPrewarmAck(
                        payload,
                        contactID: contactID,
                        attemptID: attemptID
                    )
                },
                onPathClosing: { [weak self] payload in
                    guard let self, !Task.isCancelled else { return }
                    await self.ingestDirectQuicPathClosing(
                        payload,
                        contactID: contactID
                    )
                },
                onWarmPong: { [weak self] pingID in
                    guard let self, !Task.isCancelled else { return }
                    await self.ingestDirectQuicWarmPong(
                        pingID,
                        contactID: contactID,
                        attemptID: attemptID
                    )
                },
                onAudioPlaybackStarted: { [weak self] payload in
                    guard let self, !Task.isCancelled else { return }
                    await self.ingestAudioPlaybackStartedAck(
                        payload,
                        contactID: contactID,
                        source: .directQuicDataChannel,
                        remoteDeviceID: payload.receiverDeviceId,
                        attemptID: attemptID
                    )
                },
                onLivenessConfirmed: { [weak self] reason in
                    guard let self, !Task.isCancelled else { return }
                    await self.confirmDirectQuicNetworkMigrationIfNeeded(
                        for: contactID,
                        attemptID: attemptID,
                        reason: reason
                    )
                },
                onPathLost: { [weak self] reason in
                    guard let self, !Task.isCancelled else { return }
                    await self.handleDirectQuicMediaPathLost(
                        for: contactID,
                        attemptID: attemptID,
                        reason: reason
                    )
                }
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to activate direct QUIC media path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "activation-failed",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        guard let transition = mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: attemptID,
            nominatedPath: nominatedPath
        ) else {
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC media path activated",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "nominatedPathSource": nominatedPath.source.rawValue,
                "nominatedRemoteAddress": nominatedPath.remoteAddress,
                "nominatedRemotePort": "\(nominatedPath.remotePort)",
                "nominatedRemoteCandidateKind": nominatedPath.remoteCandidateKind?.rawValue ?? "observed",
            ]
        )
        cancelDirectQuicPromotionTimeout()
        cancelDirectQuicAutoProbe()
        mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
        applyDirectQuicUpgradeTransition(transition, for: contactID)
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        await requestReceiverPrewarmForFirstTalk(
            for: contactID,
            reason: "direct-quic-activated"
        )
    }

    func requestReceiverPrewarmForFirstTalk(
        for contactID: UUID,
        reason: String
    ) async {
        if mediaRuntime.hasReceiverPrewarmRequest(for: contactID),
           mediaRuntime.receiverPrewarmRequestIsAcknowledged(for: contactID) {
            diagnostics.record(
                .media,
                message: "Skipping duplicate Direct QUIC receiver prewarm request",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "acknowledged": String(mediaRuntime.receiverPrewarmRequestIsAcknowledged(for: contactID)),
                ]
            )
            return
        }

        if shouldUseDirectQuicTransport(for: contactID),
           await sendDirectQuicReceiverPrewarmRequest(for: contactID, reason: reason) {
            Task { @MainActor [weak self] in
                _ = await self?.sendMediaRelayReceiverPrewarmRequestIfPossible(
                    for: contactID,
                    reason: reason,
                    requestID: self?.mediaRuntime.receiverPrewarmRequestID(for: contactID)
                )
            }
            await sendDirectQuicWarmPingIfPossible(for: contactID, reason: reason)
            return
        }

        if await sendMediaRelayReceiverPrewarmRequestIfPossible(for: contactID, reason: reason) {
            return
        }

        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .receiverPrewarmRequest
        )
    }

    @discardableResult
    func sendDirectQuicReceiverPrewarmRequest(
        for contactID: UUID,
        reason: String,
        requestID: String? = nil,
        recordOutboundRequestID: Bool = false
    ) async -> Bool {
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let attempt = directQuicAttempt(for: contactID),
              attempt.isDirectActive,
              let controller = mediaRuntime.directQuicProbeController else {
            return false
        }

        let requestID = requestID ?? mediaRuntime.receiverPrewarmRequestID(for: contactID)
        if recordOutboundRequestID {
            mediaRuntime.replaceReceiverPrewarmRequestID(
                for: contactID,
                requestID: requestID
            )
        }
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: requestID,
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            reason: reason,
            directQuicAttemptId: attempt.attemptId
        )

        do {
            try await controller.sendReceiverPrewarmRequest(payload)
            diagnostics.record(
                .media,
                message: "Direct QUIC receiver prewarm request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestID,
                    "reason": reason,
                    "supportsOpusV2": String(payload.mediaCapabilities?.supportsOpusV2 == true),
                ]
            )
            return true
        } catch {
            mediaRuntime.clearReceiverPrewarmState(for: contactID)
            diagnostics.record(
                .media,
                message: "Direct QUIC receiver prewarm request failed; using relay readiness fallback",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    @discardableResult
    func beginDirectQuicPathClosingIfPossible(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        reason: String,
        controller: DirectQuicProbeController?
    ) -> Bool {
        guard attempt.isDirectActive,
              let controller else {
            return false
        }

        let payload = DirectQuicPathClosingPayload(
            attemptId: attempt.attemptId,
            reason: reason
        )

        controller.beginIntentionalPathClose(
            payload,
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "reason": reason,
            ],
            cancelReason: reason
        )
        return true
    }

    @discardableResult
    func sendDirectQuicReceiverTransmitPrepareIfPossible(
        for contactID: UUID,
        reason: String,
        sendWarmPing: Bool = true
    ) async -> Bool {
        let requestID = UUID().uuidString.lowercased()
        let transmitPrepareReason = "transmit-\(reason)"
        let sent = await sendDirectQuicReceiverPrewarmRequest(
            for: contactID,
            reason: transmitPrepareReason,
            requestID: requestID,
            recordOutboundRequestID: true
        )
        if sent, sendWarmPing {
            await sendDirectQuicWarmPingIfPossible(for: contactID, reason: transmitPrepareReason)
        }
        if sent {
            Task { @MainActor [weak self] in
                _ = await self?.sendMediaRelayReceiverPrewarmRequestIfPossible(
                    for: contactID,
                    reason: transmitPrepareReason,
                    requestID: requestID
                )
            }
        } else {
            _ = await sendMediaRelayReceiverPrewarmRequestIfPossible(
                for: contactID,
                reason: transmitPrepareReason,
                requestID: requestID,
                recordOutboundRequestID: true
            )
        }
        return sent
    }

    @discardableResult
    func sendMediaRelayReceiverPrewarmRequestIfPossible(
        for contactID: UUID,
        reason: String,
        requestID: String? = nil,
        recordOutboundRequestID: Bool = false
    ) async -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return false
        }
        let requestID = requestID ?? mediaRuntime.receiverPrewarmRequestID(for: contactID)
        if recordOutboundRequestID {
            mediaRuntime.replaceReceiverPrewarmRequestID(
                for: contactID,
                requestID: requestID
            )
        }
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: requestID,
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            reason: reason,
            directQuicAttemptId: directQuicAttempt(for: contactID)?.attemptId
        )
        guard let relayClient = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID,
            missingConfigMessage: "Media relay prewarm skipped because relay config is missing",
            connectingMessage: "Connecting media relay for prewarm",
            selectedMessage: "Media relay prewarm path selected",
            failureMessage: "Media relay prewarm connection failed",
            cancelledMessage: "Media relay prewarm ended before relay selection",
            fromUserIDForIncoming: { contact.remoteUserId ?? "" }
        ) else {
            return false
        }
        guard mediaRuntime.reserveMediaRelayReceiverPrewarmRequestSend(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID,
            requestID: requestID
        ) else {
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm request coalesced",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "requestId": requestID,
                    "reason": reason,
                ]
            )
            return false
        }
        do {
            if let mediaRelayReceiverPrewarmSendOverride {
                try await mediaRelayReceiverPrewarmSendOverride(relayClient, payload)
            } else {
                try await relayClient.sendReceiverPrewarmRequest(payload)
            }
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "requestId": requestID,
                    "reason": reason,
                    "supportsOpusV2": String(payload.mediaCapabilities?.supportsOpusV2 == true),
                ]
            )
            return true
        } catch {
            mediaRuntime.clearMediaRelayReceiverPrewarmRequestSend(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                requestID: requestID
            )
            recordMediaRelayPeerUnavailableInvariantIfNeeded(
                error: error,
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                operation: "receiver-prewarm-request"
            )
            if isMediaRelayPeerUnavailable(error) {
                clearStaleMediaRelayClient(
                    localDeviceID: backend.deviceID,
                    channelID: channelID,
                    peerDeviceID: peerDeviceID,
                    client: relayClient,
                    reason: "receiver-prewarm-request"
                )
            }
            diagnostics.record(
                .media,
                level: .error,
                message: "Media relay receiver prewarm request failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "requestId": requestID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    @discardableResult
    func sendMediaRelayReceiverPrewarmAckIfPossible(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID
    ) async -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID, fallback: payload.fromDeviceId),
              let contact = contacts.first(where: { $0.id == contactID }) else {
            return false
        }
        guard let relayClient = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: payload.channelId,
            peerDeviceID: peerDeviceID,
            missingConfigMessage: "Media relay prewarm ack skipped because relay config is missing",
            connectingMessage: "Connecting media relay for prewarm ack",
            selectedMessage: "Media relay prewarm ack path selected",
            failureMessage: "Media relay prewarm ack connection failed",
            cancelledMessage: "Media relay prewarm ack ended before relay selection",
            fromUserIDForIncoming: { contact.remoteUserId ?? "" }
        ) else {
            return false
        }
        let ackPayload = directQuicReceiverPrewarmAckPayload(from: payload)
        guard mediaRuntime.reserveMediaRelayReceiverPrewarmAckSend(
            contactID: contactID,
            channelID: ackPayload.channelId,
            peerDeviceID: peerDeviceID,
            requestID: ackPayload.requestId
        ) else {
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm ack coalesced",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": ackPayload.channelId,
                    "peerDeviceId": peerDeviceID,
                    "requestId": ackPayload.requestId,
                ]
            )
            return false
        }
        do {
            try await relayClient.sendReceiverPrewarmAck(ackPayload)
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm ack sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": ackPayload.channelId,
                    "peerDeviceId": peerDeviceID,
                    "requestId": ackPayload.requestId,
                    "supportsOpusV2": String(ackPayload.mediaCapabilities?.supportsOpusV2 == true),
                ]
            )
            return true
        } catch {
            mediaRuntime.clearMediaRelayReceiverPrewarmAckSend(
                contactID: contactID,
                channelID: ackPayload.channelId,
                peerDeviceID: peerDeviceID,
                requestID: ackPayload.requestId
            )
            recordMediaRelayPeerUnavailableInvariantIfNeeded(
                error: error,
                contactID: contactID,
                channelID: ackPayload.channelId,
                peerDeviceID: peerDeviceID,
                operation: "receiver-prewarm-ack"
            )
            if isMediaRelayPeerUnavailable(error),
               let localDeviceID = backendServices?.deviceID ?? backendConfig?.deviceID,
               !localDeviceID.isEmpty {
                clearStaleMediaRelayClient(
                    localDeviceID: localDeviceID,
                    channelID: ackPayload.channelId,
                    peerDeviceID: peerDeviceID,
                    client: relayClient,
                    reason: "receiver-prewarm-ack"
                )
            }
            diagnostics.record(
                .media,
                level: .error,
                message: "Media relay receiver prewarm ack failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": ackPayload.channelId,
                    "peerDeviceId": peerDeviceID,
                    "requestId": ackPayload.requestId,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    func handleIncomingDirectQuicReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String,
        source: ControlEventSource = .directQuicDataChannel
    ) async {
        let isFirstDelivery = mediaRuntime.markReceiverPrewarmRequestHandled(payload.requestId)
        diagnostics.record(
            .media,
            message: isFirstDelivery
                ? "Direct QUIC receiver prewarm request received"
                : "Direct QUIC receiver prewarm request replayed",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "supportsOpusV2": String(payload.mediaCapabilities?.supportsOpusV2 == true),
            ]
        )
        observePeerVoiceMediaCapabilities(
            payload.mediaCapabilities,
            contactID: contactID,
            peerDeviceID: payload.fromDeviceId,
            source: "direct-quic-receiver-prewarm-request"
        )
        await promoteDirectQuicListenerPathFromReceiverPrewarmIfPossible(
            payload,
            contactID: contactID,
            attemptID: attemptID,
            source: source
        )

        if isFirstDelivery, payload.reason.hasPrefix("transmit-") {
            await handleIncomingDirectQuicTransmitPrepare(
                payload,
                contactID: contactID,
                attemptID: attemptID
            )
        } else if isFirstDelivery {
            await prewarmLocalMediaIfNeeded(for: contactID)
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .directQuicReceiverPrewarm
            )
        }

        switch source {
        case .mediaRelay:
            _ = await sendMediaRelayReceiverPrewarmAckIfPossible(payload, contactID: contactID)
        default:
            guard let controller = mediaRuntime.directQuicProbeController else { return }
            let ackPayload = directQuicReceiverPrewarmAckPayload(from: payload)
            do {
                try await controller.sendReceiverPrewarmAck(ackPayload)
                diagnostics.record(
                    .media,
                    message: "Direct QUIC receiver prewarm ack sent",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": ackPayload.channelId,
                        "attemptId": attemptID,
                        "requestId": ackPayload.requestId,
                        "supportsOpusV2": String(ackPayload.mediaCapabilities?.supportsOpusV2 == true),
                    ]
                )
            } catch {
                diagnostics.record(
                    .media,
                    level: directQuicPrewarmFailureDiagnosticsLevel(),
                    message: "Direct QUIC receiver prewarm ack failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": ackPayload.channelId,
                        "attemptId": attemptID,
                        "requestId": ackPayload.requestId,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func promoteDirectQuicListenerPathFromReceiverPrewarmIfPossible(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String,
        source: ControlEventSource
    ) async {
        guard payload.directQuicAttemptId == attemptID else {
            if let directQuicAttemptId = payload.directQuicAttemptId {
                diagnostics.record(
                    .media,
                    message: "Ignored remote receiver prewarm for stale Direct QUIC attempt",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": payload.channelId,
                        "expectedAttemptId": attemptID,
                        "receivedAttemptId": directQuicAttemptId,
                        "requestId": payload.requestId,
                        "source": source.rawValue,
                    ]
                )
            }
            return
        }
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID),
              !attempt.isDirectActive,
              let controller = mediaRuntime.directQuicProbeController else {
            return
        }
        guard controller.nominatedPath(matching: attemptID) != nil else {
            diagnostics.record(
                .media,
                message: "Deferred Direct QUIC listener promotion from remote receiver prewarm because no nominated path is available yet",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "attemptId": attemptID,
                    "requestId": payload.requestId,
                    "source": source.rawValue,
                ]
            )
            return
        }
        guard let expectedPeerCertificateFingerprint =
                directQuicExpectedPeerCertificateFingerprint(for: attempt)
                ?? backendPeerDirectQuicFingerprint(for: contactID),
              !expectedPeerCertificateFingerprint.isEmpty else {
            diagnostics.record(
                .media,
                message: "Deferred Direct QUIC listener promotion from remote receiver prewarm because peer fingerprint is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "attemptId": attemptID,
                    "requestId": payload.requestId,
                    "source": source.rawValue,
                ]
            )
            return
        }

        do {
            guard try controller.verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) else {
                diagnostics.record(
                    .media,
                    message: "Deferred Direct QUIC listener promotion from remote receiver prewarm because peer certificate is not verified yet",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": payload.channelId,
                        "attemptId": attemptID,
                        "requestId": payload.requestId,
                        "source": source.rawValue,
                    ]
                )
                return
            }
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC remote receiver prewarm certificate verification failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "attemptId": attemptID,
                    "requestId": payload.requestId,
                    "source": source.rawValue,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "receiver-prewarm-certificate-mismatch",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Promoting Direct QUIC listener path from remote receiver prewarm",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "source": source.rawValue,
            ]
        )
        await activateDirectQuicMediaPath(for: contactID, attemptID: attemptID)
    }

    func directQuicPrewarmFailureDiagnosticsLevel(
        explicitDirectQuicTestMode: Bool = false
    ) -> DiagnosticsLevel {
        if explicitDirectQuicTestMode {
            return .error
        }
        switch mediaTransportPathState {
        case .relay, .fastRelay, .fastRelayTcp:
            return .notice
        case .promoting, .direct, .recovering:
            return .error
        }
    }

    func handleDirectQuicReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String,
        source: ControlEventSource = .directQuicDataChannel
    ) {
        mediaRuntime.markReceiverPrewarmAckReceived(
            contactID: contactID,
            requestID: payload.requestId
        )
        observePeerVoiceMediaCapabilities(
            payload.mediaCapabilities,
            contactID: contactID,
            peerDeviceID: payload.fromDeviceId,
            source: "direct-quic-receiver-prewarm-ack"
        )
        if let existing = channelReadinessByContactID[contactID] {
            applyChannelReadiness(
                existing.settingRemoteAudioReadiness(.ready),
                for: contactID,
                reason: "direct-quic-receiver-prewarm-ack"
            )
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC receiver prewarm ack received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "source": source.rawValue,
                "supportsOpusV2": String(payload.mediaCapabilities?.supportsOpusV2 == true),
            ]
        )
        if source != .mediaRelay,
           let attempt = directQuicAttempt(for: contactID, matching: attemptID),
           attempt.isDirectActive {
            recordDirectQuicLanePromotionProof(
                contactID: contactID,
                channelID: payload.channelId,
                peerDeviceID: payload.fromDeviceId,
                reason: "receiver-prewarm-ack",
                source: source.rawValue,
                attemptID: attemptID
            )
            applyDirectQuicUpgradeTransition(.directActivated(attempt), for: contactID)
            if let activeTarget = transmitProjection.activeTarget,
               activeTarget.contactID == contactID {
                configureOutgoingAudioRoute(target: activeTarget)
            }
        }
        updateStatusForSelectedContact()
    }

    func directQuicReceiverPrewarmAckPayload(
        from request: DirectQuicReceiverPrewarmPayload
    ) -> DirectQuicReceiverPrewarmPayload {
        DirectQuicReceiverPrewarmPayload(
            requestId: request.requestId,
            channelId: request.channelId,
            fromDeviceId: backendServices?.deviceID ?? backendConfig?.deviceID ?? request.fromDeviceId,
            reason: request.reason,
            directQuicAttemptId: request.directQuicAttemptId,
            mediaCapabilities: .local
        )
    }

    func handleIncomingDirectQuicPathClosing(
        _ payload: DirectQuicPathClosingPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        guard payload.attemptId == attemptID else {
            diagnostics.record(
                .media,
                message: "Ignored Direct QUIC path closing for stale attempt",
                metadata: [
                    "contactId": contactID.uuidString,
                    "expectedAttemptId": attemptID,
                    "receivedAttemptId": payload.attemptId,
                    "reason": payload.reason,
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC path closing received",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": payload.attemptId,
                "reason": payload.reason,
            ]
        )
        if isRemoteExplicitDisconnectReason(payload.reason) {
            await handleRemoteExplicitDirectQuicDisconnect(
                payload,
                contactID: contactID
            )
            return
        }
        if isRemoteReceiverBackgroundTransitionReason(payload.reason),
           let existing = channelReadinessByContactID[contactID] {
            var updated = existing.settingRemoteAudioReadiness(.wakeCapable)
            if case .unavailable = existing.remoteWakeCapability,
               let peerDeviceID = directQuicPeerDeviceID(for: contactID),
               !peerDeviceID.isEmpty {
                updated = updated.settingRemoteWakeCapability(
                    .wakeCapable(targetDeviceId: peerDeviceID)
                )
            }
            applyChannelReadiness(
                updated,
                for: contactID,
                reason: "direct-quic-path-closing"
            )
            diagnostics.record(
                .media,
                message: "Marked peer receiver wake-capable from Direct QUIC path closing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": payload.attemptId,
                    "reason": payload.reason,
                ]
            )
        }
        await retireDirectQuicPath(
            for: contactID,
            reason: payload.reason,
            sendHangup: false,
            configureActiveRoute: true
        )
    }

    func handleRemoteExplicitDirectQuicDisconnect(
        _ payload: DirectQuicPathClosingPayload,
        contactID: UUID
    ) async {
        conversationActionCoordinator.markExplicitLeave(contactID: contactID)
        backendRuntime.clearBackendJoinSettling(for: contactID)
        recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: contactID)
        recentOutgoingBeepEvidenceByContactID.removeValue(forKey: contactID)
        recentPeerDeviceEvidenceByContactID.removeValue(forKey: contactID)
        clearRemoteAudioActivity(for: contactID)
        diagnostics.record(
            .state,
            message: "Remote explicit Direct QUIC disconnect is ending selected conversation",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": payload.attemptId,
                "reason": payload.reason,
                "invariantID": "selected.remote_explicit_disconnect_must_teardown",
            ]
        )
        captureDiagnosticsState("direct-quic:remote-explicit-disconnect")
        await retireDirectQuicPath(
            for: contactID,
            reason: payload.reason,
            sendHangup: false,
            configureActiveRoute: true
        )

        guard selectedContactId == contactID else { return }
        performReconciledTeardown(for: contactID)
    }

    func isRemoteExplicitDisconnectReason(_ reason: String) -> Bool {
        reason == "explicit-disconnect"
    }

    func isRemoteReceiverBackgroundTransitionReason(_ reason: String) -> Bool {
        reason == "app-background-media-closed"
            || reason == "application-will-resign-active"
            || reason == "application-did-enter-background"
    }

    func sendDirectQuicWarmPingIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard shouldUseDirectQuicTransport(for: contactID),
              let attempt = directQuicAttempt(for: contactID),
              attempt.isDirectActive,
              let controller = mediaRuntime.directQuicProbeController else {
            return
        }

        let pingID = UUID().uuidString.lowercased()
        do {
            try await controller.sendWarmPing(id: pingID)
            diagnostics.record(
                .media,
                message: "Direct QUIC warm ping sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "pingId": pingID,
                    "reason": reason,
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                message: "Direct QUIC warm ping failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "pingId": pingID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func handleDirectQuicWarmPong(
        _ pingID: String?,
        contactID: UUID,
        attemptID: String
    ) {
        confirmDirectQuicNetworkMigrationIfNeeded(
            for: contactID,
            attemptID: attemptID,
            reason: "warm-pong"
        )
        mediaRuntime.markDirectQuicWarmPongReceived(
            contactID: contactID,
            pingID: pingID
        )
        if let attempt = directQuicAttempt(for: contactID, matching: attemptID),
           attempt.isDirectActive,
           let peerDeviceID = directQuicPeerDeviceID(
                for: contactID,
                fallback: attempt.peerDeviceID
           ) {
            recordDirectQuicLanePromotionProof(
                contactID: contactID,
                channelID: attempt.channelID,
                peerDeviceID: peerDeviceID,
                reason: "warm-pong",
                source: "direct-quic-data-channel",
                attemptID: attemptID
            )
            applyDirectQuicUpgradeTransition(.directActivated(attempt), for: contactID)
            if let activeTarget = transmitProjection.activeTarget,
               activeTarget.contactID == contactID {
                configureOutgoingAudioRoute(target: activeTarget)
            }
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC warm pong received",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "pingId": pingID ?? "",
            ]
        )
    }

    func handleIncomingDirectQuicAudioPayload(
        _ payload: String,
        contactID: UUID,
        attemptID: String
    ) async {
        await handleIncomingDirectQuicAudioPayload(
            DirectQuicIncomingAudioPayload(payload: payload),
            contactID: contactID,
            attemptID: attemptID
        )
    }

    nonisolated func handleIncomingDirectQuicPacketAudioPayload(
        _ incomingPayload: DirectQuicIncomingAudioPayload,
        contactID: UUID,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        expectedReceiveEpoch: UInt64? = nil
    ) async {
        guard !Task.isCancelled else { return }
        await handleIncomingLiveAudioPayload(
            incomingPayload.payload,
            channelID: channelID,
            fromUserID: fromUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: .directQuic,
            transportSequenceNumber: incomingPayload.sequenceNumber,
            expectedReceiveEpoch: expectedReceiveEpoch,
            ingressContext: IncomingAudioIngressContext(
                receivedAtNanoseconds: incomingPayload.datagramReceivedAtNanoseconds,
                sequenceNumber: incomingPayload.sequenceNumber,
                sentAtMilliseconds: incomingPayload.sentAtMilliseconds,
                source: "direct-quic"
            )
        )
    }

    func handleIncomingDirectQuicAudioPayload(
        _ incomingPayload: DirectQuicIncomingAudioPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        guard !Task.isCancelled else { return }
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        let preservesRemotePlaybackDrain =
            receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .drainingAudio
        if receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs.contains(contactID),
           !preservesRemotePlaybackDrain,
           !reopenRemoteReceiveForPostLocalStopDirectQuicAudioIfNeeded(
            incomingPayload,
            contactID: contactID,
            attempt: attempt
           ) {
            let sequenceNumber = incomingPayload.sequenceNumber.map(String.init) ?? "none"
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped Direct QUIC audio payload after remote transmit stop",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                    "directQuicSequenceNumber": sequenceNumber,
                    "reason": "remote-transmit-stopped",
                ]
            )
            recordIncomingAudioIngressSummaryIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                fromDeviceID: attempt.peerDeviceID ?? "direct-quic",
                incomingAudioTransport: .directQuic,
                sequenceNumber: incomingPayload.sequenceNumber,
                localQueueDelayNanoseconds: 0,
                senderSentAtMilliseconds: incomingPayload.sentAtMilliseconds,
                freshnessDecision: "dropped-after-remote-stop",
                playbackAccepted: false,
                source: "direct-quic"
            )
            return
        }
        let handlerStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let localQueueDelayNanoseconds =
            handlerStartedAtNanoseconds >= incomingPayload.datagramReceivedAtNanoseconds
            ? handlerStartedAtNanoseconds - incomingPayload.datagramReceivedAtNanoseconds
            : 0
        var timingMetadata = [
            "contactId": contactID.uuidString,
            "channelId": attempt.channelID,
            "attemptId": attemptID,
            "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
        ]
        if let sequenceNumber = incomingPayload.sequenceNumber {
            timingMetadata["directQuicSequenceNumber"] = String(sequenceNumber)
        }
        if let sentAtMilliseconds = incomingPayload.sentAtMilliseconds {
            timingMetadata["sentAtMs"] = String(sentAtMilliseconds)
            timingMetadata["senderClockAgeMs"] = String(
                Int64(Date().timeIntervalSince1970 * 1_000) - sentAtMilliseconds
            )
        }
        let liveBacklogDropThresholdNanoseconds = min(
            directQuicIncomingAudioLiveBacklogDropNanoseconds,
            incomingLiveAudioBacklogExpirationNanoseconds
        )
        let activeReceiveDropThresholdNanoseconds =
            receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .receivingAudio
            ? directQuicIncomingAudioQueueSevereDelayNanoseconds
            : 0
        let directQuicDropThresholdNanoseconds: UInt64 = ([
            liveBacklogDropThresholdNanoseconds,
            activeReceiveDropThresholdNanoseconds,
        ]
        .filter { $0 > 0 }
        .min()) ?? 0
        if directQuicDropThresholdNanoseconds > 0,
           localQueueDelayNanoseconds >= directQuicDropThresholdNanoseconds {
            recordDirectQuicIncomingAudioQueueDelayIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                attemptID: attemptID,
                timingMetadata: timingMetadata,
                thresholdNanoseconds: directQuicDropThresholdNanoseconds,
                action: "dropped-expired-live-backlog"
            )
            recordIncomingAudioIngressSummaryIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                fromDeviceID: attempt.peerDeviceID ?? "direct-quic",
                incomingAudioTransport: .directQuic,
                sequenceNumber: incomingPayload.sequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: incomingPayload.sentAtMilliseconds,
                freshnessDecision: "dropped-expired-live-backlog",
                playbackAccepted: false,
                source: "direct-quic"
            )
            return
        } else if localQueueDelayNanoseconds >= directQuicIncomingAudioQueueSevereDelayNanoseconds {
            recordDirectQuicIncomingAudioQueueDelayIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                attemptID: attemptID,
                timingMetadata: timingMetadata,
                thresholdNanoseconds: directQuicIncomingAudioQueueSevereDelayNanoseconds,
                action: "preserved-severe"
            )
        } else if localQueueDelayNanoseconds >= directQuicIncomingAudioQueueDelayViolationNanoseconds {
            recordDirectQuicIncomingAudioQueueDelayIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                attemptID: attemptID,
                timingMetadata: timingMetadata,
                thresholdNanoseconds: directQuicIncomingAudioQueueDelayViolationNanoseconds,
                action: "preserved"
            )
        } else if localQueueDelayNanoseconds >= directQuicIncomingAudioQueueSlowNanoseconds {
            recordDirectQuicIncomingAudioQueueDelayNoticeIfNeeded(
                contactID: contactID,
                channelID: attempt.channelID,
                attemptID: attemptID,
                timingMetadata: timingMetadata,
                thresholdNanoseconds: directQuicIncomingAudioQueueSlowNanoseconds
            )
        }
        confirmDirectQuicNetworkMigrationIfNeeded(
            for: contactID,
            attemptID: attemptID,
            reason: "incoming-audio"
        )
        let remoteUserID = contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
        let fromDeviceID = attempt.peerDeviceID ?? "direct-quic"
        if beginRemoteAudioReceiveEpochIfNeeded(
            contactID: contactID,
            channelID: attempt.channelID,
            senderDeviceID: fromDeviceID,
            source: .transmitStartSignal,
            controlTransport: "direct-quic-audio",
            resetLiveAudioRuntime: false,
            shouldResetIncomingPacketAudioPayloadQueues: false
        ) {
            markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
            await resetLiveAudioReceiveRuntimeNow(
                for: contactID,
                reason: "direct-quic-implicit-audio-epoch-start"
            )
        }
        let receiveEpoch = mediaRuntime.incomingAudioReceiveEpoch(for: contactID)

        recordIncomingDirectQuicAudioPayloadDiagnosticIfNeeded(
            contactID: contactID,
            channelID: attempt.channelID,
            attemptID: attemptID,
            fromDeviceID: fromDeviceID,
            timingMetadata: timingMetadata
        )
        recordWakeReceiveTiming(
            stage: "direct-quic-audio-received",
            contactID: contactID,
            channelID: attempt.channelID,
            metadata: [
                "attemptId": attemptID,
                "fromDeviceId": fromDeviceID,
            ],
            ifAbsent: true
        )
        await handleIncomingLiveAudioPayload(
            incomingPayload.payload,
            channelID: attempt.channelID,
            fromUserID: remoteUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: .directQuic,
            transportSequenceNumber: incomingPayload.sequenceNumber,
            expectedReceiveEpoch: receiveEpoch,
            ingressContext: IncomingAudioIngressContext(
                receivedAtNanoseconds: incomingPayload.datagramReceivedAtNanoseconds,
                sequenceNumber: incomingPayload.sequenceNumber,
                sentAtMilliseconds: incomingPayload.sentAtMilliseconds,
                source: "direct-quic"
            )
        )
    }

    @discardableResult
    func retireDirectQuicReceivePathAfterLiveAudioFreshnessFailureIfFallbackReady(
        contactID: UUID,
        attemptID: String? = nil,
        reason: String,
        sequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64? = nil,
        thresholdNanoseconds: UInt64? = nil
    ) -> Bool {
        let selectedTransport = selectedMediaTransportState(for: contactID)
        guard selectedTransport.fallbackReady,
              let attempt = directQuicAttempt(for: contactID, matching: attemptID),
              selectedTransport.directMediaPathActive
                || attempt.isDirectActive
                || selectedTransport.pathState == .direct
                || selectedTransport.pathState == .promoting else {
            return false
        }

        guard retireDirectQuicPathImmediately(
            for: contactID,
            reason: reason,
            sendHangup: false,
            configureActiveRoute: true
        ) else {
            return false
        }

        startMediaRelayFallbackAfterDirectQuicPathLost(
            contactID: contactID,
            channelID: attempt.channelID,
            peerDeviceID: attempt.peerDeviceID,
            reason: reason
        )

        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": attempt.channelID,
            "attemptId": attempt.attemptId,
            "reason": reason,
            "directQuicSequenceNumber": sequenceNumber.map(String.init) ?? "none",
            "fallback": selectedTransport.fallbackDiagnosticsValue,
            "selectedTransport": selectedTransport.diagnosticsValue,
        ]
        if let localQueueDelayNanoseconds {
            metadata["localQueueDelayMs"] = String(localQueueDelayNanoseconds / 1_000_000)
        }
        if let thresholdNanoseconds {
            metadata["thresholdMs"] = String(thresholdNanoseconds / 1_000_000)
        }
        diagnostics.record(
            .media,
            level: .notice,
            message: "Retired Direct QUIC receive path after stale live audio; preserving fallback receive epoch",
            metadata: metadata
        )
        return true
    }

    nonisolated func handleExpiredDirectQuicIncomingAudioPayloadBeforeAppHandler(
        _ incoming: DirectQuicIncomingAudioPayload,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        localQueueDelayNanoseconds: UInt64,
        thresholdNanoseconds: UInt64
    ) async {
        let report = await voiceTurnRuntime.recordExpiredBeforeAppHandler(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: peerDeviceID,
            transport: "direct-quic",
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            staleReceiveRepairThresholdNanoseconds: thresholdNanoseconds
        )
        let shouldRecordReport: Bool
        switch report.disposition {
        case .detailed, .suppressionNotice:
            shouldRecordReport = true
        case .suppressed:
            shouldRecordReport = report.shouldRepairStaleReceive
        }
        guard shouldRecordReport else {
            return
        }

        await MainActor.run {
            var metadata = [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": peerDeviceID,
                "directQuicSequenceNumber": incoming.sequenceNumber.map(String.init) ?? "none",
                "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                "maxLocalQueueDelayMs": String(report.maxLocalQueueDelayNanoseconds / 1_000_000),
                "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                "expiredCount": String(report.expiredCount),
            ]
            switch report.disposition {
            case .detailed:
                diagnostics.record(
                    .media,
                    message: "Dropped expired Direct QUIC incoming audio payload before app handler",
                    metadata: metadata
                )
            case .suppressionNotice:
                metadata["reason"] = "budget-exhausted"
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Suppressing repetitive expired Direct QUIC incoming audio payload diagnostics",
                    metadata: metadata
                )
            case .suppressed:
                break
            }

            guard report.shouldRepairStaleReceive else { return }
            let repaired = repairExpiredRemoteTransmitLeaseIfNeeded(contactID: contactID)
            if !repaired,
               receiveExecutionCoordinator.state.remoteActivityByContactID[contactID] != nil,
               localQueueDelayNanoseconds >= thresholdNanoseconds {
                forceStopRemoteReceiveAfterExpiredLiveAudio(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: peerDeviceID,
                    incomingAudioTransport: .directQuic,
                    reason: "expired-before-app-handler",
                    diagnosticsMessage: "Forced remote receive stop after expired Direct QUIC app-handler backlog",
                    additionalMetadata: [
                        "directQuicSequenceNumber": incoming.sequenceNumber.map(String.init) ?? "none",
                        "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                        "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                    ]
                )
            }
        }
    }

    @discardableResult
    func reopenRemoteReceiveForPostLocalStopDirectQuicAudioIfNeeded(
        _ incomingPayload: DirectQuicIncomingAudioPayload,
        contactID: UUID,
        attempt: DirectQuicUpgradeAttempt
    ) -> Bool {
        guard localTransmitStopProjectionGraceIsActive(for: contactID),
              !hasActiveTransmitPressIntent(),
              let localStopStartedAtNanoseconds =
                localTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID],
              incomingPayload.datagramReceivedAtNanoseconds >= localStopStartedAtNanoseconds
        else {
            return false
        }
        if let sentAtMilliseconds = incomingPayload.sentAtMilliseconds,
           let localStopStartedAtMilliseconds =
                localTransmitStopProjectionGraceStartedAtMillisecondsByContactID[contactID],
           sentAtMilliseconds + 250 < localStopStartedAtMilliseconds {
            return false
        }

        let senderDeviceID = attempt.peerDeviceID ?? "direct-quic"
        beginRemoteAudioReceiveEpochIfNeeded(
            contactID: contactID,
            channelID: attempt.channelID,
            senderDeviceID: senderDeviceID,
            source: .transmitStartSignal,
            controlTransport: "direct-quic-audio"
        )
        markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        clearLocalTransmitStopProjectionGrace(for: contactID)
        diagnostics.record(
            .media,
            message: "Reopened remote receive from fresh Direct QUIC audio after local stop",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "senderDeviceId": senderDeviceID,
                "directQuicSequenceNumber": incomingPayload.sequenceNumber.map(String.init) ?? "none",
                "controlTransport": "direct-quic-audio",
            ]
        )
        return true
    }

    private func recordIncomingDirectQuicAudioPayloadDiagnosticIfNeeded(
        contactID: UUID,
        channelID: String,
        attemptID: String,
        fromDeviceID: String,
        timingMetadata: [String: String]
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let detailedReportLimit = incomingAudioDiagnosticDetailedReportLimit()
        switch mediaRuntime.consumeDirectQuicIncomingAudioDiagnosticDisposition(
            for: contactID,
            detailedReportLimit: detailedReportLimit
        ) {
        case .detailed:
            diagnostics.record(
                .media,
                message: "Direct QUIC audio payload received",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "fromDeviceId": fromDeviceID,
                    "localQueueDelayMs": timingMetadata["localQueueDelayMs"] ?? "0",
                    "directQuicSequenceNumber": timingMetadata["directQuicSequenceNumber"] ?? "none",
                    "senderClockAgeMs": timingMetadata["senderClockAgeMs"] ?? "none",
                    "verbose": String(TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()),
                ]
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                message: "Suppressing repetitive Direct QUIC audio payload diagnostics",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "reason": "budget-exhausted",
                    "detailedReportLimit": String(detailedReportLimit),
                ]
            )

        case .suppressed:
            break
        }
    }

    private func recordDirectQuicIncomingAudioQueueDelayIfNeeded(
        contactID: UUID,
        channelID: String,
        attemptID: String,
        timingMetadata: [String: String],
        thresholdNanoseconds: UInt64,
        action: String
    ) {
        let detailedReportLimit = incomingAudioDiagnosticDetailedReportLimit()
        switch mediaRuntime.consumeDirectQuicIncomingAudioQueueDelayDiagnosticDisposition(
            for: contactID,
            attemptID: attemptID,
            action: action,
            detailedReportLimit: detailedReportLimit
        ) {
        case .detailed:
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.incomingAudioQueueDelay(
                    contactID: contactID,
                    channelID: channelID,
                    attemptID: attemptID,
                    incomingTransport: IncomingAudioPayloadTransport.directQuic.diagnosticsValue,
                    sequenceNumber: timingMetadata["directQuicSequenceNumber"] ?? "none",
                    localQueueDelayMilliseconds: UInt64(timingMetadata["localQueueDelayMs"] ?? "0") ?? 0,
                    senderClockAgeMilliseconds: timingMetadata["senderClockAgeMs"] ?? "none",
                    thresholdMilliseconds: thresholdNanoseconds / 1_000_000,
                    action: action
                ),
                metadata: timingMetadata
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                level: .notice,
                message: "Suppressing repetitive Direct QUIC audio queue delay diagnostics",
                metadata: timingMetadata.merging(
                    [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "attemptId": attemptID,
                        "action": action,
                        "reason": "budget-exhausted",
                        "detailedReportLimit": String(detailedReportLimit),
                        "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )

        case .suppressed:
            break
        }
    }

    private func recordDirectQuicIncomingAudioQueueDelayNoticeIfNeeded(
        contactID: UUID,
        channelID: String,
        attemptID: String,
        timingMetadata: [String: String],
        thresholdNanoseconds: UInt64
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let detailedReportLimit = incomingAudioDiagnosticDetailedReportLimit()
        switch mediaRuntime.consumeDirectQuicIncomingAudioQueueDelayDiagnosticDisposition(
            for: contactID,
            attemptID: attemptID,
            action: "handler-started-late",
            detailedReportLimit: detailedReportLimit
        ) {
        case .detailed:
            diagnostics.record(
                .media,
                level: .notice,
                message: "Direct QUIC audio handler started late after local receive queue delay",
                metadata: timingMetadata.merging(
                    [
                        "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                level: .notice,
                message: "Suppressing repetitive Direct QUIC audio queue delay diagnostics",
                metadata: timingMetadata.merging(
                    [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "attemptId": attemptID,
                        "action": "handler-started-late",
                        "reason": "budget-exhausted",
                        "detailedReportLimit": String(detailedReportLimit),
                        "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )

        case .suppressed:
            break
        }
    }

    func handleDirectQuicMediaPathLost(
        for contactID: UUID,
        attemptID: String,
        reason: String
    ) async {
        guard let lostAttempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            diagnostics.record(
                .media,
                message: "Ignored stale Direct QUIC media path loss",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "reason": reason,
                    "networkPathGeneration": "\(mediaRuntime.networkPathGeneration)",
                    "transportPathState": mediaTransportPathState.rawValue,
                ]
            )
            return
        }
        _ = mediaRuntime.clearDirectQuicNetworkMigrationProbe(
            contactID: contactID,
            attemptID: attemptID
        )
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        diagnostics.record(
            .media,
            level: .notice,
            message: "Direct QUIC media path lost",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "reason": reason,
                "failureCategory": category.rawValue,
            ]
        )
        syncEngineDirectQuicLaneFailed(
            reason: reason,
            source: "direct-quic-path-lost"
        )
        mediaRuntime.directQuicUpgrade.applyRetryBackoff(
            for: contactID,
            request: directQuicPathLostRetryBackoffRequest(
                for: contactID,
                reason: reason,
                attemptID: attemptID
            )
        )

        if let recovering = mediaRuntime.directQuicUpgrade.markDirectPathLost(
            for: contactID,
            reason: reason
        ) {
            clearDirectAudioPlaybackVerification(contactID: contactID)
            mediaRuntime.clearReceiverPrewarmState(for: contactID)
            applyDirectQuicUpgradeTransition(recovering, for: contactID)
            applyDirectQuicUpgradeTransition(
                .fellBackToRelay(previousAttemptId: recovering.attemptId, reason: reason),
                for: contactID
            )
        }

        mediaRuntime.directQuicProbeController?.cancel(reason: "path-lost")
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        startMediaRelayFallbackAfterDirectQuicPathLost(
            contactID: contactID,
            channelID: lostAttempt.channelID,
            peerDeviceID: lostAttempt.peerDeviceID,
            reason: reason
        )
        scheduleAutomaticDirectQuicProbe(
            for: contactID,
            reason: "path-lost"
        )
    }

    func startMediaRelayFallbackAfterDirectQuicPathLost(
        contactID: UUID,
        channelID: String?,
        peerDeviceID: String?,
        reason: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            await self.ensureMediaRelayFallbackAfterDirectQuicPathLost(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                reason: reason
            )
        }
    }

    func ensureMediaRelayFallbackAfterDirectQuicPathLost(
        contactID: UUID,
        channelID: String?,
        peerDeviceID: String?,
        reason: String
    ) async {
        guard shouldSurfaceDirectTransportPath(for: contactID) else { return }
        guard !isDirectPathRelayOnlyForced else { return }
        guard TurboMediaRelayDebugOverride.isEnabled()
            || TurboMediaRelayDebugOverride.isForced() else {
            return
        }
        guard !mediaRuntime.hasActiveMediaRelayClient else {
            diagnostics.record(
                .media,
                message: "Fast relay fallback already active after Direct QUIC path loss",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }

        let resolvedChannelID = channelID
            ?? contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId
            ?? contactSummaryByContactID[contactID]?.channelId
        let resolvedPeerDeviceID = peerDeviceID
            ?? directQuicPeerDeviceID(for: contactID)

        guard let resolvedChannelID,
              !resolvedChannelID.isEmpty,
              let resolvedPeerDeviceID,
              !resolvedPeerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Fast relay fallback skipped after Direct QUIC path loss because routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "hasChannelId": String(resolvedChannelID?.isEmpty == false),
                    "hasPeerDeviceId": String(resolvedPeerDeviceID?.isEmpty == false),
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Starting fast relay fallback after Direct QUIC path loss",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": resolvedChannelID,
                "peerDeviceId": resolvedPeerDeviceID,
                "reason": reason,
            ]
        )
        await connectMediaRelayForReceiveIfNeeded(
            contactID: contactID,
            channelID: resolvedChannelID,
            peerDeviceID: resolvedPeerDeviceID
        )
    }

    func sendDirectQuicHangup(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        reason: String
    ) async {
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let remoteUserID = contact.remoteUserId else {
            return
        }
        let peerDeviceID = attempt.peerDeviceID
            ?? directQuicPeerDeviceID(for: contactID)
            ?? attempt.remoteOffer?.fromDeviceId
        guard let peerDeviceID, !peerDeviceID.isEmpty else {
            diagnostics.record(
                .websocket,
                message: "Skipped direct QUIC hangup because peer device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "reason": reason,
                ]
            )
            return
        }

        do {
            let envelope = try TurboSignalEnvelope.directQuicHangup(
                channelId: attempt.channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: TurboDirectQuicHangupPayload(
                    attemptId: attempt.attemptId,
                    reason: reason
                )
            )
            _ = try await backend.sendDirectQuicSignal(envelope)
            diagnostics.record(
                .backend,
                message: "Direct QUIC hangup sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
        } catch is CancellationError {
            diagnostics.record(
                .backend,
                message: "Direct QUIC hangup send cancelled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Direct QUIC hangup send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func shouldSendDirectQuicSetupSignal(
        contactID: UUID,
        channelID: String,
        attemptID: String,
        signalKind: String
    ) -> Bool {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID),
              attempt.channelID == channelID else {
            diagnostics.record(
                .backend,
                message: "Skipped stale Direct QUIC setup signal",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "signalKind": signalKind,
                    "reason": "stale-attempt",
                ]
            )
            return false
        }
        guard !isExplicitTransmitStopInProgress(for: contactID) else {
            diagnostics.record(
                .backend,
                message: "Skipped Direct QUIC setup signal during explicit transmit stop",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "signalKind": signalKind,
                    "reason": "explicit-stop",
                ]
            )
            return false
        }
        return true
    }

    func isExplicitTransmitStopInProgress(for contactID: UUID) -> Bool {
        guard transmitRuntime.explicitStopRequested else { return false }
        return transmitRuntime.activeTarget?.contactID == contactID
            || transmitCoordinator.state.activeTarget?.contactID == contactID
    }

    func sendDirectQuicCandidateSignals(
        channelID: String,
        contactID: UUID,
        remoteUserID: String,
        remoteDeviceID: String,
        attemptID: String,
        candidates: [TurboDirectQuicCandidate],
        endOfCandidates: Bool
    ) async {
        guard let backend = backendServices else { return }
        guard shouldSendDirectQuicSetupSignal(
            contactID: contactID,
            channelID: channelID,
            attemptID: attemptID,
            signalKind: endOfCandidates ? "candidate-end" : "candidate"
        ) else { return }

        do {
            for candidate in candidates {
                guard shouldSendDirectQuicSetupSignal(
                    contactID: contactID,
                    channelID: channelID,
                    attemptID: attemptID,
                    signalKind: "candidate"
                ) else { return }
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: candidate
                    )
                )
                _ = try await backend.sendDirectQuicSignal(envelope)
            }
            if endOfCandidates {
                guard shouldSendDirectQuicSetupSignal(
                    contactID: contactID,
                    channelID: channelID,
                    attemptID: attemptID,
                    signalKind: "candidate-end"
                ) else { return }
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: nil,
                        endOfCandidates: true
                    )
                )
                _ = try await backend.sendDirectQuicSignal(envelope)
            }
            diagnostics.record(
                .backend,
                message: "Direct QUIC candidates sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC candidate send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func continueDirectQuicPromotionIfNeeded(
        for contactID: UUID,
        attemptID: String,
        expectedPeerCertificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate],
        trigger: String
    ) async {
        guard !candidates.isEmpty else { return }
        guard directQuicAttempt(for: contactID, matching: attemptID)?.isDirectActive != true else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }

        do {
            let outcome = try await controller.probeRemoteCandidatesIfNeeded(
                attemptId: attemptID,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidates
            )
            guard outcome.didEstablishPath else {
                let metadata: [String: String] = [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                    "lastError": outcome.lastErrorDescription ?? "none",
                ]
                let message: String
                switch outcome.disposition {
                case .alreadyConnected, .pathEstablished:
                    message = "Direct QUIC remote candidate probe established path"
                case .noViableCandidates:
                    message = "Direct QUIC promotion ignored remote candidates without viable UDP addresses"
                case .noNewCandidates:
                    message = "Direct QUIC promotion is waiting because remote candidates were already attempted"
                case .probeAlreadyInFlight:
                    message = "Direct QUIC promotion probe is already in flight"
                case .batchExhausted:
                    message = "Direct QUIC remote candidate probe batch exhausted without nomination"
                }
                diagnostics.record(
                    .media,
                    level: .info,
                    message: message,
                    metadata: metadata
                )
                return
            }

            diagnostics.record(
                .media,
                message: "Direct QUIC remote candidate probe established path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                ]
            )
            await activateDirectQuicMediaPath(
                for: contactID,
                attemptID: attemptID
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC remote candidate probe failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func maybeStartDirectQuicProbe(
        for contactID: UUID,
        allowDebugBypassWithoutBackendAdvertisement: Bool = false
    ) async {
        let isUpgradeAllowed =
            !isDirectPathRelayOnlyForced
            && !TurboMediaRelayDebugOverride.isForced()
            && (
                backendAdvertisesDirectQuicUpgrade
                    || allowDebugBypassWithoutBackendAdvertisement
            )
        guard isUpgradeAllowed else { return }
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        guard let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId else {
            return
        }
        if allowDebugBypassWithoutBackendAdvertisement,
           !backendAdvertisesDirectQuicUpgrade {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug probe bypassed backend capability gate",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "handle": contact.handle,
                ]
            )
        }
        guard mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil else { return }
        guard !isExplicitTransmitStopInProgress(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe during explicit transmit stop",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": "explicit-stop",
                ]
            )
            return
        }
        if let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID),
           let retryRemaining = mediaRuntime.directQuicUpgrade.retryBackoffRemaining(for: contactID) {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe during retry backoff",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "retryRemainingMs": "\(Int(retryRemaining * 1_000))",
                    "retryReason": retryBackoff.reason,
                    "retryCategory": retryBackoff.category.rawValue,
                    "retryAttemptId": retryBackoff.attemptId ?? "",
                    "retryBackoffMs": "\(retryBackoff.milliseconds)",
                ]
            )
            return
        }

        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe because peer target device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                ]
            )
            return
        }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        )
        guard role == .listenerOfferer else { return }

        if !allowDebugBypassWithoutBackendAdvertisement {
            let localIdentityStatus = DirectQuicIdentityConfiguration.status()
            let identityIsRegistered =
                localIdentityStatus.source == .production
                    && localIdentityStatus.fingerprint != nil
                    && (
                        localIdentityStatus.fingerprint == directQuicRegisteredFingerprint
                            || directQuicRegisteredFingerprint == nil
                    )
            if !identityIsRegistered {
                let repaired = await repairDirectQuicProductionIdentityRegistrationIfPossible(
                    contactID: contactID,
                    channelID: channelID,
                    reason: "direct-quic-probe"
                )
                guard repaired else {
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Skipped direct QUIC probe because production identity is not registered",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "identitySource": localIdentityStatus.source.rawValue,
                            "identityStatus": localIdentityStatus.diagnosticsText,
                            "provisioningStatus": directQuicProvisioningStatus,
                            "fingerprint": localIdentityStatus.fingerprint ?? "none",
                            "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
                        ]
                    )
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Continuing Direct QUIC probe after repairing production identity registration",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
                    ]
                )
            }
            guard backendPeerDirectQuicFingerprint(for: contactID) != nil else {
                diagnostics.record(
                    .media,
                    message: "Skipped direct QUIC probe because backend peer identity is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
                return
            }
        }

        let attemptID = UUID().uuidString.lowercased()
        let transition = mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptID: attemptID,
            peerDeviceID: peerDeviceID,
            networkPathGeneration: mediaRuntime.networkPathGeneration
        )
        applyDirectQuicUpgradeTransition(transition, for: contactID)

        do {
            let preparedOffer = try await directQuicProbeController().prepareListenerOffer(
                attemptId: attemptID,
                stunServers: directQuicStunServers()
            )
            let offerPayload = TurboDirectQuicOfferPayload(
                attemptId: attemptID,
                channelId: channelID,
                fromDeviceId: backend.deviceID,
                toDeviceId: peerDeviceID,
                quicAlpn: preparedOffer.quicAlpn,
                certificateFingerprint: preparedOffer.certificateFingerprint,
                candidates: preparedOffer.candidates,
                roleIntent: .listener,
                debugBypass: allowDebugBypassWithoutBackendAdvertisement
                    && !backendAdvertisesDirectQuicUpgrade
            )
            mediaRuntime.directQuicUpgrade.markLocalOffer(offerPayload, for: contactID)
            let envelope = try TurboSignalEnvelope.directQuicOffer(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: offerPayload
            )
            guard shouldSendDirectQuicSetupSignal(
                contactID: contactID,
                channelID: channelID,
                attemptID: attemptID,
                signalKind: "offer"
            ) else { return }
            _ = try await backend.sendDirectQuicSignal(envelope)
            diagnostics.record(
                .backend,
                message: "Direct QUIC offer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(preparedOffer.candidates.count)",
                    "peerDeviceId": peerDeviceID,
                ]
            )
            scheduleDirectQuicSetupLivenessResends(
                contactID: contactID,
                attemptID: attemptID,
                peerDeviceID: peerDeviceID
            )
            scheduleDirectQuicPromotionTimeout(contactID: contactID, attemptID: attemptID)
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC offer preparation failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "offer-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        switch signal {
        case .offer(let payload):
            await respondToDirectQuicOffer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .answer(let payload):
            await handleDirectQuicAnswer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .candidate(let payload):
            guard let attempt = directQuicAttempt(for: contactID, matching: payload.attemptId) else {
                return
            }
            if payload.endOfCandidates {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC remote candidate trickle completed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": attempt.channelID,
                        "attemptId": payload.attemptId,
                        "remoteCandidateCount": "\(attempt.remoteCandidateCount)",
                    ]
                )
            }
            guard let expectedPeerCertificateFingerprint = directQuicExpectedPeerCertificateFingerprint(
                for: attempt
            ) else {
                return
            }
            let candidatesToProbe = directQuicCandidateBatchToProbe(
                for: attempt,
                payload: payload
            )
            if !attempt.isDirectActive {
                scheduleDirectQuicPromotionTimeout(
                    contactID: contactID,
                    attemptID: payload.attemptId
                )
            }
            await continueDirectQuicPromotionIfNeeded(
                for: contactID,
                attemptID: payload.attemptId,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidatesToProbe,
                trigger: payload.endOfCandidates ? "end-of-candidates" : "trickle-candidate"
            )
        case .hangup(let payload):
            let isRecoveringActivePath =
                mediaRuntime.transportPathState == .direct
                || mediaRuntime.transportPathState == .recovering
            if isOrderlyDirectQuicClosureReason(payload.reason) {
                cancelDirectQuicPromotionTimeout()
                clearDirectQuicFreshSessionGuards(
                    for: contactID,
                    reason: payload.reason
                )
                mediaRuntime.directQuicProbeController?.cancel(reason: payload.reason)
                mediaRuntime.directQuicProbeController = nil
                if isRecoveringActivePath {
                    mediaRuntime.clearReceiverPrewarmState(for: contactID)
                    applyDirectQuicUpgradeTransition(
                        .fellBackToRelay(
                            previousAttemptId: payload.attemptId,
                            reason: payload.reason
                        ),
                        for: contactID
                    )
                    if let activeTarget = transmitProjection.activeTarget,
                       activeTarget.contactID == contactID {
                        configureOutgoingAudioRoute(target: activeTarget)
                    }
                }
                return
            }
            if directQuicAttempt(for: contactID)?.isDirectActive == true {
                await handleDirectQuicMediaPathLost(
                    for: contactID,
                    attemptID: payload.attemptId,
                    reason: payload.reason
                )
                return
            }
            cancelDirectQuicPromotionTimeout()
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicPromotionRetryBackoffRequest(
                    for: contactID,
                    reason: payload.reason,
                    attemptID: payload.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(reason: payload.reason)
            mediaRuntime.directQuicProbeController = nil
            if isRecoveringActivePath {
                mediaRuntime.clearReceiverPrewarmState(for: contactID)
                applyDirectQuicUpgradeTransition(
                    .fellBackToRelay(
                        previousAttemptId: payload.attemptId,
                        reason: payload.reason
                    ),
                    for: contactID
                )
                if let activeTarget = transmitProjection.activeTarget,
                   activeTarget.contactID == contactID {
                    configureOutgoingAudioRoute(target: activeTarget)
                }
            }
        }
    }

    func handleIncomingDirectQuicUpgradeRequest(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        do {
            let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
            guard let backend = backendServices else { return }

            var metadata: [String: String] = [
                "contactId": contactID.uuidString,
                "channelId": envelope.channelId,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "fromDeviceId": envelope.fromDeviceId,
                "toDeviceId": envelope.toDeviceId,
                "debugBypass": String(payload.debugBypass == true),
            ]

            if TurboJoinAcceptedControlSignal.matches(payload) {
                handleIncomingJoinAcceptedControlSignal(
                    envelope,
                    payload: payload,
                    contactID: contactID,
                    metadata: metadata
                )
                return
            }

            guard envelope.toDeviceId == backend.deviceID,
                  payload.toDeviceId == backend.deviceID,
                  payload.fromDeviceId == envelope.fromDeviceId,
                  payload.channelId == envelope.channelId else {
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected Direct QUIC upgrade request because envelope and payload disagree",
                    metadata: metadata
                )
                return
            }

            if let contact = contacts.first(where: { $0.id == contactID }),
               let remoteUserID = contact.remoteUserId,
               remoteUserID != envelope.fromUserId {
                metadata["expectedRemoteUserId"] = remoteUserID
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected Direct QUIC upgrade request from unexpected peer user",
                    metadata: metadata
                )
                return
            }
            recordRecentPeerDeviceEvidence(
                contactID: contactID,
                channelID: envelope.channelId,
                peerDeviceID: envelope.fromDeviceId,
                reason: "direct-quic-upgrade-request:\(payload.reason)",
                diagnosticSubsystem: .websocket
            )

            let peerDeviceID = directQuicPeerDeviceID(for: contactID, fallback: envelope.fromDeviceId)
            guard peerDeviceID == envelope.fromDeviceId else {
                metadata["expectedPeerDeviceId"] = peerDeviceID ?? "none"
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected Direct QUIC upgrade request from unexpected peer device",
                    metadata: metadata
                )
                return
            }

            let role = directQuicAttemptRole(
                localDeviceID: backend.deviceID,
                peerDeviceID: envelope.fromDeviceId
            )
            metadata["localRole"] = role.rawValue
            guard role == .listenerOfferer else {
                diagnostics.record(
                    .websocket,
                    message: "Ignored Direct QUIC upgrade request because local role is not listener-offerer",
                    metadata: metadata
                )
                return
            }

            let allowsSelectionPrewarmRequest = payload.reason.hasPrefix("selection-direct-quic-prewarm-")
            var blockReason: String?
            if allowsSelectionPrewarmRequest {
                blockReason = selectedContactDirectQuicPrewarmEnabled
                    ? directQuicSelectionPrewarmBlockReason(
                        for: contactID,
                        requireSelectedContact: false
                    )
                    : "selected-prewarm-disabled"
            } else {
                blockReason = automaticDirectQuicProbeBlockReason(for: contactID)
            }
            if allowsSelectionPrewarmRequest, blockReason == "retry-backoff",
               clearDirectQuicConnectivityBackoffForSelectedPrewarmRequestIfNeeded(
                for: contactID,
                requestID: payload.requestId,
                reason: payload.reason,
                peerDeviceID: envelope.fromDeviceId
               ) {
                metadata["clearedRetryBackoff"] = "true"
                blockReason = directQuicSelectionPrewarmBlockReason(
                    for: contactID,
                    requireSelectedContact: false
                )
            }
            if allowsSelectionPrewarmRequest, blockReason == "attempt-active" {
                metadata["blockReason"] = blockReason
                diagnostics.record(
                    .websocket,
                    message: "Resending active Direct QUIC offer after selected prewarm request",
                    metadata: metadata
                )
                Task {
                    await resendActiveDirectQuicOfferIfPossible(
                        for: contactID,
                        requestedBy: envelope.fromDeviceId,
                        requestId: payload.requestId,
                        reason: payload.reason
                    )
                }
                return
            }

            if let blockReason {
                metadata["blockReason"] = blockReason
                let message = allowsSelectionPrewarmRequest
                    ? "Ignored Direct QUIC upgrade request because selection prewarm is blocked"
                    : "Ignored Direct QUIC upgrade request because automatic probe is blocked"
                diagnostics.record(
                    .websocket,
                    message: message,
                    metadata: metadata
                )
                return
            }

            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request accepted",
                metadata: metadata
            )
            Task {
                await maybeStartDirectQuicProbe(
                    for: contactID,
                    allowDebugBypassWithoutBackendAdvertisement: payload.debugBypass == true
                        && shouldAllowDirectQuicDebugBypassForAutomaticProbe()
                )
            }
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Failed to decode Direct QUIC upgrade request",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func resendActiveDirectQuicOfferIfPossible(
        for contactID: UUID,
        requestedBy peerDeviceID: String,
        requestId: String,
        reason: String
    ) async {
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let remoteUserID = contact.remoteUserId else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC active offer resend skipped because contact routing is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "requestId": requestId,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                ]
            )
            return
        }
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              let offerPayload = attempt.localOffer,
              attempt.peerDeviceID == peerDeviceID,
              offerPayload.toDeviceId == peerDeviceID else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC active offer resend skipped because no matching active offer is available",
                metadata: [
                    "contactId": contactID.uuidString,
                    "requestId": requestId,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "activeAttemptId": mediaRuntime.directQuicUpgrade.attempt(for: contactID)?.attemptId ?? "none",
                ]
            )
            return
        }
        if let warmabilityBlockReason = directQuicPeerDirectWarmabilityBlockReason(for: contactID) {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC active offer resend skipped because peer is not direct warmable",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestId,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "blockReason": warmabilityBlockReason,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "peer-not-direct-warmable-\(warmabilityBlockReason)",
                sendHangup: false,
                applyRetryBackoff: false
            )
            return
        }

        do {
            let offerEnvelope = try TurboSignalEnvelope.directQuicOffer(
                channelId: attempt.channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: offerPayload
            )
            guard shouldSendDirectQuicSetupSignal(
                contactID: contactID,
                channelID: attempt.channelID,
                attemptID: attempt.attemptId,
                signalKind: "offer-resend"
            ) else { return }
            _ = try await backend.sendDirectQuicSignal(offerEnvelope)
            diagnostics.record(
                .backend,
                message: "Direct QUIC active offer resent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestId,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "candidateCount": "\(offerPayload.candidates.count)",
                ]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Direct QUIC active offer resend failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestId,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func handleIncomingJoinAcceptedControlSignal(
        _ envelope: TurboSignalEnvelope,
        payload: TurboDirectQuicUpgradeRequestPayload,
        contactID: UUID,
        metadata: [String: String]
    ) {
        guard let backend = backendServices else { return }
        var metadata = metadata

        guard envelope.toDeviceId == backend.deviceID,
              payload.fromDeviceId == envelope.fromDeviceId,
              payload.channelId == envelope.channelId else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal because envelope and payload disagree",
                metadata: metadata
            )
            return
        }

        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal because contact is missing",
                metadata: metadata
            )
            return
        }

        if let remoteUserId = contact.remoteUserId,
           remoteUserId != envelope.fromUserId {
            metadata["expectedRemoteUserId"] = remoteUserId
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal from unexpected peer user",
                metadata: metadata
            )
            return
        }

        if let outgoingBeep = outgoingBeepByContactID[contactID],
           outgoingBeep.beepId != payload.requestId {
            metadata["currentBeepId"] = outgoingBeep.beepId
            diagnostics.record(
                .websocket,
                message: "Ignored stale join accepted control signal",
                metadata: metadata
            )
            return
        }

        let relationship = beepThreadProjection(for: contactID)
        let acceptedToken = recentOutgoingJoinAcceptedTokensByContactID[contactID]
        let acceptedViaRecentOutgoingToken = acceptedToken?.matches(payload) == true
        let recentOutgoingBeepEvidence = recentOutgoingBeepEvidenceByContactID[contactID]
        let acceptedViaRecentOutgoingBeepEvidence =
            recentOutgoingBeepEvidence?.matches(payload) == true
        guard relationship.hasOutgoingBeep
            || outgoingBeepByContactID[contactID] != nil
            || acceptedViaRecentOutgoingToken
            || acceptedViaRecentOutgoingBeepEvidence else {
            diagnostics.record(
                .websocket,
                message: "Ignored join accepted control signal without a local outgoing Beep",
                metadata: metadata
            )
            return
        }
        if acceptedViaRecentOutgoingToken {
            metadata["acceptedViaRecentOutgoingToken"] = "true"
            recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: contactID)
        }
        if acceptedViaRecentOutgoingBeepEvidence {
            metadata["acceptedViaRecentOutgoingBeepEvidence"] = "true"
            metadata["recentOutgoingBeepCount"] =
                String(recentOutgoingBeepEvidence?.requestCount ?? 0)
            recentOutgoingBeepEvidenceByContactID.removeValue(forKey: contactID)
        }

        guard !backendLeaveIsInFlight(for: contactID) else {
            metadata["pendingAction"] = String(describing: conversationActionCoordinator.pendingAction)
            metadata["activeBackendOperation"] = String(describing: backendCommandCoordinator.state.activeOperation)
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Ignored join accepted control signal while leave is active",
                metadata: metadata
            )
            return
        }

        if selectedContactId != contactID {
            if let activeConversationContactID,
               activeConversationContactID != contactID {
                metadata["activeConversationContactId"] = activeConversationContactID.uuidString
                diagnostics.record(
                    .websocket,
                    level: .notice,
                    message: "Ignored join accepted control signal while another Conversation is active",
                    metadata: metadata
                )
                return
            }

            metadata["previousSelectedContactId"] = selectedContactId?.uuidString ?? "none"
            diagnostics.record(
                .websocket,
                message: "Selected contact for accepted outgoing Beep control signal",
                metadata: metadata
            )
            selectContact(contact, reason: "join-accepted-control-signal")
        }

        diagnostics.record(
            .websocket,
            message: "Join accepted control signal received",
            metadata: metadata
        )

        promoteOptimisticOutgoingBeepToJoinTransition(contactID: contactID)
        backendRuntime.markBackendJoinSettling(for: contactID)
        let devicePTTEvidenceAlreadyActive =
            devicePTTEvidenceExists(for: contactID)
            || conversationActionCoordinator.pendingJoinContactID == contactID
        if !devicePTTEvidenceAlreadyActive {
            joinPTTChannel(for: contact)
        } else {
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-signal:join-accepted-dedup")
        }

        Task { @MainActor [weak self, contact] in
            guard let self else { return }
            await self.reassertBackendJoin(for: contact, intent: .joinAcceptedOutgoingBeep)
            await self.refreshContactSummaries()
            await self.refreshChannelState(for: contactID)
        }
    }

    func respondToDirectQuicOffer(
        _ offer: TurboDirectQuicOfferPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        guard let backend = backendServices else { return }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: envelope.fromDeviceId
        )
        guard role == .dialerAnswerer else {
            diagnostics.record(
                .websocket,
                message: "Ignored direct QUIC offer because local role is not dialer",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "localDeviceId": backend.deviceID,
                    "peerDeviceId": envelope.fromDeviceId,
                ]
            )
            return
        }

        let answerPayload: TurboDirectQuicAnswerPayload
        var shouldProbeRemoteCandidates = false
        do {
            let preparedAnswer = try await directQuicProbeController().prepareDialerAnswer(
                using: offer,
                stunServers: directQuicStunServers()
            )
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: true,
                certificateFingerprint: preparedAnswer.certificateFingerprint,
                candidates: preparedAnswer.candidates
            )
            shouldProbeRemoteCandidates = true
            diagnostics.record(
                .media,
                message: "Direct QUIC answer prepared; sending candidates before probing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "localCandidateCount": "\(preparedAnswer.candidates.count)",
                    "remoteCandidateCount": "\(offer.candidates.count)",
                ]
            )
        } catch {
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: false,
                rejectionReason: error.localizedDescription
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC probe connect failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            let relayFallback = mediaRuntime.directQuicUpgrade.clearAttempt(
                for: contactID,
                fallbackReason: "probe-connect-failed",
                retryBackoff: directQuicRetryBackoffRequest(
                    reason: "probe-connect-failed",
                    attemptID: offer.attemptId
                )
            )
            applyDirectQuicUpgradeTransition(relayFallback, for: contactID)
            mediaRuntime.directQuicProbeController?.cancel(reason: "connect-failed")
            mediaRuntime.directQuicProbeController = nil
        }

        do {
            let answerEnvelope = try TurboSignalEnvelope.directQuicAnswer(
                channelId: envelope.channelId,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: envelope.fromUserId,
                toDeviceId: envelope.fromDeviceId,
                payload: answerPayload
            )
            guard shouldSendDirectQuicSetupSignal(
                contactID: contactID,
                channelID: envelope.channelId,
                attemptID: offer.attemptId,
                signalKind: "answer"
            ) else { return }
            _ = try await backend.sendDirectQuicSignal(answerEnvelope)
            diagnostics.record(
                .backend,
                message: "Direct QUIC answer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "accepted": String(answerPayload.accepted),
                ]
            )
            if answerPayload.accepted {
                await sendDirectQuicCandidateSignals(
                    channelID: envelope.channelId,
                    contactID: contactID,
                    remoteUserID: envelope.fromUserId,
                    remoteDeviceID: envelope.fromDeviceId,
                    attemptID: offer.attemptId,
                    candidates: answerPayload.candidates,
                    endOfCandidates: true
                )
                scheduleDirectQuicPromotionTimeout(
                    contactID: contactID,
                    attemptID: offer.attemptId
                )
                if shouldProbeRemoteCandidates {
                    await continueDirectQuicPromotionIfNeeded(
                        for: contactID,
                        attemptID: offer.attemptId,
                        expectedPeerCertificateFingerprint: offer.certificateFingerprint,
                        candidates: offer.candidates,
                        trigger: "received-offer"
                    )
                }
            } else {
                mediaRuntime.directQuicProbeController?.cancel(reason: "answer-sent")
                mediaRuntime.directQuicProbeController = nil
            }
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC answer send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "answer-send-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicAnswer(
        _ answer: TurboDirectQuicAnswerPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        if !answer.accepted {
            cancelDirectQuicPromotionTimeout()
            let rejectionReason = answer.rejectionReason ?? "answer-rejected"
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicRetryBackoffRequest(
                    reason: rejectionReason,
                    attemptID: answer.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(
                reason: rejectionReason
            )
            mediaRuntime.directQuicProbeController = nil
            return
        }

        guard let controller = mediaRuntime.directQuicProbeController else {
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-probe-controller",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }
        guard let expectedPeerCertificateFingerprint = answer.certificateFingerprint,
              !expectedPeerCertificateFingerprint.isEmpty else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer missing peer certificate fingerprint",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-peer-certificate-fingerprint",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let localCandidatesToRetrickle = controller.preparedLocalCandidates(
            matching: answer.attemptId
        )
        if !localCandidatesToRetrickle.isEmpty {
            await sendDirectQuicCandidateSignals(
                channelID: envelope.channelId,
                contactID: contactID,
                remoteUserID: envelope.fromUserId,
                remoteDeviceID: envelope.fromDeviceId,
                attemptID: answer.attemptId,
                candidates: localCandidatesToRetrickle,
                endOfCandidates: true
            )
        }

        do {
            if try controller.verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC listener received successful probe answer",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "attemptId": answer.attemptId,
                        "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                        "peerCandidateCount": "\(answer.candidates.count)",
                    ]
                )
                await activateDirectQuicMediaPath(
                    for: contactID,
                    attemptID: answer.attemptId
                )
                return
            }
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer peer certificate fingerprint verification failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "peer-certificate-fingerprint-mismatch",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let remoteCandidates = directQuicAttempt(
            for: contactID,
            matching: answer.attemptId
        )?.remoteCandidates ?? answer.candidates
        diagnostics.record(
            .media,
            message: "Direct QUIC answer accepted; continuing promotion with remote candidates",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": envelope.channelId,
                "attemptId": answer.attemptId,
                "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                "peerCandidateCount": "\(remoteCandidates.count)",
            ]
        )
        scheduleDirectQuicPromotionTimeout(
            contactID: contactID,
            attemptID: answer.attemptId
        )
        await continueDirectQuicPromotionIfNeeded(
            for: contactID,
            attemptID: answer.attemptId,
            expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
            candidates: remoteCandidates,
            trigger: "accepted-answer"
        )
    }
}
