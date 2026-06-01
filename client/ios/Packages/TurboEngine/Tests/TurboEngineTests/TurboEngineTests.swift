import Foundation
import Testing
import TurboEngine
import TurboEngineSimulation

@Suite("TurboEngine algebraic core")
struct TurboEngineCoreTests {
    @Test func appProjectionIsDerivedFromAlgebraicState() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .fastRelay))))

        let projection = EngineAppSnapshotProjector.derive(from: engine.snapshot)

        #expect(projection.isReady)
        #expect(projection.isJoined)
        #expect(!projection.isTransmitting)
        #expect(projection.canTransmitNow)
        #expect(projection.statusMessage == "Ready")
    }

    @Test func beginTalkRequiresJoinedReadyConversationEvidence() {
        var engine = TurboEngine(localDeviceID: "sender-device")

        let transition = engine.send(.beginTalk)

        #expect(transition.invariantViolations.map(\.invariantID).contains("engine.transmit_requires_joined_conversation"))
        if case .failed(let failure) = transition.state.transmit {
            #expect(failure.reason == .noJoinedConversation)
        } else {
            Issue.record("expected failed transmit phase")
        }
    }

    @Test func engineTraceReplaysDeterministically() throws {
        var engine = TurboEngine(localDeviceID: "sender-device")
        var recorder = TurboEngineTraceRecorder(localDeviceID: "sender-device")

        let joinInput = EngineTraceInput.event(.backend(.joined(joinedEvidence(transport: .fastRelay))))
        let beforeJoinState = engine.state
        let join = engine.replay(joinInput)
        recorder.record(
            input: joinInput,
            source: "test-join",
            previousState: beforeJoinState,
            transition: join
        )

        let beginInput = EngineTraceInput.intent(.beginTalk)
        let beforeBeginState = engine.state
        let begin = engine.replay(beginInput)
        recorder.record(
            input: beginInput,
            source: "test-begin",
            previousState: beforeBeginState,
            transition: begin
        )

        let acceptedInput = EngineTraceInput.event(.backend(.beginTransmitAccepted("tx-trace")))
        let beforeAcceptedState = engine.state
        let accepted = engine.replay(acceptedInput)
        recorder.record(
            input: acceptedInput,
            source: "test-accepted",
            previousState: beforeAcceptedState,
            transition: accepted
        )

        let systemBeganInput = EngineTraceInput.event(.ptt(.systemTransmitBegan("system-channel-a-b")))
        let beforeSystemBeganState = engine.state
        let systemBegan = engine.replay(systemBeganInput)
        recorder.record(
            input: systemBeganInput,
            source: "test-system-began",
            previousState: beforeSystemBeganState,
            transition: systemBegan
        )

        let data = try JSONEncoder().encode(recorder.trace)
        let decoded = try JSONDecoder().decode(EngineTrace.self, from: data)
        let report = EngineTraceReplayer.replay(decoded)

        #expect(report.passed)
        #expect(report.stepCount == 4)
        #expect(report.mismatches.isEmpty)
        #expect(report.finalSnapshot.transmit.activeEpoch?.transmitID == "tx-trace")
    }

    @Test func enginePreconditionInvariantsHaveFocusedProofs() {
        var accept = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            accept.send(.acceptConnection("blake")),
            "engine.accept_requires_beep"
        )

        var request = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            request.send(.requestConnection("blake")),
            "engine.connection_request_requires_selected_friend"
        )

        var disconnect = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            disconnect.send(.disconnect("blake")),
            "engine.disconnect_requires_joined_conversation"
        )

        var readyFriend = TurboEngine(localDeviceID: "sender-device")
        _ = readyFriend.receive(
            .backend(
                .joined(
                    joinedEvidence(
                        transport: .fastRelay,
                        readiness: .pending(.waitingForAudio)
                    )
                )
            )
        )
        expectInvariant(readyFriend.send(.beginTalk), "engine.transmit_requires_receiver_readiness")

        var beginAck = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            beginAck.receive(.backend(.beginTransmitAccepted("tx-unexpected"))),
            "engine.transmit_begin_ack_requires_beginning_phase"
        )

        var stopAck = activeEngine(transmitID: "tx-active")
        expectInvariant(
            stopAck.receive(.backend(.stopTransmitAccepted("tx-active"))),
            "engine.transmit_stop_ack_requires_stopping_phase"
        )

        var remoteStop = TurboEngine(localDeviceID: "receiver-device")
        expectInvariant(
            remoteStop.receive(.backend(.remoteTransmitStopped("tx-missing"))),
            "engine.remote_stop_requires_matching_receive_epoch"
        )

        var localObserved = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            localObserved.receive(.backend(.localTransmitObserved("tx-observed"))),
            "engine.local_transmit_observation_requires_joined_conversation"
        )

        var addressability = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            addressability.receive(.backend(.receiverAddressabilityChanged(.unavailable(.membershipLost)))),
            "engine.receiver_addressability_requires_joined_conversation"
        )

        var clear = activeEngine(transmitID: "tx-current")
        expectInvariant(
            clear.receive(.backend(.activeTransmitCleared("tx-other", .backendLeaseExpired))),
            "engine.active_transmit_clear_requires_matching_epoch"
        )

        var systemBegin = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            systemBegin.receive(.ptt(.systemTransmitBegan("tx-system"))),
            "engine.system_transmit_begin_requires_joined_conversation"
        )

        var systemConflict = activeEngine(transmitID: "tx-current")
        expectInvariant(
            systemConflict.receive(.ptt(.systemTransmitBegan("tx-other"))),
            "engine.system_transmit_begin_conflicts_with_active_epoch"
        )
    }

    @Test func engineLivenessAndPostconditionInvariantsHaveFocusedProofs() {
        var firstAudio = TurboEngine(localDeviceID: "receiver-device")
        expectInvariant(
            firstAudio.receive(.clock(.deadlineElapsed(.firstAudio("tx-missing-audio")))),
            "engine.first_audio_deadline_elapsed"
        )

        var pttDeadline = TurboEngine(localDeviceID: "receiver-device")
        _ = pttDeadline.receive(
            .ptt(.audioActivationStarted(PTTActivationAttempt(channelID: "channel-a-b", reason: .incomingPush)))
        )
        expectInvariant(
            pttDeadline.receive(.clock(.deadlineElapsed(.pttActivation("channel-a-b")))),
            "engine.ptt_activation_deadline_elapsed"
        )

        var pttFailed = TurboEngine(localDeviceID: "receiver-device")
        expectInvariant(
            pttFailed.receive(
                .ptt(
                    .audioActivationFailed(
                        PTTActivationFailure(channelID: "channel-a-b", reason: .systemRejected("denied"))
                    )
                )
            ),
            "engine.ptt_activation_failed"
        )

        var systemFailed = TurboEngine(localDeviceID: "sender-device")
        expectInvariant(
            systemFailed.receive(.ptt(.systemTransmitBeginFailed(.systemRejected("denied")))),
            "engine.system_transmit_begin_failed"
        )

        let chunk = EngineAudioChunk(
            id: "chunk-playback-failed",
            transmitID: "tx-playback",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )
        var playbackFailed = TurboEngine(localDeviceID: "receiver-device")
        expectInvariant(
            playbackFailed.receive(.media(.playbackFailed(chunk, "decode failed"))),
            "engine.playback_failed"
        )

        var duplicateSchedule = TurboEngine(localDeviceID: "receiver-device")
        _ = duplicateSchedule.receive(.backend(.joined(joinedForReceiver(transport: .fastRelay))))
        _ = duplicateSchedule.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-dup-schedule"))))
        let accepted = EngineAudioChunk(
            id: "chunk-dup-schedule",
            transmitID: "tx-dup-schedule",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )
        _ = duplicateSchedule.receive(.media(.remoteAudioReceived(accepted)))
        expectInvariant(
            duplicateSchedule.receive(.media(.playbackScheduled(accepted))),
            "engine.playback_schedule_has_no_duplicate_chunks"
        )

        var activeChannel = TurboEngine(localDeviceID: "sender-device")
        _ = activeChannel.receive(.backend(.joined(joinedEvidence(transport: .fastRelay, channelID: ""))))
        _ = activeChannel.send(.beginTalk)
        _ = activeChannel.receive(.ptt(.systemTransmitBegan("system-empty-channel")))
        expectInvariant(
            activeChannel.receive(.backend(.beginTransmitAccepted("tx-empty-channel"))),
            "engine.active_transmit_requires_channel"
        )
    }

    @Test func beginTalkRequiresAddressableReceiverEvidence() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(
            .backend(
                .joined(
                    joinedEvidence(
                        transport: .fastRelay,
                        peerDevice: .pending(.waitingForPeerDevice),
                        receiverAddressability: .unavailable(.wakeTokenRevoked)
                    )
                )
            )
        )

        let transition = engine.send(.beginTalk)

        #expect(transition.invariantViolations.map(\.invariantID).contains("engine.transmit_requires_addressable_receiver"))
        if case .failed(let failure) = transition.state.transmit {
            #expect(failure.reason == .receiverNotAddressable(.wakeTokenRevoked))
        } else {
            Issue.record("expected failed transmit phase")
        }
        #expect(transition.snapshot.localTalkCapability == .blocked(.receiverNotAddressable(.wakeTokenRevoked)))
    }

    @Test func activeTransmitCannotSurviveReceiverAddressabilityLoss() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .fastRelay))))
        _ = engine.send(.beginTalk)
        _ = engine.receive(.backend(.beginTransmitAccepted("tx-active")))
        _ = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))

        let lost = engine.receive(.backend(.receiverAddressabilityChanged(.unavailable(.membershipLost))))

        if case .stopping(let stop) = lost.state.transmit {
            #expect(stop.reason == .receiverUnaddressable(.membershipLost))
            #expect(stop.epoch.transmitID == "tx-active")
        } else {
            Issue.record("expected transmit to move to stopping")
        }
        #expect(
            lost.state.transmit.activeEpoch == nil,
            "engine.active_transmit_requires_addressable_receiver"
        )
        #expect(lost.effects.contains(.backend(.endTransmit("channel-a-b", "tx-active"))))

        let cleared = engine.receive(
            .backend(.activeTransmitCleared("tx-active", .receiverBecameUnaddressable(.membershipLost)))
        )

        #expect(cleared.state.transmit == .idle)
        #expect(cleared.invariantViolations.isEmpty)
    }

    @Test func localAudioRequiresMatchingActiveTransmitEpoch() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        let chunk = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-missing",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )

        let transition = engine.receive(.media(.localAudioCaptured(chunk)))

        #expect(transition.invariantViolations.map(\.invariantID).contains("engine.local_audio_requires_active_transmit_epoch"))
    }

    @Test func systemTransmitBeforeBackendLeaseActivatesWithBackendTransmitID() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.send(.beginTalk)

        let systemBegan = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))

        #expect(systemBegan.invariantViolations.isEmpty)
        #expect(!systemBegan.effects.contains { effect in
            if case .media(.startCapture) = effect { return true }
            return false
        })
        if case .beginning(let attempt) = systemBegan.state.transmit {
            #expect(attempt.systemTransmitID == "system-channel-a-b")
        } else {
            Issue.record("expected transmit to remain beginning until backend lease arrives")
        }

        let accepted = engine.receive(.backend(.beginTransmitAccepted("tx-backend")))

        #expect(accepted.invariantViolations.isEmpty)
        #expect(accepted.state.transmit.activeEpoch?.transmitID == "tx-backend")
        #expect(accepted.effects.contains { effect in
            if case .media(.startCapture(let epoch)) = effect {
                return epoch.transmitID == "tx-backend"
            }
            return false
        })

        let audio = engine.receive(
            .media(
                .localAudioCaptured(
                    EngineAudioChunk(
                        id: "chunk-1",
                        transmitID: "tx-backend",
                        sequence: EngineAudioSequence(0),
                        fromDeviceID: "sender-device",
                        toDeviceID: "receiver-device",
                        transport: .directQuic,
                        payloadDigest: "digest"
                    )
                )
            )
        )
        #expect(!audio.invariantViolations.map(\.invariantID).contains("engine.local_audio_requires_active_transmit_epoch"))
    }

    @Test func backendLeaseBeforeSystemTransmitDoesNotStartCapture() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.send(.beginTalk)

        let accepted = engine.receive(.backend(.beginTransmitAccepted("tx-backend")))

        #expect(accepted.invariantViolations.isEmpty)
        #expect(accepted.state.transmit.activeEpoch == nil)
        #expect(!accepted.effects.contains { effect in
            if case .media(.startCapture) = effect { return true }
            return false
        })
        if case .beginning(let attempt) = accepted.state.transmit {
            #expect(attempt.backendTransmitID == "tx-backend")
            #expect(attempt.systemTransmitID == nil)
        } else {
            Issue.record("expected transmit to remain beginning until system transmit begins")
        }

        let systemBegan = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))

        #expect(systemBegan.invariantViolations.isEmpty)
        #expect(systemBegan.state.transmit.activeEpoch?.transmitID == "tx-backend")
        #expect(systemBegan.effects.contains { effect in
            if case .media(.startCapture(let epoch)) = effect {
                return epoch.transmitID == "tx-backend"
            }
            return false
        })
    }

    @Test func backendLocalTransmitObservationBeforeSystemTransmitDoesNotStartCapture() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.send(.beginTalk)

        let observed = engine.receive(.backend(.localTransmitObserved("tx-backend")))

        #expect(observed.invariantViolations.isEmpty)
        #expect(observed.state.transmit.activeEpoch == nil)
        #expect(!observed.effects.contains { effect in
            if case .media(.startCapture) = effect { return true }
            return false
        })
        if case .beginning(let attempt) = observed.state.transmit {
            #expect(attempt.backendTransmitID == "tx-backend")
            #expect(attempt.systemTransmitID == nil)
        } else {
            Issue.record("expected transmit to remain beginning until system transmit begins")
        }
    }

    @Test func backendLocalTransmitObservationAfterSystemTransmitStartsCaptureWithBackendTransmitID() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.send(.beginTalk)
        _ = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))

        let observed = engine.receive(.backend(.localTransmitObserved("tx-backend")))

        #expect(observed.invariantViolations.isEmpty)
        #expect(observed.state.transmit.activeEpoch?.transmitID == "tx-backend")
        #expect(observed.effects.contains { effect in
            if case .media(.startCapture(let epoch)) = effect {
                return epoch.transmitID == "tx-backend"
            }
            return false
        })
    }

    @Test func remoteAudioCannotScheduleBeforeReceiveEpoch() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        let chunk = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-1",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )

        let transition = engine.receive(.media(.remoteAudioReceived(chunk)))

        #expect(transition.state.scheduledPlayback.isEmpty)
        #expect(transition.invariantViolations.map(\.invariantID).contains("engine.remote_audio_requires_receive_epoch"))
    }

    @Test func duplicateChunksDoNotDuplicatePlaybackSchedule() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .fastRelay))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-dup"))))
        let chunk = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-dup",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )

        _ = engine.receive(.media(.remoteAudioReceived(chunk)))
        let duplicate = engine.receive(.media(.remoteAudioReceived(chunk)))

        #expect(duplicate.state.scheduledPlayback.count == 1)
        #expect(duplicate.effects.contains(.media(.dropChunk(chunk, .duplicate))))
    }

    @Test func unorderedPacketMediaBuffersReorderAndSkipsMissingOnDeadline() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .directQuic))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-packet"))))
        let capability = EngineMediaTransportCapability.unorderedPacketMedia(
            UnorderedPacketMediaEvidence(path: .directQuic, reason: .directQuicDatagram)
        )
        let chunks = (0 ..< 4).map { index in
            EngineAudioChunk(
                id: EngineAudioChunkID("chunk-\(index)"),
                transmitID: "tx-packet",
                sequence: EngineAudioSequence(index),
                fromDeviceID: "sender-device",
                toDeviceID: "receiver-device",
                transport: .directQuic,
                payloadDigest: EnginePayloadDigest("digest-\(index)"),
                mediaCapability: capability,
                receivedAtTick: UInt64(index * 20),
                durationTicks: 20
            )
        }

        _ = engine.receive(.media(.remoteAudioReceived(chunks[3])))
        _ = engine.receive(.media(.remoteAudioReceived(chunks[1])))
        _ = engine.receive(.media(.remoteAudioReceived(chunks[0])))
        let deadline = engine.receive(.media(.playoutDeadlineElapsed("tx-packet", EngineAudioSequence(2))))

        #expect(deadline.state.scheduledPlayback.map(\.sequence.rawValue) == [0, 1, 3])
    }

    @Test func unorderedPacketMediaSkipsMissingInsteadOfDroppingOnQueueOverflow() throws {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .directQuic))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-packet-overflow"))))
        let capability = EngineMediaTransportCapability.unorderedPacketMedia(
            UnorderedPacketMediaEvidence(path: .directQuic, reason: .directQuicDatagram)
        )
        var lastTransition: TurboEngineTransition?

        for index in 1 ... 65 {
            let chunk = EngineAudioChunk(
                id: EngineAudioChunkID("chunk-\(index)"),
                transmitID: "tx-packet-overflow",
                sequence: EngineAudioSequence(index),
                fromDeviceID: "sender-device",
                toDeviceID: "receiver-device",
                transport: .directQuic,
                payloadDigest: EnginePayloadDigest("digest-\(index)"),
                mediaCapability: capability,
                receivedAtTick: UInt64(index * 20),
                durationTicks: 20
            )
            lastTransition = engine.receive(.media(.remoteAudioReceived(chunk)))
        }

        let transition = try #require(lastTransition)
        #expect(!transition.effects.contains {
            if case .media(.dropChunk(_, .jitterQueueOverflow)) = $0 {
                return true
            }
            return false
        })
        #expect(transition.state.scheduledPlayback.map(\.sequence.rawValue) == Array(1 ... 65))
        #expect(transition.diagnostics.contains {
            $0.message == "Skipped missing media frame after jitter deadline"
                && $0.metadata["sequence"] == "0"
        })
    }

    @Test func orderedFastRelayMediaDropsLateBurstCatchupFrames() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .fastRelay))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-backlog"))))
        let capability = EngineMediaTransportCapability.orderedReliableMedia(
            OrderedReliableMediaEvidence(path: .fastRelay, reason: .fastRelayTcpFallback)
        )
        let first = EngineAudioChunk(
            id: "chunk-0",
            transmitID: "tx-backlog",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest-0",
            mediaCapability: capability,
            receivedAtTick: 0,
            durationTicks: 20
        )
        let late = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-backlog",
            sequence: EngineAudioSequence(1),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest-1",
            mediaCapability: capability,
            receivedAtTick: 1_000,
            durationTicks: 20
        )

        _ = engine.receive(.media(.remoteAudioReceived(first)))
        let transition = engine.receive(.media(.remoteAudioReceived(late)))

        #expect(transition.state.scheduledPlayback == [first])
        #expect(transition.effects.contains(.media(.dropChunk(late, .orderedBacklog))))
    }

    @Test func relayWebSocketFallbackKeepsSlowSequentialOrderedFrames() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .relayWebSocket))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-websocket-slow"))))
        let capability = EngineMediaTransportCapability.orderedReliableMedia(
            OrderedReliableMediaEvidence(path: .relayWebSocket, reason: .webSocketFallback)
        )
        let first = EngineAudioChunk(
            id: "chunk-0",
            transmitID: "tx-websocket-slow",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .relayWebSocket,
            payloadDigest: "digest-0",
            mediaCapability: capability,
            receivedAtTick: 0,
            durationTicks: 20
        )
        let delayedSecond = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-websocket-slow",
            sequence: EngineAudioSequence(1),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .relayWebSocket,
            payloadDigest: "digest-1",
            mediaCapability: capability,
            receivedAtTick: 1_000,
            durationTicks: 20
        )

        _ = engine.receive(.media(.remoteAudioReceived(first)))
        let transition = engine.receive(.media(.remoteAudioReceived(delayedSecond)))

        #expect(transition.state.scheduledPlayback == [first, delayedSecond])
        #expect(!transition.effects.contains(.media(.dropChunk(delayedSecond, .orderedBacklog))))
    }

    @Test func directActiveNetworkMigrationPreservesDirectAndPrewarmsFastRelay() {
        var engine = activeEngine(transmitID: "tx-migrate", transport: .directQuic)
        _ = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .fastRelayQuic, networkPathGeneration: 0)
                )
            )
        )

        let transition = engine.receive(.transport(.networkChanged(.cellular)))

        #expect(transition.state.transportSelection.networkPathGeneration == 1)
        #expect(transition.state.transportSelection.currentLane == .directQuic)
        #expect(transition.state.transportSelection.fallbackLane == .fastRelayQuic)
        #expect(transition.state.transportSelection.upgradeTarget == nil)
        #expect(transition.state.transport.currentPath == .directQuic)
        #expect(transition.effects.contains(.transport(.prewarm(.fastRelay))))

        let failed = engine.receive(
            .transport(
                .laneFailed(
                    TransportLaneFailure(
                        lane: .directQuic,
                        reason: .networkChanged(.cellular),
                        networkPathGeneration: 1
                    )
                )
            )
        )

        #expect(failed.state.transportSelection.currentLane == .fastRelayQuic)
        #expect(failed.state.transport.currentPath == .fastRelay)
    }

    @Test func fastRelayQuicNetworkMigrationPreservesCurrentLane() {
        var engine = activeEngine(transmitID: "tx-fast-relay", transport: .fastRelay)

        let transition = engine.receive(.transport(.networkChanged(.cellular)))

        #expect(transition.state.transportSelection.networkPathGeneration == 1)
        #expect(transition.state.transportSelection.currentLane == .fastRelayQuic)
        #expect(transition.state.transport.currentPath == .fastRelay)
        #expect(!transition.effects.contains(.transport(.fallBack(to: .relayWebSocket, reason: .networkChanged(.cellular)))))
    }

    @Test func fastRelayQuicFailureDowngradesToTcpThenWebSocket() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .fastRelay))))
        _ = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .fastRelayTcp, networkPathGeneration: 0)
                )
            )
        )

        let quicFailed = engine.receive(
            .transport(
                .laneFailed(
                    TransportLaneFailure(
                        lane: .fastRelayQuic,
                        reason: .quicBlocked,
                        networkPathGeneration: 0
                    )
                )
            )
        )
        let tcpFailed = engine.receive(
            .transport(
                .laneFailed(
                    TransportLaneFailure(
                        lane: .fastRelayTcp,
                        reason: .relayUnavailable,
                        networkPathGeneration: 0
                    )
                )
            )
        )

        #expect(quicFailed.state.transportSelection.currentLane == .fastRelayTcp)
        #expect(quicFailed.state.transport.currentPath == .fastRelay)
        #expect(tcpFailed.state.transportSelection.currentLane == .webSocketTcp)
        #expect(tcpFailed.state.transport.currentPath == .relayWebSocket)
    }

    @Test func idleNetworkMigrationStartsTransmitOnBestViableLane() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.receive(.transport(.networkChanged(.cellular)))
        _ = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .fastRelayQuic, networkPathGeneration: 1)
                )
            )
        )

        let begin = engine.send(.beginTalk)

        #expect(begin.snapshot.transportSelection.currentLane == .fastRelayQuic)
        if case .available(let evidence) = begin.snapshot.localTalkCapability {
            #expect(evidence.transport == .fastRelay)
        } else {
            Issue.record("expected transmit to be available on fast relay")
        }
    }

    @Test func staleDirectAvailabilityFromOldNetworkGenerationIsIgnored() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .fastRelayQuic, networkPathGeneration: 0)
                )
            )
        )
        _ = engine.receive(.transport(.networkChanged(.cellular)))

        let stale = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .directQuic, networkPathGeneration: 0)
                )
            )
        )
        let fresh = engine.receive(
            .transport(
                .laneAvailable(
                    TransportLaneAvailability(lane: .directQuic, networkPathGeneration: 1)
                )
            )
        )

        #expect(stale.state.transportSelection.currentLane == .fastRelayQuic)
        #expect(stale.diagnostics.contains { $0.message == "Ignored stale transport lane availability" })
        #expect(fresh.state.transportSelection.currentLane == .directQuic)
    }

    @Test func audioAfterRemoteStopIsRejected() {
        var engine = TurboEngine(localDeviceID: "receiver-device")
        _ = engine.receive(.backend(.joined(joinedForReceiver(transport: .fastRelay))))
        _ = engine.receive(.backend(.remoteTransmitStarted(remotePrepare(transmitID: "tx-stop"))))
        let chunk = EngineAudioChunk(
            id: "chunk-1",
            transmitID: "tx-stop",
            sequence: EngineAudioSequence(0),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest"
        )
        _ = engine.receive(.media(.remoteAudioReceived(chunk)))
        _ = engine.receive(.backend(.remoteTransmitStopped("tx-stop")))

        let late = EngineAudioChunk(
            id: "chunk-2",
            transmitID: "tx-stop",
            sequence: EngineAudioSequence(1),
            fromDeviceID: "sender-device",
            toDeviceID: "receiver-device",
            transport: .fastRelay,
            payloadDigest: "digest-2"
        )
        let transition = engine.receive(.media(.remoteAudioReceived(late)))

        #expect(transition.state.scheduledPlayback.count == 1)
        #expect(transition.invariantViolations.map(\.invariantID).contains("engine.no_playback_after_transmit_stop"))
    }

    @Test func staleStopCannotClearNewerActiveTransmit() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .fastRelay))))
        _ = engine.send(.beginTalk)
        _ = engine.receive(.backend(.beginTransmitAccepted("tx-current")))
        _ = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))
        _ = engine.send(.endTalk)

        let transition = engine.receive(.backend(.stopTransmitAccepted("tx-stale")))

        #expect(transition.invariantViolations.map(\.invariantID).contains("transmit.stale_end_overrides_newer_epoch"))
        if case .stopping(let stop) = transition.state.transmit {
            #expect(stop.epoch.transmitID == "tx-current")
        } else {
            Issue.record("expected current transmit to remain in stopping phase")
        }
    }

    @Test func backendRefreshPreservesBeginningTransmitEvidenceBeforeLeaseAck() {
        var engine = TurboEngine(localDeviceID: "sender-device")
        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        _ = engine.send(.beginTalk)
        _ = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))

        _ = engine.receive(.backend(.joined(joinedEvidence(transport: .directQuic))))
        let accepted = engine.receive(.backend(.beginTransmitAccepted("tx-current")))

        if case .active(let epoch) = accepted.state.transmit {
            #expect(epoch.transmitID == "tx-current")
        } else {
            Issue.record("expected backend lease ack to activate transmit after refreshed beginning evidence")
        }

        let stopping = engine.send(.endTalk)
        if case .stopping(let stop) = stopping.state.transmit {
            #expect(stop.epoch.transmitID == "tx-current")
        } else {
            Issue.record("expected release to stop the active backend transmit")
        }

        let stopped = engine.receive(.backend(.stopTransmitAccepted("tx-current")))
        #expect(stopped.state.transmit == .idle)
    }
}

