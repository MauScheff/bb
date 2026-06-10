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

private enum TransmitMediaSessionStartupError: LocalizedError {
    case missingMediaSession

    var errorDescription: String? {
        "Media session is not available for startup"
    }
}

extension PTTViewModel {
    private final class MediaSessionCleanupHandle: @unchecked Sendable {
        private let mediaSession: (any MediaSession)?

        init(_ mediaSession: (any MediaSession)?) {
            self.mediaSession = mediaSession
        }

        func abortSendingAudio() async {
            await mediaSession?.abortSendingAudio()
        }

        func stopSendingAudio() async {
            try? await mediaSession?.stopSendingAudio()
        }
    }

    private func currentMediaSessionForStartup() throws -> any MediaSession {
        guard let session = mediaServices.session() else {
            throw TransmitMediaSessionStartupError.missingMediaSession
        }
        return session
    }

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

    func clearFirstAudioPlaybackAckExpectations() {
        let clearedAt = Date()
        for expectation in firstAudioPlaybackAckExpectationsByContactID.values {
            rememberFirstAudioPlaybackAckRecentlyClearedKey(
                firstAudioPlaybackAckKey(for: expectation),
                now: clearedAt
            )
        }
        for key in firstAudioPlaybackAckCompletedKeys {
            rememberFirstAudioPlaybackAckRecentlyClearedKey(key, now: clearedAt)
        }
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

    func firstAudioPlaybackAckKey(
        for expectation: FirstAudioPlaybackAckExpectation
    ) -> FirstAudioPlaybackAckSentKey {
        firstAudioPlaybackAckKey(
            contactID: expectation.contactID,
            channelID: expectation.channelID,
            senderDeviceID: expectation.senderDeviceID,
            receiverDeviceID: expectation.receiverDeviceID
        )
    }

    func firstAudioPlaybackAckKeyMatchesClearFilter(
        _ key: FirstAudioPlaybackAckSentKey,
        contactID: UUID,
        channelID: String?,
        senderDeviceID: String?
    ) -> Bool {
        if key.contactID != contactID { return false }
        if let channelID, key.channelID != channelID { return false }
        if let senderDeviceID, key.senderDeviceID != senderDeviceID { return false }
        return true
    }

    func pruneFirstAudioPlaybackAckRecentlyClearedKeys(now: Date = Date()) {
        let graceSeconds = max(0, firstAudioPlaybackAckClearedKeyGraceSeconds)
        firstAudioPlaybackAckRecentlyClearedKeys = firstAudioPlaybackAckRecentlyClearedKeys.filter {
            now.timeIntervalSince($0.value) <= graceSeconds
        }
    }

    func rememberFirstAudioPlaybackAckRecentlyClearedKey(
        _ key: FirstAudioPlaybackAckSentKey,
        now: Date = Date()
    ) {
        pruneFirstAudioPlaybackAckRecentlyClearedKeys(now: now)
        firstAudioPlaybackAckRecentlyClearedKeys[key] = now
    }

    func hasRecentlyClearedFirstAudioPlaybackAckKey(
        _ key: FirstAudioPlaybackAckSentKey,
        now: Date = Date()
    ) -> Bool {
        pruneFirstAudioPlaybackAckRecentlyClearedKeys(now: now)
        return firstAudioPlaybackAckRecentlyClearedKeys[key] != nil
    }

    func clearFirstAudioPlaybackAckState(
        contactID: UUID,
        channelID: String? = nil,
        senderDeviceID: String? = nil
    ) {
        let clearedAt = Date()
        if let expectation = firstAudioPlaybackAckExpectationsByContactID[contactID],
           channelID == nil || expectation.channelID == channelID {
            rememberFirstAudioPlaybackAckRecentlyClearedKey(
                firstAudioPlaybackAckKey(for: expectation),
                now: clearedAt
            )
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
        var retainedCompletedKeys: Set<FirstAudioPlaybackAckSentKey> = []
        for key in firstAudioPlaybackAckCompletedKeys {
            if firstAudioPlaybackAckKeyMatchesClearFilter(
                key,
                contactID: contactID,
                channelID: channelID,
                senderDeviceID: senderDeviceID
            ) {
                rememberFirstAudioPlaybackAckRecentlyClearedKey(key, now: clearedAt)
            } else {
                retainedCompletedKeys.insert(key)
            }
        }
        firstAudioPlaybackAckCompletedKeys = retainedCompletedKeys
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
        if let activeTransport = activeEpochTransport(from: deliveredTransports) {
            mediaRuntime.markActiveMediaEpochTransport(activeTransport)
        }
        let senderDeviceID = backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        let key = firstAudioPlaybackAckKey(
            contactID: target.contactID,
            channelID: target.channelID,
            senderDeviceID: senderDeviceID,
            receiverDeviceID: target.deviceID
        )
        firstAudioPlaybackAckRecentlyClearedKeys.removeValue(forKey: key)
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
            await self?.handleFirstAudioPlaybackAckTimeout(
                contactID: target.contactID,
                ackID: ackID
            )
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

    func activeEpochTransport(from deliveredTransports: [String]) -> String? {
        for transport in ["direct-quic", "media-relay-packet", "media-relay-tcp"] {
            if deliveredTransports.contains(transport) {
                return transport
            }
        }
        return deliveredTransports.first
    }

    func handleFirstAudioPlaybackAckTimeout(contactID: UUID, ackID: String) async {
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
        await demoteMediaRelayAudioAfterMissingFirstPlaybackAckIfNeeded(expectation)
    }

    func demoteMediaRelayAudioAfterMissingFirstPlaybackAckIfNeeded(
        _ expectation: FirstAudioPlaybackAckExpectation
    ) async {
        let mediaRelayTransports = expectation.deliveredTransports.filter {
            $0 == "media-relay-packet" || $0 == "media-relay-tcp"
        }
        guard !mediaRelayTransports.isEmpty else { return }
        let mediaLaneOverride = TurboMediaLaneDebugOverride.mediaLaneOverride()
        guard mediaLaneOverride == .automatic else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Preserved forced media lane after missing first playback ACK",
                metadata: [
                    "contactId": expectation.contactID.uuidString,
                    "channelId": expectation.channelID,
                    "peerDeviceId": expectation.receiverDeviceID,
                    "mediaLaneOverride": mediaLaneOverride.rawValue,
                    "transports": mediaRelayTransports.joined(separator: ","),
                    "transportDigest": expectation.transportDigest,
                    "ackId": expectation.ackID,
                ]
            )
            return
        }
        guard !expectation.senderDeviceID.isEmpty,
              !expectation.receiverDeviceID.isEmpty else {
            return
        }
        let key = MediaRelayConnectionKey(
            sessionID: expectation.channelID,
            localDeviceID: expectation.senderDeviceID,
            peerDeviceID: expectation.receiverDeviceID
        )
        mediaRuntime.suppressMediaRelayAudioSend(for: key)
        await mediaServices.session()?.resetOutgoingAudioTransport(
            reason: "missing-first-playback-ack"
        )
        if let client = mediaRuntime.existingMediaRelayClient(for: key) {
            mediaRuntime.clearMediaRelayClient(matching: key, client: client)
        }
        if let activeTarget = transmitRuntime.activeTarget ?? transmitCoordinator.state.activeTarget,
           activeTarget.contactID == expectation.contactID,
           activeTarget.channelID == expectation.channelID,
           activeTarget.deviceID == expectation.receiverDeviceID {
            configureOutgoingAudioRoute(target: activeTarget)
        } else {
            mediaServices.session()?.updateSenderConfiguration(
                MediaTransportPolicy.orderedContinuity.senderConfiguration
            )
            mediaServices.session()?.updateOutboundOpusEncodingPolicy(
                MediaTransportPolicy.orderedContinuity.opusEncodingPolicy()
            )
        }
        diagnostics.record(
            .media,
            level: .notice,
            message: "Demoted media relay audio to ordered continuity after missing first playback ACK",
            metadata: [
                "contactId": expectation.contactID.uuidString,
                "channelId": expectation.channelID,
                "peerDeviceId": expectation.receiverDeviceID,
                "transports": mediaRelayTransports.joined(separator: ","),
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
            let completedKeyExists = firstAudioPlaybackAckCompletedKeys.contains(completedKey)
            let recentlyClearedKeyExists = hasRecentlyClearedFirstAudioPlaybackAckKey(completedKey)
            if completedKeyExists || recentlyClearedKeyExists {
                let verifiedDirectAudio = payload.transport == "direct-quic"
                if verifiedDirectAudio && completedKeyExists {
                    directAudioPlaybackVerifiedKeys.insert(completedKey)
                }
                diagnostics.record(
                    .media,
                    message: recentlyClearedKeyExists
                        ? "Ignored delayed audio playback ACK after cleared expectation"
                        : verifiedDirectAudio
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
        mediaRuntime.markActiveMediaEpochTransport(payload.transport)
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
            sentTransports.append("runtime-control")
        } catch {
            failures.append("runtime-control:\(error.localizedDescription)")
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
        let wasAlreadySuppressed = mediaRuntime.isMediaRelayAudioSendSuppressed(for: key)
        mediaRuntime.suppressMediaRelayAudioSend(for: key)
        diagnostics.record(
            .media,
            message: "Holding live audio send until a fresh media relay peer is available",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
            ]
        )
        guard !wasAlreadySuppressed else { return }
        demoteActiveMediaRelayAudioSendAfterPeerUnavailableIfNeeded(
            localDeviceID: localDeviceID,
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID
        )
    }

    private func demoteActiveMediaRelayAudioSendAfterPeerUnavailableIfNeeded(
        localDeviceID _: String,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String
    ) {
        guard let activeTarget = transmitRuntime.activeTarget ?? transmitCoordinator.state.activeTarget,
              activeTarget.contactID == contactID,
              activeTarget.channelID == channelID,
              activeTarget.deviceID == peerDeviceID else {
            return
        }
        let session = mediaServices.session()
        session?.updateSenderConfiguration(MediaTransportPolicy.orderedContinuity.senderConfiguration)
        session?.updateOutboundOpusEncodingPolicy(MediaTransportPolicy.orderedContinuity.opusEncodingPolicy())
        Task { @MainActor [weak self] in
            await session?.resetOutgoingAudioTransport(reason: "media-relay-peer-unavailable")
            guard let self else { return }
            self.configureOutgoingAudioRoute(target: activeTarget)
        }
    }

    func isMediaRelayAudioSendSuppressedForActiveOutgoingAudio(contactID: UUID) -> Bool {
        guard let target = transmitRuntime.activeTarget ?? transmitCoordinator.state.activeTarget,
              target.contactID == contactID else {
            return false
        }
        let localDeviceID = backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        guard !localDeviceID.isEmpty else { return false }
        let key = MediaRelayConnectionKey(
            sessionID: target.channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: target.deviceID
        )
        return mediaRuntime.isMediaRelayAudioSendSuppressed(for: key)
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

    func clearMediaRelayAudioSendSuppressionAfterFreshPrewarmIfNeeded(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        key: MediaRelayConnectionKey,
        shouldClear: Bool
    ) {
        guard shouldClear else { return }
        guard mediaRuntime.clearMediaRelayAudioSendSuppression(for: key) else { return }
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

    func shouldTreatTransmitLeaseLossAsStop(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no active transmit state for sender"
    }

    func shouldAbortAudioTailOnExplicitStop(target: TransmitTarget) -> Bool {
        switch mediaTransportPolicyForOutgoingAudio(for: target.contactID) {
        case .directLowLatency, .fastRelayBalanced:
            return true
        case .orderedContinuity, .wakeBackgroundContinuity:
            return false
        }
    }

    func stopOutgoingAudioForExplicitTransmitStop(
        _ mediaSession: (any MediaSession)?,
        target: TransmitTarget
    ) async {
        guard let mediaSession else { return }
        let cleanupHandle = MediaSessionCleanupHandle(mediaSession)
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
            await cleanupHandle.abortSendingAudio()
        } else {
            await cleanupHandle.stopSendingAudio()
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
        let shouldAbortTail = shouldAbortAudioTailOnExplicitStop(target: target)
        let cleanupHandle = MediaSessionCleanupHandle(mediaSession)
        if shouldAbortTail {
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
            Task.detached(priority: .userInitiated) {
                await cleanupHandle.abortSendingAudio()
            }
        } else {
            Task.detached(priority: .userInitiated) {
                await cleanupHandle.stopSendingAudio()
            }
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
        let fromDeviceID = backend.deviceID
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
        let configuredMediaLaneOverride = TurboMediaLaneDebugOverride.mediaLaneOverride()
        let routeIsRelayOnlyForced =
            isDirectPathRelayOnlyForced
            && configuredMediaLaneOverride != .forceFastRelayTls
        let routeIsMediaRelayForced =
            TurboMediaRelayDebugOverride.isForced()
            || configuredMediaLaneOverride.forcesFastRelay
        let configuredTransportPathState = mediaTransportPathState
        let configuredMediaLaneOverrideRaw = configuredMediaLaneOverride.rawValue
        let forcedMediaRelayMediaMode = configuredMediaLaneOverride.forcedMediaRelayMediaMode
        let directAudioAckKey = FirstAudioPlaybackAckSentKey(
            contactID: target.contactID,
            channelID: target.channelID,
            senderDeviceID: fromDeviceID,
            receiverDeviceID: target.deviceID
        )
        let directTransportForAudioSend = !configuredMediaLaneOverride.disablesDirectQuic
            && shouldUseDirectQuicAudioTransport(for: target.contactID)
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
        let requireCurrentOutgoingAudioTarget: @Sendable () throws -> Void = {
            guard outgoingAudioSendTargetGate.allows(outgoingAudioSendTargetToken) else {
                throw CancellationError()
            }
        }
        let sendAudioChunk: @Sendable (String) async throws -> Void = { [weak self] payload in
            try Task.checkCancellation()
            try requireCurrentOutgoingAudioTarget()
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
                try requireCurrentOutgoingAudioTarget()
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
            try requireCurrentOutgoingAudioTarget()
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
            let firstAckOwner = self
            let noteFirstOutboundAudioPayloadQueuedIfCurrent:
                @Sendable (String, [String]) async throws -> Bool = { deliveredPayload, deliveredTransports in
                    try Task.checkCancellation()
                    try requireCurrentOutgoingAudioTarget()
                    return try await MainActor.run {
                        try requireCurrentOutgoingAudioTarget()
                        guard let firstAckOwner else { throw CancellationError() }
                        return firstAckOwner.noteFirstOutboundAudioPayloadQueuedIfNeeded(
                            deliveredPayload,
                            target: target,
                            deliveredTransports: deliveredTransports
                        )
                    }
                }

            let mediaRelaySend: @Sendable (TurboMediaRelayClient) async throws -> TurboMediaRelayMediaMode = { relayClient in
                try Task.checkCancellation()
                try requireCurrentOutgoingAudioTarget()
                if let mediaRelayAudioSendOverride {
                    return try await mediaRelayAudioSendOverride(relayClient, transportPayload)
                }
                return try await relayClient.sendAudioPayload(
                    transportPayload,
                    forcedMediaMode: forcedMediaRelayMediaMode
                )
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
                forcedMediaRelayMediaMode == .tcpOrdered
                    || relayClient.currentMediaMode() == .tcpOrdered
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
            let failNoLegalLiveMediaLane:
                @Sendable (String, [String: String]) async throws -> Void = { reason, extraMetadata in
                    var metadata = [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "toDeviceId": target.deviceID,
                        "reason": reason,
                        "mediaLaneOverride": configuredMediaLaneOverrideRaw,
                        "mediaLaneEffective": configuredTransportPathState.rawValue,
                    ]
                    extraMetadata.forEach { metadata[$0.key] = $0.value }
                    diagnosticsStore.record(
                        .media,
                        level: .error,
                        message: "No legal live media lane available for outbound audio",
                        metadata: metadata
                    )
                    throw OutgoingAudioSendError.noLegalLiveMediaLane
                }
            if let self {
                if routeIsRelayOnlyForced {
                    try await failNoLegalLiveMediaLane(
                        "direct-path-relay-only-forced",
                        ["runtimeLiveMedia": "forbidden"]
                    )
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
                            _ = try await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                                transportPayload,
                                [deliveredTransport]
                            )
                            await MainActor.run {
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
                                    message: "Media relay background-continuity audio send failed; live audio lane is unavailable",
                                    metadata: [
                                        "contactId": target.contactID.uuidString,
                                        "channelId": target.channelID,
                                        "error": error.localizedDescription,
                                    ]
                                )
                            }
                        }
                    }
                    try await failNoLegalLiveMediaLane(
                        "wake-continuity-media-relay-unavailable",
                        ["runtimeLiveMedia": "forbidden"]
                    )
                    return
                }

                if routeIsMediaRelayForced {
                    if let relayClient = await self.mediaRelayClientForAudioSend(target: target) {
                        let bypassMediaRelayPacket = shouldBypassMediaRelayPacketForLegacyPCM(relayClient)
                        if bypassMediaRelayPacket {
                            recordLegacyPCMMediaRelayPacketBypass("forced-media-relay-packet-legacy-pcm")
                        } else if isMediaRelayTcpContinuityPath(relayClient) {
                            var prearmedTcpContinuityAckExpectation = false
                            do {
                                prearmedTcpContinuityAckExpectation =
                                    try await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                                        transportPayload,
                                        ["media-relay-tcp"]
                                    )
                                let mediaMode = try await mediaRelaySend(relayClient)
                                let deliveredTransport = IncomingAudioPayloadTransport(
                                    mediaRelayMediaMode: mediaMode
                                ).diagnosticsValue
                                scheduleLocalAudioCapturedSync(transportPayload)
                                await MainActor.run {
                                    self.mergeFirstAudioPlaybackAckDeliveredTransportsIfPending(
                                        contactID: target.contactID,
                                        deliveredTransports: [deliveredTransport]
                                    )
                                }
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
                                    "Media relay TCP continuity send failed",
                                    "forced-media-relay-tcp",
                                    error
                                )
                            }
                        }
                        if !bypassMediaRelayPacket {
                            var prearmedPacketRelayAckExpectation = false
                            do {
                                prearmedPacketRelayAckExpectation =
                                    try await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                                        transportPayload,
                                        ["media-relay-packet"]
                                    )
                                let mediaMode = try await mediaRelaySend(relayClient)
                                let deliveredTransport = IncomingAudioPayloadTransport(
                                    mediaRelayMediaMode: mediaMode
                                ).diagnosticsValue
                                scheduleLocalAudioCapturedSync(transportPayload)
                                await MainActor.run {
                                    self.mergeFirstAudioPlaybackAckDeliveredTransportsIfPending(
                                        contactID: target.contactID,
                                        deliveredTransports: [deliveredTransport]
                                    )
                                }
                                return
                            } catch is CancellationError {
                                if prearmedPacketRelayAckExpectation {
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
                                if prearmedPacketRelayAckExpectation {
                                    await MainActor.run {
                                        self.clearFirstAudioPlaybackAckState(
                                            contactID: target.contactID,
                                            channelID: target.channelID,
                                            senderDeviceID: fromDeviceID
                                        )
                                    }
                                }
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
                                        message: "Media relay audio send failed; waiting for relay recovery",
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
                    try await failNoLegalLiveMediaLane(
                        "forced-media-relay-unavailable",
                        ["runtimeLiveMedia": "forbidden"]
                    )
                    return
                }

                var deliveredTransports: [String] = []
                var deliveryFailures: [(transport: String, error: Error)] = []
                let directTransport = directTransportForAudioSend
                var prearmedDirectAckExpectation = false
                var directAckPrearmTask: Task<Void, Never>?
                let standbyRelayClient = await self.existingMediaRelayClientForSequentialRescue(
                    target: target,
                    localDeviceID: fromDeviceID
                )
                let standbyRelayIsTCPContinuity = standbyRelayClient.map {
                    isMediaRelayTcpContinuityPath($0)
                } ?? false
                let standbyRelayLegacyPCMBypass = standbyRelayClient.map {
                    shouldBypassMediaRelayPacketForLegacyPCM($0)
                } ?? false
                guard let transportPlan = OutboundAudioTransportPlan.dynamic(
                    directAvailable: directTransport != nil,
                    directVerified: directAudioInitiallyVerified,
                    standbyRelayAvailable: standbyRelayClient != nil,
                    standbyRelayIsTCPContinuity: standbyRelayIsTCPContinuity,
                    legacyPCMBypassesPacketRelay: standbyRelayLegacyPCMBypass
                ) else {
                    diagnosticsStore.record(
                        .media,
                        level: .error,
                        message: "No legal live media lane available for outbound audio",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "directAvailable": String(directTransport != nil),
                            "standbyRelayAvailable": String(standbyRelayClient != nil),
                            "legacyPCMBypassesPacketRelay": String(standbyRelayLegacyPCMBypass),
                        ]
                    )
                    throw OutgoingAudioSendError.noLegalLiveMediaLane
                }
                if let directTransport {
                    do {
                        if directAckPrearmGate.take() {
                            prearmedDirectAckExpectation = true
                            directAckPrearmTask = Task {
                                guard !Task.isCancelled else { return }
                                _ = try? await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                                    transportPayload,
                                    ["direct-quic"]
                                )
                            }
                        }
                        try Task.checkCancellation()
                        try requireCurrentOutgoingAudioTarget()
                        let directSendStartedAt = DispatchTime.now().uptimeNanoseconds
                        if let directQuicAudioSendOverride {
                            try await directQuicAudioSendOverride(directTransport, transportPayload)
                        } else {
                            try await directTransport.sendAudioPayload(transportPayload)
                        }
                        try requireCurrentOutgoingAudioTarget()
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
                                message: "Direct QUIC audio send failed; trying sequential rescue",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "error": error.localizedDescription,
                                ]
                            )
                        }
                    }
                }

                if let relayClient = standbyRelayClient {
                    let bypassMediaRelayPacket = standbyRelayLegacyPCMBypass
                    if bypassMediaRelayPacket {
                        recordLegacyPCMMediaRelayPacketBypass("media-relay-standby-legacy-pcm")
                    } else if transportPlan.usesTcpContinuityRelay, deliveredTransports.isEmpty {
                        var prearmedTcpContinuityAckExpectation = false
                        do {
                            prearmedTcpContinuityAckExpectation =
                                try await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                                    transportPayload,
                                    ["media-relay-tcp"]
                                )
                            let mediaMode = try await mediaRelaySend(relayClient)
                            let deliveredTransport = IncomingAudioPayloadTransport(
                                mediaRelayMediaMode: mediaMode
                            ).diagnosticsValue
                            deliveredTransports.append(deliveredTransport)
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
                            deliveryFailures.append(("media-relay-tcp", error))
                            recordMediaRelayTcpContinuityFailure(
                                "Media relay TCP continuity send failed",
                                "media-relay-tcp-rescue",
                                error
                            )
                        }
                    }
                    let shouldSendStandbyPacketRelay =
                        deliveredTransports.isEmpty
                        && (
                            transportPlan.usesPrimaryMediaRelay
                            || transportPlan.hasSequentialMediaRelayRescue
                        )
                    if shouldSendStandbyPacketRelay, !bypassMediaRelayPacket {
                        do {
                            let mediaMode = try await mediaRelaySend(relayClient)
                            let deliveredTransport = IncomingAudioPayloadTransport(
                                mediaRelayMediaMode: mediaMode
                            ).diagnosticsValue
                            deliveredTransports.append(deliveredTransport)
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
                                    message: "Media relay audio rescue send failed",
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

                if deliveredTransports.count > 1 {
                    let deliveredTransportNames = deliveredTransports.joined(separator: ",")
                    let deliveryFailureCount = deliveryFailures.count
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            message: "Delivered outbound audio after sequential rescue",
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
                    let deliveredTransportsSnapshot = deliveredTransports
                    scheduleLocalAudioCapturedSync(transportPayload)
                    if prearmedDirectAckExpectation {
                        await MainActor.run {
                            self.mergeFirstAudioPlaybackAckDeliveredTransportsIfPending(
                                contactID: target.contactID,
                                deliveredTransports: deliveredTransportsSnapshot
                            )
                        }
                    }
                    if firstPlaybackAckExpectationGate.take() {
                        _ = try await noteFirstOutboundAudioPayloadQueuedIfCurrent(
                            transportPayload,
                            deliveredTransportsSnapshot
                        )
                    }
                }
                return
            }

            try await failNoLegalLiveMediaLane(
                "sender-owner-unavailable",
                ["runtimeLiveMedia": "forbidden"]
            )
        }
        mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateSendAudioChunk(sendAudioChunk)
        let senderPolicy = mediaTransportPolicyForOutgoingAudio(for: target.contactID)
        mediaServices.session()?.updateSenderConfiguration(senderPolicy.senderConfiguration)
        mediaServices.session()?.updateOutboundVoiceMediaPolicy(
            outboundVoiceMediaPayloadFormat(for: target)
        )
        let opusPolicy = outboundOpusEncodingPolicy(for: target.contactID)
        mediaServices.session()?.updateOutboundOpusEncodingPolicy(opusPolicy)
        let selectedChannel = selectedChannelSnapshot(for: target.contactID)
        let directQuicAudioEligible = shouldUseDirectQuicAudioTransport(for: target.contactID)
        let wakeContinuityOutgoing = shouldUseWakeBackgroundContinuityForOutgoingAudio(
            for: target.contactID
        )
        diagnostics.record(
            .media,
            message: "Configured outgoing audio transport",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "deviceId": target.deviceID,
                "voiceMediaPolicy": outboundVoiceMediaPayloadFormat(for: target).rawValue,
                "transportPolicy": senderPolicy.rawValue,
                "transport": configuredOutgoingAudioTransportLabel(for: target.contactID),
                "mediaLaneOverride": TurboMediaLaneDebugOverride.mediaLaneOverride().rawValue,
                "mediaLaneEffective": mediaTransportPathState.rawValue,
                "mediaLaneActiveProven": mediaRuntime.activeMediaEpochPathState?.rawValue ?? "none",
                "directQuicActive": String(shouldUseDirectQuicTransport(for: target.contactID)),
                "directQuicAudioEligible": String(directQuicAudioEligible),
                "directQuicAudioVerified": String(directAudioPlaybackVerifiedKeys.contains(directAudioAckKey)),
                "wakeContinuityOutgoing": String(wakeContinuityOutgoing),
                "applicationState": String(describing: currentApplicationState()),
                "remoteAudioReadyForLiveTransmit": String(
                    selectedChannel?.remoteAudioReadyForLiveTransmit ?? false
                ),
                "remoteWakeCapability": String(describing: selectedChannel?.remoteWakeCapability),
                "mediaRelayEnabled": String(TurboMediaRelayDebugOverride.isEnabled()),
                "mediaRelayForced": String(TurboMediaRelayDebugOverride.isForced()),
                "mediaRelayConfigured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
                "selection": "dynamic",
            ].merging(opusPolicy.diagnosticsMetadata, uniquingKeysWith: { current, _ in current })
        )
        preconnectMediaRelayForAudioSendIfNeeded(target: target)
    }

    func preconnectMediaRelayForAudioSendIfNeeded(target: TransmitTarget) {
        let mediaLaneOverride = TurboMediaLaneDebugOverride.mediaLaneOverride()
        let isIdlePrewarm =
            !transmitCoordinator.state.isPressingTalk
            && !transmitRuntime.isPressingTalk
            && transmitCoordinator.state.activeTarget != target
            && transmitRuntime.activeTarget != target
        let shouldAttempt =
            (!isDirectPathRelayOnlyForced || mediaLaneOverride == .forceFastRelayTls)
            && !mediaLaneOverride.disablesMediaRelay
            && (TurboMediaRelayDebugOverride.isEnabled()
            || TurboMediaRelayDebugOverride.isForced()
            || mediaLaneOverride.forcesFastRelay
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
                "mediaLaneOverride": mediaLaneOverride.rawValue,
                "preferredTransport": mediaLaneOverride.forcedMediaRelayTransport?.rawValue ?? "automatic",
            ]
        )
        Task { [weak self] in
            guard let self else { return }
            _ = await self.mediaRelayClientForAudioSend(
                target: target,
                bypassAudioSendSuppression: isIdlePrewarm,
                preferredTransport: mediaLaneOverride.forcedMediaRelayTransport
            )
        }
    }

