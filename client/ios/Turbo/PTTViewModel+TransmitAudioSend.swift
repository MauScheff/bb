//
//  PTTViewModel+TransmitAudioSend.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit
import TurboEngine

extension PTTViewModel {
    func isMediaRelayPeerUnavailable(_ error: Error) -> Bool {
        guard case let DirectQuicProbeError.connectionFailed(message) = error else { return false }
        return message == "media relay peer is unavailable"
    }

    func recordMediaRelayPeerUnavailableInvariantIfNeeded(
        error: Error,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        operation: String
    ) {
        guard isMediaRelayPeerUnavailable(error) else { return }
        diagnostics.recordInvariantViolation(
            invariantID: "relay.send_without_live_peer",
            scope: .backend,
            message: "media relay send was attempted after relay reported peer unavailable",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "operation": operation,
                "selectedConversationPhase": String(describing: selectedConversationState(for: contactID).phase),
                "systemSession": String(describing: systemSessionState),
                "error": error.localizedDescription,
            ]
        )
    }

    func relayWebSocketAudioSignalPayload(_ payload: String, target: TransmitTarget) -> String {
        let sequenceNumber = mediaRuntime.nextRelayWebSocketAudioSequence(for: target.contactID)
        let wrappedPayload = TurboRelayWebSocketAudioPayload(
            payload: payload,
            sequenceNumber: sequenceNumber
        )
        do {
            return try TurboRelayWebSocketAudioPayloadCodec.encode(wrappedPayload)
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to encode relay WebSocket audio payload envelope",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "sequenceNumber": String(sequenceNumber),
                    "error": error.localizedDescription,
                ]
            )
            return payload
        }
    }

    func clearFirstAudioPlaybackAckExpectations() {
        firstAudioPlaybackAckTimeoutTasksByContactID.values.forEach { $0.cancel() }
        firstAudioPlaybackAckTimeoutTasksByContactID.removeAll()
        firstAudioPlaybackAckExpectationsByContactID.removeAll()
        firstAudioPlaybackAckSentKeys.removeAll()
        firstAudioPlaybackAckSentEncryptedSequenceByKey.removeAll()
        firstAudioPlaybackAckCompletedKeys.removeAll()
        directAudioPlaybackVerifiedKeys.removeAll()
    }

    func firstAudioPlaybackAckKey(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String,
        receiverDeviceID: String
    ) -> FirstAudioPlaybackAckSentKey {
        FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: senderDeviceID,
            receiverDeviceID: receiverDeviceID
        )
    }

    func clearFirstAudioPlaybackAckState(
        contactID: UUID,
        channelID: String? = nil,
        senderDeviceID: String? = nil
    ) {
        if let expectation = firstAudioPlaybackAckExpectationsByContactID[contactID],
           channelID == nil || expectation.channelID == channelID {
            firstAudioPlaybackAckTimeoutTasksByContactID[contactID]?.cancel()
            firstAudioPlaybackAckTimeoutTasksByContactID[contactID] = nil
            firstAudioPlaybackAckExpectationsByContactID[contactID] = nil
        }
        firstAudioPlaybackAckSentKeys = firstAudioPlaybackAckSentKeys.filter { key in
            if key.contactID != contactID { return true }
            if let channelID, key.channelID != channelID { return true }
            if let senderDeviceID, key.senderDeviceID != senderDeviceID { return true }
            return false
        }
        firstAudioPlaybackAckCompletedKeys = firstAudioPlaybackAckCompletedKeys.filter { key in
            if key.contactID != contactID { return true }
            if let channelID, key.channelID != channelID { return true }
            if let senderDeviceID, key.senderDeviceID != senderDeviceID { return true }
            return false
        }
        directAudioPlaybackVerifiedKeys = directAudioPlaybackVerifiedKeys.filter { key in
            if key.contactID != contactID { return true }
            if let channelID, key.channelID != channelID { return true }
            if let senderDeviceID, key.senderDeviceID != senderDeviceID { return true }
            return false
        }
    }

    func clearFirstAudioPlaybackAckSentState(
        contactID: UUID,
        channelID: String? = nil,
        senderDeviceID: String? = nil
    ) {
        firstAudioPlaybackAckSentKeys = firstAudioPlaybackAckSentKeys.filter { key in
            if key.contactID != contactID { return true }
            if let channelID, key.channelID != channelID { return true }
            if let senderDeviceID, key.senderDeviceID != senderDeviceID { return true }
            return false
        }
    }

    func clearDirectAudioPlaybackVerification(
        contactID: UUID,
        channelID: String? = nil
    ) {
        directAudioPlaybackVerifiedKeys = directAudioPlaybackVerifiedKeys.filter { key in
            if key.contactID != contactID { return true }
            if let channelID, key.channelID != channelID { return true }
            return false
        }
    }

    func mergeFirstAudioPlaybackAckDeliveredTransportsIfPending(
        contactID: UUID,
        deliveredTransports: [String]
    ) {
        guard let expectation = firstAudioPlaybackAckExpectationsByContactID[contactID] else { return }
        var mergedTransports = expectation.deliveredTransports
        for transport in deliveredTransports where !mergedTransports.contains(transport) {
            mergedTransports.append(transport)
        }
        guard mergedTransports != expectation.deliveredTransports else { return }
        firstAudioPlaybackAckExpectationsByContactID[contactID] = FirstAudioPlaybackAckExpectation(
            ackID: expectation.ackID,
            contactID: expectation.contactID,
            channelID: expectation.channelID,
            senderDeviceID: expectation.senderDeviceID,
            receiverDeviceID: expectation.receiverDeviceID,
            transportDigest: expectation.transportDigest,
            encryptedSequenceNumber: expectation.encryptedSequenceNumber,
            queuedAt: expectation.queuedAt,
            deliveredTransports: mergedTransports
        )
        diagnostics.record(
            .media,
            message: "Expanded first audio playback ACK transports",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": expectation.channelID,
                "receiverDeviceId": expectation.receiverDeviceID,
                "transportDigest": expectation.transportDigest,
                "ackId": expectation.ackID,
                "deliveredTransports": mergedTransports.joined(separator: ","),
            ]
        )
    }

    func audioPlaybackAckTransportLabel(_ transport: IncomingAudioPayloadTransport) -> String {
        switch transport {
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

    func audioPayloadIdentity(_ payload: String) -> (transportDigest: String, encryptedSequenceNumber: UInt64?) {
        let sequenceNumber: UInt64?
        if MediaEncryptedAudioPacket.isEncodedPacket(payload) {
            sequenceNumber = try? MediaEndToEndEncryption.decodePacket(payload).sequenceNumber
        } else {
            sequenceNumber = nil
        }
        return (AudioChunkPayloadCodec.transportDigest(payload), sequenceNumber)
    }

    @discardableResult
    func noteFirstOutboundAudioPayloadQueuedIfNeeded(
        _ payload: String,
        target: TransmitTarget,
        deliveredTransports: [String]
    ) -> Bool {
        guard firstAudioPlaybackAckExpectationsByContactID[target.contactID] == nil else { return false }
        let senderDeviceID = backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        let key = firstAudioPlaybackAckKey(
            contactID: target.contactID,
            channelID: target.channelID,
            senderDeviceID: senderDeviceID,
            receiverDeviceID: target.deviceID
        )
        guard !firstAudioPlaybackAckCompletedKeys.contains(key) else { return false }
        let identity = audioPayloadIdentity(payload)
        let ackID = UUID().uuidString
        let expectation = FirstAudioPlaybackAckExpectation(
            ackID: ackID,
            contactID: target.contactID,
            channelID: target.channelID,
            senderDeviceID: senderDeviceID,
            receiverDeviceID: target.deviceID,
            transportDigest: identity.transportDigest,
            encryptedSequenceNumber: identity.encryptedSequenceNumber,
            queuedAt: Date(),
            deliveredTransports: deliveredTransports
        )
        firstAudioPlaybackAckExpectationsByContactID[target.contactID] = expectation
        let timeoutNanoseconds = firstAudioPlaybackAckTimeoutNanoseconds
        firstAudioPlaybackAckTimeoutTasksByContactID[target.contactID]?.cancel()
        firstAudioPlaybackAckTimeoutTasksByContactID[target.contactID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            await MainActor.run {
                self?.handleFirstAudioPlaybackAckTimeout(
                    contactID: target.contactID,
                    ackID: ackID
                )
            }
        }
        diagnostics.record(
            .media,
            message: "Awaiting first audio playback ACK",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "senderDeviceId": expectation.senderDeviceID,
                "receiverDeviceId": target.deviceID,
                "transportDigest": identity.transportDigest,
                "encryptedSequenceNumber": identity.encryptedSequenceNumber.map(String.init) ?? "none",
                "deliveredTransports": deliveredTransports.joined(separator: ","),
                "ackId": ackID,
            ]
        )
        return true
    }

    func handleFirstAudioPlaybackAckTimeout(contactID: UUID, ackID: String) {
        guard let expectation = firstAudioPlaybackAckExpectationsByContactID[contactID],
              expectation.ackID == ackID else {
            return
        }
        firstAudioPlaybackAckTimeoutTasksByContactID[contactID] = nil
        let timeoutMilliseconds = firstAudioPlaybackAckTimeoutNanoseconds / 1_000_000
        diagnostics.recordContractViolation(
            DiagnosticsContracts.Media.firstAudioPlaybackAckMissing(
                contactID: contactID,
                channelID: expectation.channelID,
                senderDeviceID: expectation.senderDeviceID,
                receiverDeviceID: expectation.receiverDeviceID,
                transportDigest: expectation.transportDigest,
                encryptedSequenceNumber: expectation.encryptedSequenceNumber,
                deliveredTransports: expectation.deliveredTransports,
                timeoutMilliseconds: timeoutMilliseconds,
                ackID: expectation.ackID
            )
        )
        diagnostics.record(
            .media,
            level: .error,
            message: "Timed out waiting for first audio playback ACK",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": expectation.channelID,
                "receiverDeviceId": expectation.receiverDeviceID,
                "transportDigest": expectation.transportDigest,
                "ackId": expectation.ackID,
            ]
        )
    }

    func handleAudioPlaybackStartedAck(
        _ payload: TurboAudioPlaybackStartedPayload,
        contactID: UUID,
        source: ControlEventSource
    ) {
        let completedKey = firstAudioPlaybackAckKey(
            contactID: contactID,
            channelID: payload.channelId,
            senderDeviceID: payload.senderDeviceId,
            receiverDeviceID: payload.receiverDeviceId
        )
        guard let expectation = firstAudioPlaybackAckExpectationsByContactID[contactID] else {
            if firstAudioPlaybackAckCompletedKeys.contains(completedKey) {
                let verifiedDirectAudio = payload.transport == "direct-quic"
                if verifiedDirectAudio {
                    directAudioPlaybackVerifiedKeys.insert(completedKey)
                }
                diagnostics.record(
                    .media,
                    message: verifiedDirectAudio
                        ? "Recorded delayed Direct QUIC audio playback ACK after completed expectation"
                        : "Ignored duplicate audio playback ACK after completed expectation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": payload.channelId,
                        "senderDeviceId": payload.senderDeviceId,
                        "receiverDeviceId": payload.receiverDeviceId,
                        "transport": payload.transport,
                        "transportDigest": payload.transportDigest,
                        "ackId": payload.ackId,
                        "source": source.rawValue,
                        "verifiedDirectAudio": String(verifiedDirectAudio),
                    ]
                )
                return
            }
            if let encryptedSequenceNumber = payload.encryptedSequenceNumber,
               encryptedSequenceNumber > 0 {
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Ignored stale non-initial audio playback ACK without pending expectation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": payload.channelId,
                        "senderDeviceId": payload.senderDeviceId,
                        "receiverDeviceId": payload.receiverDeviceId,
                        "transport": payload.transport,
                        "transportDigest": payload.transportDigest,
                        "encryptedSequenceNumber": String(encryptedSequenceNumber),
                        "ackId": payload.ackId,
                        "source": source.rawValue,
                    ]
                )
                return
            }
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.firstAudioAckHasExpectation(
                    contactID: contactID,
                    channelID: payload.channelId,
                    senderDeviceID: payload.senderDeviceId,
                    receiverDeviceID: payload.receiverDeviceId,
                    transportDigest: payload.transportDigest,
                    encryptedSequenceNumber: payload.encryptedSequenceNumber,
                    ackID: payload.ackId,
                    source: source.rawValue
                )
            )
            return
        }

        let expectedSequenceNumber = expectation.encryptedSequenceNumber
        let receivedSequenceNumber = payload.encryptedSequenceNumber
        let packetRelayFallbackAck =
            expectation.encryptedSequenceNumber == nil
            && payload.encryptedSequenceNumber == nil
            && expectation.deliveredTransports.contains("media-relay-packet")
            && (payload.transport == "relay-websocket" || payload.transport == "media-relay-tcp")
        let orderedRelayAckForCurrentExpectation =
            expectation.encryptedSequenceNumber == nil
            && payload.encryptedSequenceNumber == nil
            && expectation.deliveredTransports.contains(payload.transport)
            && (payload.transport == "relay-websocket" || payload.transport == "media-relay-tcp")
        let unorderedPacketAckForCurrentExpectation =
            expectation.encryptedSequenceNumber == nil
            && payload.encryptedSequenceNumber == nil
            && expectation.deliveredTransports.contains(payload.transport)
            && (payload.transport == "direct-quic" || payload.transport == "media-relay-packet")
        let deliveredTransportMatches =
            expectation.deliveredTransports.isEmpty
            || expectation.deliveredTransports.contains(payload.transport)
            || packetRelayFallbackAck
        let packetIdentityMatches: Bool
        if let expectedSequenceNumber, let receivedSequenceNumber {
            packetIdentityMatches = receivedSequenceNumber >= expectedSequenceNumber
        } else if packetRelayFallbackAck
                    || orderedRelayAckForCurrentExpectation
                    || unorderedPacketAckForCurrentExpectation {
            packetIdentityMatches = true
        } else {
            packetIdentityMatches = payload.transportDigest == expectation.transportDigest
        }
        let matches =
            payload.channelId == expectation.channelID
            && payload.senderDeviceId == expectation.senderDeviceID
            && payload.receiverDeviceId == expectation.receiverDeviceID
            && deliveredTransportMatches
            && packetIdentityMatches
        guard matches else {
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.firstAudioAckMatchesExpectation(
                    contactID: contactID,
                    expectedChannelID: expectation.channelID,
                    receivedChannelID: payload.channelId,
                    expectedSenderDeviceID: expectation.senderDeviceID,
                    receivedSenderDeviceID: payload.senderDeviceId,
                    expectedReceiverDeviceID: expectation.receiverDeviceID,
                    receivedReceiverDeviceID: payload.receiverDeviceId,
                    expectedTransports: expectation.deliveredTransports,
                    receivedTransport: payload.transport,
                    expectedTransportDigest: expectation.transportDigest,
                    receivedTransportDigest: payload.transportDigest,
                    expectedEncryptedSequenceNumber: expectedSequenceNumber,
                    receivedEncryptedSequenceNumber: receivedSequenceNumber,
                    ackID: payload.ackId,
                    source: source.rawValue
                )
            )
            return
        }

        firstAudioPlaybackAckTimeoutTasksByContactID[contactID]?.cancel()
        firstAudioPlaybackAckTimeoutTasksByContactID[contactID] = nil
        firstAudioPlaybackAckExpectationsByContactID[contactID] = nil
        firstAudioPlaybackAckCompletedKeys.insert(completedKey)
        if payload.transport == "direct-quic" {
            directAudioPlaybackVerifiedKeys.insert(completedKey)
        }
        diagnostics.record(
            .media,
            message: "First audio playback ACK received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "senderDeviceId": payload.senderDeviceId,
                "receiverDeviceId": payload.receiverDeviceId,
                "transport": payload.transport,
                "transportDigest": payload.transportDigest,
                "encryptedSequenceNumber": payload.encryptedSequenceNumber.map(String.init) ?? "none",
                "source": source.rawValue,
                "ackId": payload.ackId,
                "waitedMs": String(Int(Date().timeIntervalSince(expectation.queuedAt) * 1000)),
            ]
        )
    }

    func sendFirstAudioPlaybackStartedAckIfNeeded(
        originalPayload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) async {
        guard let backend = backendServices else { return }
        let sentKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: fromDeviceID,
            receiverDeviceID: backend.deviceID
        )
        let identity = audioPayloadIdentity(originalPayload)
        if let encryptedSequenceNumber = identity.encryptedSequenceNumber,
           let sentSequenceNumber = firstAudioPlaybackAckSentEncryptedSequenceByKey[sentKey],
           firstAudioPlaybackAckSentKeys.contains(sentKey)
                || encryptedSequenceNumber > sentSequenceNumber {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Suppressed duplicate first audio playback ACK for encrypted receive epoch",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": fromDeviceID,
                    "receiverDeviceId": backend.deviceID,
                    "transportDigest": identity.transportDigest,
                    "incomingTransport": audioPlaybackAckTransportLabel(incomingAudioTransport),
                    "encryptedSequenceNumber": String(encryptedSequenceNumber),
                    "sentEncryptedSequenceNumber": String(sentSequenceNumber),
                    "sentLatchArmed": String(firstAudioPlaybackAckSentKeys.contains(sentKey)),
                ]
            )
            return
        }
        guard !firstAudioPlaybackAckSentKeys.contains(sentKey) else { return }
        firstAudioPlaybackAckSentKeys.insert(sentKey)
        if let encryptedSequenceNumber = identity.encryptedSequenceNumber {
            firstAudioPlaybackAckSentEncryptedSequenceByKey[sentKey] = encryptedSequenceNumber
        }
        let payload = TurboAudioPlaybackStartedPayload(
            ackId: UUID().uuidString,
            channelId: channelID,
            senderDeviceId: fromDeviceID,
            receiverDeviceId: backend.deviceID,
            transport: audioPlaybackAckTransportLabel(incomingAudioTransport),
            transportDigest: identity.transportDigest,
            encryptedSequenceNumber: identity.encryptedSequenceNumber
        )
        var sentTransports: [String] = []
        var failures: [String] = []

        do {
            let envelope = try TurboSignalEnvelope.audioPlaybackStarted(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: fromUserID,
                toDeviceId: fromDeviceID,
                payload: payload
            )
            try await backend.client.sendSignal(envelope)
            sentTransports.append("relay-websocket")
        } catch {
            failures.append("relay-websocket:\(error.localizedDescription)")
        }

        if let controller = mediaRuntime.directQuicProbeController {
            do {
                try await controller.sendAudioPlaybackStarted(payload)
                sentTransports.append("direct-quic")
            } catch {
                failures.append("direct-quic:\(error.localizedDescription)")
            }
        }

        if let relayClient = mediaRuntime.mediaRelayClient {
            do {
                try await relayClient.sendAudioPlaybackStarted(payload)
                sentTransports.append("media-relay")
            } catch {
                failures.append("media-relay:\(error.localizedDescription)")
            }
        }

        guard !sentTransports.isEmpty else {
            firstAudioPlaybackAckSentKeys.remove(sentKey)
            if let encryptedSequenceNumber = identity.encryptedSequenceNumber,
               firstAudioPlaybackAckSentEncryptedSequenceByKey[sentKey] == encryptedSequenceNumber {
                firstAudioPlaybackAckSentEncryptedSequenceByKey.removeValue(forKey: sentKey)
            }
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to send first audio playback ACK",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": fromDeviceID,
                    "receiverDeviceId": backend.deviceID,
                    "transportDigest": identity.transportDigest,
                    "failures": failures.joined(separator: ","),
                    "ackId": payload.ackId,
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Sent first audio playback ACK",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "senderDeviceId": fromDeviceID,
                "receiverDeviceId": backend.deviceID,
                "incomingTransport": payload.transport,
                "sentTransports": sentTransports.joined(separator: ","),
                "transportDigest": identity.transportDigest,
                "encryptedSequenceNumber": identity.encryptedSequenceNumber.map(String.init) ?? "none",
                "ackId": payload.ackId,
            ]
        )
    }

    func clearStaleMediaRelayClient(
        localDeviceID: String,
        channelID: String,
        peerDeviceID: String,
        client: TurboMediaRelayClient,
        reason: String
    ) {
        let key = MediaRelayConnectionKey(
            sessionID: channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
        mediaRuntime.clearMediaRelayClient(matching: key, client: client)
        diagnostics.record(
            .media,
            message: "Cleared stale media relay client after peer unavailable",
            metadata: [
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
            ]
        )
    }

    func suppressMediaRelayAudioSendUntilNextIdlePrewarm(
        localDeviceID: String,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        reason: String
    ) {
        let key = MediaRelayConnectionKey(
            sessionID: channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
        mediaRuntime.suppressMediaRelayAudioSend(for: key)
        diagnostics.record(
            .media,
            message: "Holding WebSocket relay for active transmit after media relay peer unavailable",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
            ]
        )
    }

    func clearMediaRelayAudioSendSuppressionIfPresent(
        target: TransmitTarget,
        reason: String
    ) {
        let localDeviceID = backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        guard !localDeviceID.isEmpty else { return }
        let key = MediaRelayConnectionKey(
            sessionID: target.channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: target.deviceID
        )
        guard mediaRuntime.clearMediaRelayAudioSendSuppression(for: key) else { return }
        diagnostics.record(
            .media,
            message: "Cleared media relay send suppression",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "peerDeviceId": target.deviceID,
                "reason": reason,
            ]
        )
    }

    func shouldTreatTransmitLeaseLossAsStop(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no active transmit state for sender"
    }

    func shouldAbortAudioTailOnExplicitStop(target: TransmitTarget) -> Bool {
        switch mediaTransportPolicyForOutgoingAudio(for: target.contactID) {
        case .directLowLatency, .fastRelayBalanced:
            return true
        case .websocketContinuity, .wakeBackgroundContinuity:
            return false
        }
    }

    func stopOutgoingAudioForExplicitTransmitStop(
        _ mediaSession: (any MediaSession)?,
        target: TransmitTarget
    ) async {
        guard let mediaSession else { return }
        if shouldAbortAudioTailOnExplicitStop(target: target) {
            diagnostics.record(
                .media,
                message: "Aborting live packet audio tail on explicit transmit stop",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "transportPath": mediaTransportPathState.rawValue,
                    "transportPolicy": mediaTransportPolicyForOutgoingAudio(for: target.contactID).rawValue,
                ]
            )
            await mediaSession.abortSendingAudio()
        } else {
            try? await mediaSession.stopSendingAudio()
        }
    }

    func cutLocalOutgoingAudioImmediatelyForExplicitStop(
        target: TransmitTarget,
        reason: String
    ) {
        let media = mediaServices
        let mediaSession = media.session()
        transmitTaskRuntime.cancelCaptureReassertionTask()
        media.replaceSendAudioChunk(nil)
        mediaSession?.updateSendAudioChunk(nil)
        if let currentSession = media.session(), currentSession !== mediaSession {
            currentSession.updateSendAudioChunk(nil)
        }
        diagnostics.record(
            .media,
            message: "Cut local outgoing audio immediately for explicit transmit stop",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "reason": reason,
                "transportPath": mediaTransportPathState.rawValue,
                "transportPolicy": mediaTransportPolicyForOutgoingAudio(for: target.contactID).rawValue,
            ]
        )
        Task { [weak self, weak mediaSession] in
            guard let self else { return }
            await self.stopOutgoingAudioForExplicitTransmitStop(
                mediaSession,
                target: target
            )
        }
    }

    @discardableResult
    func requireOutgoingAudioTargetMatchesContact(
        _ target: TransmitTarget,
        localDeviceID: String,
        reason: String
    ) -> Bool {
        let contact = contacts.first(where: { $0.id == target.contactID })
        let targetMatchesContact =
            contact?.backendChannelId == target.channelID
            && contact?.remoteUserId == target.userID
            && !target.deviceID.isEmpty
            && target.deviceID != localDeviceID
        return diagnostics.requireContract(
            targetMatchesContact,
            DiagnosticsContracts.Transmit.targetMatchesContact(
                contactID: target.contactID,
                expectedChannelID: contact?.backendChannelId,
                targetChannelID: target.channelID,
                expectedRemoteUserID: contact?.remoteUserId,
                targetUserID: target.userID,
                targetDeviceID: target.deviceID,
                localDeviceID: localDeviceID,
                reason: reason
            ),
            metadata: ["contactFound": String(contact != nil)]
        )
    }

    @discardableResult
    func requireOutgoingAudioSendBelongsToCurrentTarget(
        _ target: TransmitTarget,
        source: String
    ) -> Bool {
        let activeEpoch = engine.snapshot.transmit.activeEpoch
        let activeSession = activeEpoch?.conversation
        let engineMatches =
            activeSession?.friend.contactID.rawValue == target.contactID.uuidString
            && activeSession?.channelID.rawValue == target.channelID
            && activeSession?.peerDeviceID?.rawValue == target.deviceID
        let appMatches =
            transmitCoordinator.state.activeTarget == target
            || transmitRuntime.activeTarget == target
        let activeContactID = activeSession
            .flatMap { UUID(uuidString: $0.friend.contactID.rawValue) }
            ?? transmitCoordinator.state.activeTarget?.contactID
            ?? transmitRuntime.activeTarget?.contactID
        let activeChannelID =
            activeSession?.channelID.rawValue
            ?? transmitCoordinator.state.activeTarget?.channelID
            ?? transmitRuntime.activeTarget?.channelID
        let activeDeviceID =
            activeSession?.peerDeviceID?.rawValue
            ?? transmitCoordinator.state.activeTarget?.deviceID
            ?? transmitRuntime.activeTarget?.deviceID
        return diagnostics.requireContract(
            engineMatches || appMatches,
            DiagnosticsContracts.Transmit.outgoingAudioSendRequiresCurrentTarget(
                contactID: target.contactID,
                channelID: target.channelID,
                targetDeviceID: target.deviceID,
                activeContactID: activeContactID,
                activeChannelID: activeChannelID,
                activeDeviceID: activeDeviceID,
                source: source
            ),
            metadata: [
                "engineMatches": String(engineMatches),
                "appMatches": String(appMatches),
            ]
        )
    }

    func configureOutgoingAudioRoute(target: TransmitTarget) {
        guard let backend = backendServices else {
            mediaServices.replaceSendAudioChunk(nil)
            mediaServices.session()?.updateSendAudioChunk(nil)
            diagnostics.record(
                .media,
                level: .error,
                message: "Cleared outgoing audio transport because backend services are unavailable",
                metadata: ["contactId": target.contactID.uuidString, "channelId": target.channelID]
            )
            return
        }

        let channelID = target.channelID
        let fromUserID = backend.currentUserID ?? ""
        let fromDeviceID = backend.deviceID
        let toUserID = target.userID
        let toDeviceID = target.deviceID
        guard requireOutgoingAudioTargetMatchesContact(
            target,
            localDeviceID: fromDeviceID,
            reason: "configure-outgoing-audio-route"
        ) else {
            mediaServices.replaceSendAudioChunk(nil)
            mediaServices.session()?.updateSendAudioChunk(nil)
            return
        }
        let diagnosticsStore = diagnostics
        let slowOutboundAudioSendStageThresholdNanoseconds: UInt64 = 40_000_000
        let recordSlowOutboundAudioSendStage: @Sendable (String, UInt64, Int) -> Void = {
            stage,
            startedAt,
            payloadLength in
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            let elapsedNanoseconds = finishedAt >= startedAt ? finishedAt - startedAt : 0
            guard elapsedNanoseconds >= slowOutboundAudioSendStageThresholdNanoseconds else { return }
            diagnosticsStore.record(
                .media,
                level: .notice,
                message: "Outbound audio send stage was slow",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "toDeviceId": target.deviceID,
                    "stage": stage,
                    "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                    "payloadLength": String(payloadLength),
                ]
            )
        }
        configureMediaEncryptionSessionIfPossible(
            contactID: target.contactID,
            channelID: channelID,
            peerDeviceID: toDeviceID
        )
        let mediaPayloadSealer = outgoingMediaPayloadSealer(target: target)
        let routeIsRelayOnlyForced = isDirectPathRelayOnlyForced
        let routeIsMediaRelayForced = TurboMediaRelayDebugOverride.isForced()
        let configuredTransportPathState = mediaTransportPathState
        let directAudioAckKey = FirstAudioPlaybackAckSentKey(
            contactID: target.contactID,
            channelID: target.channelID,
            senderDeviceID: fromDeviceID,
            receiverDeviceID: target.deviceID
        )
        let directTransportForAudioSend = shouldUseDirectQuicAudioTransport(for: target.contactID)
            ? mediaRuntime.directQuicProbeController
            : nil
        let mediaRelayAudioSendOverride = self.mediaRelayAudioSendOverride
        let directQuicAudioSendOverride = self.directQuicAudioSendOverride
        let directAudioInitiallyVerified = directAudioPlaybackVerifiedKeys.contains(directAudioAckKey)
        let directAckPrearmGate = MediaHotPathOneShotGate(consumed: directAudioInitiallyVerified)
        let firstPlaybackAckExpectationGate = MediaHotPathOneShotGate(
            consumed: firstAudioPlaybackAckExpectationsByContactID[target.contactID] != nil
                || firstAudioPlaybackAckCompletedKeys.contains(directAudioAckKey)
        )
        let localAudioCapturedSyncLimiter = MediaHotPathEventLimiter(
            minimumIntervalNanoseconds: 250_000_000
        )
        let outboundDeliveryDiagnosticsLimiter = MediaHotPathEventLimiter(
            minimumIntervalNanoseconds: 1_000_000_000
        )
        let initialOutboundAudioSendGate = MediaHotPathOneShotGate(
            consumed: !takeShouldAwaitInitialOutboundAudioSendGate()
        )
        let outgoingAudioSendTargetGate = mediaRuntime.outgoingAudioSendTargetGate
        let outgoingAudioSendTargetToken = outgoingAudioSendTargetGate.install(target)
        let sendAudioChunk: @Sendable (String) async throws -> Void = { [weak self] payload in
            try Task.checkCancellation()
            guard outgoingAudioSendTargetGate.allows(outgoingAudioSendTargetToken) else {
                return
            }
            if let self,
               initialOutboundAudioSendGate.take() {
                let stageStartedAt = DispatchTime.now().uptimeNanoseconds
                let receiverBecameReady = await self.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
                    target: target
                )
                recordSlowOutboundAudioSendStage(
                    "receiver-readiness-gate",
                    stageStartedAt,
                    payload.count
                )
                try Task.checkCancellation()
                guard receiverBecameReady else {
                    throw OutgoingAudioSendError.remoteReceiverAudioNotReady
                }
            }

            let payloadContainsLegacyPCM = VoiceAudioFramePayloadCodec.decodeTransportFrames(payload)?.contains {
                if case .legacyPCM = $0 {
                    return true
                }
                return false
            } == true
            let transportPayload: String
            let sealStartedAt = DispatchTime.now().uptimeNanoseconds
            transportPayload = try mediaPayloadSealer.seal(payload)
            recordSlowOutboundAudioSendStage(
                "media-e2ee-seal",
                sealStartedAt,
                transportPayload.count
            )
            try Task.checkCancellation()
            let scheduleLocalAudioCapturedSync: @Sendable (String) -> Void = { [weak self] deliveredPayload in
                guard localAudioCapturedSyncLimiter.take() else { return }
                Task(priority: .utility) { @MainActor [weak self] in
                    guard let self else { return }
                    _ = self.syncEngineLocalAudioCaptured(
                        payload: deliveredPayload,
                        target: target,
                        source: "send-audio-chunk-delivered"
                    )
                }
            }

            let relaySend: @Sendable () async throws -> Void = { [weak self] in
                try Task.checkCancellation()
                let relayPayload: String
                if let self {
                    relayPayload = await MainActor.run {
                        self.relayWebSocketAudioSignalPayload(transportPayload, target: target)
                    }
                } else {
                    relayPayload = transportPayload
                }
                let envelope = TurboSignalEnvelope(
                    type: .audioChunk,
                    channelId: channelID,
                    fromUserId: fromUserID,
                    fromDeviceId: fromDeviceID,
                    toUserId: toUserID,
                    toDeviceId: toDeviceID,
                    payload: relayPayload
                )
                try await backend.sendSignal(envelope)
            }
            let mediaRelaySend: @Sendable (TurboMediaRelayClient) async throws -> TurboMediaRelayMediaMode = { relayClient in
                try Task.checkCancellation()
                if let mediaRelayAudioSendOverride {
                    return try await mediaRelayAudioSendOverride(relayClient, transportPayload)
                }
                return try await relayClient.sendAudioPayload(transportPayload)
            }
            let recordMediaRelayTcpContinuityFailure: @Sendable (String, String, Error) -> Void = {
                message,
                reason,
                error in
                diagnosticsStore.record(
                    .media,
                    level: .notice,
                    message: message,
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "toDeviceId": target.deviceID,
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
            let isMediaRelayTcpContinuityPath: @Sendable (TurboMediaRelayClient) -> Bool = { relayClient in
                relayClient.currentMediaMode() == .tcpOrdered
                    || configuredTransportPathState == .fastRelayTcp
            }
            let shouldBypassMediaRelayPacketForLegacyPCM: @Sendable (TurboMediaRelayClient) -> Bool = { relayClient in
                payloadContainsLegacyPCM && !isMediaRelayTcpContinuityPath(relayClient)
            }
            let recordLegacyPCMMediaRelayPacketBypass: @Sendable (String) -> Void = { reason in
                guard outboundDeliveryDiagnosticsLimiter.take() else { return }
                diagnosticsStore.record(
                    .media,
                    level: .notice,
                    message: "Bypassed media relay packet audio for legacy PCM payload",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "toDeviceId": target.deviceID,
                        "reason": reason,
                        "payloadLength": String(payload.count),
                        "transportPayloadLength": String(transportPayload.count),
                    ]
                )
            }
            let sendMediaRelayTcpInBackground: @Sendable (TurboMediaRelayClient, String) -> Void = {
                relayClient,
                reason in
                Task(priority: .userInitiated) {
                    do {
                        let stageStartedAt = DispatchTime.now().uptimeNanoseconds
                        _ = try await mediaRelaySend(relayClient)
                        recordSlowOutboundAudioSendStage(
                            "media-relay-tcp-background-send",
                            stageStartedAt,
                            transportPayload.count
                        )
                    } catch is CancellationError {
                    } catch {
                        recordMediaRelayTcpContinuityFailure(
                            "Media relay TCP background continuity send failed",
                            reason,
                            error
                        )
                    }
                }
            }
            if let self {
                if routeIsRelayOnlyForced {
                    try await relaySend()
                    scheduleLocalAudioCapturedSync(transportPayload)
                    await MainActor.run {
                        _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                            transportPayload,
                            target: target,
                            deliveredTransports: ["relay-websocket"]
                        )
                    }
                    return
                }

                let shouldUseWakeContinuityAudioPath = await MainActor.run {
                    self.shouldUseWakeBackgroundContinuityForOutgoingAudio(for: target.contactID)
                }
                if shouldUseWakeContinuityAudioPath {
                    let shouldRecoverWithMediaRelay = await MainActor.run {
                        self.currentApplicationState() != .active
                            && self.backendServices?.isWebSocketConnected != true
                            && (self.mediaRuntime.hasActiveMediaRelayClient
                                || self.mediaRuntime.hasInFlightMediaRelayConnection)
                    }
                    if shouldRecoverWithMediaRelay,
                       let relayClient = await self.mediaRelayClientForAudioSend(target: target) {
                        do {
                            let mediaMode = try await mediaRelaySend(relayClient)
                            let deliveredTransport = IncomingAudioPayloadTransport(
                                mediaRelayMediaMode: mediaMode
                            ).diagnosticsValue
                            scheduleLocalAudioCapturedSync(transportPayload)
                            await MainActor.run {
                                _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                    transportPayload,
                                    target: target,
                                    deliveredTransports: [deliveredTransport]
                                )
                                if outboundDeliveryDiagnosticsLimiter.take() {
                                    self.diagnostics.record(
                                        .media,
                                        message: "Sent outbound audio over media relay background-continuity path",
                                        metadata: [
                                            "contactId": target.contactID.uuidString,
                                            "channelId": target.channelID,
                                            "toDeviceId": target.deviceID,
                                            "transport": deliveredTransport,
                                            "transportPath": self.mediaTransportPathState.rawValue,
                                            "applicationState": String(describing: self.currentApplicationState()),
                                        ]
                                    )
                                }
                            }
                            return
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await MainActor.run {
                                self.diagnostics.record(
                                    .media,
                                    level: .error,
                                    message: "Media relay background-continuity audio send failed; falling back to WebSocket relay",
                                    metadata: [
                                        "contactId": target.contactID.uuidString,
                                        "channelId": target.channelID,
                                        "error": error.localizedDescription,
                                    ]
                                )
                            }
                        }
                    }
                    try await relaySend()
                    scheduleLocalAudioCapturedSync(transportPayload)
                    await MainActor.run {
                        _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                            transportPayload,
                            target: target,
                            deliveredTransports: ["relay-websocket"]
                        )
                        if outboundDeliveryDiagnosticsLimiter.take() {
                            self.diagnostics.record(
                                .media,
                                message: "Sent outbound audio over WebSocket wake-continuity path",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "toDeviceId": target.deviceID,
                                    "transportPath": self.mediaTransportPathState.rawValue,
                                    "applicationState": String(describing: self.currentApplicationState()),
                                ]
                            )
                        }
                    }
                    return
                }

                if routeIsMediaRelayForced {
                    let shouldUseWebSocketContinuityForUnacknowledgedRelay = await MainActor.run {
                        self.shouldUseWebSocketContinuityForUnacknowledgedForcedMediaRelay(target: target)
                    }
                    if shouldUseWebSocketContinuityForUnacknowledgedRelay {
                        await MainActor.run {
                            self.clearMediaRelayClientAfterUnacknowledgedPrewarmIfPresent(
                                target: target,
                                localDeviceID: fromDeviceID
                            )
                        }
                        try await relaySend()
                        scheduleLocalAudioCapturedSync(transportPayload)
                        await MainActor.run {
                            _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                transportPayload,
                                target: target,
                                deliveredTransports: ["relay-websocket"]
                            )
                            if outboundDeliveryDiagnosticsLimiter.take() {
                                self.diagnostics.record(
                                    .media,
                                    message: "Sent outbound audio over WebSocket continuity while forced media relay prewarm is unacknowledged",
                                    metadata: [
                                        "contactId": target.contactID.uuidString,
                                        "channelId": target.channelID,
                                        "toDeviceId": target.deviceID,
                                        "transportPath": self.mediaTransportPathState.rawValue,
                                    ]
                                )
                            }
                        }
                        return
                    }
                    if let relayClient = await self.mediaRelayClientForAudioSend(target: target) {
                        let bypassMediaRelayPacket = shouldBypassMediaRelayPacketForLegacyPCM(relayClient)
                        if bypassMediaRelayPacket {
                            recordLegacyPCMMediaRelayPacketBypass("forced-media-relay-packet-legacy-pcm")
                        } else if isMediaRelayTcpContinuityPath(relayClient) {
                            var prearmedTcpContinuityAckExpectation = false
                            do {
                                prearmedTcpContinuityAckExpectation = await MainActor.run {
                                    self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                        transportPayload,
                                        target: target,
                                        deliveredTransports: ["relay-websocket", "media-relay-tcp"]
                                    )
                                }
                                try await relaySend()
                                sendMediaRelayTcpInBackground(relayClient, "forced-media-relay-tcp")
                                scheduleLocalAudioCapturedSync(transportPayload)
                                return
                            } catch is CancellationError {
                                if prearmedTcpContinuityAckExpectation {
                                    await MainActor.run {
                                        self.clearFirstAudioPlaybackAckState(
                                            contactID: target.contactID,
                                            channelID: target.channelID,
                                            senderDeviceID: fromDeviceID
                                        )
                                    }
                                }
                                throw CancellationError()
                            } catch {
                                if prearmedTcpContinuityAckExpectation {
                                    await MainActor.run {
                                        self.clearFirstAudioPlaybackAckState(
                                            contactID: target.contactID,
                                            channelID: target.channelID,
                                            senderDeviceID: fromDeviceID
                                        )
                                    }
                                }
                                recordMediaRelayTcpContinuityFailure(
                                    "Media relay TCP WebSocket continuity send failed",
                                    "forced-media-relay-tcp",
                                    error
                                )
                            }
                        }
                        if !bypassMediaRelayPacket {
                            do {
                                let mediaMode = try await mediaRelaySend(relayClient)
                                let deliveredTransport = IncomingAudioPayloadTransport(
                                    mediaRelayMediaMode: mediaMode
                                ).diagnosticsValue
                                let expectedAckTransports =
                                    mediaMode == .tcpOrdered
                                    ? [deliveredTransport, "relay-websocket"]
                                    : [deliveredTransport]
                                scheduleLocalAudioCapturedSync(transportPayload)
                                await MainActor.run {
                                    _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                        transportPayload,
                                        target: target,
                                        deliveredTransports: expectedAckTransports
                                    )
                                }
                                if mediaMode == .tcpOrdered {
                                    do {
                                        try await relaySend()
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        recordMediaRelayTcpContinuityFailure(
                                            "Media relay TCP WebSocket continuity send failed",
                                            "forced-media-relay-tcp",
                                            error
                                        )
                                    }
                                }
                                return
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                await MainActor.run {
                                    self.recordMediaRelayPeerUnavailableInvariantIfNeeded(
                                        error: error,
                                        contactID: target.contactID,
                                        channelID: target.channelID,
                                        peerDeviceID: target.deviceID,
                                        operation: "audio-payload"
                                    )
                                    self.diagnostics.record(
                                        .media,
                                        level: .error,
                                        message: "Media relay audio send failed; falling back to WebSocket relay",
                                        metadata: [
                                            "contactId": target.contactID.uuidString,
                                            "channelId": target.channelID,
                                            "error": error.localizedDescription,
                                        ]
                                    )
                                    if self.isMediaRelayPeerUnavailable(error) {
                                        self.suppressMediaRelayAudioSendUntilNextIdlePrewarm(
                                            localDeviceID: fromDeviceID,
                                            contactID: target.contactID,
                                            channelID: target.channelID,
                                            peerDeviceID: target.deviceID,
                                            reason: "audio-payload"
                                        )
                                        self.clearStaleMediaRelayClient(
                                            localDeviceID: fromDeviceID,
                                            channelID: target.channelID,
                                            peerDeviceID: target.deviceID,
                                            client: relayClient,
                                            reason: "audio-payload"
                                        )
                                    }
                                }
                            }
                        }
                    }
                    try await relaySend()
                    scheduleLocalAudioCapturedSync(transportPayload)
                    await MainActor.run {
                        _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                            transportPayload,
                            target: target,
                            deliveredTransports: ["relay-websocket"]
                        )
                    }
                    return
                }

                var deliveredTransports: [String] = []
                var deliveryFailures: [(transport: String, error: Error)] = []
                var shouldShadowMediaRelayTcpOverWebSocket = false
                let directTransport = directTransportForAudioSend
                var prearmedDirectAckExpectation = false
                var directAckPrearmTask: Task<Void, Never>?
                if let directTransport {
                    do {
                        if directAckPrearmGate.take() {
                            prearmedDirectAckExpectation = true
                            directAckPrearmTask = Task { @MainActor [weak self] in
                                guard !Task.isCancelled else { return }
                                guard let self else { return }
                                _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                    transportPayload,
                                    target: target,
                                    deliveredTransports: ["direct-quic"]
                                )
                            }
                        }
                        try Task.checkCancellation()
                        let directSendStartedAt = DispatchTime.now().uptimeNanoseconds
                        if let directQuicAudioSendOverride {
                            try await directQuicAudioSendOverride(directTransport, transportPayload)
                        } else {
                            try await directTransport.sendAudioPayload(transportPayload)
                        }
                        recordSlowOutboundAudioSendStage(
                            "direct-quic-send",
                            directSendStartedAt,
                            transportPayload.count
                        )
                        deliveredTransports.append("direct-quic")
                        scheduleLocalAudioCapturedSync(transportPayload)
                        if !Task.isCancelled, outboundDeliveryDiagnosticsLimiter.take() {
                            diagnosticsStore.record(
                                .media,
                                message: directAudioInitiallyVerified
                                    ? "Delivered outbound audio over verified Direct QUIC transport"
                                    : "Delivered outbound audio over Direct QUIC packet transport",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "verifiedDirectAudio": String(directAudioInitiallyVerified),
                                    "sampled": "true",
                                ]
                            )
                        }
                        if directAudioInitiallyVerified {
                            return
                        }
                    } catch is CancellationError {
                        directAckPrearmTask?.cancel()
                        throw CancellationError()
                    } catch {
                        deliveryFailures.append(("direct-quic", error))
                        directAckPrearmTask?.cancel()
                        if prearmedDirectAckExpectation {
                            await MainActor.run {
                                self.clearFirstAudioPlaybackAckState(
                                    contactID: target.contactID,
                                    channelID: target.channelID,
                                    senderDeviceID: fromDeviceID
                                )
                            }
                            prearmedDirectAckExpectation = false
                        }
                        await MainActor.run {
                            self.directAudioPlaybackVerifiedKeys.remove(directAudioAckKey)
                            self.diagnostics.record(
                                .media,
                                level: .error,
                                message: "Direct QUIC audio send failed during multipath fanout",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "error": error.localizedDescription,
                                ]
                            )
                        }
                    }
                }

                let standbyRelayClient = await self.existingMediaRelayClientForAudioFanout(
                    target: target,
                    localDeviceID: fromDeviceID
                )
                if let relayClient = standbyRelayClient {
                    let shouldSendStandbyRelayAfterUnverifiedDirect =
                        !directAudioInitiallyVerified && deliveredTransports.contains("direct-quic")
                    let bypassMediaRelayPacket = shouldBypassMediaRelayPacketForLegacyPCM(relayClient)
                    if bypassMediaRelayPacket {
                        recordLegacyPCMMediaRelayPacketBypass("media-relay-standby-legacy-pcm")
                    } else if isMediaRelayTcpContinuityPath(relayClient) {
                        var prearmedTcpContinuityAckExpectation = false
                        do {
                            prearmedTcpContinuityAckExpectation = await MainActor.run {
                                self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                    transportPayload,
                                    target: target,
                                    deliveredTransports: ["relay-websocket", "media-relay-tcp"]
                                )
                            }
                            try await relaySend()
                            deliveredTransports.append("relay-websocket")
                            deliveredTransports.append("media-relay-tcp")
                            sendMediaRelayTcpInBackground(relayClient, "media-relay-tcp-standby")
                        } catch is CancellationError {
                            if prearmedTcpContinuityAckExpectation {
                                await MainActor.run {
                                    self.clearFirstAudioPlaybackAckState(
                                        contactID: target.contactID,
                                        channelID: target.channelID,
                                        senderDeviceID: fromDeviceID
                                    )
                                }
                            }
                            throw CancellationError()
                        } catch {
                            if prearmedTcpContinuityAckExpectation {
                                await MainActor.run {
                                    self.clearFirstAudioPlaybackAckState(
                                        contactID: target.contactID,
                                        channelID: target.channelID,
                                        senderDeviceID: fromDeviceID
                                    )
                                }
                            }
                            deliveryFailures.append(("relay-websocket", error))
                            recordMediaRelayTcpContinuityFailure(
                                "Media relay TCP WebSocket continuity send failed",
                                "media-relay-tcp-standby",
                                error
                            )
                        }
                    }
                    if (deliveredTransports.isEmpty || shouldSendStandbyRelayAfterUnverifiedDirect),
                       !bypassMediaRelayPacket {
                        do {
                            let mediaMode = try await mediaRelaySend(relayClient)
                            let deliveredTransport = IncomingAudioPayloadTransport(
                                mediaRelayMediaMode: mediaMode
                            ).diagnosticsValue
                            deliveredTransports.append(deliveredTransport)
                            shouldShadowMediaRelayTcpOverWebSocket = mediaMode == .tcpOrdered
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            deliveryFailures.append((
                                relayClient.currentMediaTransportLabel(),
                                error
                            ))
                            await MainActor.run {
                                self.recordMediaRelayPeerUnavailableInvariantIfNeeded(
                                    error: error,
                                    contactID: target.contactID,
                                    channelID: target.channelID,
                                    peerDeviceID: target.deviceID,
                                    operation: "audio-payload"
                                )
                                self.diagnostics.record(
                                    .media,
                                    level: .error,
                                    message: "Media relay audio send failed during multipath fanout",
                                    metadata: [
                                        "contactId": target.contactID.uuidString,
                                        "channelId": target.channelID,
                                        "error": error.localizedDescription,
                                    ]
                                )
                                if self.isMediaRelayPeerUnavailable(error) {
                                    self.suppressMediaRelayAudioSendUntilNextIdlePrewarm(
                                        localDeviceID: fromDeviceID,
                                        contactID: target.contactID,
                                        channelID: target.channelID,
                                        peerDeviceID: target.deviceID,
                                        reason: "audio-payload"
                                    )
                                    self.clearStaleMediaRelayClient(
                                        localDeviceID: fromDeviceID,
                                        channelID: target.channelID,
                                        peerDeviceID: target.deviceID,
                                        client: relayClient,
                                        reason: "audio-payload"
                                    )
                                }
                            }
                        }
                    }
                }

                if deliveredTransports.isEmpty {
                    do {
                        try await relaySend()
                        deliveredTransports.append("relay-websocket")
                    } catch {
                        deliveryFailures.append(("relay-websocket", error))
                        throw error
                    }
                }

                if deliveredTransports.count > 1 {
                    let deliveredTransportNames = deliveredTransports.joined(separator: ",")
                    let deliveryFailureCount = deliveryFailures.count
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            message: "Delivered outbound audio over multipath transports",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "transports": deliveredTransportNames,
                                "failureCount": String(deliveryFailureCount),
                            ]
                        )
                    }
                }
                if deliveredTransports.isEmpty, let firstFailure = deliveryFailures.first {
                    throw firstFailure.error
                }
                if !deliveredTransports.isEmpty {
                    let expectedAckTransportsSnapshot: [String] = {
                        var transports = deliveredTransports
                        if shouldShadowMediaRelayTcpOverWebSocket,
                           !transports.contains("relay-websocket") {
                            transports.append("relay-websocket")
                        }
                        return transports
                    }()
                    scheduleLocalAudioCapturedSync(transportPayload)
                    if prearmedDirectAckExpectation {
                        await MainActor.run {
                            self.mergeFirstAudioPlaybackAckDeliveredTransportsIfPending(
                                contactID: target.contactID,
                                deliveredTransports: expectedAckTransportsSnapshot
                            )
                        }
                    }
                    if firstPlaybackAckExpectationGate.take() {
                        await MainActor.run {
                            _ = self.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                                transportPayload,
                                target: target,
                                deliveredTransports: expectedAckTransportsSnapshot
                            )
                        }
                    }
                    if shouldShadowMediaRelayTcpOverWebSocket {
                        do {
                            try await relaySend()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            recordMediaRelayTcpContinuityFailure(
                                "Media relay TCP WebSocket continuity send failed",
                                "media-relay-tcp-standby",
                                error
                            )
                        }
                    }
                }
                return
            }

            try await relaySend()
        }
        mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateOutboundVoiceMediaPolicy(
            outboundVoiceMediaPayloadFormat(for: target)
        )
        let opusPolicy = outboundOpusEncodingPolicy(for: target.contactID)
        mediaServices.session()?.updateOutboundOpusEncodingPolicy(opusPolicy)
        diagnostics.record(
            .media,
            message: "Configured outgoing audio transport",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "deviceId": target.deviceID,
                "voiceMediaPolicy": outboundVoiceMediaPayloadFormat(for: target).rawValue,
                "transport": configuredOutgoingAudioTransportLabel(for: target.contactID),
                "directQuicActive": String(shouldUseDirectQuicTransport(for: target.contactID)),
                "mediaRelayEnabled": String(TurboMediaRelayDebugOverride.isEnabled()),
                "mediaRelayForced": String(TurboMediaRelayDebugOverride.isForced()),
                "mediaRelayConfigured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
                "selection": "dynamic",
            ].merging(opusPolicy.diagnosticsMetadata, uniquingKeysWith: { current, _ in current })
        )
        preconnectMediaRelayForAudioSendIfNeeded(target: target)
    }

    func preconnectMediaRelayForAudioSendIfNeeded(target: TransmitTarget) {
        let isIdlePrewarm =
            !transmitCoordinator.state.isPressingTalk
            && !transmitRuntime.isPressingTalk
            && transmitCoordinator.state.activeTarget != target
            && transmitRuntime.activeTarget != target
        let shouldAttempt =
            !isDirectPathRelayOnlyForced
            && (TurboMediaRelayDebugOverride.isEnabled()
            || TurboMediaRelayDebugOverride.isForced()
            )
        guard shouldAttempt else { return }
        guard TurboMediaRelayDebugOverride.config()?.isConfigured == true else { return }
        diagnostics.record(
            .media,
            message: "Preconnecting media relay for audio send",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "peerDeviceId": target.deviceID,
                "forced": String(TurboMediaRelayDebugOverride.isForced()),
            ]
        )
        Task { [weak self] in
            guard let self else { return }
            _ = await self.mediaRelayClientForAudioSend(
                target: target,
                bypassAudioSendSuppression: isIdlePrewarm
            )
        }
    }

    func configuredOutgoingAudioTransportLabel(for contactID: UUID) -> String {
        if isDirectPathRelayOnlyForced {
            return "relay-websocket"
        }
        if TurboMediaRelayDebugOverride.isForced() {
            return "media-relay-forced"
        }
        if shouldUseDirectQuicAudioTransport(for: contactID) {
            return "direct-quic"
        }
        if TurboMediaRelayDebugOverride.isEnabled() {
            return "media-relay-standby"
        }
        return "relay-websocket"
    }

    func shouldUseWebSocketContinuityForUnacknowledgedForcedMediaRelay(target: TransmitTarget) -> Bool {
        guard TurboMediaRelayDebugOverride.isForced() else { return false }
        guard !isDirectPathRelayOnlyForced else { return false }
        guard backendServices?.supportsWebSocket == true else { return false }
        let maximumAge = TimeInterval(directQuicAudioFreshnessMilliseconds) / 1_000
        return !mediaRuntime.receiverPrewarmRequestIsAcknowledged(
            for: target.contactID,
            maximumAge: maximumAge
        )
    }

    func clearMediaRelayClientAfterUnacknowledgedPrewarmIfPresent(
        target: TransmitTarget,
        localDeviceID: String
    ) {
        let key = MediaRelayConnectionKey(
            sessionID: target.channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: target.deviceID
        )
        guard let client = mediaRuntime.existingMediaRelayClient(for: key) else { return }
        mediaRuntime.clearMediaRelayClient(matching: key, client: client)
        diagnostics.record(
            .media,
            message: "Cleared media relay client after receiver prewarm ACK did not arrive",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "peerDeviceId": target.deviceID,
            ]
        )
    }

    func mediaRelayClientForAudioSend(
        target: TransmitTarget,
        bypassAudioSendSuppression: Bool = false
    ) async -> TurboMediaRelayClient? {
        let localDeviceID = await MainActor.run {
            backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        }
        if !localDeviceID.isEmpty, !bypassAudioSendSuppression {
            let key = MediaRelayConnectionKey(
                sessionID: target.channelID,
                localDeviceID: localDeviceID,
                peerDeviceID: target.deviceID
            )
            let isSuppressed = await MainActor.run {
                mediaRuntime.isMediaRelayAudioSendSuppressed(for: key)
            }
            if isSuppressed {
                return nil
            }
        }
        return await mediaRelayClientIfEnabled(
            contactID: target.contactID,
            channelID: target.channelID,
            peerDeviceID: target.deviceID,
            missingConfigMessage: "Media relay skipped because relay config is missing",
            connectingMessage: "Connecting media relay",
            selectedMessage: "Media relay selected",
            failureMessage: "Media relay connection failed; falling back to WebSocket relay",
            cancelledMessage: "Media relay connection ended before relay selection",
            fromUserIDForIncoming: { target.userID }
        )
    }

    func existingMediaRelayClientForAudioFanout(
        target: TransmitTarget,
        localDeviceID: String
    ) async -> TurboMediaRelayClient? {
        await MainActor.run {
            guard TurboMediaRelayDebugOverride.isEnabled(),
                  !TurboMediaRelayDebugOverride.isForced(),
                  !localDeviceID.isEmpty else {
                return nil
            }
            let key = MediaRelayConnectionKey(
                sessionID: target.channelID,
                localDeviceID: localDeviceID,
                peerDeviceID: target.deviceID
            )
            guard !mediaRuntime.isMediaRelayAudioSendSuppressed(for: key) else {
                return nil
            }
            return mediaRuntime.existingMediaRelayClient(for: key)
        }
    }

    func connectMediaRelayForReceiveIfNeeded(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        allowConfiguredReceiveWithoutLocalToggle: Bool = false
    ) async {
        _ = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID,
            allowConfiguredReceiveWithoutLocalToggle: allowConfiguredReceiveWithoutLocalToggle,
            missingConfigMessage: "Media relay receive prejoin skipped because relay config is missing",
            connectingMessage: "Prejoining media relay for receive",
            selectedMessage: "Media relay receive prejoin selected",
            failureMessage: "Media relay receive prejoin failed",
            cancelledMessage: "Media relay receive prejoin ended before relay selection",
            fromUserIDForIncoming: { [weak self] in
                guard let viewModel = self else { return "" }
                return await MainActor.run {
                    viewModel.contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
                }
            }
        )
    }

    func mediaRelayClientIfEnabled(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        allowConfiguredReceiveWithoutLocalToggle: Bool = false,
        missingConfigMessage: String,
        connectingMessage: String,
        selectedMessage: String,
        failureMessage: String,
        cancelledMessage: String,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let shouldAttempt = await MainActor.run {
            !isDirectPathRelayOnlyForced
                && (
                    TurboMediaRelayDebugOverride.isEnabled()
                    || TurboMediaRelayDebugOverride.isForced()
                    || allowConfiguredReceiveWithoutLocalToggle
                )
        }
        guard shouldAttempt else { return nil }
        guard let config = await MainActor.run(body: { TurboMediaRelayDebugOverride.config() }) else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: missingConfigMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
            }
            return nil
        }
        let localDeviceId = await MainActor.run {
            backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        }
        guard !localDeviceId.isEmpty else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Media relay skipped because local device id is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
            }
            return nil
        }
        let key = MediaRelayConnectionKey(
            sessionID: channelID,
            localDeviceID: localDeviceId,
            peerDeviceID: peerDeviceID
        )
        let start = await MainActor.run {
            mediaRuntime.mediaRelayConnectionStart(for: key)
        }
        switch start {
        case .existingClient(let client):
            if client.hasFreshPeerUnavailable() {
                await MainActor.run {
                    clearStaleMediaRelayClient(
                        localDeviceID: localDeviceId,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        client: client,
                        reason: "peer-unavailable-reuse-blocked"
                    )
                }
                return nil
            }
            if await MainActor.run(body: { mediaRuntime.transportPathState == .fastRelayTcp }) {
                await MainActor.run {
                    scheduleMediaRelayQuicUpgradeProbe(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        localDeviceID: localDeviceId,
                        client: client,
                        reason: "existing-fast-relay-tcp-client"
                    )
                }
            }
            return client
        case .existingAttempt(let attempt):
            let client = await attempt.wait()
            if client == nil {
                await MainActor.run {
                    diagnostics.record(
                        .media,
                        level: .notice,
                        message: cancelledMessage,
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                        ]
                    )
                }
            }
            return client
        case .newAttempt(let attempt):
            return await connectNewMediaRelayClient(
                attempt: attempt,
                config: config,
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                localDeviceID: localDeviceId,
                connectingMessage: connectingMessage,
                selectedMessage: selectedMessage,
                failureMessage: failureMessage,
                cancelledMessage: cancelledMessage,
                fromUserIDForIncoming: fromUserIDForIncoming
            )
        }
    }

    func mediaRelayQuicUpgradeDelayNanoseconds(failureCount: Int, reason: String) -> UInt64 {
        if reason == "network-change" {
            return 0
        }
        switch failureCount {
        case 0:
            return 2_000_000_000
        case 1:
            return 5_000_000_000
        case 2:
            return 12_000_000_000
        case 3:
            return 30_000_000_000
        default:
            return 60_000_000_000
        }
    }

    func scheduleMediaRelayQuicUpgradeProbe(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        localDeviceID: String,
        client: TurboMediaRelayClient,
        reason: String
    ) {
        guard mediaRuntime.existingMediaRelayClient(
            for: MediaRelayConnectionKey(
                sessionID: channelID,
                localDeviceID: localDeviceID,
                peerDeviceID: peerDeviceID
            )
        ) === client else {
            return
        }
        guard mediaRuntime.transportPathState == .fastRelayTcp else { return }
        let key = MediaRelayConnectionKey(
            sessionID: channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
        let generation = mediaRuntime.networkPathGeneration
        let failureCount = mediaRuntime.mediaRelayQuicUpgradeFailureCount(for: key)
        let delayNanoseconds = mediaRelayQuicUpgradeDelayNanoseconds(
            failureCount: failureCount,
            reason: reason
        )
        if delayNanoseconds > 0,
           mediaRuntime.hasScheduledMediaRelayQuicUpgradeProbe(for: key, generation: generation) {
            diagnostics.record(
                .media,
                message: "Kept existing Fast Relay QUIC upgrade probe",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                    "failureCount": "\(failureCount)",
                    "delayMs": "\(delayNanoseconds / 1_000_000)",
                    "networkPathGeneration": "\(generation)",
                ]
            )
            return
        }
        let task = Task { @MainActor [weak self, weak client] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard let self, let client, !Task.isCancelled else { return }
            await self.attemptMediaRelayQuicUpgradeProbe(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                localDeviceID: localDeviceID,
                client: client,
                key: key,
                generation: generation,
                reason: reason
            )
        }
        mediaRuntime.scheduleMediaRelayQuicUpgradeProbe(
            for: key,
            generation: generation,
            task: task
        )
        diagnostics.record(
            .media,
            message: "Scheduled Fast Relay QUIC upgrade probe",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
                "failureCount": "\(failureCount)",
                "delayMs": "\(delayNanoseconds / 1_000_000)",
                "networkPathGeneration": "\(generation)",
            ]
        )
    }

    func attemptMediaRelayQuicUpgradeProbe(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        localDeviceID: String,
        client: TurboMediaRelayClient,
        key: MediaRelayConnectionKey,
        generation: UInt64,
        reason: String
    ) async {
        mediaRuntime.clearMediaRelayQuicUpgradeProbe(for: key, generation: generation)
        guard mediaRuntime.networkPathGeneration == generation,
              mediaRuntime.existingMediaRelayClient(for: key) === client,
              mediaRuntime.transportPathState == .fastRelayTcp else {
            return
        }
        diagnostics.record(
            .media,
            message: "Probing Fast Relay QUIC upgrade from TCP",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
                "networkPathGeneration": "\(generation)",
            ]
        )
        do {
            let transport: TurboMediaRelayTransport
            if let mediaRelayQuicUpgradeOverride {
                transport = try await mediaRelayQuicUpgradeOverride(
                    client,
                    contactID,
                    channelID,
                    peerDeviceID,
                    localDeviceID
                )
            } else {
                transport = try await client.upgradeToDatagramMediaChannel()
            }
            guard mediaRuntime.existingMediaRelayClient(for: key) === client else { return }
            mediaRuntime.clearMediaRelayQuicUpgradeFailures(for: key)
            mediaRuntime.updateTransportPathState(
                mediaRuntime.activeMediaRelayPathState(for: transport)
            )
            syncEngineMediaRelayLaneAvailable(
                transport: transport,
                source: "Fast Relay QUIC upgrade probe succeeded"
            )
            diagnostics.record(
                .media,
                message: "Fast Relay QUIC upgrade probe succeeded",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "transport": transport.rawValue,
                    "networkPathGeneration": "\(generation)",
                ]
            )
        } catch {
            guard mediaRuntime.existingMediaRelayClient(for: key) === client else { return }
            let failureCount = mediaRuntime.recordMediaRelayQuicUpgradeFailure(for: key)
            let nextDelay = mediaRelayQuicUpgradeDelayNanoseconds(
                failureCount: failureCount,
                reason: "retry"
            )
            diagnostics.record(
                .media,
                level: .notice,
                message: "Fast Relay QUIC upgrade probe failed; keeping TCP fallback",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                    "failureCount": "\(failureCount)",
                    "nextDelayMs": "\(nextDelay / 1_000_000)",
                    "networkPathGeneration": "\(generation)",
                ]
            )
            scheduleMediaRelayQuicUpgradeProbe(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                localDeviceID: localDeviceID,
                client: client,
                reason: "retry"
            )
        }
    }

    func connectNewMediaRelayClient(
        attempt: MediaRelayConnectionAttempt,
        config: TurboMediaRelayClientConfig,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        localDeviceID: String,
        connectingMessage: String,
        selectedMessage: String,
        failureMessage: String,
        cancelledMessage: String,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let client = TurboMediaRelayClient(
            config: config,
            sessionId: channelID,
            localDeviceId: localDeviceID,
            peerDeviceId: peerDeviceID,
            onIncomingAudioPayload: { [weak self] incoming in
                let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                let fromUserID = await fromUserIDForIncoming()
                await self?.handleIncomingAudioPayload(
                    incoming.payload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: peerDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: IncomingAudioPayloadTransport(
                        mediaRelayMediaMode: incoming.mediaMode
                    ),
                    transportSequenceNumber: incoming.sequenceNumber,
                    ingressContext: IncomingAudioIngressContext(
                        receivedAtNanoseconds: receivedAtNanoseconds,
                        sequenceNumber: incoming.sequenceNumber,
                        sentAtMilliseconds: incoming.sentAtMilliseconds,
                        source: "media-relay"
                    )
                )
            },
            onIncomingControlFrame: { [weak self] frame in
                await self?.handleIncomingMediaRelayControlFrame(
                    frame,
                    contactID: contactID,
                    channelID: channelID,
                    peerDeviceID: peerDeviceID
                )
            },
            onDisconnected: { [weak self] client in
                guard let viewModel = self else { return }
                await MainActor.run {
                    let key = MediaRelayConnectionKey(
                        sessionID: channelID,
                        localDeviceID: localDeviceID,
                        peerDeviceID: peerDeviceID
                    )
                    viewModel.mediaRuntime.clearMediaRelayClient(matching: key, client: client)
                    viewModel.diagnostics.record(
                        .media,
                        message: "Media relay disconnected; returning to WebSocket relay",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                        ]
                    )
                }
            },
            reportEvent: { [weak self] message, metadata in
                guard let viewModel = self else { return }
                await MainActor.run {
                    viewModel.diagnostics.record(.media, message: message, metadata: metadata)
                }
            }
        )
        await MainActor.run {
            diagnostics.record(
                .media,
                message: connectingMessage,
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "host": config.host,
                    "quicPort": String(config.quicPort),
                    "tcpPort": String(config.tcpPort),
                    "forced": String(TurboMediaRelayDebugOverride.isForced()),
                ]
            )
        }
        do {
            let transport: TurboMediaRelayTransport
            if let mediaRelayConnectOverride {
                transport = try await mediaRelayConnectOverride(
                    client,
                    config,
                    contactID,
                    channelID,
                    peerDeviceID,
                    localDeviceID
                )
            } else {
                transport = try await client.connect()
            }
            let accepted = await MainActor.run {
                let key = MediaRelayConnectionKey(
                    sessionID: channelID,
                    localDeviceID: localDeviceID,
                    peerDeviceID: peerDeviceID
                )
                let hadSuppression = mediaRuntime.isMediaRelayAudioSendSuppressed(for: key)
                let accepted = mediaRuntime.finishMediaRelayConnectionAttempt(attempt, client: client)
                if accepted && hadSuppression {
                    diagnostics.record(
                        .media,
                        message: "Cleared media relay send suppression",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                            "reason": "fresh-prewarm-succeeded",
                        ]
                    )
                }
                return accepted
            }
            guard accepted else {
                await MainActor.run {
                    diagnostics.record(
                        .media,
                        level: .notice,
                        message: cancelledMessage,
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                            "transport": transport.rawValue,
                            "reason": "superseded",
                        ]
                    )
                }
                return nil
            }
            await MainActor.run {
                if !TurboMediaRelayDebugOverride.isForced(),
                   !isDirectPathRelayOnlyForced,
                   shouldUseDirectQuicTransport(for: contactID) {
                    mediaRuntime.updateTransportPathState(.direct)
                } else {
                    mediaRuntime.updateTransportPathState(
                        mediaRuntime.activeMediaRelayPathState(for: transport)
                    )
                }
                syncEngineMediaRelayLaneAvailable(
                    transport: transport,
                    source: selectedMessage
                )
                diagnostics.record(
                    .media,
                    message: selectedMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "transport": transport.rawValue,
                    ]
                )
                if transport == .tcpTls {
                    scheduleMediaRelayQuicUpgradeProbe(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        localDeviceID: localDeviceID,
                        client: client,
                        reason: "tcp-fallback-connected"
                    )
                } else {
                    mediaRuntime.clearMediaRelayQuicUpgradeFailures(
                        for: MediaRelayConnectionKey(
                            sessionID: channelID,
                            localDeviceID: localDeviceID,
                            peerDeviceID: peerDeviceID
                        )
                    )
                    mediaRuntime.cancelMediaRelayQuicUpgradeProbe()
                }
            }
            return client
        } catch {
            await MainActor.run {
                _ = mediaRuntime.finishMediaRelayConnectionAttempt(attempt, client: nil)
                diagnostics.record(
                    .media,
                    level: .error,
                    message: failureMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "error": error.localizedDescription,
                    ]
                )
            }
            return nil
        }
    }

    func handleIncomingMediaRelayControlFrame(
        _ frame: TurboMediaRelayControlFrame,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String
    ) async {
        do {
            switch frame.kind {
            case .receiverPrewarmRequest, .receiverPrewarmAck:
                let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(frame.payload)
                guard payload.channelId == channelID,
                      payload.fromDeviceId == peerDeviceID else {
                    await MainActor.run {
                        diagnostics.recordContractViolation(
                            DiagnosticsContracts.Media.relayControlFrameMatchesCurrentPeer(
                                contactID: contactID,
                                expectedChannelID: channelID,
                                receivedChannelID: payload.channelId,
                                expectedPeerDeviceID: peerDeviceID,
                                receivedPeerDeviceID: payload.fromDeviceId,
                                kind: frame.kind.rawValue,
                                requestID: payload.requestId,
                                ackID: nil
                            )
                        )
                    }
                    return
                }

                await MainActor.run {
                    diagnostics.record(
                        .media,
                        message: "Media relay control frame received",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                            "kind": frame.kind.rawValue,
                            "requestId": payload.requestId,
                        ]
                    )
                }

                switch frame.kind {
                case .receiverPrewarmRequest:
                    await ingestMediaRelayReceiverPrewarmRequest(payload, contactID: contactID)
                case .receiverPrewarmAck:
                    await ingestMediaRelayReceiverPrewarmAck(payload, contactID: contactID)
                case .audioPlaybackStarted:
                    break
                }
            case .audioPlaybackStarted:
                let ackPayload = try TurboAudioPlaybackStartedPayloadCodec.decode(frame.payload)
                guard ackPayload.channelId == channelID,
                      ackPayload.receiverDeviceId == peerDeviceID else {
                    await MainActor.run {
                        diagnostics.recordContractViolation(
                            DiagnosticsContracts.Media.relayControlFrameMatchesCurrentPeer(
                                contactID: contactID,
                                expectedChannelID: channelID,
                                receivedChannelID: ackPayload.channelId,
                                expectedPeerDeviceID: peerDeviceID,
                                receivedPeerDeviceID: ackPayload.receiverDeviceId,
                                kind: frame.kind.rawValue,
                                requestID: nil,
                                ackID: ackPayload.ackId
                            )
                        )
                    }
                    return
                }
                await MainActor.run {
                    diagnostics.record(
                        .media,
                        message: "Media relay audio playback ACK received",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                            "ackId": ackPayload.ackId,
                        ]
                    )
                }
                await ingestAudioPlaybackStartedAck(
                    ackPayload,
                    contactID: contactID,
                    source: .mediaRelay,
                    remoteDeviceID: ackPayload.receiverDeviceId
                )
            }
        } catch {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Media relay control frame decode failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "kind": frame.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func prejoinMediaRelayForReadyChannelIfNeeded(
        contactID: UUID,
        channelReadiness: TurboChannelReadinessResponse?
    ) async {
        let shouldAttempt = await MainActor.run {
            !isDirectPathRelayOnlyForced
                && (TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced())
        }
        guard shouldAttempt else { return }
        guard let channelReadiness else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    message: "Media relay ready-channel prejoin skipped because peer target device is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": "none",
                    ]
                )
            }
            return
        }
        let peerDeviceID = channelReadiness.peerTargetDeviceId
            ?? recentPeerDeviceEvidence(for: contactID)?.deviceId
        guard let peerDeviceID,
              !peerDeviceID.isEmpty else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    message: "Media relay ready-channel prejoin skipped because peer target device is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelReadiness.channelId,
                    ]
                )
            }
            return
        }
        await connectMediaRelayForReceiveIfNeeded(
            contactID: contactID,
            channelID: channelReadiness.channelId,
            peerDeviceID: peerDeviceID
        )
    }

    func takeShouldAwaitInitialOutboundAudioSendGate() -> Bool {
        transmitRuntime.takeShouldAwaitInitialOutboundAudioSendGate()
    }

    func waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
        target: TransmitTarget,
        timeoutNanoseconds: UInt64? = nil,
        pollNanoseconds: UInt64? = nil,
        wakeRecoveryGraceNanoseconds: UInt64? = nil,
        postReleaseWakeRecoveryGraceNanoseconds: UInt64? = nil
    ) async -> Bool {
        let timeoutNanoseconds = timeoutNanoseconds ?? remoteReceiverAudioReadyGateTimeoutNanoseconds
        let pollNanoseconds = pollNanoseconds ?? remoteReceiverAudioReadyGatePollNanoseconds
        let wakeRecoveryGraceNanoseconds =
            wakeRecoveryGraceNanoseconds ?? wakeCapableInitialAudioSendGraceNanoseconds
        let postReleaseWakeRecoveryGraceNanoseconds =
            postReleaseWakeRecoveryGraceNanoseconds ?? wakeCapablePostReleaseAudioSendGraceNanoseconds

        guard let channelSnapshot = selectedChannelSnapshot(for: target.contactID) else {
            return true
        }
        guard !channelSnapshot.remoteAudioReadyForLiveTransmit else {
            return true
        }
        if shouldReleaseInitialOutboundAudioSendGateForForegroundDirectQuic(
            target: target,
            channelSnapshot: channelSnapshot
        ) {
            diagnostics.record(
                .media,
                message: "Foreground Direct QUIC receiver is prepared; releasing outbound audio send gate",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "remoteAudioReadiness": String(describing: channelSnapshot.remoteAudioReadiness),
                    "readinessStatus": String(describing: channelSnapshot.readinessStatus),
                    "peerDeviceConnected": String(channelSnapshot.membership.peerDeviceConnected),
                ]
            )
            return true
        }
        let wakeCapableReceiver: Bool
        if case .wakeCapable = channelSnapshot.remoteWakeCapability {
            wakeCapableReceiver = true
            diagnostics.record(
                .media,
                message: "Waiting for wake-capable receiver recovery before sending initial outbound audio",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "remoteAudioReadiness": String(describing: channelSnapshot.remoteAudioReadiness),
                    "readinessStatus": String(describing: channelSnapshot.readinessStatus),
                    "wakeRecoveryGraceMilliseconds": String(wakeRecoveryGraceNanoseconds / 1_000_000),
                ]
            )
        } else {
            wakeCapableReceiver = false
            diagnostics.record(
                .media,
                message: "Waiting for remote receiver audio readiness before sending outbound audio",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "remoteAudioReadiness": String(describing: channelSnapshot.remoteAudioReadiness),
                    "readinessStatus": String(describing: channelSnapshot.readinessStatus),
                    "peerDeviceConnected": String(channelSnapshot.membership.peerDeviceConnected),
                ]
            )
        }

        let startedAt = Date()
        var releaseLogged = false
        var postReleaseGraceLogged = false
        while true {
            if selectedChannelSnapshot(for: target.contactID)?.remoteAudioReadyForLiveTransmit == true {
                diagnostics.record(
                    .media,
                    message: "Remote receiver audio became ready; releasing outbound audio send gate",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ]
                )
                return true
            }

            let waitedNanoseconds = UInt64(Date().timeIntervalSince(startedAt) * 1_000_000_000)
            if waitedNanoseconds >= timeoutNanoseconds {
                let currentSnapshot = selectedChannelSnapshot(for: target.contactID)
                diagnostics.recordContractViolation(
                    DiagnosticsContracts.Media.outboundAudioRequiresRemoteReceiverReady(
                        reason: "remote-receiver-ready-gate-timeout",
                        contactID: target.contactID,
                        channelID: target.channelID,
                        selectedConversationPhase: String(describing: selectedConversationState(for: target.contactID).phase),
                        backendChannelStatus: currentSnapshot?.status?.rawValue ?? "none",
                        backendReadiness: currentSnapshot?.readinessStatus?.kind ?? "none",
                        remoteAudioReadiness: String(
                            describing: currentSnapshot?.remoteAudioReadiness ?? .unknown
                        ),
                        peerDeviceConnected: currentSnapshot?.membership.peerDeviceConnected ?? false,
                        waitedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000)
                    )
                )
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Timed out waiting for remote receiver audio readiness; not sending outbound audio",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ]
                )
                return false
            }

            if wakeCapableReceiver && waitedNanoseconds >= wakeRecoveryGraceNanoseconds {
                if transmitRuntime.isPressingTalk {
                    diagnostics.record(
                        .media,
                        message: "Wake-capable receiver grace elapsed; releasing outbound audio send gate",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                            "wakeRecoveryGraceMilliseconds": String(wakeRecoveryGraceNanoseconds / 1_000_000),
                        ]
                    )
                    return true
                }
                if !transmitRuntime.isPressingTalk,
                   waitedNanoseconds
                    < wakeRecoveryGraceNanoseconds + postReleaseWakeRecoveryGraceNanoseconds {
                    if !postReleaseGraceLogged {
                        postReleaseGraceLogged = true
                        diagnostics.record(
                            .media,
                            message: "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                                "postReleaseGraceMilliseconds": String(
                                    postReleaseWakeRecoveryGraceNanoseconds / 1_000_000
                                ),
                            ]
                        )
                    }
                }
            }

            if !transmitRuntime.isPressingTalk {
                if !wakeCapableReceiver {
                    return false
                }
                if !releaseLogged {
                    releaseLogged = true
                    diagnostics.record(
                        .media,
                        message: "Continuing to hold initial outbound audio after talk release until wake-capable receiver recovery",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        ]
                    )
                }
            }

            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    func shouldReleaseInitialOutboundAudioSendGateForForegroundDirectQuic(
        target: TransmitTarget,
        channelSnapshot: ChannelReadinessSnapshot
    ) -> Bool {
        guard currentApplicationState() == .active else { return false }
        guard shouldUseDirectQuicTransport(for: target.contactID) else { return false }
        guard channelSnapshot.membership.peerDeviceConnected else { return false }
        if case .wakeCapable = channelSnapshot.remoteWakeCapability {
            return false
        }
        return true
    }

    func reconcileExplicitTransmitStopIfNeeded(
        target: TransmitTarget,
        source: String
    ) async {
        guard !usesLocalHTTPBackend else { return }
        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID,
              channelUUID(for: target.contactID) == systemChannelUUID else {
            return
        }

        let previousPTTState = pttCoordinator.state
        let endOrigin = SystemTransmitEndOrigin.explicitStopReconciliation(source: source)
        await pttCoordinator.handle(
            .didEndTransmitting(
                channelUUID: systemChannelUUID,
                origin: endOrigin
            )
        )
        guard pttCoordinator.state != previousPTTState else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Reconciling explicit transmit stop without system callback",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelUUID": systemChannelUUID.uuidString,
                "source": source,
                "origin": endOrigin.kind,
            ]
        )
        syncPTTState()
        captureDiagnosticsState("transmit-stop:reconciled")
    }

    func finalizeExplicitTransmitStopLocallyIfNeeded(
        target: TransmitTarget,
        source: String
    ) async {
        await reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: source
        )

        let shouldCompleteStop =
            transmitCoordinator.state.activeTarget == target
            || transmitRuntime.activeTarget == target
            || {
                switch transmitCoordinator.state.phase {
                case .stopping(let contactID):
                    return contactID == target.contactID
                case .idle, .requesting, .active:
                    return false
                }
            }()
        guard shouldCompleteStop else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Finalizing explicit transmit stop locally",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "source": source,
            ]
        )
        await transmitCoordinator.handle(.stopCompleted(target))
        syncTransmitState()
        clearMediaRelayAudioSendSuppressionIfPresent(
            target: target,
            reason: "\(source)-completed-locally"
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-stop:completed-locally")
    }

    func performStopTransmit(_ target: TransmitTarget) async {
        let media = mediaServices
        let mediaSession = media.session()
        transmitTaskCoordinator.send(.renewalCancelled)
        transmitTaskRuntime.cancelCaptureReassertionTask()

        if usesLocalHTTPBackend {
            clearEngineTransmitIfActive(reason: "local-http-stop")
        } else if let activeChannelId,
                  let channelUUID = channelUUID(for: activeChannelId),
                  pttCoordinator.state.isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }

        do {
            await stopOutgoingAudioForExplicitTransmitStop(
                mediaSession,
                target: target
            )
            media.replaceSendAudioChunk(nil)
            mediaSession?.updateSendAudioChunk(nil)
            if let currentSession = media.session(), currentSession !== mediaSession {
                currentSession.updateSendAudioChunk(nil)
            }
            if let backend = backendServices {
                if backend.supportsWebSocket && backend.isWebSocketConnected {
                    diagnostics.record(
                        .websocket,
                        message: "Sending transmit stop signal before backend end",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                        ]
                    )
                    try? await backend.sendSignal(
                        TurboSignalEnvelope(
                            type: .transmitStop,
                            channelId: target.channelID,
                            fromUserId: backend.currentUserID ?? "",
                            fromDeviceId: backend.deviceID,
                            toUserId: target.userID,
                            toDeviceId: target.deviceID,
                            payload: "ptt-end"
                        )
                    )
                }
                diagnostics.record(
                    .media,
                    message: "Ending transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "webSocketConnected": String(backend.isWebSocketConnected),
                    ]
                )
                _ = try await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
                diagnostics.record(
                    .media,
                    message: "Ended transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                    ]
                )
                syncEngineBackendTransmitStopped(
                    target: target,
                    source: "explicit-stop-backend-complete"
                )
            }
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "explicit-stop-backend-complete"
            )
            await refreshChannelState(for: target.contactID)
        } catch {
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "explicit-stop-backend-failed"
            )
            syncEngineBackendTransmitStopped(
                target: target,
                source: "explicit-stop-backend-failed"
            )
            guard !isExpectedBackendSyncCancellation(error) else {
                await refreshChannelState(for: target.contactID)
                updateStatusForSelectedContact()
                return
            }
            if shouldTreatTransmitStopCleanupAsAlreadyComplete(error) {
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Treated transmit stop cleanup failure as already complete",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "error": error.localizedDescription,
                    ]
                )
                await refreshChannelState(for: target.contactID)
                updateStatusForSelectedContact()
                return
            }
            let message = error.localizedDescription
            statusMessage = "Stop cleanup failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit stop cleanup failed after local completion",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "error": message,
                ]
            )
            await refreshChannelState(for: target.contactID)
        }

        updateStatusForSelectedContact()
    }

    func performAbortTransmit(_ target: TransmitTarget) async {
        let media = mediaServices
        let mediaSession = media.session()
        transmitTaskCoordinator.send(.renewalCancelled)
        transmitTaskRuntime.cancelCaptureReassertionTask()
        try? await mediaSession?.stopSendingAudio()
        media.replaceSendAudioChunk(nil)
        mediaSession?.updateSendAudioChunk(nil)
        if let currentSession = media.session(), currentSession !== mediaSession {
            currentSession.updateSendAudioChunk(nil)
        }

        if let backend = backendServices {
            diagnostics.record(
                .media,
                message: "Aborting transmit on backend",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "webSocketConnected": String(backend.isWebSocketConnected),
                ]
            )
            _ = try? await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
            diagnostics.record(
                .media,
                message: "Aborted transmit on backend",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                ]
            )
            syncEngineBackendTransmitStopped(
                target: target,
                source: "abort-backend"
            )
            if backend.supportsWebSocket && backend.isWebSocketConnected {
                try? await backend.sendSignal(
                    TurboSignalEnvelope(
                        type: .transmitStop,
                        channelId: target.channelID,
                        fromUserId: backend.currentUserID ?? "",
                        fromDeviceId: backend.deviceID,
                        toUserId: target.userID,
                        toDeviceId: target.deviceID,
                        payload: "ptt-end"
                    )
                )
            }
        }

        await refreshChannelState(for: target.contactID)
        syncTransmitState()
        updateStatusForSelectedContact()
    }

    private func currentTransmitLeaseRenewalContext(
        for target: TransmitTarget
    ) -> (systemTransmitDurationMs: String, webSocketConnected: Bool)? {
        guard transmitCoordinator.state.isPressingTalk,
              transmitProjection.activeTarget?.channelID == target.channelID else { return nil }
        return (
            systemTransmitDurationMs: transmitRuntime.currentSystemTransmitDurationMilliseconds().map(String.init) ?? "unknown",
            webSocketConnected: backendServices?.isWebSocketConnected == true
        )
    }

    private func renewTransmitLeaseOnBackend(
        target: TransmitTarget
    ) async throws -> TurboRenewTransmitResponse {
        guard let backend = backendServices else {
            throw TurboBackendError.invalidConfiguration
        }
        return try await withHTTPTransportFault(route: .renewTransmit) {
            try await backend.renewTransmit(channelId: target.channelID, transmitId: target.transmitID)
        }
    }

    func startRenewingTransmit(_ target: TransmitTarget) {
        transmitTaskCoordinator.send(.renewalRequested(target))
    }

    func performTransmitLeaseRenewal(for target: TransmitTarget, workID: Int) async {
        defer {
            transmitTaskCoordinator.send(.renewalFinished(id: workID))
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: transmitLeaseRenewIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            guard let context = currentTransmitLeaseRenewalContext(for: target) else { return }
            let renewStartedAt = Date()
            do {
                await MainActor.run {
                    self.diagnostics.record(
                        .media,
                        message: "Renewing transmit lease",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "systemTransmitDurationMs": context.systemTransmitDurationMs,
                            "webSocketConnected": String(context.webSocketConnected),
                        ]
                    )
                }
                let response = try await renewTransmitLeaseOnBackend(target: target)
                let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1000)
                await MainActor.run {
                    self.diagnostics.record(
                        .media,
                        message: "Transmit lease renewed",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "systemTransmitDurationMs": context.systemTransmitDurationMs,
                            "renewDurationMs": String(renewDurationMs),
                            "expiresAt": response.expiresAt,
                        ]
                    )
                }
            } catch {
                let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1000)
                let currentSystemTransmitDurationMs = await MainActor.run {
                    self.transmitRuntime.currentSystemTransmitDurationMilliseconds().map(String.init) ?? "unknown"
                }
                let shouldTreatAsCancellation = await MainActor.run {
                    self.isExpectedBackendSyncCancellation(error)
                        || !self.transmitCoordinator.state.isPressingTalk
                        || !self.pttCoordinator.state.isTransmitting
                }
                if shouldTreatAsCancellation {
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            message: "Transmit lease renewal cancelled",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "renewDurationMs": String(renewDurationMs),
                                "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    return
                }
                let shouldTreatAsLeaseLoss = await MainActor.run {
                    self.shouldTreatTransmitLeaseLossAsStop(error)
                }
                if shouldTreatAsLeaseLoss {
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            level: .error,
                            message: "Transmit lease lost during renewal",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "renewDurationMs": String(renewDurationMs),
                                "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    await handleTransmitLeaseLossDuringRenewal(target: target)
                    return
                }
                let message = error.localizedDescription
                await MainActor.run {
                    self.statusMessage = "Transmit lease expired: \(message)"
                    self.clearEngineTransmitIfActive(reason: "lease-renewal-failed")
                    self.diagnostics.record(
                        .media,
                        level: .error,
                        message: "Transmit lease renewal failed",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "renewDurationMs": String(renewDurationMs),
                            "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                            "error": message,
                        ]
                    )
                }
                await transmitCoordinator.handle(.renewalFailed(message))
                await refreshChannelState(for: target.contactID)
                await MainActor.run {
                    self.syncTransmitState()
                }
                return
            }
        }
    }

    private func handleTransmitLeaseLossDuringRenewal(target: TransmitTarget) async {
        if !usesLocalHTTPBackend,
           let channelUUID = channelUUID(for: target.contactID) {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        if let backend = backendServices,
           backend.supportsWebSocket,
           backend.isWebSocketConnected {
            try? await backend.sendSignal(
                TurboSignalEnvelope(
                    type: .transmitStop,
                    channelId: target.channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: target.userID,
                    toDeviceId: target.deviceID,
                    payload: "ptt-end"
                )
            )
        }
        clearEngineTransmitIfActive(reason: "stop-completed")
        await transmitCoordinator.handle(.stopCompleted(target))
        await refreshChannelState(for: target.contactID)
        syncTransmitState()
        updateStatusForSelectedContact()
    }

    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState) {
        let media = mediaServices
        guard session === media.session() else { return }
        media.updateConnectionState(state)
        diagnostics.record(.media, message: "Media state changed", metadata: ["state": String(describing: state)])
        switch state {
        case .failed(let message):
            localAudioLevel = 0
            backendStatusMessage = "Media failed: \(message)"
        case .connected:
            if let contactID = media.contactID(),
               viewModelWakeStateNeedsClearingAfterRecovery(contactID: contactID) {
                pttWakeRuntime.clear(for: contactID)
            }
        case .closed, .idle, .preparing:
            localAudioLevel = 0
        }
        updateStatusForSelectedContact()
        if let contactID = media.contactID() {
            if case .preparing = state {
                if shouldSuppressReceiverAudioReadinessSyncForMediaState(
                    state,
                    contactID: contactID
                ) {
                    diagnostics.record(
                        .websocket,
                        message: "Suppressed receiver audio readiness sync during active receive playback recovery",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "state": String(describing: state),
                        ]
                    )
                } else {
                    diagnostics.record(
                        .websocket,
                        message: "Skipped receiver audio readiness sync for transitional media state",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "state": String(describing: state),
                        ]
                    )
                }
                return
            }
            Task {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .mediaState(state)
                )
            }
        }
    }

    func mediaSession(_ session: MediaSession, didMeasureLocalAudioLevel level: Double) {
        let media = mediaServices
        guard session === media.session() else { return }
        let clampedLevel = max(0, min(1, level))
        let smoothing = clampedLevel > localAudioLevel ? 0.58 : 0.24
        let smoothedLevel = localAudioLevel + (clampedLevel - localAudioLevel) * smoothing
        guard abs(smoothedLevel - localAudioLevel) >= 0.01 || clampedLevel == 0 else { return }
        localAudioLevel = smoothedLevel
    }

    func mediaSessionDidDrainPendingPlayback(_ session: MediaSession) {
        let media = mediaServices
        guard session === media.session(), let contactID = media.contactID() else { return }
        handleRemotePlaybackDrained(for: contactID)
    }

    private func viewModelWakeStateNeedsClearingAfterRecovery(contactID: UUID) -> Bool {
        pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd
    }

    private func shouldSuppressReceiverAudioReadinessSyncForMediaState(
        _ state: MediaConnectionState,
        contactID: UUID
    ) -> Bool {
        guard case .preparing = state else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard !isTransmitting else { return false }
        return remoteTransmittingContactIDs.contains(contactID)
    }

    private func shouldPreserveAudioSessionDuringMediaClose() -> Bool {
        pttWakeRuntime.pendingIncomingPush != nil
    }

    func precreateSelectedContactMediaShellIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State? = nil
    ) {
        #if targetEnvironment(simulator)
        return
        #else
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return }
        guard contacts.contains(where: { $0.id == contactID }) else { return }
        guard !isTransmitting else { return }
        guard !isPTTAudioSessionActive else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard mediaSessionContactID == nil || mediaSessionContactID == contactID else { return }

        _ = prepareMediaSessionShellIfNeeded(
            for: contactID,
            reason: "selected-contact-\(reason)"
        )
        #endif
    }

    func publishSelectedFriendPrewarmHintIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard selectedFriendPrewarmPublishBlockReason(for: contactID) == nil else {
            diagnostics.record(
                .websocket,
                message: "Selected friend prewarm hint skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": selectedFriendPrewarmPublishBlockReason(for: contactID) ?? "unknown",
                ]
            )
            return
        }
        guard let backend = backendServices, let currentUserID = backend.currentUserID else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId else {
            diagnostics.record(
                .websocket,
                message: "Selected friend prewarm hint skipped because routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }

        // Pre-call selection hints should follow the backend's fresh presence
        // routing instead of trusting a possibly stale cached remote device.
        let peerDeviceID = ""
        let payload = TurboSelectedFriendPrewarmPayload(
            requestId: UUID().uuidString.lowercased(),
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            toDeviceId: peerDeviceID,
            reason: reason
        )

        do {
            let envelope = try TurboSignalEnvelope.selectedFriendPrewarm(
                channelId: channelID,
                fromUserId: currentUserID,
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Selected friend prewarm hint sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "requestId": payload.requestId,
                    "reason": reason,
                    "targetDeviceId": peerDeviceID.isEmpty ? "prejoin-fresh-device" : peerDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Selected friend prewarm hint send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func selectedFriendPrewarmPublishBlockReason(for contactID: UUID) -> String? {
        guard let backend = backendServices else { return "backend-unavailable" }
        guard backend.supportsWebSocket else { return "websocket-unsupported" }
        guard backend.currentUserID != nil else { return "missing-current-user" }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "missing-contact"
        }
        guard contact.backendChannelId != nil else { return "missing-channel-id" }
        guard contact.remoteUserId != nil else { return "missing-remote-user-id" }
        return nil
    }

    func selectedFriendPrewarmHintBlockReason(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> String? {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return "not-foreground" }
        guard contacts.contains(where: { $0.id == contactID }) else { return "missing-contact" }
        guard !isJoined, activeChannelId == nil else { return "local-session-active" }
        guard conversationActionCoordinator.pendingAction == .none else { return "local-session-transition" }
        guard !isTransmitting else { return "transmitting" }
        guard !isPTTAudioSessionActive else { return "ptt-audio-active" }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return "incoming-wake-pending" }
        guard mediaSessionContactID == nil || mediaSessionContactID == contactID else {
            return "other-media-session-active"
        }
        return nil
    }

    func recordMediaSessionEvent(
        _ message: String,
        metadata: [String: String]
    ) {
        recordTransmitStartupTimingForMediaEvent(
            message,
            metadata: metadata
        )
        recordWakeReceiveTimingForMediaEvent(
            message,
            metadata: metadata
        )
        guard let invariantID = metadata["invariantID"],
              let contractKindValue = metadata["contractKind"],
              let contractKind = DiagnosticsContractKind(rawValue: contractKindValue) else {
            let level = metadata["diagnosticLevel"]
                .flatMap(DiagnosticsLevel.init(rawValue:)) ?? .info
            diagnostics.record(.media, level: level, message: message, metadata: metadata)
            return
        }
        let scope = metadata["scope"]
            .flatMap(DiagnosticsInvariantScope.init(rawValue:)) ?? .local
        diagnostics.recordContractViolation(
            DiagnosticsContracts.Media.sessionEvent(
                message: message,
                invariantID: invariantID,
                kind: contractKind,
                scope: scope,
                metadata: metadata
            )
        )
    }

    @discardableResult
    func prepareMediaSessionShellIfNeeded(
        for contactID: UUID,
        reason: String
    ) -> Bool {
        guard contacts.contains(where: { $0.id == contactID }) else { return false }
        let media = mediaServices
        let existingMediaContactID = media.contactID()
        let sessionNeedsContactSwitch =
            existingMediaContactID != nil && existingMediaContactID != contactID
        let sessionNeedsRecreation = shouldRecreateMediaSession(connectionState: mediaConnectionState)

        if sessionNeedsContactSwitch {
            closeMediaSession()
        }

        if sessionNeedsRecreation {
            closeMediaSession(
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
        }

        guard !media.hasSession() else { return false }

        let sessionCreationStartedAt = Date()
        let supportsWebSocket = backendServices?.supportsWebSocket == true
        let senderPolicy = mediaTransportPolicyForOutgoingAudio(for: contactID)
        let voiceMediaPolicy = mediaRuntime.outboundVoiceMediaPayloadFormat(for: contactID)
        let opusPolicy = outboundOpusEncodingPolicy(for: contactID)
        let session = makeDefaultMediaSession(
            supportsWebSocket: supportsWebSocket,
            sendAudioChunk: media.sendAudioChunk(),
            reportEvent: { [weak self] message, metadata in
                guard let self else { return }
                await MainActor.run {
                    self.recordMediaSessionEvent(message, metadata: metadata)
                }
            },
            senderConfiguration: senderPolicy.senderConfiguration,
            outboundVoiceMediaPolicy: voiceMediaPolicy,
            outboundOpusEncodingPolicy: opusPolicy
        )
        session.delegate = self
        media.attach(session, contactID)
        session.updateSendAudioChunk(media.sendAudioChunk())
        diagnostics.record(
            .media,
            message: "Media session shell prepared",
            metadata: [
                "contactId": contactID.uuidString,
                "supportsWebSocket": String(supportsWebSocket),
                "transportPolicy": senderPolicy.rawValue,
                "voiceMediaPolicy": voiceMediaPolicy.rawValue,
                "durationMs": String(Int(Date().timeIntervalSince(sessionCreationStartedAt) * 1000)),
                "reason": reason,
            ].merging(opusPolicy.diagnosticsMetadata, uniquingKeysWith: { current, _ in current })
        )
        return true
    }

    func ensureMediaSession(
        for contactID: UUID,
        activationMode: MediaSessionActivationMode? = nil,
        startupMode: MediaSessionStartupMode = .interactive
    ) async {
        guard contacts.contains(where: { $0.id == contactID }) else { return }
        let media = mediaServices
        let existingMediaContactID = media.contactID()
        let sessionNeedsContactSwitch =
            existingMediaContactID != nil && existingMediaContactID != contactID
        let sessionNeedsRecreation = shouldRecreateMediaSession(connectionState: mediaConnectionState)
        let sessionNeedsCreation = !media.hasSession()
        let resolvedActivationMode = activationMode ?? pttWakeRuntime.mediaSessionActivationMode(for: contactID)
        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: resolvedActivationMode,
            startupMode: startupMode
        )

        if sessionNeedsContactSwitch {
            closeMediaSession()
        }

        if sessionNeedsRecreation {
            closeMediaSession(
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
        }

        if sessionNeedsCreation || sessionNeedsContactSwitch || sessionNeedsRecreation {
            _ = prepareMediaSessionShellIfNeeded(
                for: contactID,
                reason: sessionNeedsCreation ? "created" : sessionNeedsContactSwitch ? "contact-switch" : "recreated"
            )
        }

        if media.isStartupInFlight(startupContext) {
            return
        }

        let shouldStartSession =
            sessionNeedsCreation
            || sessionNeedsContactSwitch
            || sessionNeedsRecreation
            || mediaConnectionState != .connected

        guard shouldStartSession else { return }

        if media.shouldDelayRetry(startupContext, mediaSessionRetryCooldown) {
            diagnostics.record(
                .media,
                message: "Deferred media session retry after recent start failure",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode)
                ]
            )
            return
        }

        media.markStartupInFlight(startupContext)

        do {
            let startRequestedAt = Date()
            try await media.session()?.start(
                activationMode: resolvedActivationMode,
                startupMode: startupMode
            )
            diagnostics.record(
                .media,
                message: "Media session start await completed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode),
                    "durationMs": String(Int(Date().timeIntervalSince(startRequestedAt) * 1000)),
                ]
            )
            media.markStartupSucceeded()
            applyPreferredAudioOutputRouteIfPossible()
            await maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "media-session-started"
            )
        } catch {
            let message = error.localizedDescription
            media.markStartupFailed(startupContext, message)
            backendStatusMessage = "Media setup failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Media session start failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode),
                    "error": message
                ]
            )
        }
    }

    func closeMediaSession(
        deactivateAudioSession: Bool = true,
        preserveDirectQuic: Bool = false,
        preserveMediaRelay: Bool = false
    ) {
        if let contactID = mediaSessionContactID,
           let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
           !preserveDirectQuic {
            cancelDirectQuicPromotionTimeout()
            Task { [weak self] in
                guard let self else { return }
                await self.sendDirectQuicHangup(
                    for: contactID,
                    attempt: attempt,
                    reason: "media-session-closed"
                )
            }
        }
        if preserveDirectQuic {
            diagnostics.record(
                .media,
                message: "Preserving direct QUIC media path during media close",
                metadata: [
                    "contactId": mediaSessionContactID?.uuidString ?? "none",
                    "reason": "system-transmit-handoff",
                ]
            )
        }
        if preserveMediaRelay {
            diagnostics.record(
                .media,
                message: "Preserving fast relay media path during media close",
                metadata: [
                    "contactId": mediaSessionContactID?.uuidString ?? "none",
                    "reason": "system-transmit-handoff",
                ]
            )
        }
        let shouldDeactivateAudioSession =
            deactivateAudioSession && !shouldPreserveAudioSessionDuringMediaClose()
        if deactivateAudioSession && !shouldDeactivateAudioSession {
            diagnostics.record(
                .media,
                message: "Preserving audio session during media close while wake activation is pending",
                metadata: [
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeContactID": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                    "pendingWakeActivationState": String(
                        describing: pttWakeRuntime.pendingIncomingPush?.activationState ?? .signalBuffered
                    ),
                ]
            )
        }
        mediaServices.reset(shouldDeactivateAudioSession, preserveDirectQuic, preserveMediaRelay)
    }

    func shouldPreserveMediaRelayDuringMediaClose(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        if mediaRuntime.hasActiveMediaRelayClient {
            return mediaTransportPathState.isFastRelay
        }
        guard mediaRuntime.hasInFlightMediaRelayConnection else { return false }
        guard !isDirectPathRelayOnlyForced else { return false }
        return TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced()
    }
}