@Suite("TurboEngine scenarios")
struct TurboEngineScenarioTests {
    @Test(
        "required scenario passes",
        arguments: [
            "foreground_transmit_receive",
            "locked_receiver_delayed_activation",
            "background_audio_buffers_then_activation_drains",
            "active_transmit_network_migration",
            "direct_active_network_migration_fast_relay_reprobe",
            "fast_relay_quic_network_migration_preserves",
            "fast_relay_quic_failure_tcp_then_websocket",
            "wake_token_revocation_clears_active_transmit",
            "active_transmit_membership_loss_clears_transmit",
            "idle_network_migration_then_transmit",
            "stale_direct_generation_ignored",
            "quic_unavailable_fast_relay_fallback",
            "fast_relay_unavailable_websocket_fallback",
            "direct_quic_send_failure_relay_fallback",
            "duplicate_reordered_chunks",
            "direct_datagram_loss_reorder_duplicate",
            "fast_relay_packet_loss_reorder_duplicate",
            "websocket_ordered_burst_drop",
            "fast_relay_tcp_ordered_burst_drop",
            "stale_stop_behind_newer_start",
            "incoming_audio_buffers_then_drains",
        ]
    )
    func requiredScenarioPasses(name: String) async throws {
        let report = try await EngineScenarioRunner().run(name: name)

        #expect(report.passed, "scenario \(name) failed with invariants \(report.invariantIDs)")
    }