    func configuredOutgoingAudioTransportLabel(for contactID: UUID) -> String {
        let mediaLaneOverride = TurboMediaLaneDebugOverride.mediaLaneOverride()
        if isDirectPathRelayOnlyForced && mediaLaneOverride != .forceFastRelayTls {
            return "no-live-media-lane"
        }
        if mediaLaneOverride == .forceDirectQuic {
            return "direct-quic-forced"
        }
        if mediaLaneOverride == .forceFastRelayQuic {
            return "media-relay-packet-forced"
        }
        if mediaLaneOverride == .forceFastRelayTls {
            return "media-relay-tcp-forced"
        }
        if isMediaRelayAudioSendSuppressedForActiveOutgoingAudio(contactID: contactID) {
            return "media-relay-suppressed"
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
        return "no-live-media-lane"
    }

    func mediaRelayClientForAudioSend(
        target: TransmitTarget,
        bypassAudioSendSuppression: Bool = false,
        preferredTransport: TurboMediaRelayTransport? = nil
    ) async -> TurboMediaRelayClient? {
        let requestedPreferredTransport =
            preferredTransport ?? TurboMediaLaneDebugOverride.mediaLaneOverride().forcedMediaRelayTransport
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
            clearsAudioSendSuppressionOnSuccess: bypassAudioSendSuppression,
            missingConfigMessage: "Media relay skipped because relay config is missing",
            connectingMessage: "Connecting media relay",
            selectedMessage: "Media relay selected",
            failureMessage: "Media relay connection failed; live audio lane unavailable",
            cancelledMessage: "Media relay connection ended before relay selection",
            preferredTransport: requestedPreferredTransport,
            fromUserIDForIncoming: { target.userID }
        )
    }

