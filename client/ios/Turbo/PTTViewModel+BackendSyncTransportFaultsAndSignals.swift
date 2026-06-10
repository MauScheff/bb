//
//  PTTViewModel+BackendSyncTransportFaultsAndSignals.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import TurboEngine
import UIKit

extension PTTViewModel {
    func scheduleIncomingSignalDelivery(_ envelope: TurboSignalEnvelope) {
        switch backendRuntime.transportFaults.consumeWebSocketReorderResult(for: envelope) {
        case .buffered:
            diagnostics.record(
                .websocket,
                message: "Buffered websocket signal for scenario reorder",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            captureDiagnosticsState("backend-signal:buffered:\(envelope.type.rawValue)")
        case .deliver(let envelopes):
            if envelopes.count > 1 {
                diagnostics.record(
                    .websocket,
                    message: "Reordered websocket signals for scenario fault injection",
                    metadata: [
                        "count": "\(envelopes.count)",
                        "types": envelopes.map(\.type.rawValue).joined(separator: ",")
                    ]
                )
                captureDiagnosticsState("backend-signal:reordered")
            }
            for envelope in envelopes {
                deliverIncomingSignalWithFaultPlan(envelope)
            }
        }
    }

    private func deliverIncomingSignalWithFaultPlan(_ envelope: TurboSignalEnvelope) {
        let plan = backendRuntime.transportFaults.consumeWebSocketSignalDeliveryPlan(for: envelope.type)

        if plan.shouldDrop {
            diagnostics.record(
                .websocket,
                message: "Dropped websocket signal for scenario fault injection",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            captureDiagnosticsState("backend-signal:dropped:\(envelope.type.rawValue)")
            return
        }

        for deliveryIndex in 0...plan.duplicateDeliveries {
            let deliveryDelayMilliseconds = plan.delayMilliseconds + (deliveryIndex * 25)
            Task { @MainActor [weak self] in
                if deliveryDelayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(deliveryDelayMilliseconds) * 1_000_000)
                }
                guard let self else { return }
                if deliveryIndex > 0 {
                    self.diagnostics.record(
                        .websocket,
                        message: "Duplicated websocket signal for scenario fault injection",
                        metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
                    )
                } else if plan.delayMilliseconds > 0 {
                    self.diagnostics.record(
                        .websocket,
                        message: "Delayed websocket signal for scenario fault injection",
                        metadata: [
                            "type": envelope.type.rawValue,
                            "channelId": envelope.channelId,
                            "delayMilliseconds": "\(plan.delayMilliseconds)"
                        ]
                    )
                }
                await self.ingestBackendWebSocketSignal(envelope)
            }
        }
    }

    func withHTTPTransportFault<Response>(
        route: TransportFaultHTTPRoute,
        operation: () async throws -> Response
    ) async throws -> Response {
        let delayMilliseconds = backendRuntime.transportFaults.consumeHTTPDelay(for: route)
        if delayMilliseconds > 0 {
            diagnostics.record(
                .backend,
                message: "Delayed HTTP backend request for scenario fault injection",
                metadata: [
                    "route": route.rawValue,
                    "delayMilliseconds": "\(delayMilliseconds)"
                ]
            )
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        }
        return try await operation()
    }

    func shouldSurfaceDirectTransportPath(for contactID: UUID) -> Bool {
        selectedContactId == contactID
            || activeChannelId == contactID
            || mediaSessionContactID == contactID
    }

