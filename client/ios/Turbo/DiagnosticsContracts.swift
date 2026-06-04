import Foundation

struct DiagnosticsContractSpec: Equatable {
    let name: String
    let kind: DiagnosticsContractKind
    let invariantID: String
    let scope: DiagnosticsInvariantScope
    let subsystem: DiagnosticsSubsystem
    let message: String
    let metadata: [String: String]

    init(
        name: String,
        kind: DiagnosticsContractKind,
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        subsystem: DiagnosticsSubsystem,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.invariantID = invariantID
        self.scope = scope
        self.subsystem = subsystem
        self.message = message
        self.metadata = metadata.merging(
            [
                "contractName": name,
                "contractKind": kind.rawValue,
                "invariantID": invariantID,
                "scope": scope.rawValue,
            ],
            uniquingKeysWith: { current, _ in current }
        )
    }

    nonisolated func mergedMetadata(_ extraMetadata: [String: String]) -> [String: String] {
        metadata.merging(extraMetadata, uniquingKeysWith: { _, new in new })
    }
}

extension DiagnosticsStore {
    @discardableResult
    nonisolated func requireContract(
        _ condition: Bool,
        _ contract: DiagnosticsContractSpec,
        metadata extraMetadata: [String: String] = [:]
    ) -> Bool {
        requireContract(
            condition,
            kind: contract.kind,
            invariantID: contract.invariantID,
            scope: contract.scope,
            subsystem: contract.subsystem,
            message: contract.message,
            metadata: contract.mergedMetadata(extraMetadata)
        )
    }

    nonisolated func recordContractViolation(
        _ contract: DiagnosticsContractSpec,
        metadata extraMetadata: [String: String] = [:]
    ) {
        recordContractViolation(
            kind: contract.kind,
            invariantID: contract.invariantID,
            scope: contract.scope,
            subsystem: contract.subsystem,
            message: contract.message,
            metadata: contract.mergedMetadata(extraMetadata)
        )
    }
}