    @Test func fuzzReportsAreReplayableArtifacts() async throws {
        let runner = EngineScenarioRunner()
        let reports = try await runner.fuzz(seed: 12345, count: 20)

        #expect(reports.count == 20)
        #expect(!reports.contains { !$0.passed })
        #expect(reports.allSatisfy { $0.name.hasPrefix("fuzz_case:12345:") })
        #expect(reports.contains { report in
            report.notes.contains("activeNetworkMigration=true")
                && report.notes.contains { $0.hasPrefix("networkFaults=") && $0 != "networkFaults=none" }
        })

        let replay = try await runner.run(name: reports[0].name)
        #expect(replay == reports[0])
    }

    @Test func foregroundScenarioExecutesBackendEffectsThroughInMemoryPort() async throws {
        let backend = InMemoryEngineBackendPort()

        let report = try await EngineScenarioRunner().run(
            name: "foreground_transmit_receive",
            backend: backend
        )
        let signals = await backend.sentSignals()

        #expect(report.passed)
        #expect(signals.count == 10)
        #expect(signals.allSatisfy { $0.type == .audioChunk })
    }
}

private func joinedEvidence(
    transport: EngineTransportPath,
    channelID: EngineChannelID = "channel-a-b",
    peerDevice: EngineReadiness<PeerDeviceEvidence> = .ready(PeerDeviceEvidence(deviceID: "receiver-device")),
    receiverAddressability: ReceiverAddressability? = nil,
    readiness: EngineReadiness<JoinedReadinessEvidence>? = nil
) -> JoinedConversationEvidence {
    let membership = BackendMembershipEvidence(
        channelID: channelID,
        localDeviceID: "sender-device",
        peerDeviceID: "receiver-device",
        observedAtTick: 1
    )
    let resolvedReadiness = readiness ?? .ready(
        JoinedReadinessEvidence(backendMembershipObserved: membership, transport: transport)
    )
    return JoinedConversationEvidence(
        friend: SelectedFriendEvidence(contactID: "blake", handle: "@blake"),
        channelID: channelID,
        localDeviceID: "sender-device",
        peerDevice: peerDevice,
        receiverAddressability: receiverAddressability,
        readiness: resolvedReadiness
    )
}