    func applyDirectQuicUpgradeTransition(
        _ transition: DirectQuicUpgradeTransition,
        for contactID: UUID
    ) {
        guard shouldSurfaceDirectTransportPath(for: contactID) else { return }

        let surfacedPathState = mediaRuntime.surfacedTransportPathState(for: transition)
        let suppressedByActiveMediaRelay =
            surfacedPathState != transition.pathState && mediaRuntime.hasActiveMediaRelayClient

        if suppressedByActiveMediaRelay {
            diagnostics.record(
                .media,
                message: "Preserved fast relay path while processing Direct QUIC transition",
                metadata: [
                    "contactId": contactID.uuidString,
                    "directQuicPathState": transition.pathState.rawValue,
                    "surfacedPathState": surfacedPathState.rawValue,
                    "attemptId": transition.attemptId ?? "none",
                    "reason": transition.reason ?? "none",
                ]
            )
        }

        mediaRuntime.updateTransportPathState(surfacedPathState)

        switch transition {
        case .enteredPromoting, .updatedPromoting:
            if !suppressedByActiveMediaRelay {
                backendStatusMessage = "Direct path promoting"
            }
        case .directActivated:
            backendStatusMessage = "Direct path active"
        case .recovering:
            if !suppressedByActiveMediaRelay {
                backendStatusMessage = "Direct path recovering"
            } else if backendStatusMessage.hasPrefix("Direct path")
                || backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
        case .fellBackToRelay:
            if backendStatusMessage.hasPrefix("Direct path")
                || backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
        }

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("direct-quic:\(surfacedPathState.rawValue)")
        }
    }

    func handleIncomingDirectQuicControlSignal(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        do {
            let signal = try envelope.decodeDirectQuicSignalPayload()
            guard shouldAcceptIncomingDirectQuicSignal(
                signal,
                envelope: envelope,
                contactID: contactID
            ) else {
                let debugBypass: String = {
                    if case .offer(let payload) = signal {
                        return String(payload.debugBypass == true)
                    }
                    return "false"
                }()
                diagnostics.record(
                    .websocket,
                    message: "Ignored direct QUIC signal while upgrade disabled",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "backendAdvertisesDirectQuicUpgrade": String(backendAdvertisesDirectQuicUpgrade),
                        "localRelayOnlyOverride": String(isDirectPathRelayOnlyForced),
                        "debugBypass": debugBypass,
                    ]
                )
                return
            }
            guard shouldObserveIncomingDirectQuicSignal(
                signal,
                envelope: envelope,
                contactID: contactID
            ) else {
                return
            }

            if !effectiveDirectQuicUpgradeEnabled {
                diagnostics.record(
                    .websocket,
                    message: "Accepted direct QUIC signal through debug bypass",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "backendAdvertisesDirectQuicUpgrade": String(backendAdvertisesDirectQuicUpgrade),
                    ]
                )
            }

            let transition = mediaRuntime.directQuicUpgrade.observeIncomingSignal(
                contactID: contactID,
                channelID: envelope.channelId,
                signal: signal
            )

            var metadata: [String: String] = [
                "type": envelope.type.rawValue,
                "channelId": envelope.channelId,
                "contactId": contactID.uuidString,
                "attemptId": signal.attemptId,
                "pathState": transition.pathState.rawValue,
                "fromDeviceId": envelope.fromDeviceId,
                "toDeviceId": envelope.toDeviceId,
            ]

            let message: String = {
                switch signal {
                case .offer(let payload):
                    metadata["candidateCount"] = "\(payload.candidates.count)"
                    metadata["quicAlpn"] = payload.quicAlpn
                    metadata["roleIntent"] = payload.roleIntent?.rawValue ?? "none"
                    metadata["debugBypass"] = String(payload.debugBypass == true)
                    return "Direct QUIC offer received"
                case .answer(let payload):
                    metadata["candidateCount"] = "\(payload.candidates.count)"
                    metadata["accepted"] = String(payload.accepted)
                    if let rejectionReason = payload.rejectionReason {
                        metadata["rejectionReason"] = rejectionReason
                    }
                    return "Direct QUIC answer received"
                case .candidate(let payload):
                    metadata["hasCandidate"] = String(payload.candidate != nil)
                    metadata["endOfCandidates"] = String(payload.endOfCandidates)
                    return "Direct QUIC candidate received"
                case .hangup(let payload):
                    metadata["reason"] = payload.reason
                    return "Direct QUIC hangup received"
                }
            }()

            diagnostics.record(.websocket, message: message, metadata: metadata)
            applyDirectQuicUpgradeTransition(transition, for: contactID)
            Task {
                await handleDirectQuicSignal(
                    signal,
                    envelope: envelope,
                    contactID: contactID
                )
            }
        } catch {
            backendStatusMessage = "Direct path signal decode failed"
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Failed to decode direct QUIC signal",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func shouldObserveIncomingDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> Bool {
        if let localBlockReason = incomingDirectQuicLocalConversationBlockReason(
            signal,
            envelope: envelope,
            contactID: contactID
        ) {
            diagnostics.record(
                .websocket,
                message: "Ignored stale Direct QUIC signal because local Conversation is not eligible",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "attemptId": signal.attemptId,
                    "reason": localBlockReason,
                    "fromDeviceId": envelope.fromDeviceId,
                    "toDeviceId": envelope.toDeviceId,
                    "activeChannelId": activeChannelId?.uuidString ?? "none",
                    "isJoined": String(isJoined),
                    "systemSessionMatches": String(systemSessionMatches(contactID)),
                    "pendingLeave": String(
                        conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
                    ),
                ]
            )
            _ = retireDirectQuicPathImmediately(
                for: contactID,
                reason: "incoming-signal-local-\(localBlockReason)",
                sendHangup: false,
                configureActiveRoute: false
            )
            return false
        }

        switch signal {
        case .offer:
            if directQuicAttempt(for: contactID, matching: signal.attemptId)?.isDirectActive == true {
                diagnostics.record(
                    .websocket,
                    message: "Ignored duplicate Direct QUIC offer for active path",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "toDeviceId": envelope.toDeviceId,
                    ]
                )
                return false
            }
            return true
        case .hangup:
            return true
        case .answer, .candidate:
            guard directQuicAttempt(for: contactID, matching: signal.attemptId) != nil else {
                diagnostics.record(
                    .websocket,
                    message: "Ignored stale Direct QUIC follow-up signal without active attempt",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "toDeviceId": envelope.toDeviceId,
                    ]
                )
                return false
            }
            return true
        }
    }

    func incomingDirectQuicLocalConversationBlockReason(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> String? {
        if case .hangup = signal {
            return nil
        }
        if conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            return "leave-in-flight"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelID = contact.backendChannelId,
              !backendChannelID.isEmpty,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        guard backendChannelID == envelope.channelId else {
            return "channel-id-mismatch"
        }
        guard systemSessionMatches(contactID),
              isJoined,
              activeChannelId == contactID else {
            return "local-session-not-aligned"
        }
        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return "channel-snapshot-missing"
        }
        guard channel.membership.hasLocalMembership else {
            return "local-membership-missing"
        }
        guard channel.membership.peerDeviceConnected else {
            return "peer-device-not-connected"
        }
        return nil
    }

    func shouldAcceptIncomingDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> Bool {
        if let authorizationFailure = directQuicProductionSignalAuthorizationFailure(
            signal: signal,
            envelope: envelope,
            contactID: contactID
        ) {
            let recoverableIdentityRace = isRecoverableDirectQuicAuthorizationRace(authorizationFailure)
            if recoverableIdentityRace,
               shouldAcceptDirectQuicSignalDuringPeerIdentityRace(
                signal,
                envelope: envelope,
                contactID: contactID
               ) {
                recordRecentPeerDeviceEvidence(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    peerDeviceID: envelope.fromDeviceId,
                    reason: "direct-quic-peer-identity-race:\(envelope.type.rawValue)",
                    diagnosticSubsystem: .websocket
                )
                diagnostics.record(
                    .media,
                    message: "Accepted direct QUIC signal while backend peer identity is catching up",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "reason": authorizationFailure,
                        "fromDeviceId": envelope.fromDeviceId,
                        "backendPeerFingerprint": "none",
                    ]
                )
                return true
            }
            diagnostics.record(
                .media,
                level: recoverableIdentityRace ? .info : .error,
                message: recoverableIdentityRace
                    ? "Deferred direct QUIC signal until backend peer identity is available"
                    : "Rejected direct QUIC signal because backend peer identity did not authorize it",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "attemptId": signal.attemptId,
                    "reason": authorizationFailure,
                    "fromDeviceId": envelope.fromDeviceId,
                    "backendPeerFingerprint": backendPeerDirectQuicFingerprint(for: contactID) ?? "none",
                ]
            )
            if !recoverableIdentityRace {
                mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                    for: contactID,
                    request: directQuicRetryBackoffRequest(
                        reason: authorizationFailure,
                        attemptID: signal.attemptId
                    )
                )
            }
            return false
        }
        if effectiveDirectQuicUpgradeEnabled {
            return true
        }
        guard !isDirectPathRelayOnlyForced else {
            return false
        }

        if case .offer(let payload) = signal,
           payload.debugBypass == true,
           envelope.toDeviceId == backendServices?.deviceID {
            return true
        }

        guard let existingAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return false
        }
        return existingAttempt.attemptId == signal.attemptId
    }

    func isRecoverableDirectQuicAuthorizationRace(_ reason: String) -> Bool {
        reason == "backend-peer-fingerprint-missing"
    }

    func shouldAcceptDirectQuicSignalDuringPeerIdentityRace(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> Bool {
        guard case .offer(let payload) = signal else {
            return false
        }
        guard DirectQuicProductionIdentityManager.normalizedFingerprint(
            payload.certificateFingerprint
        ) != nil else {
            return false
        }
        guard let backend = backendServices,
              envelope.toDeviceId == backend.deviceID,
              payload.toDeviceId == backend.deviceID,
              payload.fromDeviceId == envelope.fromDeviceId else {
            return false
        }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              contact.remoteUserId == envelope.fromUserId else {
            return false
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID, fallback: envelope.fromDeviceId),
              peerDeviceID == envelope.fromDeviceId else {
            return false
        }
        return true
    }

    func recordIncomingAudioStandbyIngressIfNeeded(
        contactID: UUID,
        channelID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) {
        let selectedTransport = selectedMediaTransportState(for: contactID)
        guard selectedTransport.directMediaPathActive,
              incomingAudioTransport != .directQuic else {
            return
        }
        diagnostics.record(
            .media,
            message: "Accepted standby audio while Direct transport is selected",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "selectedTransport": selectedTransport.diagnosticsValue,
                "fallback": selectedTransport.fallbackDiagnosticsValue,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "transportPathState": mediaTransportPathState.rawValue,
            ]
        )
    }

    @discardableResult
    func recordIncomingAudioContinuityContractIfNeeded(
        contactID: UUID,
        channelID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        fromDeviceID: String = "unknown",
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        let thresholdNanoseconds = incomingAudioChunkContinuityGapNanoseconds(
            for: incomingAudioTransport
        )
        let observation = mediaRuntime.observeIncomingAudioContinuity(
            contactID: contactID,
            transport: incomingAudioTransport,
            nowNanoseconds: nowNanoseconds
        )
        guard let gapNanoseconds = observation.gapNanoseconds,
              gapNanoseconds >= thresholdNanoseconds,
              receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .receivingAudio else {
            return false
        }
        let disposition = mediaRuntime.consumeIncomingAudioContractDiagnosticDisposition(
            for: contactID,
            transport: incomingAudioTransport,
            invariantID: "media.incoming_audio_chunk_gap"
        )
        switch disposition {
        case .detailed:
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.incomingAudioChunkGap(
                    contactID: contactID,
                    channelID: channelID,
                    incomingTransport: incomingAudioTransport.diagnosticsValue,
                    previousTransport: observation.previousTransport?.diagnosticsValue ?? "none",
                    gapMilliseconds: gapNanoseconds / 1_000_000,
                    thresholdMilliseconds: thresholdNanoseconds / 1_000_000,
                    receivePhase: String(
                        describing: receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase
                    ),
                    selectedTransport: selectedMediaTransportState(for: contactID).diagnosticsValue
                )
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                level: .notice,
                message: "Suppressing repetitive incoming audio chunk gap diagnostics",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "previousTransport": observation.previousTransport?.diagnosticsValue ?? "none",
                    "gapMilliseconds": String(gapNanoseconds / 1_000_000),
                    "thresholdMilliseconds": String(thresholdNanoseconds / 1_000_000),
                    "reason": "budget-exhausted",
                    "detailedReportLimit": "1",
                ]
            )

        case .suppressed:
            break
        }
        let didResetReceiveEpoch = resetRemoteReceiveEpochAfterIncomingAudioContinuityGapIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            observation: observation,
            thresholdNanoseconds: thresholdNanoseconds
        )
        preserveRelayRemoteReceiveAfterIncomingAudioContinuityGapIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            observation: observation,
            thresholdNanoseconds: thresholdNanoseconds
        )
        return didResetReceiveEpoch
    }

    private func resetRemoteReceiveEpochAfterIncomingAudioContinuityGapIfNeeded(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        observation: IncomingAudioContinuityObservation,
        thresholdNanoseconds: UInt64
    ) -> Bool {
        guard let gapNanoseconds = observation.gapNanoseconds else { return false }
        guard incomingAudioTransport != .mediaRelayPacket else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Preserved Fast Relay QUIC receive epoch after incoming audio continuity gap",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "gapMilliseconds": String(gapNanoseconds / 1_000_000),
                    "thresholdMilliseconds": String(thresholdNanoseconds / 1_000_000),
                    "previousTransport": observation.previousTransport?.diagnosticsValue ?? "none",
                ]
            )
            return false
        }
        guard incomingAudioTransport.isUnreliablePacketMedia else { return false }

        if incomingAudioTransport == .directQuic,
           retireDirectQuicReceivePathAfterLiveAudioFreshnessFailureIfFallbackReady(
            contactID: contactID,
            reason: "incoming-audio-continuity-gap",
            sequenceNumber: nil
        ) {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Preserved fallback receive epoch after Direct QUIC continuity gap",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "gapMilliseconds": String(gapNanoseconds / 1_000_000),
                    "thresholdMilliseconds": String(thresholdNanoseconds / 1_000_000),
                ]
            )
            return false
        }

        mediaRuntime.resetDirectQuicIncomingAudioQueueDelayDiagnostics(for: contactID)
        mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
        resetLiveAudioReceiveRuntime(for: contactID, reason: "incoming-audio-continuity-gap")
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        switch incomingAudioTransport {
        case .directQuic:
            mediaRuntime.directQuicProbeController?.resetIncomingAudioPayloadQueue(
                reason: "incoming-audio-continuity-gap"
            )
        case .mediaRelayPacket:
            mediaRuntime.mediaRelayClient?.resetIncomingAudioPayloadQueue(
                reason: "incoming-audio-continuity-gap"
            )
        case .mediaRelayTcp, .relayWebSocket:
            break
        }
        mediaServices.session()?.beginRemoteAudioReceiveEpoch()
        clearFirstAudioPlaybackAckSentState(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: fromDeviceID
        )
        diagnostics.record(
            .media,
            level: .notice,
            message: "Reset remote audio receive epoch after incoming audio continuity gap",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "gapMilliseconds": String(gapNanoseconds / 1_000_000),
                "thresholdMilliseconds": String(thresholdNanoseconds / 1_000_000),
            ]
        )
        return true
    }

    private func preserveRelayRemoteReceiveAfterIncomingAudioContinuityGapIfNeeded(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        observation: IncomingAudioContinuityObservation,
        thresholdNanoseconds: UInt64
    ) {
        guard !incomingAudioTransport.isUnreliablePacketMedia else { return }
        guard let gapNanoseconds = observation.gapNanoseconds else { return }
        guard observation.previousTransport != .directQuic else { return }
        diagnostics.record(
            .media,
            level: .notice,
            message: "Preserved relay receive epoch after incoming audio continuity gap",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "gapMilliseconds": String(gapNanoseconds / 1_000_000),
                "thresholdMilliseconds": String(thresholdNanoseconds / 1_000_000),
                "previousTransport": observation.previousTransport?.diagnosticsValue ?? "none",
            ]
        )
    }

    func incomingAudioChunkContinuityGapNanoseconds(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> UInt64 {
        switch incomingAudioTransport {
        case .directQuic, .mediaRelayPacket:
            return remoteAudioChunkContinuityGapNanoseconds
        case .mediaRelayTcp:
            return max(remoteAudioChunkContinuityGapNanoseconds, 700_000_000)
        case .relayWebSocket:
            return max(remoteAudioChunkContinuityGapNanoseconds, 1_000_000_000)
        }
    }

    func incomingLiveAudioBacklogExpirationNanoseconds(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> UInt64 {
        switch incomingAudioTransport {
        case .directQuic:
            return directQuicIncomingAudioLiveBacklogDropNanoseconds
        case .mediaRelayPacket:
            return mediaRelayPacketIncomingAudioLiveBacklogDropNanoseconds
        case .mediaRelayTcp, .relayWebSocket:
            return incomingLiveAudioBacklogExpirationNanoseconds
        }
    }

    func incomingLiveAudioBacklogExpirationNanoseconds(
        for incomingAudioTransport: IncomingAudioPayloadTransport,
        heldForAppleAudioActivation _: Bool
    ) -> UInt64 {
        incomingLiveAudioBacklogExpirationNanoseconds(
            for: incomingAudioTransport
        )
    }

    func recordIncomingAudioSequenceContractIfNeeded(
        contactID: UUID,
        channelID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        sequenceNumber: UInt64
    ) {
        let observation = mediaRuntime.observeIncomingAudioSequence(
            contactID: contactID,
            transport: incomingAudioTransport,
            sequenceNumber: sequenceNumber
        )
        guard !incomingAudioTransport.isUnreliablePacketMedia else {
            return
        }
        guard let previousSequenceNumber = observation.previousSequenceNumber,
              let missingSequenceCount = observation.missingSequenceCount,
              receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .receivingAudio else {
            return
        }
        let disposition = mediaRuntime.consumeIncomingAudioContractDiagnosticDisposition(
            for: contactID,
            transport: incomingAudioTransport,
            invariantID: "media.incoming_audio_sequence_gap"
        )
        switch disposition {
        case .detailed:
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.incomingAudioSequenceGap(
                    contactID: contactID,
                    channelID: channelID,
                    incomingTransport: incomingAudioTransport.diagnosticsValue,
                    previousTransport: observation.previousTransport?.diagnosticsValue ?? "none",
                    previousSequenceNumber: previousSequenceNumber,
                    sequenceNumber: observation.sequenceNumber,
                    missingSequenceCount: missingSequenceCount,
                    receivePhase: String(
                        describing: receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase
                    ),
                    selectedTransport: selectedMediaTransportState(for: contactID).diagnosticsValue
                )
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                level: .notice,
                message: "Suppressing repetitive incoming audio sequence gap diagnostics",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "previousTransport": observation.previousTransport?.diagnosticsValue ?? "none",
                    "previousSequenceNumber": String(previousSequenceNumber),
                    "sequenceNumber": String(observation.sequenceNumber),
                    "missingSequenceCount": String(missingSequenceCount),
                    "reason": "budget-exhausted",
                    "detailedReportLimit": "1",
                ]
            )

        case .suppressed:
            break
        }
    }

    func handleIncomingAudioPayload(
        _ payload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport = .mediaRelayTcp,
        transportSequenceNumber: UInt64? = nil,
        expectedReceiveEpoch: UInt64? = nil,
        ingressContext: IncomingAudioIngressContext? = nil
    ) async {
        guard incomingAudioTransport != .relayWebSocket else {
            diagnostics.recordInvariantViolation(
                invariantID: "media.runtime_never_carries_live_audio",
                scope: .local,
                message: "Rejected runtime WebSocket audio payload at media ingress",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromUserId": fromUserID,
                    "fromDeviceId": fromDeviceID,
                    "toDeviceId": backendServices?.deviceID ?? backendConfig?.deviceID ?? "unknown",
                    "payloadClass": "liveMedia",
                    "endpoint": "runtime",
                    "mechanism": "websocket",
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "action": "rejected",
                ]
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Rejected runtime WebSocket audio payload at media ingress",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "action": "rejected-runtime-live-media",
                ]
            )
            return
        }
        let applicationState = currentApplicationState()
        guard !dropIncomingAudioAfterCancelledTransportDeliveryIfNeeded(
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: transportSequenceNumber ?? ingressContext?.sequenceNumber,
            receivedAtNanoseconds: ingressContext?.receivedAtNanoseconds,
            senderSentAtMilliseconds: ingressContext?.sentAtMilliseconds,
            source: ingressContext?.source ?? "incoming-audio",
            stage: "before-admission"
        ) else {
            return
        }
        configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: fromDeviceID,
            logPreservedSession: false
        )
        guard !dropIncomingAudioAfterExpiredBackendTransmitLeaseIfNeeded(
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            transportSequenceNumber: transportSequenceNumber,
            ingressContext: ingressContext
        ) else {
            return
        }
        let heldForAppleAudioActivation =
            shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
                for: contactID,
                channelID: channelID,
                incomingAudioTransport: incomingAudioTransport,
                applicationState: applicationState
            )
        let ingressAdmission = await incomingAudioIngressExecutor.admit(
            IncomingAudioIngressPacket(
                payload: payload,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                transportSequenceNumber: transportSequenceNumber,
                ingressContext: ingressContext,
                receiveEpoch: expectedReceiveEpoch
                    ?? mediaRuntime.incomingAudioReceiveEpoch(for: contactID)
            ),
            policy: IncomingAudioIngressConfiguration(
                mediaEncryptionRequired: mediaEncryptionIsRequired(for: contactID),
                mediaEncryptionSession: mediaRuntime.mediaEncryptionSession(for: contactID),
                liveAudioBacklogExpirationNanoseconds: incomingLiveAudioBacklogExpirationNanoseconds(
                    for: incomingAudioTransport,
                    heldForAppleAudioActivation: heldForAppleAudioActivation
                ),
                liveAudioSenderClockExpirationMilliseconds: incomingLiveAudioSenderClockExpirationMilliseconds(
                    for: incomingAudioTransport,
                    heldForAppleAudioActivation: heldForAppleAudioActivation
                )
            )
        )

        let admittedPacket: IncomingAudioIngressAcceptedPacket
        switch ingressAdmission {
        case .accepted(let packet):
            admittedPacket = packet

        case .deferredEncrypted(let deferred):
            deferIncomingEncryptedAudioPayloadUntilMediaEncryptionReady(
                deferred.incomingMediaPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                ingressContext: ingressContext
            )
            return

        case .rejected(.encryptedOpenFailed(let errorDescription)):
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to open incoming media E2EE payload",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": String(describing: incomingAudioTransport),
                    "error": errorDescription,
                ]
            )
            return

        case .rejected(.duplicateEncrypted(let sequenceNumber)):
            diagnostics.record(
                .media,
                message: "Ignored duplicate encrypted audio packet",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sequenceNumber": String(sequenceNumber),
                ]
            )
            return

        case .rejected(.replayedEncrypted(let sequenceNumber)):
            diagnostics.recordInvariantViolation(
                invariantID: "media.e2ee_replayed_audio_packet",
                scope: .local,
                message: "encrypted audio packet sequence was replayed or reordered",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sequenceNumber": String(sequenceNumber),
                ]
            )
            return

        case .rejected(.duplicatePlaintext(let previousTransport, let transportDigest)):
            let disposition = mediaRuntime.consumeIncomingAudioDropDiagnosticDisposition(
                for: contactID,
                transport: incomingAudioTransport,
                reason: "duplicate-plaintext-standby",
                detailedReportLimit: 3
            )
            switch disposition {
            case .detailed:
                diagnostics.record(
                    .media,
                    message: "Ignored duplicate plaintext audio payload from standby transport",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "fromDeviceId": fromDeviceID,
                        "transport": String(describing: incomingAudioTransport),
                        "previousTransport": String(describing: previousTransport),
                        "transportDigest": transportDigest,
                    ]
                )

            case .suppressedNotice:
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Suppressing repetitive duplicate plaintext audio diagnostics",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "fromDeviceId": fromDeviceID,
                        "transport": incomingAudioTransport.diagnosticsValue,
                        "previousTransport": previousTransport.diagnosticsValue,
                        "reason": "duplicate-plaintext-standby",
                        "detailedReportLimit": "3",
                    ]
                )

            case .suppressed:
                break
            }
            return

        case .rejected(
            .droppedByPlaybackGate(
                let playbackDecision,
                let sequenceNumber,
                let transportDigest,
                let senderSentAtMilliseconds,
                let localQueueDelayNanoseconds
            )
        ):
            let freshnessDecision = incomingAudioPlaybackDropDecisionValue(playbackDecision)
            recordIncomingAudioIngressSummaryIfNeeded(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                incomingAudioTransport: incomingAudioTransport,
                sequenceNumber: sequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                freshnessDecision: freshnessDecision,
                playbackAccepted: false,
                source: ingressContext?.source ?? "incoming-audio"
            )
            var metadata = [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "transport": incomingAudioTransport.diagnosticsValue,
                "sequenceNumber": sequenceNumber.map(String.init) ?? "none",
                "transportDigest": transportDigest,
            ]
            var dropReason = "unknown"
            var expiredLiveBacklog: (localQueueDelayNanoseconds: UInt64, thresholdNanoseconds: UInt64)?
            var expiredSenderClockAge: (senderClockAgeMilliseconds: Int64, thresholdMilliseconds: Int64)?
            switch playbackDecision.dropReason {
            case .duplicateOrStaleSequence:
                dropReason = "duplicate-or-stale-sequence"
            case .orderedBacklog(let elapsedNanoseconds, let expectedSequenceFloor):
                dropReason = "ordered-backlog"
                metadata["elapsedMilliseconds"] = String(elapsedNanoseconds / 1_000_000)
                metadata["expectedSequenceFloor"] = String(expectedSequenceFloor)
            case .expiredLiveBacklog(let expiredLocalQueueDelayNanoseconds, let thresholdNanoseconds):
                dropReason = "expired-live-backlog"
                expiredLiveBacklog = (
                    localQueueDelayNanoseconds: expiredLocalQueueDelayNanoseconds,
                    thresholdNanoseconds: thresholdNanoseconds
                )
                metadata["localQueueDelayMs"] = String(expiredLocalQueueDelayNanoseconds / 1_000_000)
                metadata["thresholdMs"] = String(thresholdNanoseconds / 1_000_000)
            case .expiredSenderClockAge(let senderClockAgeMilliseconds, let thresholdMilliseconds):
                dropReason = "expired-sender-clock-age"
                expiredSenderClockAge = (
                    senderClockAgeMilliseconds: senderClockAgeMilliseconds,
                    thresholdMilliseconds: thresholdMilliseconds
                )
                metadata["senderClockAgeMs"] = String(senderClockAgeMilliseconds)
                metadata["thresholdMs"] = String(thresholdMilliseconds)
                metadata["senderClockAgeThresholdMs"] = String(thresholdMilliseconds)
            case .duplicatePlaintextStandby(let previousTransport):
                dropReason = "duplicate-plaintext-standby"
                metadata["previousTransport"] = previousTransport.diagnosticsValue
            case .standbyContinuity(let authoritativeTransport):
                dropReason = "standby-continuity"
                metadata["authoritativeTransport"] = authoritativeTransport.diagnosticsValue
            case nil:
                break
            }
            metadata["reason"] = dropReason
            handleDirectQuicStalePlaybackDropIfNeeded(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                incomingAudioTransport: incomingAudioTransport,
                dropReason: dropReason,
                sequenceNumber: sequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds
            )
            if expiredLiveBacklog != nil {
                handleExpiredLiveAudioDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    reason: "expired-live-backlog"
                )
            }
            if expiredSenderClockAge != nil {
                handleExpiredLiveAudioDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    reason: "expired-sender-clock-age"
                )
            }

            let disposition = mediaRuntime.consumeIncomingAudioDropDiagnosticDisposition(
                for: contactID,
                transport: incomingAudioTransport,
                reason: dropReason
            )
            switch disposition {
            case .detailed:
                if let expiredLiveBacklog {
                    diagnostics.recordContractViolation(
                        DiagnosticsContracts.Media.incomingAudioQueueDelay(
                            contactID: contactID,
                            channelID: channelID,
                            attemptID: ingressContext?.source ?? incomingAudioTransport.diagnosticsValue,
                            incomingTransport: incomingAudioTransport.diagnosticsValue,
                            sequenceNumber: sequenceNumber.map(String.init) ?? "none",
                            localQueueDelayMilliseconds:
                                expiredLiveBacklog.localQueueDelayNanoseconds / 1_000_000,
                            senderClockAgeMilliseconds: senderSentAtMilliseconds.map {
                                String(Int64(Date().timeIntervalSince1970 * 1_000) - $0)
                            } ?? "none",
                            thresholdMilliseconds: expiredLiveBacklog.thresholdNanoseconds / 1_000_000,
                            action: "dropped-expired-live-backlog"
                        ),
                        metadata: metadata
                    )
                }
                if let expiredSenderClockAge {
                    diagnostics.recordContractViolation(
                        DiagnosticsContracts.Media.incomingAudioQueueDelay(
                            contactID: contactID,
                            channelID: channelID,
                            attemptID: ingressContext?.source ?? incomingAudioTransport.diagnosticsValue,
                            incomingTransport: incomingAudioTransport.diagnosticsValue,
                            sequenceNumber: sequenceNumber.map(String.init) ?? "none",
                            localQueueDelayMilliseconds: localQueueDelayNanoseconds / 1_000_000,
                            senderClockAgeMilliseconds: String(
                                expiredSenderClockAge.senderClockAgeMilliseconds
                            ),
                            thresholdMilliseconds: UInt64(
                                max(0, expiredSenderClockAge.thresholdMilliseconds)
                            ),
                            action: "dropped-expired-sender-clock-age"
                        ),
                        metadata: metadata
                    )
                }
                diagnostics.record(
                    .media,
                    message: "Dropped incoming audio frame before playback",
                    metadata: metadata
                )

            case .suppressedNotice:
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Suppressing repetitive incoming audio drop diagnostics",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "fromDeviceId": fromDeviceID,
                        "transport": incomingAudioTransport.diagnosticsValue,
                        "sequenceNumber": sequenceNumber.map(String.init) ?? "none",
                        "reason": dropReason,
                        "detailedReportLimit": "1",
                    ]
                )

            case .suppressed:
                break
            }
            return
        }

        let incomingMediaPayload = admittedPacket.incomingMediaPayload
        let audioPayload = admittedPacket.audioPayload
        let playbackSequenceNumber = admittedPacket.sequenceNumber
        let senderSentAtMilliseconds = admittedPacket.senderSentAtMilliseconds
        let localQueueDelayNanoseconds = admittedPacket.localQueueDelayNanoseconds
        let frameDurationNanoseconds = admittedPacket.frameDurationNanoseconds
        guard !dropIncomingAudioAfterCancelledTransportDeliveryIfNeeded(
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: playbackSequenceNumber,
            receivedAtNanoseconds: admittedPacket.ingressReceivedAtNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            source: ingressContext?.source ?? "incoming-audio",
            stage: "after-admission"
        ) else {
            return
        }
        if let expectedReceiveEpoch,
           mediaRuntime.incomingAudioReceiveEpoch(for: contactID) != expectedReceiveEpoch {
            recordIncomingAudioIngressSummaryIfNeeded(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                incomingAudioTransport: incomingAudioTransport,
                sequenceNumber: playbackSequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                freshnessDecision: "dropped-stale-receive-epoch",
                playbackAccepted: false,
                source: ingressContext?.source ?? "incoming-audio"
            )
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped incoming audio after receive epoch changed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "sequenceNumber": playbackSequenceNumber.map(String.init) ?? "none",
                    "expectedReceiveEpoch": String(expectedReceiveEpoch),
                    "currentReceiveEpoch": String(mediaRuntime.incomingAudioReceiveEpoch(for: contactID)),
                ]
            )
            return
        }
        if admittedPacket.shouldLogPlaintextFallback,
           mediaRuntime.takeShouldLogMediaEncryptionPlaintextFallback(
            contactID: contactID,
            direction: "incoming"
           ) {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Accepted plaintext media payload during opportunistic E2EE fallback",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "peerIdentityAdvertised": "true",
                    "sessionConfigured": String(mediaRuntime.mediaEncryptionSession(for: contactID) != nil),
                ]
            )
        }
        let receivedAtNanoseconds = admittedPacket.ingressReceivedAtNanoseconds
        if shouldUseImmediateIncomingAudioPlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) {
            let effectiveReceiveEpoch = recordAcceptedIncomingAudioBookkeeping(
                incomingMediaPayload: incomingMediaPayload,
                audioPayload: audioPayload,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                receivedAtNanoseconds: receivedAtNanoseconds,
                frameDurationNanoseconds: frameDurationNanoseconds
            )
            markRemoteAudioActivity(for: contactID, source: .audioChunk)
            if selectedContactId == nil {
                selectedContactId = contactID
            }
            scheduleIncomingAudioPlaybackCompletion(
                audioPayload: audioPayload,
                incomingMediaPayload: incomingMediaPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                receiveEpoch: effectiveReceiveEpoch,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                receivedAtNanoseconds: receivedAtNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                ingressSource: ingressContext?.source ?? "incoming-audio"
            )
            return
        }
        let alreadyHasPendingWake = pttWakeRuntime.hasPendingWake(for: contactID)
        let shouldArmDeferredBackgroundAudioWakeCandidate =
            !alreadyHasPendingWake
            && shouldBufferDeferredBackgroundAudioAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
        let shouldArmAudioWakeCandidate =
            shouldTreatIncomingSignalAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
            || shouldArmDeferredBackgroundAudioWakeCandidate
        let wakeIsAlreadySystemActivated =
            pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated
        let shouldRepairRemoteParticipant =
            !wakeIsAlreadySystemActivated
            && !shouldSuppressForegroundDirectQuicRemoteParticipant(
                for: contactID,
                applicationState: applicationState
            )
            && (!remoteTransmittingContactIDs.contains(contactID) || shouldArmDeferredBackgroundAudioWakeCandidate)
            && (alreadyHasPendingWake || shouldArmAudioWakeCandidate)
            && shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: applicationState
            )
        if shouldArmAudioWakeCandidate {
            ensurePendingWakeCandidate(
                for: contactID,
                channelId: channelID,
                senderUserId: fromUserID,
                senderDeviceId: fromDeviceID
            )
        }
        recordWakeReceiveTiming(
            stage: "signal-audio-received",
            contactID: contactID,
            channelID: channelID,
            metadata: [
                "fromDeviceId": fromDeviceID,
                "fromUserId": fromUserID,
                "transport": String(describing: incomingAudioTransport),
            ],
            ifAbsent: true
        )
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        if selectedContactId == nil {
            selectedContactId = contactID
        }
        if shouldRepairRemoteParticipant {
            await updateSystemRemoteParticipant(for: contactID, isActive: true)
        }
        if shouldUseForegroundAppManagedWakePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) {
            startForegroundAppManagedWakePlayback(
                for: contactID,
                channelID: channelID
            )
        }
        if bufferForegroundSystemReceiveAudioChunkUntilPTTActivation(
            audioPayload,
            incomingMediaPayload: incomingMediaPayload,
            channelID: channelID,
            fromUserID: fromUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            playbackSequenceNumber: playbackSequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            frameDurationNanoseconds: frameDurationNanoseconds,
            ingressSource: ingressContext?.source ?? "incoming-audio",
            applicationState: applicationState
        ) {
            return
        }
        let effectiveReceiveEpoch = recordAcceptedIncomingAudioBookkeeping(
            incomingMediaPayload: incomingMediaPayload,
            audioPayload: audioPayload,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            playbackSequenceNumber: playbackSequenceNumber,
            receivedAtNanoseconds: receivedAtNanoseconds,
            frameDurationNanoseconds: frameDurationNanoseconds
        )
        if bufferWakeAudioChunkUntilPTTActivation(
            audioPayload,
            channelID: channelID,
            contactID: contactID
        ) {
            return
        }
        if shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
            for: contactID,
            applicationState: applicationState
        ) {
            if shouldBufferDeferredBackgroundAudioAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            ) {
                ensurePendingWakeCandidate(
                    for: contactID,
                    channelId: channelID,
                    senderUserId: fromUserID,
                    senderDeviceId: fromDeviceID
                )
                if bufferWakeAudioChunkUntilPTTActivation(
                    audioPayload,
                    channelID: channelID,
                    contactID: contactID
                ) {
                    return
                }
            }
            if !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) {
                diagnostics.recordInvariantViolation(
                    invariantID: "audio.deferred_background_chunk_requires_wake_buffer",
                    scope: .local,
                    message: "background audio chunk was deferred without an active wake buffer",
                    metadata: [
                        "channelId": channelID,
                        "contactId": contactID.uuidString,
                        "applicationState": String(describing: applicationState),
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "remoteActivity": String(
                            describing: receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]
                        ),
                    ]
                )
            }
            diagnostics.record(
                .media,
                message: "Deferred background audio chunk until PTT audio session activates",
                metadata: ["channelId": channelID, "contactId": contactID.uuidString]
            )
            return
        }
        if mediaSessionContactID == contactID, mediaConnectionState == .preparing {
            if incomingAudioTransport.isUnreliablePacketMedia {
                scheduleIncomingAudioPlaybackCompletion(
                    audioPayload: audioPayload,
                    incomingMediaPayload: incomingMediaPayload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: fromDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    receiveEpoch: effectiveReceiveEpoch,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                    receivedAtNanoseconds: receivedAtNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    ingressSource: ingressContext?.source ?? "incoming-audio"
                )
                return
            }
            let playbackAccepted = await receiveRemoteAudioChunk(
                audioPayload,
                incomingAudioTransport: incomingAudioTransport
            )
            await completeIncomingAudioPlayback(
                playbackAccepted: playbackAccepted,
                incomingMediaPayload: incomingMediaPayload,
                audioPayload: audioPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                ingressSource: ingressContext?.source ?? "incoming-audio"
            )
            return
        }
        let receiveActivationMode: MediaSessionActivationMode =
            shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: applicationState,
                incomingAudioTransport: incomingAudioTransport
            ) ? .systemActivated : .appManaged
        await ensureMediaSession(
            for: contactID,
            activationMode: receiveActivationMode,
            startupMode: .playbackOnly
        )
        if incomingAudioTransport.isUnreliablePacketMedia {
            scheduleIncomingAudioPlaybackCompletion(
                audioPayload: audioPayload,
                incomingMediaPayload: incomingMediaPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                receiveEpoch: effectiveReceiveEpoch,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                receivedAtNanoseconds: receivedAtNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                ingressSource: ingressContext?.source ?? "incoming-audio"
            )
            return
        }
        let playbackAccepted = await receiveRemoteAudioChunk(
            audioPayload,
            incomingAudioTransport: incomingAudioTransport
        )
        await completeIncomingAudioPlayback(
            playbackAccepted: playbackAccepted,
            incomingMediaPayload: incomingMediaPayload,
            audioPayload: audioPayload,
            channelID: channelID,
            fromUserID: fromUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            playbackSequenceNumber: playbackSequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            ingressSource: ingressContext?.source ?? "incoming-audio"
        )
    }

    nonisolated func handleIncomingLiveAudioPayload(
        _ payload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        transportSequenceNumber: UInt64? = nil,
        expectedReceiveEpoch: UInt64? = nil,
        ingressContext: IncomingAudioIngressContext
    ) async {
        let packet = LiveAudioReceivePacket(
            payload: payload,
            channelID: channelID,
            fromUserID: fromUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            transport: incomingAudioTransport,
            transportSequenceNumber: transportSequenceNumber,
            ingressContext: ingressContext
        )
        await liveAudioReceiveExecutor.receive(
            packet,
            diagnosticsSink: liveMediaDiagnosticsSink,
            makeContext: { [weak self] in
                guard let self else { return nil }
                return await self.makeLiveAudioReceiveContext(
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: incomingAudioTransport,
                    expectedReceiveEpoch: expectedReceiveEpoch,
                    ingressContext: ingressContext
                )
            },
            fallbackToMainActorReceive: { [weak self] in
                await self?.handleIncomingAudioPayload(
                    payload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: fromDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: incomingAudioTransport,
                    transportSequenceNumber: transportSequenceNumber,
                    expectedReceiveEpoch: expectedReceiveEpoch,
                    ingressContext: ingressContext
                )
            },
            onFirstPlaybackAccepted: { [weak self] admittedPacket in
                await self?.recordLiveAudioFirstPlaybackAccepted(
                    admittedPacket,
                    packet: packet
                )
            },
            onDiagnosticSummary: { [weak self] summary in
                await self?.recordLiveAudioReceiveSummary(summary)
            },
            onDropDiagnostic: { [weak self] drop in
                await self?.recordLiveAudioReceiveDropDiagnostic(drop)
            },
            onPlaybackReadinessDiagnostic: { [weak self] diagnostic in
                await self?.recordLiveAudioReceivePlaybackReadinessDiagnostic(diagnostic)
            }
        )
    }

    private func makeLiveAudioReceiveContext(
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        expectedReceiveEpoch: UInt64?,
        ingressContext: IncomingAudioIngressContext
    ) async -> LiveAudioReceiveContext? {
        guard incomingAudioTransport != .relayWebSocket || currentApplicationState() == .active else {
            return nil
        }
        guard !dropIncomingAudioAfterCancelledTransportDeliveryIfNeeded(
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: ingressContext.sequenceNumber,
            receivedAtNanoseconds: ingressContext.receivedAtNanoseconds,
            senderSentAtMilliseconds: ingressContext.sentAtMilliseconds,
            source: ingressContext.source,
            stage: "live-receive-context"
        ) else {
            return nil
        }
        configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: fromDeviceID,
            logPreservedSession: false
        )
        guard !dropIncomingAudioAfterExpiredBackendTransmitLeaseIfNeeded(
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            transportSequenceNumber: ingressContext.sequenceNumber,
            ingressContext: ingressContext
        ) else {
            return nil
        }
        let applicationState = currentApplicationState()
        let shouldBufferForegroundSystemReceive =
            shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
                for: contactID,
                channelID: channelID,
                incomingAudioTransport: incomingAudioTransport,
                applicationState: applicationState
            )
        let shouldUseForegroundPacketExecutor =
            shouldAdmitForegroundPacketAudioBeforeSystemBootstrap(
                incomingAudioTransport: incomingAudioTransport,
                applicationState: applicationState
            )
        if shouldArmLiveAudioBootstrapOnMainActor(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            applicationState: applicationState,
            recordDiagnostic: !shouldUseForegroundPacketExecutor
        ) {
            guard shouldUseForegroundPacketExecutor else {
                return nil
            }
            startForegroundPacketAudioBootstrapSideEffectsIfNeeded(
                contactID: contactID,
                channelID: channelID,
                incomingAudioTransport: incomingAudioTransport,
                applicationState: applicationState
            )
        }
        let receiveActivationMode: MediaSessionActivationMode =
            shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: applicationState,
                incomingAudioTransport: incomingAudioTransport
            ) ? .systemActivated : .appManaged
        if shouldUseForegroundPacketExecutor {
            prepareForegroundPacketAudioSessionForImmediateAdmission(
                contactID: contactID,
                activationMode: receiveActivationMode
            )
        } else if mediaServices.session() == nil || mediaSessionContactID != contactID {
            await ensureMediaSession(
                for: contactID,
                activationMode: receiveActivationMode,
                startupMode: .playbackOnly
            )
        }
        guard let session = mediaServices.session(),
              mediaSessionContactID == contactID else {
            return nil
        }
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        if selectedContactId == nil {
            selectedContactId = contactID
        }
        let receiveEpoch = expectedReceiveEpoch ?? mediaRuntime.incomingAudioReceiveEpoch(for: contactID)
        let normalIngressPolicy = IncomingAudioIngressConfiguration(
            mediaEncryptionRequired: mediaEncryptionIsRequired(for: contactID),
            mediaEncryptionSession: mediaRuntime.mediaEncryptionSession(for: contactID),
            liveAudioBacklogExpirationNanoseconds: incomingLiveAudioBacklogExpirationNanoseconds(
                for: incomingAudioTransport,
                heldForAppleAudioActivation: false
            ),
            liveAudioSenderClockExpirationMilliseconds: incomingLiveAudioSenderClockExpirationMilliseconds(
                for: incomingAudioTransport,
                heldForAppleAudioActivation: false
            )
        )
        let preAudibleIngressPolicy = shouldBufferForegroundSystemReceive
            ? IncomingAudioIngressConfiguration(
                mediaEncryptionRequired: mediaEncryptionIsRequired(for: contactID),
                mediaEncryptionSession: mediaRuntime.mediaEncryptionSession(for: contactID),
                liveAudioBacklogExpirationNanoseconds: incomingLiveAudioBacklogExpirationNanoseconds(
                    for: incomingAudioTransport,
                    heldForAppleAudioActivation: true
                ),
                liveAudioSenderClockExpirationMilliseconds: incomingLiveAudioSenderClockExpirationMilliseconds(
                    for: incomingAudioTransport,
                    heldForAppleAudioActivation: true
                )
            )
            : nil
        return LiveAudioReceiveContext(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            transport: incomingAudioTransport,
            receiveEpoch: receiveEpoch,
            session: session,
            sessionReceiveEpoch: session.currentRemoteAudioReceiveEpoch(),
            ingressPolicy: normalIngressPolicy,
            preAudibleIngressPolicy: preAudibleIngressPolicy,
            playbackProfile: mediaTransportPolicy(for: incomingAudioTransport).playbackProfile,
            ingressExecutor: incomingAudioIngressExecutor,
            requiresSystemAudioActivationForPlayback: shouldBufferForegroundSystemReceive,
            isSystemAudioActive: { [weak self] in
                await self?.isSystemReceiveAudioActiveForLivePlayback() ?? false
            }
        )
    }

    private func isSystemReceiveAudioActiveForLivePlayback() -> Bool {
        isPTTAudioSessionActive
    }

    private func shouldAdmitForegroundPacketAudioBeforeSystemBootstrap(
        incomingAudioTransport: IncomingAudioPayloadTransport,
        applicationState: UIApplication.State
    ) -> Bool {
        applicationState == .active && incomingAudioTransport.isUnreliablePacketMedia
    }

    private func startForegroundPacketAudioBootstrapSideEffectsIfNeeded(
        contactID: UUID,
        channelID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        applicationState: UIApplication.State
    ) {
        if shouldUseForegroundAppManagedWakePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) {
            startForegroundAppManagedWakePlayback(
                for: contactID,
                channelID: channelID
            )
        }
        guard shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
            for: contactID,
            incomingAudioTransport: incomingAudioTransport,
            applicationState: applicationState
        ) else { return }
        diagnostics.record(
            .media,
            level: .notice,
            message: "Bypassed foreground receive buffer for packet media",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
            ]
        )
    }

    private func prepareForegroundPacketAudioSessionForImmediateAdmission(
        contactID: UUID,
        activationMode: MediaSessionActivationMode
    ) {
        let preparedShell = prepareMediaSessionShellIfNeeded(
            for: contactID,
            reason: "foreground-packet-receive"
        )
        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: activationMode,
            startupMode: .playbackOnly
        )
        guard preparedShell || mediaConnectionState != .connected else { return }
        guard !mediaServices.isStartupInFlight(startupContext) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.ensureMediaSession(
                for: contactID,
                activationMode: activationMode,
                startupMode: .playbackOnly
            )
        }
    }

    private func shouldArmLiveAudioBootstrapOnMainActor(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        applicationState: UIApplication.State,
        recordDiagnostic: Bool = true
    ) -> Bool {
        let alreadyHasPendingWake = pttWakeRuntime.hasPendingWake(for: contactID)
        let shouldArmDeferredBackgroundAudioWakeCandidate =
            !alreadyHasPendingWake
            && shouldBufferDeferredBackgroundAudioAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
        let shouldArmAudioWakeCandidate =
            shouldTreatIncomingSignalAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
            || shouldArmDeferredBackgroundAudioWakeCandidate
        let wakeIsAlreadySystemActivated =
            pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated
        let shouldRepairRemoteParticipant =
            !wakeIsAlreadySystemActivated
            && !shouldSuppressForegroundDirectQuicRemoteParticipant(
                for: contactID,
                applicationState: applicationState
            )
            && (!remoteTransmittingContactIDs.contains(contactID) || shouldArmDeferredBackgroundAudioWakeCandidate)
            && (alreadyHasPendingWake || shouldArmAudioWakeCandidate)
            && shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: applicationState
            )
        guard shouldArmAudioWakeCandidate
              || shouldRepairRemoteParticipant
              || shouldUseForegroundAppManagedWakePlayback(
                for: contactID,
                applicationState: applicationState,
                incomingAudioTransport: incomingAudioTransport
              )
              || shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
                for: contactID,
                incomingAudioTransport: incomingAudioTransport,
                applicationState: applicationState
              )
              || shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: applicationState
              )
        else {
            return false
        }
        if recordDiagnostic {
            diagnostics.record(
                .media,
                message: "Routed incoming live audio through MainActor bootstrap",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "applicationState": String(describing: applicationState),
                ]
            )
        }
        return true
    }

    private func recordLiveAudioFirstPlaybackAccepted(
        _ admittedPacket: IncomingAudioIngressAcceptedPacket,
        packet: LiveAudioReceivePacket
    ) async {
        let ackIdentityPayload = MediaEncryptedAudioPacket.isEncodedPacket(admittedPacket.incomingMediaPayload)
            ? admittedPacket.incomingMediaPayload
            : admittedPacket.audioPayload
        await sendFirstAudioPlaybackStartedAckIfNeeded(
            originalPayload: ackIdentityPayload,
            channelID: packet.channelID,
            fromUserID: packet.fromUserID,
            fromDeviceID: packet.fromDeviceID,
            contactID: packet.contactID,
            incomingAudioTransport: packet.transport
        )
    }

    private func recordLiveAudioReceiveSummary(
        _ summary: LiveAudioReceiveDiagnosticSummary
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        var metadata = [
            "contactId": summary.contactID.uuidString,
            "channelId": summary.channelID,
            "fromDeviceId": summary.fromDeviceID,
            "transport": summary.transport.diagnosticsValue,
            "receiveEpoch": String(summary.receiveEpoch),
            "sampleCount": String(summary.sampleCount),
            "acceptedCount": String(summary.acceptedCount),
            "droppedCount": String(summary.droppedCount),
            "playbackAcceptedCount": String(summary.playbackAcceptedCount),
            "playbackRejectedCount": String(summary.playbackRejectedCount),
            "maxLocalQueueDelayMs": String(summary.maxLocalQueueDelayNanoseconds / 1_000_000),
            "lastLocalQueueDelayMs": String(summary.lastLocalQueueDelayNanoseconds / 1_000_000),
            "freshnessDecision": summary.lastFreshnessDecision,
            "playbackDecision": summary.lastPlaybackDecision,
            "source": "live-audio-receive-executor",
        ]
        if let sequenceNumber = summary.lastSequenceNumber {
            metadata["sequenceNumber"] = String(sequenceNumber)
        }
        let metadataSnapshot = metadata
        scheduleLiveAudioObservability(
            key: "receive-summary:\(summary.contactID.uuidString):\(summary.receiveEpoch)"
        ) { diagnostics in
            diagnostics.record(
                .media,
                message: "Incoming audio ingress summary",
                metadata: metadataSnapshot
            )
        }
        recordPreservedPacketMediaDelayIfNeeded(summary)
    }

    private func recordPreservedPacketMediaDelayIfNeeded(
        _ summary: LiveAudioReceiveDiagnosticSummary
    ) {
        recordPreservedPacketMediaDelayIfNeeded(
            contactID: summary.contactID,
            channelID: summary.channelID,
            fromDeviceID: summary.fromDeviceID,
            transport: summary.transport,
            receiveEpoch: summary.receiveEpoch,
            sequenceNumber: summary.lastSequenceNumber,
            localQueueDelayNanoseconds: summary.lastLocalQueueDelayNanoseconds,
            freshnessDecision: summary.lastFreshnessDecision,
            source: "live-audio-receive-executor"
        )
    }

    private func recordPreservedPacketMediaDelayIfNeeded(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        transport: IncomingAudioPayloadTransport,
        receiveEpoch: UInt64?,
        sequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        freshnessDecision: String,
        source: String
    ) {
        guard transport.isUnreliablePacketMedia else { return }
        guard freshnessDecision == "accepted" else { return }
        let thresholdNanoseconds = incomingLiveAudioBacklogExpirationNanoseconds(
            for: transport,
            heldForAppleAudioActivation: false
        )
        guard thresholdNanoseconds > 0,
              localQueueDelayNanoseconds >= thresholdNanoseconds else {
            return
        }
        let sequenceNumberValue = sequenceNumber.map(String.init) ?? "none"
        let contract = DiagnosticsContracts.Media.incomingAudioQueueDelay(
            contactID: contactID,
            channelID: channelID,
            attemptID: source,
            incomingTransport: transport.diagnosticsValue,
            sequenceNumber: sequenceNumberValue,
            localQueueDelayMilliseconds: localQueueDelayNanoseconds / 1_000_000,
            senderClockAgeMilliseconds: "none",
            thresholdMilliseconds: thresholdNanoseconds / 1_000_000,
            action: "accepted-expired-live-backlog"
        )
        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": channelID,
            "fromDeviceId": fromDeviceID,
            "incomingTransport": transport.diagnosticsValue,
            "sequenceNumber": sequenceNumberValue,
            "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
            "thresholdMs": String(thresholdNanoseconds / 1_000_000),
            "action": "accepted-expired-live-backlog",
            "source": source,
        ]
        if let receiveEpoch {
            metadata["receiveEpoch"] = String(receiveEpoch)
        }
        let metadataSnapshot = metadata
        scheduleLiveAudioContractObservability { diagnostics in
            diagnostics.recordContractViolation(contract, metadata: metadataSnapshot)
        }
    }

    private func scheduleLiveAudioObservability(
        key: String,
        _ operation: @escaping @Sendable (DiagnosticsStore) -> Void
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let diagnostics = diagnostics
        mediaRuntime.voiceObservabilityQueue.enqueue(
            workClass: .observability,
            dropPolicy: .aggregateByKey(key)
        ) {
            operation(diagnostics)
        }
    }

    private func scheduleLiveAudioMustRecordObservability(
        _ operation: @escaping @Sendable (DiagnosticsStore) -> Void
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let diagnostics = diagnostics
        mediaRuntime.voiceObservabilityQueue.enqueue(
            workClass: .observability,
            dropPolicy: .expireAtDeadline,
            expiringAtNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ) {
            operation(diagnostics)
        }
    }

    private func scheduleLiveAudioContractObservability(
        _ operation: @escaping @Sendable (DiagnosticsStore) -> Void
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let diagnostics = diagnostics
        mediaRuntime.voiceObservabilityQueue.enqueue(
            workClass: .observability,
            dropPolicy: .mustRun
        ) {
            operation(diagnostics)
        }
    }

    private func recordLiveAudioReceiveDropDiagnostic(
        _ drop: LiveAudioReceiveDropDiagnostic
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        var metadata = [
            "contactId": drop.contactID.uuidString,
            "channelId": drop.channelID,
            "fromDeviceId": drop.fromDeviceID,
            "incomingTransport": drop.transport.diagnosticsValue,
            "sequenceNumber": drop.sequenceNumber.map(String.init) ?? "none",
            "localQueueDelayMs": String(drop.localQueueDelayNanoseconds / 1_000_000),
            "receiveEpoch": String(drop.receiveEpoch),
            "reason": drop.reason,
            "action": drop.freshnessDecision,
            "stage": "live-audio-receive-executor",
        ]
        if let thresholdNanoseconds = drop.thresholdNanoseconds {
            metadata["thresholdMs"] = String(thresholdNanoseconds / 1_000_000)
        }
        if let senderSentAtMilliseconds = drop.senderSentAtMilliseconds {
            metadata["senderClockAgeMs"] = String(
                Int64(Date().timeIntervalSince1970 * 1_000) - senderSentAtMilliseconds
            )
        }
        let contractMetadataSnapshot = metadata
        if drop.shouldRecordContract {
            let contract = DiagnosticsContracts.Media.incomingAudioQueueDelay(
                contactID: drop.contactID,
                channelID: drop.channelID,
                attemptID: "live-audio-receive-executor",
                incomingTransport: drop.transport.diagnosticsValue,
                sequenceNumber: drop.sequenceNumber.map(String.init) ?? "none",
                localQueueDelayMilliseconds: drop.localQueueDelayNanoseconds / 1_000_000,
                senderClockAgeMilliseconds: metadata["senderClockAgeMs"] ?? "none",
                thresholdMilliseconds: (drop.thresholdNanoseconds ?? 0) / 1_000_000,
                action: drop.freshnessDecision
            )
            scheduleLiveAudioContractObservability { diagnostics in
                diagnostics.recordContractViolation(contract, metadata: contractMetadataSnapshot)
            }
        }
        if drop.shouldRecordSuppression {
            metadata["reason"] = "budget-exhausted"
            let suppressionMetadataSnapshot = metadata
            scheduleLiveAudioObservability(
                key: "receive-drop-suppression:\(drop.contactID.uuidString):\(drop.receiveEpoch)"
            ) { diagnostics in
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Suppressing repetitive incoming audio drop diagnostics",
                    metadata: suppressionMetadataSnapshot
                )
            }
        } else {
            let dropMetadataSnapshot = metadata
            scheduleLiveAudioMustRecordObservability { diagnostics in
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Dropped incoming audio frame before playback",
                    metadata: dropMetadataSnapshot
                )
            }
        }
    }

    private func recordLiveAudioReceivePlaybackReadinessDiagnostic(
        _ diagnostic: LiveAudioReceivePlaybackReadinessDiagnostic
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let metadata = [
            "contactId": diagnostic.contactID.uuidString,
            "channelId": diagnostic.channelID,
            "fromDeviceId": diagnostic.fromDeviceID,
            "incomingTransport": diagnostic.transport.diagnosticsValue,
            "receiveEpoch": String(diagnostic.receiveEpoch),
            "readiness": diagnostic.readiness.diagnosticsValue,
            "pendingPacketCount": String(diagnostic.pendingPacketCount),
            "maxPendingAgeMs": String(diagnostic.maxPendingAgeNanoseconds / 1_000_000),
            "action": diagnostic.action,
            "source": "live-audio-receive-executor",
        ]
        scheduleLiveAudioObservability(
            key: "receive-readiness:\(diagnostic.contactID.uuidString):\(diagnostic.receiveEpoch)"
        ) { diagnostics in
            diagnostics.record(
                .media,
                level: diagnostic.action == "held-until-playback-ready" ? .notice : .info,
                message: "Held live audio until receive playback is ready",
                metadata: metadata
            )
        }
    }

    private func scheduleIncomingAudioPlaybackCompletion(
        audioPayload: String,
        incomingMediaPayload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        receiveEpoch: UInt64,
        localQueueDelayNanoseconds: UInt64,
        receivedAtNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        ingressSource: String
    ) {
        let transportPolicy = mediaTransportPolicy(for: incomingAudioTransport)
        guard let session = mediaServices.session() else {
            Task { [weak self] in
                await self?.completeIncomingAudioPlayback(
                    playbackAccepted: false,
                    incomingMediaPayload: incomingMediaPayload,
                    audioPayload: audioPayload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: fromDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    ingressSource: ingressSource
                )
            }
            return
        }

        let sessionReceiveEpoch = session.currentRemoteAudioReceiveEpoch()
        let playbackDeadlineNanoseconds = incomingAudioAsyncPlaybackDeadlineNanoseconds(
            receivedAtNanoseconds: receivedAtNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            incomingAudioTransport: incomingAudioTransport
        )
        let playbackQueueExpirationNanoseconds = playbackDeadlineNanoseconds
        let sessionPlaybackDeadlineNanoseconds = incomingAudioTransport.isUnreliablePacketMedia
            ? nil
            : playbackDeadlineNanoseconds
        mediaRuntime.incomingAudioPlaybackQueue.enqueue(
            expiringAtNanoseconds: playbackQueueExpirationNanoseconds,
            expiresRunningHandler: false,
            onExpired: { [weak self] in
                guard let self,
                      let dropReason = await self.incomingAudioAsyncPlaybackDropReason(
                        receivedAtNanoseconds: receivedAtNanoseconds,
                        senderSentAtMilliseconds: senderSentAtMilliseconds,
                        incomingAudioTransport: incomingAudioTransport
                      )
                else { return }
                await self.recordExpiredAsyncIncomingAudioPlaybackDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    receivedAtNanoseconds: receivedAtNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    dropReason: dropReason,
                    ingressSource: ingressSource,
                    stage: "queue-expired"
                )
            }
        ) { [weak self] in
            guard await self?.isIncomingAudioPlaybackCompletionCurrent(
                contactID: contactID,
                expectedReceiveEpoch: receiveEpoch,
                session: session
            ) == true else {
                await self?.recordStaleAsyncIncomingAudioPlaybackDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    expectedReceiveEpoch: receiveEpoch,
                    ingressSource: ingressSource,
                    stage: "before-playback"
                )
                return
            }
            if let dropReason = await self?.incomingAudioAsyncPlaybackDropReason(
                   receivedAtNanoseconds: receivedAtNanoseconds,
                   senderSentAtMilliseconds: senderSentAtMilliseconds,
                   incomingAudioTransport: incomingAudioTransport
               ) {
                await self?.recordExpiredAsyncIncomingAudioPlaybackDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    receivedAtNanoseconds: receivedAtNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    dropReason: dropReason,
                    ingressSource: ingressSource,
                    stage: "before-playback"
                )
                return
            }
            let playbackAccepted = await session.receiveRemoteAudioChunk(
                audioPayload,
                playbackProfile: transportPolicy.playbackProfile,
                expectedReceiveEpoch: sessionReceiveEpoch,
                playbackDeadlineNanoseconds: sessionPlaybackDeadlineNanoseconds
            )
            guard await self?.isIncomingAudioPlaybackCompletionCurrent(
                contactID: contactID,
                expectedReceiveEpoch: receiveEpoch,
                session: session
            ) == true else {
                await self?.recordStaleAsyncIncomingAudioPlaybackDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    expectedReceiveEpoch: receiveEpoch,
                    ingressSource: ingressSource,
                    stage: "after-playback"
                )
                return
            }
            if !(incomingAudioTransport.isUnreliablePacketMedia && playbackAccepted),
               let dropReason = await self?.incomingAudioAsyncPlaybackDropReason(
                   receivedAtNanoseconds: receivedAtNanoseconds,
                   senderSentAtMilliseconds: senderSentAtMilliseconds,
                   incomingAudioTransport: incomingAudioTransport
               ) {
                await self?.recordExpiredAsyncIncomingAudioPlaybackDrop(
                    contactID: contactID,
                    channelID: channelID,
                    fromDeviceID: fromDeviceID,
                    incomingAudioTransport: incomingAudioTransport,
                    playbackSequenceNumber: playbackSequenceNumber,
                    receivedAtNanoseconds: receivedAtNanoseconds,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    dropReason: dropReason,
                    ingressSource: ingressSource,
                    stage: "after-playback"
                )
                return
            }
            await self?.completeIncomingAudioPlayback(
                playbackAccepted: playbackAccepted,
                incomingMediaPayload: incomingMediaPayload,
                audioPayload: audioPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport,
                playbackSequenceNumber: playbackSequenceNumber,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                ingressSource: ingressSource
            )
        }
    }

    private func isIncomingAudioPlaybackCompletionCurrent(
        contactID: UUID,
        expectedReceiveEpoch: UInt64,
        session: MediaSession
    ) -> Bool {
        guard mediaServices.session() === session else { return false }
        guard mediaSessionContactID == contactID else { return false }
        return mediaRuntime.incomingAudioReceiveEpoch(for: contactID) == expectedReceiveEpoch
    }

    private func incomingAudioAsyncPlaybackDeadlineNanoseconds(
        receivedAtNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> UInt64? {
        var deadlineNanoseconds: UInt64?
        let liveBacklogExpirationNanoseconds = incomingLiveAudioBacklogExpirationNanoseconds(
            for: incomingAudioTransport
        )
        if liveBacklogExpirationNanoseconds > 0 {
            deadlineNanoseconds = saturatingNanosecondDeadline(
                base: receivedAtNanoseconds,
                interval: liveBacklogExpirationNanoseconds
            )
        }

        guard let senderSentAtMilliseconds else { return deadlineNanoseconds }
        let senderClockExpirationMilliseconds = incomingLiveAudioSenderClockExpirationMilliseconds(
            for: incomingAudioTransport
        )
        guard senderClockExpirationMilliseconds > 0 else { return deadlineNanoseconds }
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let (senderDeadlineMilliseconds, overflow) = senderSentAtMilliseconds.addingReportingOverflow(
            senderClockExpirationMilliseconds
        )
        guard !overflow else { return deadlineNanoseconds }
        let senderDeadlineNanoseconds: UInt64
        if senderDeadlineMilliseconds <= nowMilliseconds {
            senderDeadlineNanoseconds = nowNanoseconds
        } else {
            let remainingMilliseconds = UInt64(senderDeadlineMilliseconds - nowMilliseconds)
            let (remainingNanoseconds, multipliedOverflow) =
                remainingMilliseconds.multipliedReportingOverflow(by: 1_000_000)
            senderDeadlineNanoseconds = multipliedOverflow
                ? UInt64.max
                : saturatingNanosecondDeadline(base: nowNanoseconds, interval: remainingNanoseconds)
        }
        return deadlineNanoseconds.map { min($0, senderDeadlineNanoseconds) } ?? senderDeadlineNanoseconds
    }

    private func saturatingNanosecondDeadline(base: UInt64, interval: UInt64) -> UInt64 {
        let (deadline, overflow) = base.addingReportingOverflow(interval)
        return overflow ? UInt64.max : deadline
    }

    private func incomingAudioAsyncPlaybackDropReason(
        receivedAtNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> IncomingAudioPlaybackDropReason? {
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let localQueueDelayNanoseconds =
            nowNanoseconds >= receivedAtNanoseconds
            ? nowNanoseconds - receivedAtNanoseconds
            : 0
        let liveBacklogExpirationNanoseconds = incomingLiveAudioBacklogExpirationNanoseconds(
            for: incomingAudioTransport
        )
        if liveBacklogExpirationNanoseconds > 0,
           localQueueDelayNanoseconds >= liveBacklogExpirationNanoseconds {
            return .expiredLiveBacklog(
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                thresholdNanoseconds: liveBacklogExpirationNanoseconds
            )
        }

        guard let senderSentAtMilliseconds else { return nil }
        let senderClockExpirationMilliseconds = incomingLiveAudioSenderClockExpirationMilliseconds(
            for: incomingAudioTransport
        )
        guard senderClockExpirationMilliseconds > 0 else { return nil }
        let senderClockAgeMilliseconds =
            Int64(Date().timeIntervalSince1970 * 1_000) - senderSentAtMilliseconds
        guard senderClockAgeMilliseconds >= senderClockExpirationMilliseconds else { return nil }
        return .expiredSenderClockAge(
            senderClockAgeMilliseconds: senderClockAgeMilliseconds,
            thresholdMilliseconds: senderClockExpirationMilliseconds
        )
    }

    private func recordExpiredAsyncIncomingAudioPlaybackDrop(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        receivedAtNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        dropReason: IncomingAudioPlaybackDropReason,
        ingressSource: String,
        stage: String
    ) {
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let localQueueDelayNanoseconds =
            nowNanoseconds >= receivedAtNanoseconds
            ? nowNanoseconds - receivedAtNanoseconds
            : 0
        let freshnessDecision = incomingAudioPlaybackDropDecisionValue(.drop(dropReason))
        recordIncomingAudioIngressSummaryIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: playbackSequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            freshnessDecision: freshnessDecision,
            playbackAccepted: false,
            source: ingressSource
        )

        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": channelID,
            "fromDeviceId": fromDeviceID,
            "incomingTransport": incomingAudioTransport.diagnosticsValue,
            "sequenceNumber": playbackSequenceNumber.map(String.init) ?? "none",
            "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
            "stage": stage,
        ]
        var action: String?
        switch dropReason {
        case .expiredLiveBacklog(let expiredLocalQueueDelayNanoseconds, let thresholdNanoseconds):
            action = "dropped-expired-live-backlog"
            metadata["reason"] = "expired-live-backlog"
            metadata["localQueueDelayMs"] = String(expiredLocalQueueDelayNanoseconds / 1_000_000)
            metadata["thresholdMs"] = String(thresholdNanoseconds / 1_000_000)
            if TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() {
                diagnostics.recordContractViolation(
                    DiagnosticsContracts.Media.incomingAudioQueueDelay(
                        contactID: contactID,
                        channelID: channelID,
                        attemptID: ingressSource,
                        incomingTransport: incomingAudioTransport.diagnosticsValue,
                        sequenceNumber: playbackSequenceNumber.map(String.init) ?? "none",
                        localQueueDelayMilliseconds: expiredLocalQueueDelayNanoseconds / 1_000_000,
                        senderClockAgeMilliseconds: senderSentAtMilliseconds.map {
                            String(Int64(Date().timeIntervalSince1970 * 1_000) - $0)
                        } ?? "none",
                        thresholdMilliseconds: thresholdNanoseconds / 1_000_000,
                        action: "dropped-expired-live-backlog"
                    ),
                    metadata: metadata
                )
            }
            handleExpiredLiveAudioDrop(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                incomingAudioTransport: incomingAudioTransport,
                reason: "expired-live-backlog"
            )

        case .expiredSenderClockAge(let senderClockAgeMilliseconds, let thresholdMilliseconds):
            action = "dropped-expired-sender-clock-age"
            metadata["reason"] = "expired-sender-clock-age"
            metadata["senderClockAgeMs"] = String(senderClockAgeMilliseconds)
            metadata["thresholdMs"] = String(thresholdMilliseconds)
            if TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() {
                diagnostics.recordContractViolation(
                    DiagnosticsContracts.Media.incomingAudioQueueDelay(
                        contactID: contactID,
                        channelID: channelID,
                        attemptID: ingressSource,
                        incomingTransport: incomingAudioTransport.diagnosticsValue,
                        sequenceNumber: playbackSequenceNumber.map(String.init) ?? "none",
                        localQueueDelayMilliseconds: localQueueDelayNanoseconds / 1_000_000,
                        senderClockAgeMilliseconds: String(senderClockAgeMilliseconds),
                        thresholdMilliseconds: UInt64(max(0, thresholdMilliseconds)),
                        action: "dropped-expired-sender-clock-age"
                    ),
                    metadata: metadata
                )
            }
            handleExpiredLiveAudioDrop(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                incomingAudioTransport: incomingAudioTransport,
                reason: "expired-sender-clock-age"
            )

        case .duplicateOrStaleSequence, .orderedBacklog, .duplicatePlaintextStandby, .standbyContinuity:
            break
        }
        if let action {
            metadata["action"] = action
        }
        if TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped asynchronous incoming audio playback after freshness deadline",
                metadata: metadata
            )
        }
    }

    private func recordStaleAsyncIncomingAudioPlaybackDrop(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        expectedReceiveEpoch: UInt64,
        ingressSource: String,
        stage: String
    ) {
        recordIncomingAudioIngressSummaryIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: playbackSequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            freshnessDecision: "dropped-stale-receive-epoch",
            playbackAccepted: false,
            source: ingressSource
        )
        if TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped asynchronous incoming audio playback after receive epoch changed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "incomingTransport": incomingAudioTransport.diagnosticsValue,
                    "sequenceNumber": playbackSequenceNumber.map(String.init) ?? "none",
                    "expectedReceiveEpoch": String(expectedReceiveEpoch),
                    "currentReceiveEpoch": String(mediaRuntime.incomingAudioReceiveEpoch(for: contactID)),
                    "stage": stage,
                ]
            )
        }
    }

    private func dropIncomingAudioAfterExpiredBackendTransmitLeaseIfNeeded(
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        transportSequenceNumber: UInt64?,
        ingressContext: IncomingAudioIngressContext?
    ) -> Bool {
        guard selectedPeerTransmitLeaseExpired(for: contactID) else { return false }

        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let receivedAtNanoseconds = ingressContext?.receivedAtNanoseconds ?? nowNanoseconds
        let localQueueDelayNanoseconds =
            nowNanoseconds >= receivedAtNanoseconds
            ? nowNanoseconds - receivedAtNanoseconds
            : 0
        let sequenceNumber = transportSequenceNumber ?? ingressContext?.sequenceNumber
        recordIncomingAudioIngressSummaryIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: sequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: ingressContext?.sentAtMilliseconds,
            freshnessDecision: "dropped-expired-backend-transmit-lease",
            playbackAccepted: false,
            source: ingressContext?.source ?? "incoming-audio"
        )
        let repaired = repairExpiredRemoteTransmitLeaseIfNeeded(contactID: contactID)
        diagnostics.record(
            .media,
            level: .notice,
            message: "Dropped incoming audio after expired backend transmit lease",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "sequenceNumber": sequenceNumber.map(String.init) ?? "none",
                "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                "repairTriggered": String(repaired),
            ]
        )
        return true
    }

    private func dropIncomingAudioAfterCancelledTransportDeliveryIfNeeded(
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        sequenceNumber: UInt64?,
        receivedAtNanoseconds: UInt64?,
        senderSentAtMilliseconds: Int64?,
        source: String,
        stage: String
    ) -> Bool {
        guard Task.isCancelled else { return false }

        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        let effectiveReceivedAtNanoseconds = receivedAtNanoseconds ?? nowNanoseconds
        let localQueueDelayNanoseconds =
            nowNanoseconds >= effectiveReceivedAtNanoseconds
            ? nowNanoseconds - effectiveReceivedAtNanoseconds
            : 0
        recordIncomingAudioIngressSummaryIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: sequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            freshnessDecision: "dropped-cancelled-delivery",
            playbackAccepted: false,
            source: source
        )
        diagnostics.record(
            .media,
            level: .notice,
            message: "Dropped incoming audio after transport delivery was cancelled",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "incomingTransport": incomingAudioTransport.diagnosticsValue,
                "sequenceNumber": sequenceNumber.map(String.init) ?? "none",
                "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                "source": source,
                "stage": stage,
            ]
        )
        return true
    }

    func playBufferedForegroundSystemReceiveAudioChunks(
        _ bufferedAudioChunks: [BufferedForegroundReceiveAudioChunk],
        contactID: UUID
    ) async {
        for bufferedAudioChunk in bufferedAudioChunks {
            _ = recordAcceptedIncomingAudioBookkeeping(
                incomingMediaPayload: bufferedAudioChunk.incomingMediaPayload,
                audioPayload: bufferedAudioChunk.payload,
                channelID: bufferedAudioChunk.channelID,
                fromDeviceID: bufferedAudioChunk.fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: bufferedAudioChunk.transport,
                playbackSequenceNumber: bufferedAudioChunk.playbackSequenceNumber,
                receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                frameDurationNanoseconds: bufferedAudioChunk.frameDurationNanoseconds
            )
            let playbackAccepted = await receiveRemoteAudioChunk(
                bufferedAudioChunk.payload,
                incomingAudioTransport: bufferedAudioChunk.transport
            )
            await completeIncomingAudioPlayback(
                playbackAccepted: playbackAccepted,
                incomingMediaPayload: bufferedAudioChunk.incomingMediaPayload,
                audioPayload: bufferedAudioChunk.payload,
                channelID: bufferedAudioChunk.channelID,
                fromUserID: bufferedAudioChunk.fromUserID,
                fromDeviceID: bufferedAudioChunk.fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: bufferedAudioChunk.transport,
                playbackSequenceNumber: bufferedAudioChunk.playbackSequenceNumber,
                localQueueDelayNanoseconds: bufferedAudioChunk.localQueueDelayNanoseconds,
                senderSentAtMilliseconds: bufferedAudioChunk.senderSentAtMilliseconds,
                ingressSource: bufferedAudioChunk.ingressSource
            )
        }
    }

    private func shouldUseImmediateIncomingAudioPlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard mediaServices.session() != nil else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard !shouldUseForegroundAppManagedWakePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) else { return false }
        guard !shouldBufferForegroundSystemReceiveAudioUntilPTTActivation(
            for: contactID,
            incomingAudioTransport: incomingAudioTransport,
            applicationState: applicationState
        ) else { return false }
        return true
    }

    @discardableResult
    private func recordAcceptedIncomingAudioBookkeeping(
        incomingMediaPayload: String,
        audioPayload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        receivedAtNanoseconds: UInt64,
        frameDurationNanoseconds: UInt64?
    ) -> UInt64 {
        syncEngineRemoteAudioReceived(
            originalPayload: incomingMediaPayload,
            openedPayload: audioPayload,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport,
            source: "incoming-\(incomingAudioTransport.diagnosticsValue)",
            receivedAtTick: receivedAtNanoseconds / 1_000_000,
            durationTicks: max(1, (frameDurationNanoseconds ?? 20_000_000) / 1_000_000)
        )
        recordIncomingAudioStandbyIngressIfNeeded(
            contactID: contactID,
            channelID: channelID,
            incomingAudioTransport: incomingAudioTransport
        )
        if let playbackSequenceNumber {
            recordIncomingAudioSequenceContractIfNeeded(
                contactID: contactID,
                channelID: channelID,
                incomingAudioTransport: incomingAudioTransport,
                sequenceNumber: playbackSequenceNumber
            )
        }
        _ = recordIncomingAudioContinuityContractIfNeeded(
            contactID: contactID,
            channelID: channelID,
            incomingAudioTransport: incomingAudioTransport,
            fromDeviceID: fromDeviceID,
            nowNanoseconds: receivedAtNanoseconds
        )
        if incomingAudioTransport == .directQuic {
            mediaRuntime.clearDirectQuicStalePlaybackDrops(for: contactID)
        }
        return mediaRuntime.incomingAudioReceiveEpoch(for: contactID)
    }

    func incomingLiveAudioSenderClockExpirationMilliseconds(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> Int64 {
        switch incomingAudioTransport {
        case .directQuic:
            return Int64(directQuicIncomingAudioLiveBacklogDropNanoseconds / 1_000_000)
        case .mediaRelayPacket:
            return Int64(mediaRelayPacketIncomingAudioLiveBacklogDropNanoseconds / 1_000_000)
        case .mediaRelayTcp:
            return 3_500
        case .relayWebSocket:
            return 6_000
        }
    }

    func incomingLiveAudioSenderClockExpirationMilliseconds(
        for incomingAudioTransport: IncomingAudioPayloadTransport,
        heldForAppleAudioActivation _: Bool
    ) -> Int64 {
        incomingLiveAudioSenderClockExpirationMilliseconds(
            for: incomingAudioTransport
        )
    }

    private func completeIncomingAudioPlayback(
        playbackAccepted: Bool,
        incomingMediaPayload: String,
        audioPayload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        playbackSequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        ingressSource: String
    ) async {
        if playbackAccepted {
            let ackIdentityPayload = MediaEncryptedAudioPacket.isEncodedPacket(incomingMediaPayload)
                ? incomingMediaPayload
                : audioPayload
            await sendFirstAudioPlaybackStartedAckIfNeeded(
                originalPayload: ackIdentityPayload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport
            )
        } else {
            recordFirstPlaybackAckSkipped(
                incomingMediaPayload,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport
            )
        }
        recordIncomingAudioChunkDiagnosticIfNeeded(
            originalPayload: incomingMediaPayload,
            openedPayload: audioPayload,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport
        )
        recordIncomingAudioIngressSummaryIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            sequenceNumber: playbackSequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            senderSentAtMilliseconds: senderSentAtMilliseconds,
            freshnessDecision: "accepted",
            playbackAccepted: playbackAccepted,
            source: ingressSource
        )
    }

    private func incomingAudioPlaybackDropDecisionValue(
        _ decision: IncomingAudioPlaybackDecision
    ) -> String {
        switch decision.dropReason {
        case .duplicateOrStaleSequence:
            return "dropped-duplicate-or-stale-sequence"
        case .orderedBacklog:
            return "dropped-ordered-backlog"
        case .expiredLiveBacklog:
            return "dropped-expired-live-backlog"
        case .expiredSenderClockAge:
            return "dropped-expired-sender-clock-age"
        case .duplicatePlaintextStandby:
            return "dropped-duplicate-plaintext-standby"
        case .standbyContinuity:
            return "dropped-standby-continuity"
        case nil:
            return "dropped-unknown"
        }
    }

    private func handleDirectQuicStalePlaybackDropIfNeeded(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        dropReason: String,
        sequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64
    ) {
        guard incomingAudioTransport == .directQuic,
              dropReason == "duplicate-or-stale-sequence",
              receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .receivingAudio
        else { return }

        let dropCount = mediaRuntime.recordDirectQuicStalePlaybackDrop(for: contactID)
        let threshold = max(1, directQuicStalePlaybackDropFallbackThreshold)
        guard dropCount >= threshold else { return }

        if retireDirectQuicReceivePathAfterLiveAudioFreshnessFailureIfFallbackReady(
            contactID: contactID,
            reason: "duplicate-or-stale-sequence",
            sequenceNumber: sequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds
        ) {
            mediaRuntime.clearDirectQuicStalePlaybackDrops(for: contactID)
            diagnostics.record(
                .media,
                level: .notice,
                message: "Direct QUIC stale playback drop threshold reached; falling back to relay",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "directQuicSequenceNumber": sequenceNumber.map(String.init) ?? "none",
                    "dropCount": String(dropCount),
                    "threshold": String(threshold),
                ]
            )
        }
    }

    private func handleExpiredLiveAudioDrop(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        reason: String
    ) {
        guard shouldStopRemoteReceiveAfterExpiredLiveAudioDrop(for: incomingAudioTransport) else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped expired packet media without stopping remote receive",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "reason": reason,
                ]
            )
            return
        }
        forceStopRemoteReceiveAfterExpiredLiveAudio(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            incomingAudioTransport: incomingAudioTransport,
            reason: reason
        )
    }

    private func shouldStopRemoteReceiveAfterExpiredLiveAudioDrop(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> Bool {
        !incomingAudioTransport.isUnreliablePacketMedia
    }

    func forceStopRemoteReceiveAfterExpiredLiveAudio(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        reason: String,
        diagnosticsMessage: String = "Forced remote receive stop after expired live audio",
        additionalMetadata: [String: String] = [:]
    ) {
        guard receiveExecutionCoordinator
            .state
            .remoteActivityByContactID[contactID] != nil
        else { return }
        mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
        resetLiveAudioReceiveRuntime(for: contactID, reason: "expired-live-audio:\(reason)")
        mediaRuntime.clearIncomingAudioContinuity(for: contactID)
        mediaRuntime.clearIncomingAudioSequence(for: contactID)
        switch incomingAudioTransport {
        case .directQuic:
            mediaRuntime.directQuicProbeController?.resetIncomingAudioPayloadQueue(
                reason: "expired-live-audio:\(reason)"
            )
        case .mediaRelayPacket:
            mediaRuntime.mediaRelayClient?.resetIncomingAudioPayloadQueue(
                reason: "expired-live-audio:\(reason)"
            )
        case .mediaRelayTcp, .relayWebSocket:
            break
        }
        mediaServices.session()?.beginRemoteAudioReceiveEpoch()
        clearFirstAudioPlaybackAckSentState(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: fromDeviceID
        )
        syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: fromDeviceID,
            source: "expired-live-audio:\(reason)"
        )
        clearRemoteAudioActivity(for: contactID)
        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": channelID,
            "fromDeviceId": fromDeviceID,
            "transport": incomingAudioTransport.diagnosticsValue,
            "reason": reason,
        ]
        metadata.merge(additionalMetadata) { _, new in new }
        diagnostics.record(
            .media,
            level: .notice,
            message: diagnosticsMessage,
            metadata: metadata
        )
    }

    func recordIncomingAudioIngressSummaryIfNeeded(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        sequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        senderSentAtMilliseconds: Int64?,
        freshnessDecision: String,
        playbackAccepted: Bool,
        source: String
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        guard let summary = mediaRuntime.observeIncomingAudioIngress(
            contactID: contactID,
            transport: incomingAudioTransport,
            sequenceNumber: sequenceNumber,
            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
            freshnessDecision: freshnessDecision,
            playbackAccepted: playbackAccepted
        ) else { return }
        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": channelID,
            "fromDeviceId": fromDeviceID,
            "transport": summary.transport.diagnosticsValue,
            "sampleCount": String(summary.sampleCount),
            "acceptedCount": String(summary.acceptedCount),
            "droppedCount": String(summary.droppedCount),
            "playbackAcceptedCount": String(summary.playbackAcceptedCount),
            "playbackRejectedCount": String(summary.playbackRejectedCount),
            "maxLocalQueueDelayMs": String(summary.maxLocalQueueDelayNanoseconds / 1_000_000),
            "lastLocalQueueDelayMs": String(summary.lastLocalQueueDelayNanoseconds / 1_000_000),
            "freshnessDecision": summary.lastFreshnessDecision,
            "playbackDecision": summary.lastPlaybackDecision,
            "source": source,
        ]
        if let lastSequenceNumber = summary.lastSequenceNumber {
            metadata["sequenceNumber"] = String(lastSequenceNumber)
        }
        if let senderSentAtMilliseconds {
            metadata["senderClockAgeMs"] = String(
                Int64(Date().timeIntervalSince1970 * 1_000) - senderSentAtMilliseconds
            )
        }
        diagnostics.record(
            .media,
            message: "Incoming audio ingress summary",
            metadata: metadata
        )
        recordPreservedPacketMediaDelayIfNeeded(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            transport: summary.transport,
            receiveEpoch: nil,
            sequenceNumber: summary.lastSequenceNumber,
            localQueueDelayNanoseconds: summary.lastLocalQueueDelayNanoseconds,
            freshnessDecision: summary.lastFreshnessDecision,
            source: source
        )
    }

    func recordFirstPlaybackAckSkipped(
        _ originalPayload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) {
        diagnostics.record(
            .media,
            level: .notice,
            message: "Skipped first audio playback ACK because playback was not accepted",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "transport": incomingAudioTransport.diagnosticsValue,
                "transportDigest": AudioChunkPayloadCodec.transportDigest(originalPayload),
            ]
        )
    }

    func deferIncomingEncryptedAudioPayloadUntilMediaEncryptionReady(
        _ payload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        ingressContext: IncomingAudioIngressContext?
    ) {
        let queuedCount = mediaRuntime.enqueuePendingEncryptedAudioPayload(
            PendingEncryptedAudioPayload(
                payload: payload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                transport: incomingAudioTransport,
                ingressContext: ingressContext,
                receivedAt: Date()
            ),
            for: contactID,
            maxCount: encryptedAudioRecoveryMaxBufferedPayloads
        )
        diagnostics.record(
            .media,
            message: "Buffered encrypted media payload until E2EE session is configured",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "transport": String(describing: incomingAudioTransport),
                "queuedPayloadCount": String(queuedCount),
            ]
        )

        guard !mediaRuntime.hasEncryptedAudioRecoveryTask(for: contactID) else {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.recoverPendingEncryptedAudioPayloadsIfPossible(for: contactID)
        }
        mediaRuntime.replaceEncryptedAudioRecoveryTask(for: contactID, with: task)
    }

    func recoverPendingEncryptedAudioPayloadsIfPossible(for contactID: UUID) async {
        defer {
            mediaRuntime.clearEncryptedAudioRecoveryTask(for: contactID)
        }

        for attempt in 1...encryptedAudioRecoveryAttempts {
            guard !Task.isCancelled else { return }

            let pending = mediaRuntime.pendingEncryptedAudioPayloads(for: contactID)
            guard let first = pending.first else { return }

            await refreshChannelState(for: contactID)
            configureMediaEncryptionSessionIfPossible(
                contactID: contactID,
                channelID: first.channelID,
                peerDeviceID: first.fromDeviceID
            )

            if !shouldDeferIncomingEncryptedMediaUntilSessionReady(
                first.payload,
                channelID: first.channelID,
                fromDeviceID: first.fromDeviceID,
                contactID: contactID
            ) {
                diagnostics.record(
                    .media,
                    message: "Recovered media E2EE session; draining buffered encrypted audio",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": first.channelID,
                        "fromDeviceId": first.fromDeviceID,
                        "attempt": String(attempt),
                        "payloadCount": String(pending.count),
                    ]
                )
                let pending = mediaRuntime.drainPendingEncryptedAudioPayloads(for: contactID)
                mediaRuntime.clearEncryptedAudioRecoveryTask(for: contactID)
                for buffered in pending {
                    await handleIncomingAudioPayload(
                        buffered.payload,
                        channelID: buffered.channelID,
                        fromUserID: buffered.fromUserID,
                        fromDeviceID: buffered.fromDeviceID,
                        contactID: contactID,
                        incomingAudioTransport: buffered.transport,
                        ingressContext: buffered.ingressContext
                    )
                }
                continue
            }

            try? await Task.sleep(nanoseconds: encryptedAudioRecoveryRetryNanoseconds)
        }

        let droppedCount = mediaRuntime.discardPendingEncryptedAudioPayloads(for: contactID)
        diagnostics.record(
            .media,
            level: .error,
            message: "Dropped buffered encrypted media payloads because E2EE session did not recover",
            metadata: [
                "contactId": contactID.uuidString,
                "droppedPayloadCount": String(droppedCount),
            ]
        )
    }

    private func recordIncomingAudioChunkDiagnosticIfNeeded(
        originalPayload: String,
        openedPayload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) {
        guard TurboAudioDiagnosticsDebugOverride.isLiveAudioDiagnosticsEnabled() else { return }
        let detailedReportLimit = incomingAudioDiagnosticDetailedReportLimit()
        switch mediaRuntime.consumeIncomingRelayAudioDiagnosticDisposition(
            for: contactID,
            detailedReportLimit: detailedReportLimit
        ) {
        case .detailed:
            let diagnostics = diagnostics
            let transportValue = incomingAudioTransport.diagnosticsValue
            let verbose = TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()
            Task.detached(priority: .utility) {
                let decodedChunks = AudioChunkPayloadCodec.decode(openedPayload)
                var metadata = [
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": transportValue,
                    "payloadLength": String(originalPayload.count),
                    "openedPayloadLength": String(openedPayload.count),
                    "transportDigest": AudioChunkPayloadCodec.transportDigest(openedPayload),
                    "decodedChunkCount": String(decodedChunks.count),
                    "encrypted": String(MediaEncryptedAudioPacket.isEncodedPacket(originalPayload)),
                    "verbose": String(verbose),
                ]
                if MediaEncryptedAudioPacket.isEncodedPacket(originalPayload),
                   let packet = try? MediaEndToEndEncryption.decodePacket(originalPayload) {
                    metadata["encryptedSequenceNumber"] = String(packet.sequenceNumber)
                }
                if let firstFrame = decodedChunks.compactMap(VoiceAudioFramePayloadCodec.decode).first {
                    metadata["codec"] = "opus"
                    metadata["frameIndex"] = String(firstFrame.frameIndex)
                    metadata["sampleRate"] = String(firstFrame.sampleRate)
                    metadata["frameDurationMs"] = String(firstFrame.frameDurationMilliseconds)
                    metadata["packetSizeBytes"] = String(firstFrame.packet.count)
                } else {
                    metadata["codec"] = "legacy-pcm"
                }
                diagnostics.record(
                    .media,
                    message: "Audio chunk received",
                    metadata: metadata
                )
            }

        case .suppressedNotice:
            diagnostics.record(
                .media,
                message: "Suppressing repetitive audio chunk diagnostics",
                metadata: [
                    "channelId": channelID,
                    "contactId": contactID.uuidString,
                    "transport": incomingAudioTransport.diagnosticsValue,
                    "reason": "budget-exhausted",
                    "detailedReportLimit": String(detailedReportLimit),
                ]
            )

        case .suppressed:
            break
        }
    }

    func handleIncomingSignal(_ envelope: TurboSignalEnvelope) {
        guard let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id else {
            backendStatusMessage = "Signal: \(envelope.type.rawValue)"
            return
        }

        let applicationState = currentApplicationState()
        if shouldIgnoreForegroundDirectQuicTransmitControlSignal(
            envelope,
            for: contactID,
            applicationState: applicationState
        ) {
            diagnostics.record(
                .websocket,
                message: "Ignored redundant foreground Direct QUIC transmit control signal",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "payload": envelope.payload,
                ]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:redundant-direct-quic-\(envelope.type.rawValue)")
            }
            return
        }

        switch envelope.type {
        case .transmitStart where envelope.payload == "ptt-prepare":
            pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
            syncEngineRemoteTransmitStarted(
                contactID: contactID,
                channelID: envelope.channelId,
                senderDeviceID: envelope.fromDeviceId,
                source: "backend-websocket-prepare"
            )
            beginRemoteAudioReceiveEpochIfNeeded(
                contactID: contactID,
                channelID: envelope.channelId,
                senderDeviceID: envelope.fromDeviceId,
                source: .transmitPrepareSignal,
                controlTransport: "backend-websocket"
            )
            markRemoteAudioActivity(for: contactID, source: .transmitPrepareSignal)
            if shouldTreatIncomingControlSignalAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            ) {
                ensurePendingWakeCandidate(
                    for: contactID,
                    channelId: envelope.channelId,
                    senderUserId: envelope.fromUserId,
                    senderDeviceId: envelope.fromDeviceId,
                    scheduleFallback: false
                )
            }
            recordWakeReceiveTiming(
                stage: "backend-peer-transmit-prepare-observed",
                contactID: contactID,
                channelID: envelope.channelId,
                subsystem: .websocket,
                metadata: [
                    "fromDeviceId": envelope.fromDeviceId,
                    "fromUserId": envelope.fromUserId,
                    "payloadLength": String(envelope.payload.count),
                ],
                ifAbsent: true
            )
            diagnostics.record(
                .websocket,
                message: "Receiver transmit prepare signal received",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:transmit-prepare")
            }
            Task {
                if shouldSetSystemRemoteParticipantFromSignalPath(
                    for: contactID,
                    applicationState: applicationState
                ),
                   !shouldSuppressForegroundDirectQuicRemoteParticipant(
                    for: contactID,
                    applicationState: applicationState
                   ) {
                    await updateSystemRemoteParticipant(
                        for: contactID,
                        isActive: true,
                        reason: "backend-sync-remote-prepare"
                    )
                }
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .transmitStart, .transmitStop:
            let shouldDeferReceiveTeardown = envelope.type == .transmitStop
                && shouldDeferReceiveTeardownUntilRemoteAudioDrain(for: contactID)
            if envelope.type == .transmitStart {
                pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
                syncEngineRemoteTransmitStarted(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    senderDeviceID: envelope.fromDeviceId,
                    source: "backend-websocket-start"
                )
                beginRemoteAudioReceiveEpochIfNeeded(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    senderDeviceID: envelope.fromDeviceId,
                    source: .transmitStartSignal,
                    controlTransport: "backend-websocket"
                )
                let shouldArmWakeCandidate = shouldTreatIncomingControlSignalAsWakeCandidate(
                    for: contactID,
                    applicationState: applicationState
                )
                markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
                if shouldArmWakeCandidate {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
                Task {
                    await connectMediaRelayForReceiveIfNeeded(
                        contactID: contactID,
                        channelID: envelope.channelId,
                        peerDeviceID: envelope.fromDeviceId,
                        allowConfiguredReceiveWithoutLocalToggle: true
                    )
                }
                recordWakeReceiveTiming(
                    stage: "backend-peer-transmitting-observed",
                    contactID: contactID,
                    channelID: envelope.channelId,
                    subsystem: .websocket,
                    metadata: [
                        "fromDeviceId": envelope.fromDeviceId,
                        "fromUserId": envelope.fromUserId,
                        "payloadLength": String(envelope.payload.count),
                    ],
                    ifAbsent: true
                )
            } else {
                syncEngineRemoteTransmitStopped(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    senderDeviceID: envelope.fromDeviceId,
                    source: "backend-websocket-stop"
                )
                pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)
                if let activationState = pttWakeRuntime.incomingWakeActivationState(for: contactID),
                   activationState == .signalBuffered
                    || activationState == .awaitingSystemActivation
                    || activationState == .systemActivationTimedOutWaitingForForeground {
                    pttWakeRuntime.markSystemActivationInterruptedByTransmitEnd(for: contactID)
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Transmit ended before system wake audio activation arrived",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": envelope.channelId,
                            "activationState": String(describing: activationState),
                        ]
                    )
                } else {
                    if shouldDeferReceiveTeardown {
                        diagnostics.record(
                            .media,
                            message: "Deferring receive teardown until remote audio drain after transmit stop",
                            metadata: ["contactId": contactID.uuidString]
                        )
                        pttWakeRuntime.clear(for: contactID)
                        markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
                    } else {
                        pttWakeRuntime.clear(for: contactID)
                    }
                }
                if !shouldDeferReceiveTeardown {
                    clearRemoteAudioActivity(for: contactID)
                    finalizeReceiveMediaSessionIfNeeded(
                        for: contactID,
                        closeMessage: "Closed receive media session after transmit stop",
                        deferPrewarmMessage: "Deferred interactive audio prewarm until PTT audio deactivation"
                    )
                }
            }
            diagnostics.record(
                .websocket,
                message: "Signal received",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
            Task {
                let shouldSetRemoteParticipant =
                    envelope.type == .transmitStart
                    && shouldSetSystemRemoteParticipantFromSignalPath(
                        for: contactID,
                        applicationState: currentApplicationState()
                    )
                    && !shouldSuppressForegroundDirectQuicRemoteParticipant(
                        for: contactID,
                        applicationState: currentApplicationState()
                    )
                let shouldClearRemoteParticipant =
                    envelope.type == .transmitStop
                    && !shouldDeferReceiveTeardown
                    && shouldClearSystemRemoteParticipantFromSignalPath(for: contactID)
                if shouldSetRemoteParticipant || shouldClearRemoteParticipant {
                    await updateSystemRemoteParticipant(
                        for: contactID,
                        isActive: shouldSetRemoteParticipant
                    )
                }
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .receiverReady, .receiverNotReady:
            let applicationState = currentApplicationState()
            let readinessPayload = ReceiverAudioReadinessSignalPayload.decode(from: envelope.payload)
            let readinessReason = readinessPayload.reason
            applyRemoteConversationParticipantTelemetry(
                readinessPayload.telemetry,
                for: contactID,
                source: envelope.type.rawValue
            )
            observePeerVoiceMediaCapabilities(
                readinessPayload.mediaCapabilities,
                contactID: contactID,
                peerDeviceID: envelope.fromDeviceId,
                source: envelope.type.rawValue
            )
            let readiness: RemoteAudioReadinessState = {
                switch envelope.type {
                case .receiverReady:
                    return .ready
                case .receiverNotReady:
                    return readinessReason.isBackgroundMediaClosure ? .wakeCapable : .waiting
                default:
                    return .unknown
                }
            }()
            if envelope.type == .receiverNotReady {
                releaseLocalInteractivePrewarmForRemoteBackgrounding(
                    contactID: contactID,
                    readinessSignalReason: readinessReason,
                    applicationState: applicationState
                )
                if readinessReason.isBackgroundMediaClosure {
                    if let attempt = directQuicAttempt(for: contactID) {
                        diagnostics.record(
                            .media,
                            message: "Preserving Direct QUIC path after receiver readiness closed",
                            metadata: [
                                "contactId": contactID.uuidString,
                                "channelId": attempt.channelID,
                                "attemptId": attempt.attemptId,
                                "isDirectActive": String(attempt.isDirectActive),
                            ]
                        )
                    }
                }
            }
            let suppressReceiverReadinessRegressionDuringPlaybackDrain =
                remoteReceiveBlocksLocalTransmit(for: contactID)
                && (envelope.type == .receiverReady || readiness != .ready)
            if suppressReceiverReadinessRegressionDuringPlaybackDrain {
                diagnostics.record(
                    .websocket,
                    message: "Ignored receiver audio readiness regression during playback drain",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "payload": envelope.payload,
                        "reason": readinessReason.wireValue,
                        "readiness": String(describing: readiness),
                    ]
                )
            } else if let existing = channelReadinessByContactID[contactID] {
                let updatedReadiness: TurboChannelReadinessResponse = {
                    var next = existing.settingRemoteAudioReadiness(readiness)
                    if envelope.type == .receiverNotReady,
                       readinessReason.isBackgroundMediaClosure {
                        next = next.settingRemoteWakeCapability(
                            .wakeCapable(targetDeviceId: envelope.fromDeviceId)
                        )
                    }
                    return next
                }()
                applyChannelReadiness(
                    updatedReadiness,
                    for: contactID,
                    reason: "receiver-audio-readiness-signal"
                )
            }
            diagnostics.record(
                .websocket,
                message: "Receiver audio readiness signal received",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "payload": envelope.payload,
                    "reason": readinessReason.wireValue,
                    "hasTelemetry": String(readinessPayload.telemetry != nil),
                    "hasMediaCapabilities": String(readinessPayload.mediaCapabilities != nil),
                    "supportsOpusV2": String(readinessPayload.mediaCapabilities?.supportsOpusV2 == true),
                ]
            )
            if backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
            if suppressReceiverReadinessRegressionDuringPlaybackDrain {
                return
            }
            let shouldEchoReadyAfterPeerReconnect =
                readiness == .ready
                && readinessReason.requestsReciprocalReceiverReadinessAfterReconnect
            Task {
                if readiness == .ready {
                    await resumeLocalInteractivePrewarmForRemoteReady(
                        contactID: contactID,
                        applicationState: applicationState
                    )
                    if shouldEchoReadyAfterPeerReconnect {
                        controlPlaneCoordinator.send(
                            .receiverAudioReadinessCacheCleared(contactID: contactID)
                        )
                        await syncLocalReceiverAudioReadinessSignal(
                            for: contactID,
                            reason: .backendSignalingRecovery
                        )
                    }
                    await syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: .channelRefresh
                    )
                }
                await refreshChannelState(for: contactID)
            }
        case .audioChunk:
            diagnostics.recordInvariantViolation(
                invariantID: "media.runtime_never_carries_live_audio",
                scope: .local,
                message: "Rejected backend WebSocket audio chunk because runtime control cannot carry live media",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "fromUserId": envelope.fromUserId,
                    "fromDeviceId": envelope.fromDeviceId,
                    "toUserId": envelope.toUserId,
                    "toDeviceId": envelope.toDeviceId,
                    "payloadClass": "liveMedia",
                    "endpoint": "runtime",
                    "mechanism": "websocket",
                    "signalType": envelope.type.rawValue,
                    "action": "rejected",
                ]
            )
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected backend WebSocket audio chunk",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "fromDeviceId": envelope.fromDeviceId,
                    "action": "rejected-runtime-live-media",
                ]
            )
        case .audioPlaybackStarted:
            do {
                let payload = try envelope.decodeAudioPlaybackStartedPayload()
                diagnostics.record(
                    .websocket,
                    message: "Audio playback ACK signal received",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "toDeviceId": envelope.toDeviceId,
                        "transportDigest": payload.transportDigest,
                        "ackId": payload.ackId,
                    ]
                )
                handleAudioPlaybackStartedAck(
                    payload,
                    contactID: contactID,
                    source: .backendWebSocket
                )
            } catch {
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected audio playback ACK signal because payload was invalid",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "error": error.localizedDescription,
                    ]
                )
            }
        case .directQuicUpgradeRequest:
            handleIncomingDirectQuicUpgradeRequest(envelope, contactID: contactID)
        case .selectedFriendPrewarm:
            handleIncomingSelectedFriendPrewarmHint(envelope, contactID: contactID)
        case .conversationParticipantTelemetry:
            applyConversationParticipantTelemetryPayload(
                envelope.payload,
                for: contactID,
                source: envelope.type.rawValue
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
        case .offer, .answer, .iceCandidate, .hangup:
            handleIncomingDirectQuicControlSignal(envelope, contactID: contactID)
        }
    }

    func handleIncomingSelectedFriendPrewarmHint(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        guard let backend = backendServices else { return }
        let payload: TurboSelectedFriendPrewarmPayload
        do {
            payload = try envelope.decodeSelectedFriendPrewarmPayload()
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected friend prewarm hint because payload was invalid",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "fromDeviceId": envelope.fromDeviceId,
                    "toDeviceId": envelope.toDeviceId,
                    "error": error.localizedDescription,
                ]
            )
            return
        }
        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": envelope.channelId,
            "requestId": payload.requestId,
            "reason": payload.reason,
            "fromDeviceId": envelope.fromDeviceId,
            "toDeviceId": envelope.toDeviceId,
        ]

        guard envelope.toDeviceId == backend.deviceID,
              payload.fromDeviceId == envelope.fromDeviceId,
              payload.channelId == envelope.channelId,
              payload.toDeviceId.isEmpty || payload.toDeviceId == backend.deviceID else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected friend prewarm hint because envelope and payload disagree",
                metadata: metadata
            )
            return
        }

        if let contact = contacts.first(where: { $0.id == contactID }),
           let remoteUserId = contact.remoteUserId,
           remoteUserId != envelope.fromUserId {
            metadata["expectedRemoteUserId"] = remoteUserId
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected friend prewarm hint from unexpected remote user",
                metadata: metadata
            )
            return
        }

        recentPeerDeviceEvidenceByContactID[contactID] = RecentPeerDeviceEvidence(
            deviceId: envelope.fromDeviceId,
            channelId: envelope.channelId,
            reason: "selected-friend-prewarm:\(payload.reason)",
            observedAt: Date()
        )
        metadata["recordedPeerDeviceId"] = envelope.fromDeviceId
        bindKnownPTTTokenToPrewarmHintChannelIfNeeded(
            channelID: envelope.channelId,
            contactID: contactID,
            reason: payload.reason
        )

        if let blockReason = selectedFriendPrewarmHintBlockReason(for: contactID) {
            metadata["blockReason"] = blockReason
            diagnostics.record(
                .websocket,
                message: "Ignored selected friend prewarm hint because receiver is not warmable",
                metadata: metadata
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Selected friend prewarm hint received",
            metadata: metadata
        )
        if selectedContactId == contactID {
            Task {
                await runSelectedContactPrewarmPipeline(
                    for: contactID,
                    reason: "friend-hint-\(payload.reason)"
                )
            }
        } else {
            diagnostics.record(
                .websocket,
                message: "Deferred selected friend prewarm hint until contact selection",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "reason": payload.reason,
                    "recordedPeerDeviceId": envelope.fromDeviceId,
                ]
            )
        }
    }

    func bindKnownPTTTokenToPrewarmHintChannelIfNeeded(
        channelID: String,
        contactID: UUID,
        reason: String
    ) {
        let policyState = pttSystemPolicyCoordinator.state
        guard !policyState.latestTokenHex.isEmpty else { return }
        guard policyState.uploadedBackendChannelID != channelID else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Binding known PTT token to selected friend prewarm channel",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "reason": reason,
                "tokenRegistration": policyState.tokenRegistrationDescription,
                "uploadedBackendChannelId": policyState.uploadedBackendChannelID ?? "none",
            ]
        )
        Task { [weak self] in
            guard let self else { return }
            await self.pttSystemPolicyCoordinator.handle(.backendChannelReady(channelID))
            self.syncPTTSystemPolicyState()
            self.captureDiagnosticsState("selected-friend-prewarm:ptt-token-bound")
        }
    }

    func handleIncomingDirectQuicTransmitPrepare(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
        syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: payload.channelId,
            senderDeviceID: payload.fromDeviceId,
            source: "direct-quic-prepare"
        )
        beginRemoteAudioReceiveEpochIfNeeded(
            contactID: contactID,
            channelID: payload.channelId,
            senderDeviceID: payload.fromDeviceId,
            source: .transmitPrepareSignal,
            controlTransport: "direct-quic"
        )
        markRemoteAudioActivity(for: contactID, source: .transmitPrepareSignal)
        let senderUserID =
            contacts.first(where: { $0.id == contactID })?.remoteUserId
            ?? ""
        let applicationState = currentApplicationState()
        let shouldArmWakeCandidate = shouldTreatIncomingControlSignalAsWakeCandidate(
            for: contactID,
            applicationState: applicationState
        )
        if shouldArmWakeCandidate {
            ensurePendingWakeCandidate(
                for: contactID,
                channelId: payload.channelId,
                senderUserId: senderUserID,
                senderDeviceId: payload.fromDeviceId,
                scheduleFallback: applicationState != .active
            )
        }
        recordWakeReceiveTiming(
            stage: "direct-quic-transmit-prepare-observed",
            contactID: contactID,
            channelID: payload.channelId,
            subsystem: .media,
            metadata: [
                "attemptId": attemptID,
                "fromDeviceId": payload.fromDeviceId,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "applicationState": String(describing: applicationState),
                "armedWakeCandidate": String(shouldArmWakeCandidate),
            ],
            ifAbsent: true
        )
        diagnostics.record(
            .media,
            message: "Direct QUIC receiver transmit prepare received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "applicationState": String(describing: applicationState),
                "armedWakeCandidate": String(shouldArmWakeCandidate),
            ]
        )
        if applicationState == .active {
            await prewarmLocalMediaIfNeeded(for: contactID)
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .directQuicTransmitPrepare
            )
        }
        if shouldArmWakeCandidate,
           shouldSetSystemRemoteParticipantFromSignalPath(
            for: contactID,
            applicationState: applicationState
           ),
           !shouldSuppressForegroundDirectQuicRemoteParticipant(
            for: contactID,
            applicationState: applicationState
           ) {
            await updateSystemRemoteParticipant(
                for: contactID,
                isActive: true,
                reason: "direct-quic-remote-prepare"
            )
        }
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("direct-quic:transmit-prepare")
        }
    }

    func updateSystemRemoteParticipant(
        for contactID: UUID,
        isActive: Bool,
        reason: String? = nil
    ) async {
        guard let channelUUID = channelUUID(for: contactID) else { return }
        let participantName = isActive
            ? contacts.first(where: { $0.id == contactID })?.name
                ?? contacts.first(where: { $0.id == contactID })?.handle
            : nil
        let resolvedReason =
            reason ?? (isActive ? "backend-sync-remote-active" : "backend-sync-remote-inactive")
        do {
            let didApplySystemParticipant = try await setSystemActiveRemoteParticipant(
                name: participantName,
                channelUUID: channelUUID,
                contactID: contactID,
                reason: resolvedReason
            )
            guard didApplySystemParticipant else { return }
            diagnostics.record(
                .pushToTalk,
                message: isActive ? "Set active remote participant" : "Cleared active remote participant",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "participant": participantName ?? "none"
                ]
            )
        } catch {
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: isActive
                        ? "Ignoring stale-channel active remote participant set failure"
                        : "Ignoring stale-channel active remote participant clear failure",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "participant": participantName ?? "none",
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            if !isActive && isExpectedPTTStopFailure(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignoring expected active remote participant clear failure",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "participant": participantName ?? "none",
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: isActive ? "Failed to set active remote participant" : "Failed to clear active remote participant",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "participant": participantName ?? "none",
                    "error": error.localizedDescription
                ]
            )
        }
    }

    func refreshContactSummaries() async {
        guard let backend = backendServices else { return }

        do {
            let summaries = try await withHTTPTransportFault(route: .contactSummaries) {
                try await backend.contactSummaries()
            }
            var nextSummaries: [UUID: TurboContactSummaryResponse] = [:]
            for summary in summaries {
                let channelID = summary.channelId ?? ""
                let contactID = ensureContactExists(
                    handle: summary.publicId,
                    remoteUserId: summary.userId,
                    channelId: channelID,
                    displayName: summary.profileName
                )
                nextSummaries[contactID] = summary
                updateContact(contactID) { contact in
                    contact.name = summary.profileName
                    contact.handle = summary.publicId
                    contact.isOnline = summary.isOnline
                    contact.remoteUserId = summary.userId
                    if let channelId = summary.channelId {
                        contact.backendChannelId = channelId
                        contact.channelId = ContactDirectory.stableChannelUUID(for: channelId)
                    }
                }
            }
            clearStaleTrackedChannelReferencesMissingFromSummaries(excluding: nextSummaries)
            await refreshTrackedContactPresenceFallback(excluding: nextSummaries)
            let updates = nextSummaries.map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
            backendSyncCoordinator.send(.contactSummariesUpdated(updates))
            pruneContactsToAuthoritativeState()
            reconcileIncomingBeepSurface(allowsSelectedContact: true)
            if await resolveRestoredSystemSessionIfPossible(trigger: "contact-summaries") == nil {
                clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "contact-summaries")
            }
            reconcileContactSelectionIfNeeded(
                reason: "contact-summaries",
                allowSelectingFallbackContact: false
            )
            updateStatusForSelectedContact()
            await reconcileSelectedConversationIfNeeded()
            captureDiagnosticsState("backend-sync:contact-summaries")
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "contact-summaries",
                error: error
            ) {
                return
            }
            backendSyncCoordinator.send(.contactSummariesFailed("Contact sync failed: \(error.localizedDescription)"))
            diagnostics.record(.backend, level: .error, message: "Contact sync failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("backend-sync:contact-summaries-failed")
            await reconcileSelectedConversationIfNeeded()
        }
    }

    func refreshChannelState(
        for contactID: UUID,
        receiverReadinessReason: ReceiverAudioReadinessReason = .channelRefresh
    ) async {
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelId = contact.backendChannelId else {
            backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-sync:channel-cleared")
            return
        }

        do {
            async let channelStateTask = withHTTPTransportFault(route: .channelState) {
                try await backend.channelState(channelId: backendChannelId)
            }
            async let channelReadinessTask = withHTTPTransportFault(route: .channelReadiness) {
                try await backend.channelReadiness(channelId: backendChannelId)
            }

            let channelState = try await channelStateTask
            let fetchedChannelReadiness: TurboChannelReadinessResponse?
            let channelReadinessFailure: Error?
            do {
                fetchedChannelReadiness = try await channelReadinessTask
                channelReadinessFailure = nil
            } catch {
                fetchedChannelReadiness = nil
                channelReadinessFailure = error
            }

            let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
            let readinessMembershipLoss =
                channelReadinessFailure.map(shouldTreatChannelReadinessMembershipLossAsAuthoritative) ?? false
            let inactiveReadinessMembershipLoss =
                shouldHonorInactiveChannelReadinessMembershipLoss(
                    contactID: contactID,
                    existing: existingChannelState,
                    incoming: channelState,
                    readiness: fetchedChannelReadiness
                )
            let authoritativeMembershipLoss =
                (
                    readinessMembershipLoss
                    && shouldHonorAuthoritativeChannelReadinessMembershipLoss(
                        contactID: contactID,
                        existing: existingChannelState,
                        incoming: channelState
                    )
                )
                || inactiveReadinessMembershipLoss
            let membershipEffectiveChannelState = effectiveChannelStatePreservingConversationMembership(
                contactID: contactID,
                existing: existingChannelState,
                incoming: channelState,
                authoritativeMembershipLoss: authoritativeMembershipLoss
            )
            if authoritativeMembershipLoss {
                diagnostics.record(
                    .channel,
                    message: "Honoring backend membership loss after readiness refresh",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                    ]
                )
            }
            let existingDevicePTTSessionWasRoutable =
                devicePTTEvidenceExists(for: contactID)
            let existingChannelReadiness = channelReadinessByContactID[contactID]
            let directQuicReceiveOrPrepareEvidence: Bool = {
                switch receiveExecutionCoordinator.state
                    .remoteActivityByContactID[contactID]?
                    .phase {
                case .prepared, .awaitingFirstAudioChunk, .receivingAudio, .drainingAudio:
                    return true
                case .none:
                    return existingChannelReadiness?.remoteAudioReadiness == .waiting
                }
            }()
            let shouldSuppressWakeCapableAudioReadiness =
                shouldUseDirectQuicTransport(for: contactID)
                && directQuicReceiveOrPrepareEvidence
            let mergedChannelReadiness: TurboChannelReadinessResponse? = {
                guard membershipEffectiveChannelState.membership != .absent else { return nil }
                return mergedChannelReadinessPreservingWakeCapableFallback(
                    existing: existingChannelReadiness,
                    fetched: fetchedChannelReadiness,
                    peerDeviceConnected: membershipEffectiveChannelState.membership.peerDeviceConnected,
                    peerMembershipPresent: membershipEffectiveChannelState.membership.hasPeerMembership,
                    existingDevicePTTSessionWasRoutable: existingDevicePTTSessionWasRoutable,
                    suppressWakeCapableAudioReadiness: shouldSuppressWakeCapableAudioReadiness
                )
            }()
            let expiredTransmitProjection = channelProjectionClearingExpiredTransmitLeaseIfNeeded(
                contactID: contactID,
                channelState: membershipEffectiveChannelState,
                readiness: mergedChannelReadiness
            )
            let effectiveChannelState = expiredTransmitProjection.channelState
            let effectiveChannelReadiness = expiredTransmitProjection.readiness
            await recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
                contactID: contactID,
                existingChannelState: existingChannelState,
                effectiveChannelState: effectiveChannelState
            )
            let localDevicePTTEvidenceEstablished =
                devicePTTEvidenceExists(for: contactID)
            let localDevicePTTEvidenceCleared =
                !devicePTTEvidenceExists(for: contactID)
            if shouldIgnoreStaleJoinedChannelRefreshDuringLeave(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                localDevicePTTEvidenceCleared: localDevicePTTEvidenceCleared
            ) {
                recordStaleJoinedChannelRefreshRepairDuringLeave(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    effectiveChannelState: effectiveChannelState,
                    effectiveChannelReadiness: effectiveChannelReadiness
                )
                backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
                controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
                syncEngineDisconnect(contactID: contactID, reason: "stale-channel-refresh-during-leave")
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-sync:stale-channel-refresh-during-leave")
                return
            }
            if inactiveReadinessMembershipLoss {
                let reconnectGraceActive = shouldUseLiveCallControlPlaneReconnectGrace(for: contactID)
                diagnostics.requireContract(
                    effectiveChannelState.membership == .absent
                        && effectiveChannelReadiness == nil,
                    DiagnosticsContracts.Selected.inactiveBackendReadinessClearsMembership(
                        contactID: contactID,
                        channelID: backendChannelId,
                        existing: existingChannelState,
                        incoming: channelState,
                        readiness: fetchedChannelReadiness,
                        effective: effectiveChannelState,
                        effectiveReadiness: effectiveChannelReadiness,
                        localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished,
                        reconnectGraceActive: reconnectGraceActive
                    )
                )
            }
            if localDevicePTTEvidenceEstablished,
               effectiveChannelState.membership.hasLocalMembership,
               effectiveChannelReadiness?.selfHasActiveDevice != false {
                clearLiveCallControlPlaneReconnectGrace(reason: "backend-conversation-confirmed")
            }
            if shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness,
                localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished
            ) {
                backendRuntime.clearBackendJoinSettling(for: contactID)
                diagnostics.record(
                    .backend,
                    message: "Cleared backend join settling after active device became visible",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                        "backendStatus": effectiveChannelState.status,
                        "backendReadiness": effectiveChannelReadiness?.statusKind ?? "none",
                    ]
                )
            }
            if shouldRecoverMissingBackendDevicePresence(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness,
                localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished
            ) {
                startBackendJoinRecoveryForActiveDevicePTTEvidence(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.local_device_ptt_evidence_without_backend_presence",
                    invariantMessage: "local Device PTT evidence is active, but backend readiness says selfHasActiveDevice=false",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing missing backend device presence for active local Device PTT evidence",
                    captureReason: "backend-presence:self-healed"
                )
            } else if shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished
            ) {
                startBackendJoinRecoveryForActiveDevicePTTEvidence(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.local_device_ptt_evidence_without_backend_membership",
                    invariantMessage: "local Device PTT evidence is active, but backend membership dropped self while the peer remained joined",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing missing backend membership for active local Device PTT evidence",
                    captureReason: "backend-membership:self-healed"
                )
            } else if shouldRecoverAbsentBackendMembershipForActiveDevicePTTEvidence(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness,
                localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished
            ) {
                startBackendJoinRecoveryForActiveDevicePTTEvidence(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.backend_absent_with_local_device_ptt_evidence",
                    invariantScope: .backend,
                    invariantMessage: "backend dropped durable membership while local Device PTT evidence remained active",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing absent backend membership for active local Device PTT evidence",
                    captureReason: "backend-absent-membership:self-healed"
                )
            } else if !authoritativeMembershipLoss,
                      shouldRecoverBackendIdleMembershipLossForActiveDevicePTTEvidence(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished
            ) {
                startBackendJoinRecoveryForActiveDevicePTTEvidence(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.backend_idle_with_local_device_ptt_evidence",
                    invariantScope: .backend,
                    invariantMessage: "backend regressed to idle while local Device PTT evidence remained active",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing backend idle membership loss for active local Device PTT evidence",
                    captureReason: "backend-idle-membership:self-healed"
                )
            }
            let leaveWasInFlight = conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            let shouldPreserveSettlingBackendJoin =
                !effectiveChannelState.membership.hasLocalMembership
                && shouldPreservePendingLocalJoinDuringBackendJoinSettling(for: contactID)
            if shouldPreserveSettlingBackendJoin {
                diagnostics.record(
                    .state,
                    message: "Preserved pending local join during settling backend channel refresh",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                        "backendMembership": String(describing: effectiveChannelState.membership),
                        "backendStatus": effectiveChannelState.status,
                    ]
                )
            } else {
                conversationActionCoordinator.reconcileAfterChannelRefresh(
                    for: contactID,
                    effectiveChannelState: effectiveChannelState,
                    localDevicePTTEvidenceEstablished: localDevicePTTEvidenceEstablished,
                    localDevicePTTEvidenceCleared: localDevicePTTEvidenceCleared
                )
            }
            if leaveWasInFlight,
               !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
                captureDiagnosticsState("device-ptt-teardown:channel-refresh-complete")
            }
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contactID, channelState: effectiveChannelState)
            )
            let setupChannelReadiness =
                effectiveChannelReadiness
                ?? (fetchedChannelReadiness?.peerTargetDeviceId == nil ? nil : fetchedChannelReadiness)
            if let setupChannelReadiness {
                applyChannelReadiness(
                    setupChannelReadiness,
                    for: contactID,
                    reason: "channel-refresh"
                )
            }
            syncEngineJoinedConversation(contactID: contactID, reason: "channel-refresh")
            await prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness
            )
            updateContact(contactID) { contact in
                contact.isOnline = effectiveChannelState.peerOnline
                contact.remoteUserId = effectiveChannelState.peerUserId
            }
            if let effectiveChannelReadiness,
               !effectiveChannelReadiness.statusKind.isEmpty {
                let normalizedBackendNotice = normalizedBackendServerNotice(backendStatusMessage)
                let channelReadyClearsTargetDeviceNotice =
                    effectiveChannelReadiness.statusKind == ConversationState.ready.rawValue
                    && normalizedBackendNotice == "target user has no connected receiving device in this channel"
                if backendStatusMessage.hasPrefix("signaling ") || channelReadyClearsTargetDeviceNotice {
                    backendStatusMessage = "Connected"
                }
            }
            if selectedContactId == contactID {
                let backendChannelSnapshot = ChannelReadinessSnapshot(
                    channelState: effectiveChannelState,
                    readiness: effectiveChannelReadiness
                )
                let backendShowsLocalTransmit = backendChannelSnapshot.status == ConversationState.transmitting
                let transmitSnapshot = transmitDomainSnapshot
                let shouldAcceptBackendLocalTransmit = shouldAcceptBackendLocalTransmitProjection(
                    backendShowsLocalTransmit: backendShowsLocalTransmit,
                    refreshedContactID: contactID,
                    transmitSnapshot: transmitSnapshot,
                    leaveInFlight: leaveWasInFlight
                        || conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
                )
                let shouldPreserveTransmitState = shouldPreserveLocalTransmitState(
                    selectedContactID: selectedContactId,
                    refreshedContactID: contactID,
                    backendChannelStatus: backendChannelSnapshot.status?.rawValue ?? effectiveChannelState.status,
                    transmitSnapshot: transmitSnapshot
                )
                if shouldAcceptBackendLocalTransmit,
                   let activeTransmitID = backendChannelSnapshot.activeTransmitId {
                    receiveEngineEvent(
                        .backend(.localTransmitObserved(EngineTransmitID(activeTransmitID))),
                        source: "backend-sync:channel-state"
                    )
                }
                if !shouldPreserveTransmitState {
                    clearEngineTransmitIfActive(reason: "backend-refresh")
                    tearDownTransmitRuntime(resetCoordinator: true)
                }
                updateStatusForSelectedContact()
            }
            await reconcileSelectedConversationIfNeeded()
            captureDiagnosticsState("backend-sync:channel-state")
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: receiverReadinessReason
            )
            if selectedContactId == contactID {
                await maybeStartSelectedContactDirectQuicPrewarm(
                    for: contactID,
                    reason: "channel-refresh"
                )
                await prewarmForegroundTalkPathIfNeeded(
                    for: contactID,
                    reason: "channel-ready"
                )
                if canScheduleReadyChannelMediaRelayPrejoin(contactID: contactID) {
                    await prejoinMediaRelayForReadyChannelIfNeeded(
                        contactID: contactID,
                        channelReadiness: effectiveChannelReadiness
                    )
                }
                if shouldRequestAutomaticDirectQuicProbe(for: contactID) {
                    await maybeStartAutomaticDirectQuicProbe(
                        for: contactID,
                        reason: "channel-ready"
                    )
                }
            }
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "channel-state",
                error: error
            ) {
                return
            }
            if shouldTreatChannelRefreshFailureAsAuthoritativeChannelLoss(error) {
                let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
                if shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss(
                    contactID: contactID,
                    existing: existingChannelState
                ) {
                    backendSyncCoordinator.send(
                        .channelStateFailed(
                            contactID: contactID,
                            message: "Channel sync failed: \(error.localizedDescription)"
                        )
                    )
                    diagnostics.record(
                        .channel,
                        level: .info,
                        message: "Preserving selected Conversation after transient authoritative channel loss",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": backendChannelId,
                            "error": error.localizedDescription,
                        ]
                    )
                    updateStatusForSelectedContact()
                    captureDiagnosticsState("backend-sync:authoritative-channel-loss-preserved")
                    await refreshContactSummaries()
                    await reconcileSelectedConversationIfNeeded()
                    return
                }
                clearDevicePTTSessionAfterAuthoritativeChannelLoss(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    error: error
                )
                await refreshContactSummaries()
                await reconcileSelectedConversationIfNeeded()
                return
            }
            let shouldPreserveLocalConversationEvidence =
                selectedContactId == contactID
                && hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID)

            backendSyncCoordinator.send(
                .channelStateFailed(
                    contactID: contactID,
                    message: "Channel sync failed: \(error.localizedDescription)"
                )
            )
            if selectedContactId == contactID {
                if !shouldPreserveLocalConversationEvidence {
                    resetTransmitSession(closeMediaSession: true)
                }
                updateStatusForSelectedContact()
            }
            diagnostics.record(
                .channel,
                level: shouldPreserveLocalConversationEvidence ? .info : .error,
                message: shouldPreserveLocalConversationEvidence
                    ? "Channel state refresh failed; preserving local Conversation evidence"
                    : "Channel state refresh failed",
                metadata: ["contactId": contactID.uuidString, "error": error.localizedDescription]
            )
            captureDiagnosticsState("backend-sync:channel-failed")
            await reconcileSelectedConversationIfNeeded()
        }
    }

    func refreshBeeps() async {
        guard let backend = backendServices else { return }
        func updates(
            incoming: [TurboBeepResponse]?,
            outgoing: [TurboBeepResponse]?
        ) -> ([BackendBeepUpdate]?, [BackendBeepUpdate]?) {
            var nextIncoming: [UUID: TurboBeepResponse] = [:]
            var nextOutgoing: [UUID: TurboBeepResponse] = [:]

            if let incoming {
                for beep in incoming {
                    if let handle = beep.fromHandle {
                        let contactID = ensureContactExists(
                            handle: handle,
                            remoteUserId: beep.fromUserId,
                            channelId: beep.channelId
                        )
                        nextIncoming[contactID] = beep
                    }
                }
            }

            if let outgoing {
                for beep in outgoing {
                    if let handle = beep.toHandle {
                        let contactID = ensureContactExists(
                            handle: handle,
                            remoteUserId: beep.toUserId,
                            channelId: beep.channelId
                        )
                        nextOutgoing[contactID] = beep
                    }
                }
            }

            return (
                incoming.map { _ in nextIncoming.map { BackendBeepUpdate(contactID: $0.key, beep: $0.value) } },
                outgoing.map { _ in nextOutgoing.map { BackendBeepUpdate(contactID: $0.key, beep: $0.value) } }
            )
        }

        func finishBeepSync(stateReason: String) async {
            syncBeepNotificationBadge()
            reconcileIncomingBeepSurface(allowsSelectedContact: true)
            pruneContactsToAuthoritativeState()
            reconcileContactSelectionIfNeeded(
                reason: "beep-sync",
                allowSelectingFallbackContact: false
            )
            updateStatusForSelectedContact()
            captureDiagnosticsState(stateReason)
            await reconcileSelectedConversationIfNeeded()
        }

        let incomingResult: Result<[TurboBeepResponse], Error>
        do {
            incomingResult = .success(
                try await withHTTPTransportFault(route: .incomingBeeps) {
                    try await backend.incomingBeeps()
                }
            )
        } catch {
            incomingResult = .failure(error)
        }

        let outgoingResult: Result<[TurboBeepResponse], Error>
        do {
            outgoingResult = .success(
                try await withHTTPTransportFault(route: .outgoingBeeps) {
                    try await backend.outgoingBeeps()
                }
            )
        } catch {
            outgoingResult = .failure(error)
        }

        switch (incomingResult, outgoingResult) {
        case (.success(let incoming), .success(let outgoing)):
            let (incomingUpdates, outgoingUpdates) = updates(incoming: incoming, outgoing: outgoing)
            backendSyncCoordinator.send(
                .beepsUpdated(
                    incoming: incomingUpdates ?? [],
                    outgoing: outgoingUpdates ?? [],
                    now: .now
                )
            )
            await finishBeepSync(stateReason: "backend-sync:beeps")

        case (.success(let incoming), .failure(let error)):
            guard !isExpectedBackendSyncCancellation(error) else { return }
            let (incomingUpdates, _) = updates(incoming: incoming, outgoing: nil)
            backendSyncCoordinator.send(.beepsPartiallyUpdated(incoming: incomingUpdates, outgoing: nil, now: .now))
            recordBeepSyncPartialRecovery(failedRoute: "outgoing", error: error)
            await finishBeepSync(stateReason: "backend-sync:beeps-partial")

        case (.failure(let error), .success(let outgoing)):
            guard !isExpectedBackendSyncCancellation(error) else { return }
            let (_, outgoingUpdates) = updates(incoming: nil, outgoing: outgoing)
            backendSyncCoordinator.send(.beepsPartiallyUpdated(incoming: nil, outgoing: outgoingUpdates, now: .now))
            recordBeepSyncPartialRecovery(failedRoute: "incoming", error: error)
            await finishBeepSync(stateReason: "backend-sync:beeps-partial")

        case (.failure(let incomingError), .failure(let outgoingError)):
            guard !isExpectedBackendSyncCancellation(incomingError) else { return }
            guard !isExpectedBackendSyncCancellation(outgoingError) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "beep-sync",
                error: incomingError
            ) {
                return
            }
            let message = "incoming=\(incomingError.localizedDescription); outgoing=\(outgoingError.localizedDescription)"
            backendSyncCoordinator.send(.beepsFailed("Beep sync failed: \(message)"))
            diagnostics.record(.backend, level: .error, message: "Beep sync failed", metadata: ["error": message])
            captureDiagnosticsState("backend-sync:beeps-failed")
            await reconcileSelectedConversationIfNeeded()
        }
    }

    func recordStaleJoinedChannelRefreshRepairDuringLeave(
        contactID: UUID,
        backendChannelID: String,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?
    ) {
        diagnostics.record(
            .state,
            message: "Ignored backend channel refresh that preserved joined membership while explicit leave was in flight",
            metadata: [
                "repairDecision": "ignored-stale-joined-refresh",
                "invariantId": "selected.stale_joined_refresh_during_leave",
                "contactId": contactID.uuidString,
                "channelId": backendChannelID,
                "backendStatus": effectiveChannelState.status,
                "backendMembership": String(describing: effectiveChannelState.membership),
                "backendReadiness": effectiveChannelReadiness?.statusKind ?? "none",
            ]
        )
    }

    func recordBeepSyncPartialRecovery(failedRoute: String, error: Error) {
        diagnostics.record(
            .backend,
            level: .notice,
            message: "Beep sync partially recovered",
            metadata: ["failedRoute": failedRoute, "error": error.localizedDescription]
        )
    }

    func shouldRecoverMissingBackendDevicePresence(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?,
        localDevicePTTEvidenceEstablished: Bool
    ) -> Bool {
        guard effectiveChannelState.membership.hasLocalMembership else { return false }
        guard localDevicePTTEvidenceEstablished else { return false }
        guard effectiveChannelReadiness?.selfHasActiveDevice == false else { return false }
        if currentApplicationState() != .active,
           pttWakeRuntime.incomingWakeActivationState(for: contactID)
               == .systemActivationTimedOutWaitingForForeground {
            return false
        }
        if currentApplicationState() != .active,
           case .wakeCapable = effectiveChannelReadiness?.localWakeCapability {
            return false
        }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard conversationActionCoordinator.pendingAction.pendingConnectContactID != contactID else { return false }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !remoteTransmitStopProjectionGraceIsActive(for: contactID) else { return false }
        if localReceiverAudioReadinessPublications[contactID]?.isReady == true {
            return false
        }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localDevicePTTEvidenceEstablished: Bool
    ) -> Bool {
        guard !effectiveChannelState.membership.hasLocalMembership else { return false }
        guard effectiveChannelState.membership.hasPeerMembership else { return false }
        guard localDevicePTTEvidenceEstablished else { return false }
        if pttWakeRuntime.incomingWakeActivationState(for: contactID) != nil {
            return false
        }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func shouldRecoverAbsentBackendMembershipForActiveDevicePTTEvidence(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?,
        localDevicePTTEvidenceEstablished: Bool
    ) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard localDevicePTTEvidenceEstablished else { return false }
        guard effectiveChannelState.membership == .absent else { return false }
        guard effectiveChannelState.conversationStatus != .idle else { return false }
        guard effectiveChannelReadiness != nil else { return false }
        if pttWakeRuntime.incomingWakeActivationState(for: contactID) != nil {
            return false
        }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func shouldRecoverBackendIdleMembershipLossForActiveDevicePTTEvidence(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localDevicePTTEvidenceEstablished: Bool
    ) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard localDevicePTTEvidenceEstablished else { return false }
        guard selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity else { return false }
        guard effectiveChannelState.conversationStatus == .idle else { return false }
        guard effectiveChannelState.membership == .absent else { return false }
        guard effectiveChannelState.beepThreadProjection == .none else { return false }
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func startBackendJoinRecoveryForActiveDevicePTTEvidence(
        contactID: UUID,
        backendChannelID: String,
        contact: Contact,
        invariantID: String,
        invariantScope: DiagnosticsInvariantScope = .convergence,
        invariantMessage: String,
        backendStatus: String,
        backendReadiness: String,
        recoveryMessage: String,
        captureReason: String
    ) {
        diagnostics.recordInvariantViolation(
            invariantID: invariantID,
            scope: invariantScope,
            message: invariantMessage,
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": backendChannelID,
                "backendStatus": backendStatus,
                "backendReadiness": backendReadiness,
            ]
        )
        replaceBackendSignalingJoinRecoveryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.backendRuntime.signalingJoinRecoveryTask = nil
                    self.updateStatusForSelectedContact()
                }
                self.diagnostics.record(
                    .backend,
                    message: recoveryMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelID,
                        "handle": contact.handle,
                    ]
                )
                self.backendServices?.ensureWebSocketConnected()
                await self.reassertBackendJoin(
                    for: contact,
                    deviceSessionProof: .pttSystem
                )
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
                await self.syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .backendSignalingRecovery
                )
                self.captureDiagnosticsState(captureReason)
            }
        )
    }

    func shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?,
        localDevicePTTEvidenceEstablished: Bool
    ) -> Bool {
        guard effectiveChannelState.membership.hasLocalMembership else { return false }
        guard localDevicePTTEvidenceEstablished else { return false }
        guard effectiveChannelReadiness?.selfHasActiveDevice == true else { return false }
        guard effectiveChannelState.membership.hasPeerMembership || effectiveChannelState.canTransmit else {
            return false
        }
        return effectiveChannelState.canTransmit
            || effectiveChannelReadiness?.statusKind == ConversationState.ready.rawValue
    }
}

private extension ReceiverAudioReadinessReason {
    var requestsReciprocalReceiverReadinessAfterReconnect: Bool {
        switch self {
        case .websocketConnected, .backendReconnect:
            return true
        case .appBackgroundMediaClosed,
             .audioRouteChange,
             .audioRoutePreference(_),
             .backendSignalingRecovery,
             .channelRefresh,
             .directQuicReceiverPrewarm,
             .directQuicTransmitPrepare,
             .foregroundTalkPrewarm(_),
             .incomingPushForeground,
             .mediaState(_),
             .networkChange,
             .pttSync,
             .pttWakePostActivationRefresh,
             .receiverPrewarmRequest,
             .remoteAudioEndedKeepalive,
             .telemetryRefresh,
             .legacy(_):
            return false
        }
    }
}