    func existingMediaRelayClientForSequentialRescue(
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
            guard let client = mediaRuntime.existingMediaRelayClient(for: key) else {
                return nil
            }
            return client
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
            preferredTransport: nil,
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
        clearsAudioSendSuppressionOnSuccess: Bool = false,
        missingConfigMessage: String,
        connectingMessage: String,
        selectedMessage: String,
        failureMessage: String,
        cancelledMessage: String,
        preferredTransport: TurboMediaRelayTransport? = nil,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let shouldAttempt = await MainActor.run {
            let mediaLaneOverride = TurboMediaLaneDebugOverride.mediaLaneOverride()
            return (!isDirectPathRelayOnlyForced || allowConfiguredReceiveWithoutLocalToggle)
                && (!mediaLaneOverride.disablesMediaRelay || allowConfiguredReceiveWithoutLocalToggle)
                && (
                    TurboMediaRelayDebugOverride.isEnabled()
                    || TurboMediaRelayDebugOverride.isForced()
                    || mediaLaneOverride.forcesFastRelay
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
            if let preferredTransport {
                let preferredMode: TurboMediaRelayMediaMode = preferredTransport == .tcpTls
                    ? .tcpOrdered
                    : .quicDatagram
                let currentMediaMode = client.currentMediaMode()
                if currentMediaMode != preferredMode {
                    await MainActor.run {
                        mediaRuntime.clearMediaRelayClient(matching: key, client: client)
                        diagnostics.record(
                            .media,
                            level: .notice,
                            message: "Discarded media relay client with mismatched forced lane",
                            metadata: [
                                "contactId": contactID.uuidString,
                                "channelId": channelID,
                                "peerDeviceId": peerDeviceID,
                                "currentMediaMode": currentMediaMode.rawValue,
                                "preferredTransport": preferredTransport.rawValue,
                                "preferredMediaMode": preferredMode.rawValue,
                            ]
                        )
                    }
                    return await mediaRelayClientIfEnabled(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        allowConfiguredReceiveWithoutLocalToggle: allowConfiguredReceiveWithoutLocalToggle,
                        clearsAudioSendSuppressionOnSuccess: clearsAudioSendSuppressionOnSuccess,
                        missingConfigMessage: missingConfigMessage,
                        connectingMessage: connectingMessage,
                        selectedMessage: selectedMessage,
                        failureMessage: failureMessage,
                        cancelledMessage: cancelledMessage,
                        preferredTransport: preferredTransport,
                        fromUserIDForIncoming: fromUserIDForIncoming
                    )
                }
            }
            if client.hasFreshPeerUnavailable() {
                await MainActor.run {
                    suppressMediaRelayAudioSendUntilNextIdlePrewarm(
                        localDeviceID: localDeviceId,
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        reason: "peer-unavailable-reuse-blocked"
                    )
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
            if clearsAudioSendSuppressionOnSuccess {
                await MainActor.run {
                    clearMediaRelayAudioSendSuppressionAfterFreshPrewarmIfNeeded(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        key: key,
                        shouldClear: true
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
            } else if clearsAudioSendSuppressionOnSuccess {
                await MainActor.run {
                    clearMediaRelayAudioSendSuppressionAfterFreshPrewarmIfNeeded(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        key: key,
                        shouldClear: true
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
                clearsAudioSendSuppressionOnSuccess: clearsAudioSendSuppressionOnSuccess,
                preferredTransport: preferredTransport,
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
        clearsAudioSendSuppressionOnSuccess: Bool,
        preferredTransport: TurboMediaRelayTransport?,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let client = TurboMediaRelayClient(
            config: config,
            sessionId: channelID,
            localDeviceId: localDeviceID,
            peerDeviceId: peerDeviceID,
            onIncomingAudioPayload: { [weak self] incoming in
                let fromUserID = await fromUserIDForIncoming()
                await self?.handleIncomingLiveAudioPayload(
                    incoming.payload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: peerDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: IncomingAudioPayloadTransport(
                        mediaRelayMediaMode: incoming.mediaMode
                    ),
                    transportSequenceNumber: incoming.sequenceNumber,
                    expectedReceiveEpoch: nil,
                    ingressContext: IncomingAudioIngressContext(
                        receivedAtNanoseconds: incoming.receivedAtNanoseconds,
                        sequenceNumber: incoming.sequenceNumber,
                        sentAtMilliseconds: incoming.sentAtMilliseconds,
                        source: "media-relay"
                    )
                )
            },
            onExpiredIncomingAudioPayload: { [weak self] incoming, localQueueDelayNanoseconds, thresholdNanoseconds in
                await self?.handleExpiredMediaRelayIncomingAudioPayloadBeforeAppHandler(
                    incoming,
                    contactID: contactID,
                    channelID: channelID,
                    peerDeviceID: peerDeviceID,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                    thresholdNanoseconds: thresholdNanoseconds
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
                        message: "Media relay disconnected; live media lane unavailable until relay reconnects",
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
                    "preferredTransport": preferredTransport?.rawValue ?? "automatic",
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
                transport = try await client.connect(preferredTransport: preferredTransport)
            }
            let accepted = await MainActor.run {
                let key = MediaRelayConnectionKey(
                    sessionID: channelID,
                    localDeviceID: localDeviceID,
                    peerDeviceID: peerDeviceID
                )
                let accepted = mediaRuntime.finishMediaRelayConnectionAttempt(attempt, client: client)
                if accepted {
                    clearMediaRelayAudioSendSuppressionAfterFreshPrewarmIfNeeded(
                        contactID: contactID,
                        channelID: channelID,
                        peerDeviceID: peerDeviceID,
                        key: key,
                        shouldClear: clearsAudioSendSuppressionOnSuccess
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

    nonisolated func handleExpiredMediaRelayIncomingAudioPayloadBeforeAppHandler(
        _ incoming: TurboMediaRelayIncomingAudioPayload,
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
            transport: "media-relay-packet",
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
                "mediaMode": incoming.mediaMode.rawValue,
                "sequenceNumber": incoming.sequenceNumber.map(String.init) ?? "none",
                "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                "maxLocalQueueDelayMs": String(report.maxLocalQueueDelayNanoseconds / 1_000_000),
                "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                "expiredCount": String(report.expiredCount),
            ]
            switch report.disposition {
            case .detailed:
                diagnostics.record(
                    .media,
                    message: "Dropped expired media relay incoming audio payload before app handler",
                    metadata: metadata
                )
            case .suppressionNotice:
                metadata["reason"] = "budget-exhausted"
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Suppressing repetitive expired media relay incoming audio payload diagnostics",
                    metadata: metadata
                )
            case .suppressed:
                break
            }

            guard report.shouldRepairStaleReceive else { return }
            let repaired = repairExpiredRemoteTransmitLeaseIfNeeded(contactID: contactID)
            guard !repaired else { return }
            diagnostics.record(
                .media,
                level: .notice,
                message: "Dropped expired media relay packet before app handler without stopping remote receive",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": peerDeviceID,
                    "sequenceNumber": incoming.sequenceNumber.map(String.init) ?? "none",
                    "localQueueDelayMs": String(localQueueDelayNanoseconds / 1_000_000),
                    "thresholdMs": String(thresholdNanoseconds / 1_000_000),
                ]
            )
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
        let shouldPrejoin = await MainActor.run {
            shouldPrejoinReadyChannelMediaRelay(
                contactID: contactID,
                channelID: channelReadiness.channelId,
                peerDeviceID: peerDeviceID
            )
        }
        guard shouldPrejoin else { return }
        await connectMediaRelayForReceiveIfNeeded(
            contactID: contactID,
            channelID: channelReadiness.channelId,
            peerDeviceID: peerDeviceID
        )
    }

    func canScheduleReadyChannelMediaRelayPrejoin(
        contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        if applicationState == .active { return true }
        return pttWakeRuntime.hasPendingWake(for: contactID)
            && isPTTAudioSessionActive
    }

    func shouldPrejoinReadyChannelMediaRelay(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState != .active else { return true }
        let hasActivatedWake =
            pttWakeRuntime.hasPendingWake(for: contactID)
            && isPTTAudioSessionActive
        guard hasActivatedWake else {
            diagnostics.recordContractViolation(
                DiagnosticsContracts.Media.readyChannelMediaRelayPrejoinRequiresPTTWakeActivation(
                    contactID: contactID,
                    channelID: channelID,
                    peerDeviceID: peerDeviceID,
                    applicationState: readyChannelMediaRelayApplicationStateDescription(applicationState),
                    systemSession: String(describing: pttCoordinator.state.systemSessionState),
                    pendingWake: pttWakeRuntime.hasPendingWake(for: contactID),
                    wakeActivationState: pttWakeRuntime.incomingWakeActivationState(for: contactID)
                        .map { String(describing: $0) } ?? "none",
                    isPTTAudioSessionActive: isPTTAudioSessionActive
                )
            )
            return false
        }
        return true
    }

    private func readyChannelMediaRelayApplicationStateDescription(
        _ applicationState: UIApplication.State
    ) -> String {
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
            media.replaceSendAudioChunk(nil)
            mediaSession?.updateSendAudioChunk(nil)
            if let currentSession = media.session(), currentSession !== mediaSession {
                currentSession.updateSendAudioChunk(nil)
            }
            await stopOutgoingAudioForExplicitTransmitStop(
                mediaSession,
                target: target
            )
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
        media.replaceSendAudioChunk(nil)
        mediaSession?.updateSendAudioChunk(nil)
        if let currentSession = media.session(), currentSession !== mediaSession {
            currentSession.updateSendAudioChunk(nil)
        }
        try? await mediaSession?.stopSendingAudio()

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
                            level: .notice,
                            message: "Transmit lease already ended during renewal",
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
            closeRecreatedMediaSessionPreservingActiveTransport(for: contactID)
        }

        guard !media.hasSession() else { return false }

        let sessionCreationStartedAt = Date()
        let supportsWebSocket = backendServices?.supportsWebSocket == true
        let senderPolicy = mediaTransportPolicyForOutgoingAudio(for: contactID)
        let voiceMediaPolicy = mediaRuntime.outboundVoiceMediaPayloadFormat(for: contactID)
        let opusPolicy = outboundOpusEncodingPolicy(for: contactID)
        let voiceMediaCoreMode = TurboVoiceMediaCoreDebugOverride.liveMode()
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
            outboundOpusEncodingPolicy: opusPolicy,
            voiceMediaCoreMode: voiceMediaCoreMode
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
                "voiceMediaCoreMode": voiceMediaCoreMode.rawValue,
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
            closeRecreatedMediaSessionPreservingActiveTransport(for: contactID)
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
            || startupMode == .playbackOnly

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
            let session = try currentMediaSessionForStartup()
            try await session.start(
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

    func closeRecreatedMediaSessionPreservingActiveTransport(for contactID: UUID) {
        let preserveDirectQuic = shouldUseDirectQuicTransport(for: contactID)
        closeMediaSession(
            preserveDirectQuic: preserveDirectQuic,
            preserveMediaRelay: !preserveDirectQuic
                && shouldPreserveMediaRelayDuringMediaClose(for: contactID)
        )
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