enum DiagnosticsContracts {
    enum DirectQuic {
        static func selectedPrewarmRequestBlockedByConnectivityBackoff(
            contactID: UUID,
            requestID: String,
            reason: String,
            peerDeviceID: String,
            retryReason: String,
            retryAttemptID: String?,
            retryBackoffMilliseconds: Int,
            retryRemainingMilliseconds: Int
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "direct-quic.selected_prewarm_request_blocked_by_connectivity_backoff",
                kind: .liveness,
                invariantID: "direct-quic.selected_prewarm_request_blocked_by_connectivity_backoff",
                scope: .local,
                subsystem: .media,
                message: "Selected Direct QUIC prewarm request was blocked by connectivity retry backoff",
                metadata: [
                    "contactId": contactID.uuidString,
                    "requestId": requestID,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "retryReason": retryReason,
                    "retryAttemptId": retryAttemptID ?? "none",
                    "retryBackoffMs": String(retryBackoffMilliseconds),
                    "retryRemainingMs": String(retryRemainingMilliseconds),
                ]
            )
        }
    }

    enum Engine {
        static func transitionViolation(
            invariantID: String,
            kind: DiagnosticsContractKind,
            message: String,
            source: String,
            metadata: [String: String]
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: invariantID,
                kind: kind,
                invariantID: invariantID,
                scope: .local,
                subsystem: .state,
                message: message,
                metadata: metadata.merging(["source": source]) { current, _ in current }
            )
        }
    }

    enum Selected {
        static func inactiveBackendReadinessClearsMembership(
            contactID: UUID,
            channelID: String,
            existing: TurboChannelStateResponse?,
            incoming: TurboChannelStateResponse,
            readiness: TurboChannelReadinessResponse?,
            effective: TurboChannelStateResponse,
            effectiveReadiness: TurboChannelReadinessResponse?,
            localDevicePTTEvidenceEstablished: Bool,
            reconnectGraceActive: Bool
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "selected.inactive_backend_readiness_clears_membership",
                kind: .postcondition,
                invariantID: "selected.backend_inactive_ui_still_joined",
                scope: .backend,
                subsystem: .channel,
                message: "inactive backend readiness and absent membership must clear effective local membership",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "existingMembership": existing?.membership.diagnosticsKind ?? "none",
                    "incomingMembership": incoming.membership.diagnosticsKind,
                    "effectiveMembership": effective.membership.diagnosticsKind,
                    "existingStatus": existing?.statusKind ?? "none",
                    "incomingStatus": incoming.statusKind,
                    "effectiveStatus": effective.statusKind,
                    "incomingBeepThreadProjection": incoming.beepThreadProjection.diagnosticsKind,
                    "backendReadiness": readiness?.statusKind ?? "none",
                    "effectiveReadiness": effectiveReadiness?.statusKind ?? "none",
                    "localDevicePTTEvidenceEstablished": String(localDevicePTTEvidenceEstablished),
                    "reconnectGraceActive": String(reconnectGraceActive),
                ]
            )
        }
    }

    enum Transmit {
        static func targetMatchesContact(
            contactID: UUID,
            expectedChannelID: String?,
            targetChannelID: String,
            expectedRemoteUserID: String?,
            targetUserID: String,
            targetDeviceID: String,
            localDeviceID: String,
            reason: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "identity.transmit_target_matches_contact",
                kind: .precondition,
                invariantID: "identity.transmit_target_mismatch",
                scope: .local,
                subsystem: .media,
                message: "outgoing transmit target must match the contact directory and local device identity",
                metadata: [
                    "contactId": contactID.uuidString,
                    "expectedChannelId": expectedChannelID ?? "none",
                    "targetChannelId": targetChannelID,
                    "expectedRemoteUserId": expectedRemoteUserID ?? "none",
                    "targetUserId": targetUserID,
                    "targetDeviceId": targetDeviceID,
                    "localDeviceId": localDeviceID,
                    "reason": reason,
                ]
            )
        }

        static func outgoingAudioSendRequiresCurrentTarget(
            contactID: UUID,
            channelID: String,
            targetDeviceID: String,
            activeContactID: UUID?,
            activeChannelID: String?,
            activeDeviceID: String?,
            source: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "effect.outgoing_audio_send_requires_current_target",
                kind: .precondition,
                invariantID: "effect.outgoing_audio_send_without_current_target",
                scope: .local,
                subsystem: .media,
                message: "outgoing audio send effect must belong to the current transmit target",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "targetDeviceId": targetDeviceID,
                    "activeContactId": activeContactID?.uuidString ?? "none",
                    "activeChannelId": activeChannelID ?? "none",
                    "activeDeviceId": activeDeviceID ?? "none",
                    "source": source,
                ]
            )
        }

        static func appleGatedAudioActivationDeadlineElapsed(
            contactID: UUID,
            channelID: String,
            channelUUID: UUID,
            targetDeviceID: String,
            trigger: String,
            startupPolicy: String,
            isPTTAudioSessionActive: Bool,
            timeoutMilliseconds: UInt64
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "engine.ptt_activation_deadline_elapsed",
                kind: .liveness,
                invariantID: "engine.ptt_activation_deadline_elapsed",
                scope: .local,
                subsystem: .pushToTalk,
                message: "PTT audio activation did not arrive before Apple-gated transmit deadline",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "channelUUID": channelUUID.uuidString,
                    "targetDeviceId": targetDeviceID,
                    "trigger": trigger,
                    "startupPolicy": startupPolicy,
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "timeoutMs": String(timeoutMilliseconds),
                ]
            )
        }

        static func staleStartupSideEffect(
            stage: String,
            reason: String,
            contactID: UUID,
            channelID: String,
            channelUUID: UUID?,
            runtimePressActive: Bool,
            coordinatorPressActive: Bool,
            explicitStopRequested: Bool
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "transmit.startup_side_effect_requires_current_activation",
                kind: .postcondition,
                invariantID: "transmit.stale_startup_side_effect",
                scope: .local,
                subsystem: .pushToTalk,
                message: "transmit startup side effect completed after activation was no longer current",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "channelUUID": channelUUID?.uuidString ?? "none",
                    "stage": stage,
                    "reason": reason,
                    "runtimePressActive": String(runtimePressActive),
                    "coordinatorPressActive": String(coordinatorPressActive),
                    "explicitStopRequested": String(explicitStopRequested),
                ]
            )
        }
    }

    enum Media {
        static func receiverReadyRequiresNoPendingLeave(
            contactID: UUID,
            channelID: String?,
            reason: String,
            source: String,
            mediaState: String,
            applicationState: String,
            pendingAction: String,
            backendReadiness: String,
            localAudioReadiness: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "receiver.readiness_ready_forbidden_during_pending_leave",
                kind: .precondition,
                invariantID: "receiver.readiness_ready_forbidden_during_pending_leave",
                scope: .local,
                subsystem: .media,
                message: "receiver-ready publication is forbidden while a leave is in flight",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID ?? "none",
                    "reason": reason,
                    "source": source,
                    "mediaState": mediaState,
                    "applicationState": applicationState,
                    "pendingAction": pendingAction,
                    "backendReadiness": backendReadiness,
                    "localAudioReadiness": localAudioReadiness,
                ]
            )
        }

        static func receiverReadyRequiresStableEvidence(
            contactID: UUID,
            channelID: String?,
            reason: String,
            blocker: String,
            source: String,
            mediaState: String,
            applicationState: String,
            backendReadiness: String,
            localAudioReadiness: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "receiver.readiness_ready_requires_stable_evidence",
                kind: .precondition,
                invariantID: "receiver.readiness_ready_requires_stable_evidence",
                scope: .local,
                subsystem: .media,
                message: "receiver-ready publication requires stable media evidence",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID ?? "none",
                    "reason": reason,
                    "blocker": blocker,
                    "source": source,
                    "mediaState": mediaState,
                    "applicationState": applicationState,
                    "backendReadiness": backendReadiness,
                    "localAudioReadiness": localAudioReadiness,
                ]
            )
        }

        static func outboundAudioRequiresRemoteReceiverReady(
            reason: String,
            contactID: UUID,
            channelID: String,
            selectedConversationPhase: String,
            backendChannelStatus: String,
            backendReadiness: String,
            remoteAudioReadiness: String,
            peerDeviceConnected: Bool,
            waitedMilliseconds: Int
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "transmit.outbound_audio_requires_remote_receiver_ready",
                kind: .precondition,
                invariantID: "transmit.outbound_audio_without_remote_receiver_ready",
                scope: .backend,
                subsystem: .media,
                message: "sender resumed outbound audio before remote receiver readiness recovered",
                metadata: [
                    "reason": reason,
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "selectedConversationPhase": selectedConversationPhase,
                    "backendChannelStatus": backendChannelStatus,
                    "backendReadiness": backendReadiness,
                    "remoteAudioReadiness": remoteAudioReadiness,
                    "peerDeviceConnected": String(peerDeviceConnected),
                    "waitedMilliseconds": String(waitedMilliseconds),
                ]
            )
        }

        static func incomingAudioChunkGap(
            contactID: UUID,
            channelID: String,
            incomingTransport: String,
            previousTransport: String,
            gapMilliseconds: UInt64,
            thresholdMilliseconds: UInt64,
            receivePhase: String,
            selectedTransport: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.incoming_audio_chunk_gap",
                kind: .liveness,
                invariantID: "media.incoming_audio_chunk_gap",
                scope: .local,
                subsystem: .media,
                message: "active receive epoch had an excessive gap between accepted audio chunks",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "incomingTransport": incomingTransport,
                    "previousTransport": previousTransport,
                    "gapMilliseconds": String(gapMilliseconds),
                    "thresholdMilliseconds": String(thresholdMilliseconds),
                    "receivePhase": receivePhase,
                    "selectedTransport": selectedTransport,
                ]
            )
        }

        static func incomingAudioSequenceGap(
            contactID: UUID,
            channelID: String,
            incomingTransport: String,
            previousTransport: String,
            previousSequenceNumber: UInt64,
            sequenceNumber: UInt64,
            missingSequenceCount: UInt64,
            receivePhase: String,
            selectedTransport: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.incoming_audio_sequence_gap",
                kind: .liveness,
                invariantID: "media.incoming_audio_sequence_gap",
                scope: .local,
                subsystem: .media,
                message: "active receive epoch had a gap in accepted audio sequence numbers",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "incomingTransport": incomingTransport,
                    "previousTransport": previousTransport,
                    "previousSequenceNumber": String(previousSequenceNumber),
                    "sequenceNumber": String(sequenceNumber),
                    "missingSequenceCount": String(missingSequenceCount),
                    "receivePhase": receivePhase,
                    "selectedTransport": selectedTransport,
                ]
            )
        }

        static func incomingAudioQueueDelay(
            contactID: UUID,
            channelID: String,
            attemptID: String,
            incomingTransport: String,
            sequenceNumber: String,
            localQueueDelayMilliseconds: UInt64,
            senderClockAgeMilliseconds: String,
            thresholdMilliseconds: UInt64,
            action: String = "preserved"
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.incoming_audio_queue_delay",
                kind: .liveness,
                invariantID: "media.incoming_audio_queue_delay",
                scope: .local,
                subsystem: .media,
                message: "Incoming audio payload was delayed in the local receive queue",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "incomingTransport": incomingTransport,
                    "sequenceNumber": sequenceNumber,
                    "directQuicSequenceNumber": sequenceNumber,
                    "localQueueDelayMs": String(localQueueDelayMilliseconds),
                    "senderClockAgeMs": senderClockAgeMilliseconds,
                    "thresholdMs": String(thresholdMilliseconds),
                    "action": action,
                ]
            )
        }

        static func firstAudioPlaybackAckMissing(
            contactID: UUID,
            channelID: String,
            senderDeviceID: String,
            receiverDeviceID: String,
            transportDigest: String,
            encryptedSequenceNumber: UInt64?,
            deliveredTransports: [String],
            timeoutMilliseconds: UInt64,
            ackID: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.first_audio_playback_ack_arrives_before_timeout",
                kind: .liveness,
                invariantID: "transmit.first_audio_playback_ack_missing",
                scope: .pair,
                subsystem: .media,
                message: "first outbound audio was queued but receiver playback ACK did not arrive",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": senderDeviceID,
                    "receiverDeviceId": receiverDeviceID,
                    "transportDigest": transportDigest,
                    "encryptedSequenceNumber": encryptedSequenceNumber.map(String.init) ?? "none",
                    "deliveredTransports": deliveredTransports.joined(separator: ","),
                    "timeoutMs": String(timeoutMilliseconds),
                    "ackId": ackID,
                ]
            )
        }

        static func sessionEvent(
            message: String,
            invariantID: String,
            kind: DiagnosticsContractKind,
            scope: DiagnosticsInvariantScope,
            metadata: [String: String]
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: invariantID,
                kind: kind,
                invariantID: invariantID,
                scope: scope,
                subsystem: .media,
                message: message,
                metadata: metadata
            )
        }

        static func firstAudioAckMatchesExpectation(
            contactID: UUID,
            expectedChannelID: String,
            receivedChannelID: String,
            expectedSenderDeviceID: String,
            receivedSenderDeviceID: String,
            expectedReceiverDeviceID: String,
            receivedReceiverDeviceID: String,
            expectedTransports: [String],
            receivedTransport: String,
            expectedTransportDigest: String,
            receivedTransportDigest: String,
            expectedEncryptedSequenceNumber: UInt64?,
            receivedEncryptedSequenceNumber: UInt64?,
            ackID: String,
            source: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.first_audio_ack_matches_pending_expectation",
                kind: .precondition,
                invariantID: "media.audio_playback_ack_mismatch",
                scope: .local,
                subsystem: .media,
                message: "Ignored mismatched audio playback ACK",
                metadata: [
                    "contactId": contactID.uuidString,
                    "expectedChannelId": expectedChannelID,
                    "receivedChannelId": receivedChannelID,
                    "expectedSenderDeviceId": expectedSenderDeviceID,
                    "receivedSenderDeviceId": receivedSenderDeviceID,
                    "expectedReceiverDeviceId": expectedReceiverDeviceID,
                    "receivedReceiverDeviceId": receivedReceiverDeviceID,
                    "expectedTransports": expectedTransports.joined(separator: ","),
                    "receivedTransport": receivedTransport,
                    "expectedTransportDigest": expectedTransportDigest,
                    "receivedTransportDigest": receivedTransportDigest,
                    "expectedEncryptedSequenceNumber": expectedEncryptedSequenceNumber.map(String.init) ?? "none",
                    "receivedEncryptedSequenceNumber": receivedEncryptedSequenceNumber.map(String.init) ?? "none",
                    "ackId": ackID,
                    "source": source,
                ]
            )
        }

        static func firstAudioAckHasExpectation(
            contactID: UUID,
            channelID: String,
            senderDeviceID: String,
            receiverDeviceID: String,
            transportDigest: String,
            encryptedSequenceNumber: UInt64? = nil,
            ackID: String,
            source: String
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.first_audio_ack_requires_pending_expectation",
                kind: .precondition,
                invariantID: "transmit.first_audio_ack_without_expectation",
                scope: .local,
                subsystem: .media,
                message: "Ignored audio playback ACK without pending expectation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": senderDeviceID,
                    "receiverDeviceId": receiverDeviceID,
                    "transportDigest": transportDigest,
                    "encryptedSequenceNumber": encryptedSequenceNumber.map(String.init) ?? "none",
                    "ackId": ackID,
                    "source": source,
                ]
            )
        }

        static func relayControlFrameMatchesCurrentPeer(
            contactID: UUID,
            expectedChannelID: String,
            receivedChannelID: String,
            expectedPeerDeviceID: String,
            receivedPeerDeviceID: String,
            kind: String,
            requestID: String?,
            ackID: String?
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "media.relay_control_frame_matches_current_peer",
                kind: .precondition,
                invariantID: "media.relay_control_frame_mismatch",
                scope: .local,
                subsystem: .media,
                message: "Ignored stale media relay control frame",
                metadata: [
                    "contactId": contactID.uuidString,
                    "expectedChannelId": expectedChannelID,
                    "receivedChannelId": receivedChannelID,
                    "expectedPeerDeviceId": expectedPeerDeviceID,
                    "receivedPeerDeviceId": receivedPeerDeviceID,
                    "kind": kind,
                    "requestId": requestID ?? "none",
                    "ackId": ackID ?? "none",
                ]
            )
        }

        static func readyChannelMediaRelayPrejoinRequiresPTTWakeActivation(
            contactID: UUID,
            channelID: String,
            peerDeviceID: String,
            applicationState: String,
            systemSession: String,
            pendingWake: Bool,
            wakeActivationState: String,
            isPTTAudioSessionActive: Bool
        ) -> DiagnosticsContractSpec {
            DiagnosticsContractSpec(
                name: "ptt.background_media_prejoin_requires_wake_activation",
                kind: .precondition,
                invariantID: "ptt.background_media_prejoin_requires_wake_activation",
                scope: .local,
                subsystem: .media,
                message: "ready-channel media relay prejoin requires foreground or active PTT wake audio activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "applicationState": applicationState,
                    "systemSession": systemSession,
                    "pendingWake": String(pendingWake),
                    "wakeActivationState": wakeActivationState,
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                ]
            )
        }
    }
}

private extension TurboChannelMembership {
    var diagnosticsKind: String {
        switch self {
        case .absent:
            return "absent"
        case .peerOnly:
            return "peer-only"
        case .selfOnly:
            return "self-only"
        case .both:
            return "both"
        }
    }
}

private extension BackendBeepThreadProjection {
    var diagnosticsKind: String {
        switch self {
        case .none:
            return "none"
        case .incoming:
            return "incoming"
        case .outgoing:
            return "outgoing"
        case .mutual:
            return "mutual"
        }
    }
}
