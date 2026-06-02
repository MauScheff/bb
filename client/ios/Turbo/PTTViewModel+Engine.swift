//
//  PTTViewModel+Engine.swift
//  Turbo
//
//  Created by Codex on 18.05.2026.
//

import Foundation
import TurboEngine

@MainActor
extension PTTViewModel {
    var engineSnapshot: TurboEngineSnapshot {
        engine.snapshot
    }

    var engineTrace: EngineTrace {
        engineTraceRecorder.trace
    }

    func encodedEngineTrace() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(engineTraceRecorder.trace)
    }

    func resetEngineTrace(reason: String) {
        engineTraceRecorder.reset(localDeviceID: engine.state.localDeviceID)
        diagnostics.record(
            .state,
            level: .debug,
            message: "Reset TurboEngine trace",
            metadata: ["reason": reason]
        )
    }

    @discardableResult
    func sendEngineIntent(_ intent: TurboEngineIntent, source: String) -> TurboEngineTransition {
        let previousState = engine.state
        let transition = engine.send(intent)
        handleEngineTransition(
            transition,
            input: .intent(intent),
            previousState: previousState,
            source: source
        )
        return transition
    }

    @discardableResult
    func receiveEngineEvent(_ event: TurboEngineEvent, source: String) -> TurboEngineTransition {
        let previousState = engine.state
        let transition = engine.receive(event)
        handleEngineTransition(
            transition,
            input: .event(event),
            previousState: previousState,
            source: source
        )
        return transition
    }

    func syncEngineSelectedFriend(_ contact: Contact?, reason: String) {
        let friend = contact.map {
            SelectedFriendEvidence(
                contactID: ContactID($0.id.uuidString),
                handle: $0.handle
            )
        }
        sendEngineIntent(.selectFriend(friend), source: "selected-friend:\(reason)")
    }

    func syncEngineLifecycle(_ lifecycle: EngineApplicationState, reason: String) {
        receiveEngineEvent(
            .lifecycle(.moved(lifecycle)),
            source: "app-lifecycle:\(reason)"
        )
    }

    func syncEngineAudioOutputPreference(reason: String) {
        let enginePreference: EngineAudioOutputPreference
        switch audioOutputPreference {
        case .speaker:
            enginePreference = .speaker
        case .phone:
            enginePreference = .phone
        }
        sendEngineIntent(
            .setAudioOutputPreference(enginePreference),
            source: "audio-output:\(reason)"
        )
    }

    func syncEngineMediaRelayLaneAvailable(
        transport: TurboMediaRelayTransport,
        source: String
    ) {
        let lane: TransportLane
        switch transport {
        case .quic, .quicDatagram:
            lane = .fastRelayQuic
        case .tcpTls:
            lane = .fastRelayTcp
        }
        receiveEngineEvent(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(
                        lane: lane,
                        networkPathGeneration: mediaRuntime.networkPathGeneration
                    )
                )
            ),
            source: "transport-lane-available:\(source)"
        )
    }

    func syncEngineActiveMediaRelayLaneAvailable(source: String) {
        guard let client = mediaRuntime.mediaRelayClient else { return }
        let transport: TurboMediaRelayTransport =
            client.currentMediaMode() == .tcpOrdered ? .tcpTls : .quicDatagram
        syncEngineMediaRelayLaneAvailable(
            transport: transport,
            source: source
        )
    }

    func syncEngineDirectQuicLaneFailed(reason: String, source: String) {
        let normalizedReason = reason.lowercased()
        let unavailableReason: TransportUnavailableReason
        if normalizedReason.contains("network") {
            unavailableReason = .networkChanged(engineNetworkInterface(for: localConversationNetworkInterface))
        } else {
            unavailableReason = .quicBlocked
        }
        receiveEngineEvent(
            .transport(
                .laneFailed(
                    TransportLaneFailure(
                        lane: .directQuic,
                        reason: unavailableReason,
                        networkPathGeneration: mediaRuntime.networkPathGeneration
                    )
                )
            ),
            source: "transport-lane-failed:\(source)"
        )
    }

    func syncEngineJoinedConversation(contactID: UUID, reason: String) {
        guard !conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else {
            diagnostics.record(
                .backend,
                message: "Ignored backend joined Conversation while leave is in flight",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "engineConversation": String(describing: engine.snapshot.conversation),
                ]
            )
            if engine.snapshot.conversation.joinedEvidence?.friend.contactID.rawValue == contactID.uuidString {
                syncEngineDisconnect(contactID: contactID, reason: "joined-refresh-during-leave")
            }
            return
        }
        if let channelUUID = channelUUID(for: contactID),
           hasStaleSystemRejoinSuppression(channelUUID: channelUUID, contactID: contactID) {
            diagnostics.record(
                .backend,
                message: "Ignored backend joined Conversation after recent system leave",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "engineConversation": String(describing: engine.snapshot.conversation),
                ]
            )
            if engine.snapshot.conversation.joinedEvidence?.friend.contactID.rawValue == contactID.uuidString {
                syncEngineDisconnect(contactID: contactID, reason: "joined-refresh-after-recent-system-leave")
            }
            return
        }

        if let joined = engineJoinedConversationEvidence(for: contactID) {
            receiveEngineEvent(
                .backend(.joined(joined)),
                source: "backend-conversation:\(reason)"
            )
            return
        }

        if devicePTTEvidenceExists(for: contactID),
           let joined = fallbackEngineJoinedConversationEvidence(for: contactID) {
            diagnostics.record(
                .backend,
                message: "Preserved engine joined Conversation from local PTT evidence",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "systemSession": String(describing: systemSessionState),
                ]
            )
            receiveEngineEvent(
                .backend(.joined(joined)),
                source: "backend-conversation:local-session-preserved:\(reason)"
            )
            return
        }

        guard case .joined(let joined) = engine.snapshot.conversation,
              joined.friend.contactID.rawValue == contactID.uuidString else {
            return
        }
        receiveEngineEvent(
            .backend(.joinFailed(.backendReconnect)),
            source: "backend-conversation-unavailable:\(reason)"
        )
    }

    func forceSyncEngineJoinedConversation(contactID: UUID, reason: String) {
        guard let joined =
            engineJoinedConversationEvidence(for: contactID)
            ?? fallbackEngineJoinedConversationEvidence(for: contactID) else {
            return
        }
        receiveEngineEvent(
            .backend(.joined(joined)),
            source: "backend-conversation:\(reason)"
        )
    }

    func syncEngineDisconnect(contactID: UUID, reason: String) {
        guard engine.snapshot.conversation.joinedEvidence?.friend.contactID.rawValue == contactID.uuidString else {
            return
        }
        sendEngineIntent(.disconnect(ContactID(contactID.uuidString)), source: "disconnect:\(reason)")
    }

    func clearEngineTransmitIfActive(reason: String) {
        guard let transmitID = engine.snapshot.transmit.activeEpoch?.transmitID else { return }
        sendEngineIntent(.endTalk, source: "transmit-clear:\(reason)")
        receiveEngineEvent(
            .backend(.stopTransmitAccepted(transmitID)),
            source: "transmit-clear:\(reason)"
        )
    }

    func syncEngineObservedSystemTransmit(
        contactID: UUID,
        channelUUID: UUID?,
        reason: String
    ) {
        guard engine.snapshot.conversation.joinedEvidence?.friend.contactID.rawValue == contactID.uuidString else {
            return
        }
        if case .active = engine.snapshot.transmit {
            return
        }
        let transmitID =
            channelUUID
                .flatMap { activeTransmitTarget(for: $0) }
                .map(engineTransmitID(for:))
            ?? EngineTransmitID("system-\((channelUUID ?? contactID).uuidString)")
        receiveEngineEvent(
            .ptt(.systemTransmitBegan(transmitID)),
            source: "ptt-system-transmit-observed:\(reason)"
        )
    }

    func syncEngineBeginTalkIntent(reason: String) {
        sendEngineIntent(.beginTalk, source: "transmit-begin:\(reason)")
    }

    func syncEngineEndTalkIntent(reason: String) {
        sendEngineIntent(.endTalk, source: "transmit-end:\(reason)")
    }

    func syncEngineBackendTransmitAccepted(target: TransmitTarget, source: String) {
        receiveEngineEvent(
            .backend(.beginTransmitAccepted(engineTransmitID(for: target))),
            source: "backend-transmit-accepted:\(source)"
        )
    }

    func syncEngineBackendTransmitStopped(target: TransmitTarget, source: String) {
        let transmitID = engineTransmitID(for: target)
        guard case .stopping(let stop) = engineSnapshot.transmit,
              stop.epoch.transmitID == transmitID else {
            diagnostics.record(
                .state,
                message: "Skipped engine backend transmit stop because transmit is not stopping",
                metadata: [
                    "channelID": target.channelID,
                    "source": source,
                    "transmitID": transmitID.rawValue,
                    "engineTransmit": String(describing: engineSnapshot.transmit),
                ]
            )
            return
        }
        receiveEngineEvent(
            .backend(.stopTransmitAccepted(transmitID)),
            source: "backend-transmit-stopped:\(source)"
        )
    }

    func syncEngineSystemTransmitBegan(target: TransmitTarget, source: String) {
        receiveEngineEvent(
            .ptt(.systemTransmitBegan(engineTransmitID(for: target))),
            source: "ptt-transmit-began:\(source)"
        )
    }

    func syncEngineSystemTransmitEnded(target: TransmitTarget, source: String) {
        let transmitID = engineTransmitID(for: target)
        if case .active(let epoch) = engineSnapshot.transmit,
           epoch.transmitID == transmitID {
            sendEngineIntent(.endTalk, source: "ptt-transmit-ended:\(source):implicit-end")
        }
        guard case .stopping(let stop) = engineSnapshot.transmit,
              stop.epoch.transmitID == transmitID else {
            diagnostics.record(
                .state,
                message: "Skipped engine system transmit end because transmit is not stopping",
                metadata: [
                    "channelID": target.channelID,
                    "source": source,
                    "transmitID": transmitID.rawValue,
                    "engineTransmit": String(describing: engineSnapshot.transmit),
                ]
            )
            return
        }
        receiveEngineEvent(
            .ptt(.systemTransmitEnded(transmitID)),
            source: "ptt-transmit-ended:\(source)"
        )
    }

    func syncEngineSystemTransmitBeginFailed(message: String, source: String) {
        receiveEngineEvent(
            .ptt(.systemTransmitBeginFailed(.systemRejected(message))),
            source: "ptt-transmit-begin-failed:\(source)"
        )
    }

    func syncEngineRemoteTransmitStarted(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String,
        source: String
    ) {
        receiveEngineEvent(
            .backend(
                .remoteTransmitStarted(
                    engineRemoteTransmitPrepare(
                        contactID: contactID,
                        channelID: channelID,
                        senderDeviceID: senderDeviceID
                    )
                )
            ),
            source: "remote-transmit-started:\(source)"
        )
    }

    func syncEngineRemoteTransmitStopped(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String,
        source: String
    ) {
        guard let transmitID = engineCurrentRemoteTransmitID(
            channelID: channelID,
            includeDraining: true
        ) else {
            diagnostics.record(
                .state,
                message: "Skipped engine remote transmit stop without active receive epoch",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "senderDeviceId": senderDeviceID,
                    "source": source,
                ]
            )
            return
        }
        receiveEngineEvent(
            .backend(.remoteTransmitStopped(transmitID)),
            source: "remote-transmit-stopped:\(source)"
        )
    }

    func syncEnginePTTAudioActivated(
        contactID: UUID,
        channelID: String,
        source: String
    ) {
        receiveEngineEvent(
            .ptt(
                .audioActivated(
                    PTTActivationEvidence(
                        channelID: EngineChannelID(channelID),
                        activatedAtTick: engine.state.tick
                    )
                )
            ),
            source: "ptt-audio-activated:\(source)"
        )
    }

    @discardableResult
    func syncEngineLocalAudioCaptured(
        payload: String,
        target: TransmitTarget,
        source: String
    ) -> Bool {
        let transmitID = engineTransmitID(for: target)
        guard engine.snapshot.transmit.activeEpoch?.transmitID == transmitID else {
            diagnostics.record(
                .media,
                message: "Dropped local audio captured after transmit stopped",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "transmitId": transmitID.rawValue,
                    "source": source,
                    "engineTransmitPhase": String(describing: engine.snapshot.transmit),
                ]
            )
            return false
        }
        let sequence = mediaRuntime.nextEngineLocalAudioSequence(for: target.contactID)
        let digest = AudioChunkPayloadCodec.transportDigest(payload)
        let transition = receiveEngineEvent(
            .media(
                .localAudioCaptured(
                    EngineAudioChunk(
                        id: engineAudioChunkID(
                            transmitID: transmitID,
                            sequence: sequence,
                            digest: digest
                        ),
                        transmitID: transmitID,
                        sequence: EngineAudioSequence(sequence),
                        fromDeviceID: EngineDeviceID(backendServices?.deviceID ?? engine.state.localDeviceID.rawValue),
                        toDeviceID: EngineDeviceID(target.deviceID),
                        transport: engineTransportPath(for: target.contactID),
                        payloadDigest: EnginePayloadDigest(digest)
                    )
                )
            ),
            source: "local-audio-captured:\(source)"
        )
        return !transition.invariantViolations.contains {
            $0.invariantID == "engine.local_audio_requires_active_transmit_epoch"
        }
    }

    func syncEngineRemoteAudioReceived(
        originalPayload: String,
        openedPayload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport,
        source: String,
        receivedAtTick: UInt64? = nil,
        durationTicks: UInt64? = nil
    ) {
        if engineCurrentRemoteTransmitID(channelID: channelID, includeDraining: false) == nil {
            syncEngineRemoteTransmitStarted(
                contactID: contactID,
                channelID: channelID,
                senderDeviceID: fromDeviceID,
                source: "\(source)-implicit"
            )
        }
        let transmitID =
            engineCurrentRemoteTransmitID(channelID: channelID, includeDraining: false)
            ?? engineBackendActiveTransmitID(for: contactID)
            ?? EngineTransmitID("remote-\(channelID)-\(fromDeviceID)-audio")
        let identity = audioPayloadIdentity(originalPayload)
        let sequence = identity.encryptedSequenceNumber.map(engineAudioSequence) ?? mediaRuntime.nextEngineRemoteAudioSequence(for: contactID)
        let digest = AudioChunkPayloadCodec.transportDigest(openedPayload)
        receiveEngineEvent(
            .media(
                .remoteAudioReceived(
                    EngineAudioChunk(
                        id: engineAudioChunkID(
                            transmitID: transmitID,
                            sequence: sequence,
                            digest: digest
                        ),
                        transmitID: transmitID,
                        sequence: EngineAudioSequence(sequence),
                        fromDeviceID: EngineDeviceID(fromDeviceID),
                        toDeviceID: EngineDeviceID(backendServices?.deviceID ?? engine.state.localDeviceID.rawValue),
                        transport: engineTransportPath(incomingAudioTransport),
                        payloadDigest: EnginePayloadDigest(digest),
                        mediaCapability: engineMediaCapability(for: incomingAudioTransport),
                        receivedAtTick: receivedAtTick,
                        durationTicks: durationTicks
                    )
                )
            ),
            source: "remote-audio-received:\(source)"
        )
    }

    func engineMediaCapability(
        for incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> EngineMediaTransportCapability {
        switch incomingAudioTransport {
        case .directQuic:
            return .unorderedPacketMedia(
                UnorderedPacketMediaEvidence(path: .directQuic, reason: .directQuicDatagram)
            )
        case .mediaRelayPacket:
            return .unorderedPacketMedia(
                UnorderedPacketMediaEvidence(path: .fastRelay, reason: .fastRelayPacketRelay)
            )
        case .mediaRelayTcp:
            return .orderedReliableMedia(
                OrderedReliableMediaEvidence(path: .fastRelay, reason: .fastRelayTcpFallback)
            )
        case .relayWebSocket:
            return .orderedReliableMedia(
                OrderedReliableMediaEvidence(path: .relayWebSocket, reason: .webSocketFallback)
            )
        }
    }

    func syncEngineRemotePlaybackDrained(contactID: UUID, source: String) {
        guard let channelID =
            contacts.first(where: { $0.id == contactID })?.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId,
            let transmitID = engineCurrentRemoteTransmitID(
                channelID: channelID,
                includeDraining: true
            ) else {
            return
        }
        receiveEngineEvent(
            .media(.playbackDrained(transmitID)),
            source: "remote-playback-drained:\(source)"
        )
    }

    private func engineJoinedConversationEvidence(for contactID: UUID) -> JoinedConversationEvidence? {
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return nil }
        guard let channelState = channelStateByContactID[contactID] else { return nil }
        guard channelState.membership.hasLocalMembership else { return nil }

        let readiness = channelReadinessByContactID[contactID]
        let channelID = EngineChannelID(contact.backendChannelId ?? channelState.channelId)
        let localDeviceID = EngineDeviceID(backendServices?.deviceID ?? engine.state.localDeviceID.rawValue)
        let receiverAddressability = engineReceiverAddressability(
            contactID: contactID,
            channelID: channelID,
            channelState: channelState,
            readiness: readiness
        )
        let peerDeviceID = engineReceiverAddressabilityDeviceID(receiverAddressability)
        let peerDevice: EngineReadiness<PeerDeviceEvidence> = {
            switch receiverAddressability {
            case .foreground(let evidence):
                return .ready(evidence)
            case .wakeCapable, .unavailable:
                return .pending(.waitingForPeerDevice)
            }
        }()
        let sessionReadiness = engineJoinedReadiness(
            channelID: channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID,
            channelState: channelState,
            readiness: readiness,
            contactID: contactID
        )

        return JoinedConversationEvidence(
            friend: SelectedFriendEvidence(
                contactID: ContactID(contactID.uuidString),
                handle: contact.handle
            ),
            channelID: channelID,
            localDeviceID: localDeviceID,
            peerDevice: peerDevice,
            receiverAddressability: receiverAddressability,
            readiness: sessionReadiness
        )
    }

    private func fallbackEngineJoinedConversationEvidence(for contactID: UUID) -> JoinedConversationEvidence? {
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return nil }
        let channelID = contact.backendChannelId
            ?? channelStateByContactID[contactID]?.channelId
            ?? contactID.uuidString
        return JoinedConversationEvidence(
            friend: SelectedFriendEvidence(
                contactID: ContactID(contactID.uuidString),
                handle: contact.handle
            ),
            channelID: EngineChannelID(channelID),
            localDeviceID: EngineDeviceID(backendServices?.deviceID ?? engine.state.localDeviceID.rawValue),
            peerDevice: .pending(.waitingForPeerDevice),
            receiverAddressability: .unavailable(.peerDeviceUnavailable),
            readiness: .pending(.waitingForPeerDevice)
        )
    }

    private func engineJoinedReadiness(
        channelID: EngineChannelID,
        localDeviceID: EngineDeviceID,
        peerDeviceID: EngineDeviceID?,
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse?,
        contactID: UUID
    ) -> EngineReadiness<JoinedReadinessEvidence> {
        guard let peerDeviceID else {
            return .pending(.waitingForPeerDevice)
        }
        guard channelState.membership.hasPeerMembership || channelState.membership.peerDeviceConnected else {
            return .pending(.waitingForPeerDevice)
        }
        if case .wakeCapable = readiness?.remoteWakeCapability {
            let membership = BackendMembershipEvidence(
                channelID: channelID,
                localDeviceID: localDeviceID,
                peerDeviceID: peerDeviceID,
                observedAtTick: engine.state.tick
            )
            return .ready(
                JoinedReadinessEvidence(
                    backendMembershipObserved: membership,
                    transport: engineTransportPath(for: contactID)
                )
            )
        }
        guard channelState.canTransmit || readiness?.canTransmit == true else {
            return .pending(.waitingForAudio)
        }

        let membership = BackendMembershipEvidence(
            channelID: channelID,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID,
            observedAtTick: engine.state.tick
        )
        return .ready(
            JoinedReadinessEvidence(
                backendMembershipObserved: membership,
                transport: engineTransportPath(for: contactID)
            )
        )
    }

    private func enginePeerDeviceID(
        contactID: UUID,
        readiness: TurboChannelReadinessResponse?
    ) -> EngineDeviceID? {
        let value =
            directQuicPeerDeviceID(for: contactID)
            ?? readiness?.peerTargetDeviceId
        guard let value, !value.isEmpty else { return nil }
        return EngineDeviceID(value)
    }

    private func engineReceiverAddressability(
        contactID: UUID,
        channelID: EngineChannelID,
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse?
    ) -> ReceiverAddressability {
        if channelState.membership.peerDeviceConnected,
           let peerDeviceID = enginePeerDeviceID(contactID: contactID, readiness: readiness) {
            return .foreground(PeerDeviceEvidence(deviceID: peerDeviceID))
        }

        if case .wakeCapable(let targetDeviceID) = readiness?.remoteWakeCapability,
           !targetDeviceID.isEmpty {
            return .wakeCapable(
                WakeTargetEvidence(
                    channelID: channelID,
                    deviceID: EngineDeviceID(targetDeviceID),
                    tokenObservedAtTick: engine.state.tick
                )
            )
        }

        if let peerDeviceID = enginePeerDeviceID(contactID: contactID, readiness: readiness) {
            return .foreground(PeerDeviceEvidence(deviceID: peerDeviceID))
        }

        return .unavailable(channelState.membership.hasPeerMembership ? .peerDeviceUnavailable : .membershipLost)
    }

    private func engineReceiverAddressabilityDeviceID(
        _ addressability: ReceiverAddressability
    ) -> EngineDeviceID? {
        switch addressability {
        case .foreground(let evidence):
            return evidence.deviceID
        case .wakeCapable(let evidence):
            return evidence.deviceID
        case .unavailable:
            return nil
        }
    }

    private func engineTransportPath(for contactID: UUID) -> EngineTransportPath {
        if shouldUseDirectQuicTransport(for: contactID) {
            return .directQuic
        }
        switch mediaTransportPathState {
        case .fastRelay, .fastRelayTcp:
            return .fastRelay
        case .relay, .promoting, .recovering, .direct:
            return .relayWebSocket
        }
    }

    private func engineTransportPath(_ incomingAudioTransport: IncomingAudioPayloadTransport) -> EngineTransportPath {
        switch incomingAudioTransport {
        case .relayWebSocket:
            return .relayWebSocket
        case .mediaRelayPacket, .mediaRelayTcp:
            return .fastRelay
        case .directQuic:
            return .directQuic
        }
    }

    private func engineTransmitID(for target: TransmitTarget) -> EngineTransmitID {
        EngineTransmitID(target.transmitID ?? "local-\(target.channelID)")
    }

    private func engineRemoteTransmitPrepare(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String
    ) -> RemoteTransmitPrepareEvidence {
        RemoteTransmitPrepareEvidence(
            channelID: EngineChannelID(channelID),
            transmitID: engineCurrentRemoteTransmitID(channelID: channelID, includeDraining: false)
                ?? engineBackendActiveTransmitID(for: contactID)
                ?? EngineTransmitID("remote-\(channelID)-\(senderDeviceID)-\(engine.state.tick + 1)"),
            senderDeviceID: EngineDeviceID(senderDeviceID)
        )
    }

    private func engineBackendActiveTransmitID(for contactID: UUID) -> EngineTransmitID? {
        guard let activeTransmitID = selectedChannelSnapshot(for: contactID)?.activeTransmitId,
              !activeTransmitID.isEmpty else {
            return nil
        }
        return EngineTransmitID(activeTransmitID)
    }

    private func engineCurrentRemoteTransmitID(
        channelID: String,
        includeDraining: Bool
    ) -> EngineTransmitID? {
        switch engine.snapshot.receive {
        case .prepared(let prepare) where prepare.channelID.rawValue == channelID:
            return prepare.transmitID
        case .awaitingPTTActivation(let buffered) where buffered.prepare.channelID.rawValue == channelID:
            return buffered.prepare.transmitID
        case .receiving(let epoch) where epoch.prepare.channelID.rawValue == channelID:
            return epoch.prepare.transmitID
        case .draining(let drain) where includeDraining && drain.epoch.prepare.channelID.rawValue == channelID:
            return drain.epoch.prepare.transmitID
        case .idle, .prepared, .awaitingPTTActivation, .receiving, .draining, .failed:
            return nil
        }
    }

    private func engineAudioChunkID(
        transmitID: EngineTransmitID,
        sequence: Int,
        digest: String
    ) -> EngineAudioChunkID {
        EngineAudioChunkID("\(transmitID.rawValue):\(sequence):\(digest)")
    }

    private func engineAudioSequence(_ sequenceNumber: UInt64) -> Int {
        let max = UInt64(Int.max)
        return Int(sequenceNumber > max ? sequenceNumber % max : sequenceNumber)
    }

    private func handleEngineTransition(
        _ transition: TurboEngineTransition,
        input: EngineTraceInput,
        previousState: TurboEngineState,
        source: String
    ) {
        engineTraceRecorder.record(
            input: input,
            source: source,
            previousState: previousState,
            transition: transition
        )

        if shouldRecordEngineTransition(input: input, transition: transition) {
            diagnostics.recordReducerTransition(
                ReducerTransitionReport.make(
                    reducerName: "TurboEngine",
                    event: input,
                    previousState: previousState,
                    nextState: transition.state,
                    effects: transition.effects,
                    invariantViolationsEmitted: transition.invariantViolations.map(\.invariantID),
                    correlationIDs: ["source": source]
                )
            )
        }

        for diagnostic in transition.diagnostics {
            guard shouldRecordEngineDiagnostic(input: input, diagnostic: diagnostic) else {
                continue
            }
            diagnostics.record(
                .state,
                level: .info,
                message: diagnostic.message,
                metadata: diagnostic.metadata.merging(["source": source]) { current, _ in current }
            )
        }

        for violation in transition.invariantViolations {
            recordEngineInvariantViolation(violation, source: source)
        }

        for effect in transition.effects {
            handleEngineEffect(effect, source: source)
        }
    }

    private func handleEngineEffect(_ effect: TurboEngineEffect, source: String) {
        switch effect {
        case .diagnostics(.record(let diagnostic)):
            diagnostics.record(
                .state,
                message: diagnostic.message,
                metadata: diagnostic.metadata.merging(["source": source]) { current, _ in current }
            )
        case .diagnostics(.invariant(let violation)):
            recordEngineInvariantViolation(violation, source: source)
        case .backend, .ptt, .media, .transport:
            guard !shouldSuppressUnexecutedEngineEffectDiagnostic(effect) else { return }
            diagnostics.record(
                .state,
                level: .debug,
                message: "TurboEngine emitted effect without app executor",
                metadata: [
                    "source": source,
                    "effect": String(describing: effect),
                ]
            )
        }
    }

    private func shouldRecordEngineDiagnostic(
        input: EngineTraceInput,
        diagnostic: EngineDiagnostic
    ) -> Bool {
        guard case .event(.media(.remoteAudioReceived)) = input,
              diagnostic.message == "Buffered media frame in jitter buffer" else {
            return true
        }
        return false
    }

    private func shouldRecordEngineTransition(
        input: EngineTraceInput,
        transition: TurboEngineTransition
    ) -> Bool {
        guard transition.invariantViolations.isEmpty else { return true }
        guard case .event(let engineEvent) = input else { return true }
        switch engineEvent {
        case .media(.localAudioCaptured), .media(.remoteAudioReceived):
            return false
        case .backend, .ptt, .media, .transport, .lifecycle, .clock:
            return true
        }
    }

    private func shouldSuppressUnexecutedEngineEffectDiagnostic(_ effect: TurboEngineEffect) -> Bool {
        switch effect {
        case .backend(.sendAudio),
             .media(.schedulePlayback),
             .media(.dropChunk):
            return true
        case .backend, .ptt, .media, .transport, .diagnostics:
            return false
        }
    }

    private func recordEngineInvariantViolation(
        _ violation: EngineInvariantViolation,
        source: String
    ) {
        diagnostics.recordContractViolation(
            DiagnosticsContracts.Engine.transitionViolation(
                invariantID: violation.invariantID,
                kind: diagnosticsContractKind(for: violation.kind),
                message: violation.message,
                source: source,
                metadata: violation.metadata
            )
        )
    }

    private func diagnosticsContractKind(for kind: EngineContractKind) -> DiagnosticsContractKind {
        switch kind {
        case .precondition:
            return .precondition
        case .postcondition:
            return .postcondition
        case .invariant:
            return .invariant
        case .liveness:
            return .liveness
        }
    }
}