private func joinedForReceiver(transport: EngineTransportPath) -> JoinedConversationEvidence {
    let membership = BackendMembershipEvidence(
        channelID: "channel-a-b",
        localDeviceID: "receiver-device",
        peerDeviceID: "sender-device",
        observedAtTick: 1
    )
    return JoinedConversationEvidence(
        friend: SelectedFriendEvidence(contactID: "avery", handle: "@avery"),
        channelID: "channel-a-b",
        localDeviceID: "receiver-device",
        peerDevice: .ready(PeerDeviceEvidence(deviceID: "sender-device")),
        readiness: .ready(JoinedReadinessEvidence(backendMembershipObserved: membership, transport: transport))
    )
}

private func remotePrepare(transmitID: EngineTransmitID) -> RemoteTransmitPrepareEvidence {
    RemoteTransmitPrepareEvidence(
        channelID: "channel-a-b",
        transmitID: transmitID,
        senderDeviceID: "sender-device"
    )
}

private func activeEngine(
    transmitID: EngineTransmitID,
    transport: EngineTransportPath = .fastRelay
) -> TurboEngine {
    var engine = TurboEngine(localDeviceID: "sender-device")
    _ = engine.receive(.backend(.joined(joinedEvidence(transport: transport))))
    _ = engine.send(.beginTalk)
    _ = engine.receive(.backend(.beginTransmitAccepted(transmitID)))
    _ = engine.receive(.ptt(.systemTransmitBegan("system-channel-a-b")))
    return engine
}

private func expectInvariant(
    _ transition: TurboEngineTransition,
    _ invariantID: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        transition.invariantViolations.map(\.invariantID).contains(invariantID),
        "expected invariant \(invariantID), got \(transition.invariantViolations.map(\.invariantID))",
        sourceLocation: sourceLocation
    )
}
