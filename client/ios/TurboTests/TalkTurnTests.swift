import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
import UserNotifications
import Intents
import CryptoKit
import TurboEngine

@testable import BeepBeep

@MainActor
struct TalkTurnTests {
    private func encodedEncryptedAudioPacket(sequenceNumber: UInt64) throws -> String {
        let packet = MediaEncryptedAudioPacket(
            keyID: "key-1",
            sequenceNumber: sequenceNumber,
            sealedPayloadBase64: "payload"
        )
        return String(data: try JSONEncoder().encode(packet), encoding: .utf8)!
    }

    @Test func backendChannelProjectionFeedsEngineJoinedConversationEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, peerTargetDeviceId: "peer-device")
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, peerTargetDeviceId: "peer-device")
            )
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")

        if case .joined(let joined) = viewModel.engineSnapshot.conversation {
            #expect(joined.channelID.rawValue == "channel-a-b")
            #expect(joined.friend.handle == "@blake")
            if case .ready(let peerDevice) = joined.peerDevice {
                #expect(peerDevice.deviceID.rawValue == "peer-device")
            } else {
                Issue.record("expected ready friend device evidence")
            }
            #expect(joined.receiverAddressability == .foreground(PeerDeviceEvidence(deviceID: "peer-device")))
            if case .ready(let readiness) = joined.readiness {
                #expect(readiness.transport == .relayWebSocket)
            } else {
                Issue.record("expected ready joined Conversation evidence")
            }
        } else {
            Issue.record("expected joined engine Conversation")
        }
    }

    @Test func backendWakeCapabilityFeedsEngineReadyConversationForWakeTransmit() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "wake-peer-device"),
                    peerTargetDeviceId: nil
                )
            )
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineBeginTalkIntent(reason: "test")

        if case .joined(let joined) = viewModel.engineSnapshot.conversation {
            if case .wakeCapable(let evidence) = joined.receiverAddressability {
                #expect(evidence.deviceID.rawValue == "wake-peer-device")
            } else {
                Issue.record("expected wake-capable receiver addressability")
            }
            if case .ready(let readiness) = joined.readiness {
                #expect(readiness.backendMembershipObserved.peerDeviceID.rawValue == "wake-peer-device")
            } else {
                Issue.record("expected wake-capable session to be ready for engine transmit")
            }
        } else {
            Issue.record("expected joined engine Conversation with wake-capable receiver addressability")
        }
        if case .beginning = viewModel.engineSnapshot.transmit {
        } else {
            Issue.record("expected wake-capable transmit to enter beginning phase")
        }
        #expect(
            !viewModel.diagnosticsTranscript.contains("[engine.transmit_requires_receiver_readiness]")
        )
    }

    @Test func systemTransmitEndedAtEngineBoundaryDoesNotEmitIdleStopPrecondition() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "remote-user",
            deviceID: "peer-device",
            channelID: "channel-a-b",
            transmitID: "tx-idle"
        )

        viewModel.syncEngineSystemTransmitEnded(target: target, source: "test")

        #expect(viewModel.engineSnapshot.transmit == .idle)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "[engine.transmit_stop_ack_requires_stopping_phase]"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped engine system transmit end because transmit is not stopping"
            )
        )
    }

    @Test func remoteAudioPayloadFeedsEngineReceiveAndPlaybackSchedule() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, peerTargetDeviceId: "peer-device")
            )
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )
        viewModel.syncEngineRemoteAudioReceived(
            originalPayload: "encrypted-audio-1",
            openedPayload: "pcm-audio-1",
            channelID: "channel-a-b",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket,
            source: "test"
        )

        if case .receiving(let epoch) = viewModel.engineSnapshot.receive {
            #expect(epoch.prepare.channelID.rawValue == "channel-a-b")
            #expect(epoch.prepare.senderDeviceID.rawValue == "peer-device")
            #expect(epoch.acceptedChunkIDs.count == 1)
        } else {
            Issue.record("expected engine receive epoch after remote audio")
        }
        #expect(viewModel.engineSnapshot.scheduledPlaybackCount == 1)
        #expect(
            viewModel.engineTrace.steps.contains {
                $0.source == "remote-audio-received:test"
            }
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Buffered media frame in jitter buffer"
            )
        )
    }

    @Test func remoteStopAndPlaybackDrainClearsEngineReceive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, peerTargetDeviceId: "peer-device")
            )
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )
        viewModel.syncEngineRemoteAudioReceived(
            originalPayload: "encrypted-audio-1",
            openedPayload: "pcm-audio-1",
            channelID: "channel-a-b",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket,
            source: "test"
        )
        viewModel.syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )

        if case .draining(let drain) = viewModel.engineSnapshot.receive {
            #expect(drain.epoch.prepare.channelID.rawValue == "channel-a-b")
            #expect(drain.epoch.prepare.senderDeviceID.rawValue == "peer-device")
        } else {
            Issue.record("expected engine playback drain after remote stop")
        }

        viewModel.syncEngineRemotePlaybackDrained(contactID: contactID, source: "test")

        #expect(viewModel.engineSnapshot.receive == .idle)
    }

    @Test func duplicateRemoteStopAtEngineBoundaryDoesNotUseStaleBackendTransmitID() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    activeTransmitId: "tx-dup"
                )
            )
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )
        viewModel.syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "first-stop"
        )
        viewModel.syncEngineRemoteTransmitStopped(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "duplicate-stop"
        )

        #expect(viewModel.engineSnapshot.receive == .idle)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "[engine.remote_stop_requires_matching_receive_epoch]"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped engine remote transmit stop without active receive epoch"
            )
        )
    }

    @Test func receivePlaybackFailureRecoveryPlanPreservesFailedChunkAndTail() {
        let plan = ReceivePlaybackFailureRecoveryPlan.make(
            decodedChunkCount: 4,
            failedChunkIndex: 1
        )

        #expect(plan?.failedChunkIndex == 1)
        #expect(plan?.recoveryRange == 1..<4)
        #expect(
            ReceivePlaybackFailureRecoveryPlan.make(
                decodedChunkCount: 0,
                failedChunkIndex: 0
            ) == nil
        )
        #expect(
            ReceivePlaybackFailureRecoveryPlan.make(
                decodedChunkCount: 4,
                failedChunkIndex: 4
            ) == nil
        )
    }

    @Test func mediaEndToEndEncryptionRejectsWrongSessionContext() throws {
        let senderPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let receiverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try senderPrivateKey.sharedSecretFromKeyAgreement(with: receiverPrivateKey.publicKey)
        let context = MediaEncryptionContext(
            channelID: "channel-1",
            sessionID: "session-1",
            senderDeviceID: "device-a",
            receiverDeviceID: "device-b"
        )
        let key = MediaEndToEndEncryption.deriveSymmetricKey(from: sharedSecret, context: context)
        let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
            "payload",
            using: key,
            keyID: "key-1",
            sequenceNumber: 1,
            context: context
        )
        let wrongContext = MediaEncryptionContext(
            channelID: "channel-1",
            sessionID: "different-session",
            senderDeviceID: "device-a",
            receiverDeviceID: "device-b"
        )

        #expect(throws: MediaEndToEndEncryptionError.openFailed) {
            try MediaEndToEndEncryption.openTransportPayload(
                encrypted,
                using: key,
                context: wrongContext
            )
        }
    }

    @Test func mediaEndToEndEncryptionRejectsPacketTampering() throws {
        let key = SymmetricKey(size: .bits256)
        let context = MediaEncryptionContext(
            channelID: "channel-1",
            sessionID: "session-1",
            senderDeviceID: "device-a",
            receiverDeviceID: "device-b"
        )
        let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
            "payload",
            using: key,
            keyID: "key-1",
            sequenceNumber: 1,
            context: context
        )
        var packet = try JSONDecoder().decode(
            MediaEncryptedAudioPacket.self,
            from: Data(encrypted.utf8)
        )
        packet = MediaEncryptedAudioPacket(
            keyID: packet.keyID,
            sequenceNumber: packet.sequenceNumber + 1,
            sealedPayloadBase64: packet.sealedPayloadBase64
        )
        let tampered = String(data: try JSONEncoder().encode(packet), encoding: .utf8)!

        #expect(throws: MediaEndToEndEncryptionError.openFailed) {
            try MediaEndToEndEncryption.openTransportPayload(
                tampered,
                using: key,
                context: context
            )
        }
    }

    @MainActor
    @Test func mediaEncryptionSessionSealsOutgoingAndOpensIncomingPayloads() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        let session = try MediaEncryptionSession(
            channelID: "channel-1",
            localDeviceID: "device-a",
            peerDeviceID: "device-b",
            localFingerprint: localRegistration.fingerprint,
            peerFingerprint: peerRegistration.fingerprint,
            localPrivateKey: localPrivateKey,
            peerIdentity: peerRegistration
        )
        viewModel.mediaRuntime.setMediaEncryptionSession(session, for: contactID)
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "device-b",
            channelID: "channel-1"
        )
        let plaintext = Data("pcm-audio".utf8).base64EncodedString()

        let outgoing = try viewModel.sealOutgoingMediaPayloadIfPossible(plaintext, target: target)

        #expect(!outgoing.contains(plaintext))
        let outgoingContext = session.context(senderDeviceID: "device-a", receiverDeviceID: "device-b")
        let peerOpenKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: outgoingContext
        )
        #expect(
            try MediaEndToEndEncryption.openTransportPayload(
                outgoing,
                using: peerOpenKey,
                context: outgoingContext
            ) == plaintext
        )

        let incomingContext = session.context(senderDeviceID: "device-b", receiverDeviceID: "device-a")
        let peerSealKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: incomingContext
        )
        let incoming = try MediaEndToEndEncryption.sealTransportPayload(
            plaintext,
            using: peerSealKey,
            keyID: session.keyID,
            sequenceNumber: 0,
            context: incomingContext
        )

        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                incoming,
                channelID: "channel-1",
                fromDeviceID: "device-b",
                contactID: contactID
            ) == plaintext
        )
    }

    @Test func outgoingMediaPayloadSealerSealsOffMainActorAndPreservesSequence() async throws {
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        let session = try MediaEncryptionSession(
            channelID: "channel-1",
            localDeviceID: "device-a",
            peerDeviceID: "device-b",
            localFingerprint: localRegistration.fingerprint,
            peerFingerprint: peerRegistration.fingerprint,
            localPrivateKey: localPrivateKey,
            peerIdentity: peerRegistration
        )
        let runtime = MediaRuntimeState()
        runtime.setMediaEncryptionSession(session, for: contactID)
        let sealer = OutgoingMediaPayloadSealer(
            session: session,
            sequenceCounter: runtime.mediaEncryptionSendSequenceCounter(for: contactID)
        )

        let sealedPayloads = try await Task.detached {
            try (0..<4).map { index in
                try sealer.seal("pcm-audio-\(index)")
            }
        }.value

        let packets = try sealedPayloads.map(MediaEndToEndEncryption.decodePacket)
        #expect(packets.map(\.sequenceNumber) == [0, 1, 2, 3])
        let outgoingContext = session.context(senderDeviceID: "device-a", receiverDeviceID: "device-b")
        let peerOpenKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: outgoingContext
        )
        #expect(
            try MediaEndToEndEncryption.openTransportPayload(
                sealedPayloads[3],
                using: peerOpenKey,
                context: outgoingContext
            ) == "pcm-audio-3"
        )
    }

    @Test func callAudioEncryptionStatusCopyReflectsCurrentGuarantee() {
        #expect(CallAudioEncryptionStatus.endToEndEncrypted.text == "End-to-end encrypted")
        #expect(CallAudioEncryptionStatus.endToEndEncrypted.accessibilityLabel == "Audio is end-to-end encrypted")
        #expect(CallAudioEncryptionStatus.unavailable.text == "End-to-end encryption unavailable")
        #expect(CallAudioEncryptionStatus.unavailable.accessibilityLabel == "Audio is not end-to-end encrypted")
    }

    @MainActor
    @Test func mediaEndToEndEncryptionActiveRequiresMatchingChannel() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        let session = try MediaEncryptionSession(
            channelID: "channel-1",
            localDeviceID: "device-a",
            peerDeviceID: "device-b",
            localFingerprint: localRegistration.fingerprint,
            peerFingerprint: peerRegistration.fingerprint,
            localPrivateKey: localPrivateKey,
            peerIdentity: peerRegistration
        )
        viewModel.mediaRuntime.setMediaEncryptionSession(session, for: contactID)

        #expect(viewModel.mediaEndToEndEncryptionIsActive(contactID: contactID, channelID: "channel-1"))
        #expect(!viewModel.mediaEndToEndEncryptionIsActive(contactID: contactID, channelID: "channel-2"))
        #expect(viewModel.mediaEndToEndEncryptionIsActive(contactID: contactID, channelID: nil))
    }

    @MainActor
    @Test func duplicateEncryptedAudioPacketIsDroppedWithoutReplayViolation() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        let session = try MediaEncryptionSession(
            channelID: "channel-1",
            localDeviceID: "device-a",
            peerDeviceID: "device-b",
            localFingerprint: localRegistration.fingerprint,
            peerFingerprint: peerRegistration.fingerprint,
            localPrivateKey: localPrivateKey,
            peerIdentity: peerRegistration
        )
        viewModel.mediaRuntime.setMediaEncryptionSession(session, for: contactID)
        let context = session.context(senderDeviceID: "device-b", receiverDeviceID: "device-a")
        let peerSealKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: context
        )
        let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
            "pcm-audio",
            using: peerSealKey,
            keyID: session.keyID,
            sequenceNumber: 0,
            context: context
        )

        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                encrypted,
                channelID: "channel-1",
                fromDeviceID: "device-b",
                contactID: contactID
            ) == "pcm-audio"
        )
        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                encrypted,
                channelID: "channel-1",
                fromDeviceID: "device-b",
                contactID: contactID
            ) == nil
        )
        #expect(viewModel.diagnosticsTranscript.contains("Ignored duplicate encrypted audio packet"))
        #expect(!viewModel.diagnosticsTranscript.contains("media.e2ee_replayed_audio_packet"))
    }

    @MainActor
    @Test func firstAcceptedAudioPayloadSendsOnePlaybackAckAcrossStandbyDuplicates() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "receiver-user",
            mode: "cloud"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)

        await viewModel.handleIncomingAudioPayload(
            "pcm-audio",
            channelID: "channel-1",
            fromUserID: "peer-user",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .directQuic
        )
        await viewModel.handleIncomingAudioPayload(
            "pcm-audio",
            channelID: "channel-1",
            fromUserID: "peer-user",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .mediaRelayPacket
        )
        await viewModel.handleIncomingAudioPayload(
            "pcm-audio",
            channelID: "channel-1",
            fromUserID: "peer-user",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket
        )

        #expect(mediaSession.receivedRemoteAudioChunks == ["pcm-audio"])
        let playbackAcks = client.sentSignalsForTesting().filter { $0.type == .audioPlaybackStarted }
        #expect(playbackAcks.count == 1)
        let envelope = try #require(playbackAcks.first)
        let payload = try envelope.decodeAudioPlaybackStartedPayload()
        #expect(envelope.fromUserId == "receiver-user")
        #expect(envelope.fromDeviceId == client.deviceID)
        #expect(envelope.toUserId == "peer-user")
        #expect(envelope.toDeviceId == "peer-device")
        #expect(payload.channelId == "channel-1")
        #expect(payload.senderDeviceId == "peer-device")
        #expect(payload.receiverDeviceId == client.deviceID)
        #expect(payload.transport == "direct-quic")
        #expect(payload.transportDigest == AudioChunkPayloadCodec.transportDigest("pcm-audio"))
        let diagnosticMessages = viewModel.diagnostics.entries.map(\.message)
        let sentAckIndex = try #require(diagnosticMessages.firstIndex(of: "Sent first audio playback ACK"))
        let ingressSummaryIndex = try #require(diagnosticMessages.firstIndex(of: "Incoming audio ingress summary"))
        #expect(sentAckIndex > ingressSummaryIndex)
    }

    @MainActor
    @Test func firstAudioPlaybackAckSuppressesDuplicateEncryptedReceiveSequenceAfterSentLatchCleared() async throws {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "receiver-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let channelID = "channel-1"
        let senderDeviceID = "sender-device"

        await viewModel.sendFirstAudioPlaybackStartedAckIfNeeded(
            originalPayload: try encodedEncryptedAudioPacket(sequenceNumber: 0),
            channelID: channelID,
            fromUserID: "sender-user",
            fromDeviceID: senderDeviceID,
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket
        )

        #expect(client.sentSignalsForTesting().filter { $0.type == .audioPlaybackStarted }.count == 1)

        viewModel.clearFirstAudioPlaybackAckSentState(
            contactID: contactID,
            channelID: channelID,
            senderDeviceID: senderDeviceID
        )

        await viewModel.sendFirstAudioPlaybackStartedAckIfNeeded(
            originalPayload: try encodedEncryptedAudioPacket(sequenceNumber: 12),
            channelID: channelID,
            fromUserID: "sender-user",
            fromDeviceID: senderDeviceID,
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket
        )

        #expect(client.sentSignalsForTesting().filter { $0.type == .audioPlaybackStarted }.count == 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Suppressed duplicate first audio playback ACK for encrypted receive epoch"
            )
        )

        await viewModel.sendFirstAudioPlaybackStartedAckIfNeeded(
            originalPayload: try encodedEncryptedAudioPacket(sequenceNumber: 0),
            channelID: channelID,
            fromUserID: "sender-user",
            fromDeviceID: senderDeviceID,
            contactID: contactID,
            incomingAudioTransport: .relayWebSocket
        )

        let playbackAcks = client.sentSignalsForTesting().filter { $0.type == .audioPlaybackStarted }
        #expect(playbackAcks.count == 2)
        let secondPayload = try playbackAcks[1].decodeAudioPlaybackStartedPayload()
        #expect(secondPayload.encryptedSequenceNumber == 0)
    }

    @MainActor
    @Test func rejectedIncomingAudioDoesNotSendPlaybackAck() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.receiveRemoteAudioChunkResult = false
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "receiver-user",
            mode: "cloud"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)

        await viewModel.handleIncomingAudioPayload(
            "pcm-audio",
            channelID: "channel-1",
            fromUserID: "peer-user",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .mediaRelayTcp
        )

        try await waitForCondition(
            "rejected incoming audio playback completion",
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            mediaSession.receivedRemoteAudioChunks == ["pcm-audio"]
                && viewModel.diagnostics.entries.contains {
                    $0.message == "Skipped first audio playback ACK because playback was not accepted"
                }
        }
        #expect(mediaSession.receivedRemoteAudioChunks == ["pcm-audio"])
        #expect(client.sentSignalsForTesting().filter { $0.type == .audioPlaybackStarted }.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped first audio playback ACK because playback was not accepted"
            )
        )
        let skippedAckEntry = try #require(
            viewModel.diagnostics.entries.first {
                $0.message == "Skipped first audio playback ACK because playback was not accepted"
            }
        )
        #expect(skippedAckEntry.level == .notice)
    }

    @MainActor
    @Test func stopTransmitDrainsCaptureTailBeforeClearingAudioTransport() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        let sendAudioChunk: @Sendable (String) async throws -> Void = { _ in }

        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaSession.updateSendAudioChunk(sendAudioChunk)

        await viewModel.performStopTransmit(target)

        #expect(mediaSession.stopSendingAudioCallCount == 1)
        #expect(mediaSession.sendAudioChunkConfiguredWhenStopSendingAudio == true)
        #expect(mediaSession.sendAudioChunkWasClearedAfterStopSendingAudio)
        #expect(viewModel.mediaServices.sendAudioChunk() == nil)
    }

    @MainActor
    @Test func stopTransmitAbortsPacketLaneTailBeforeClearingAudioTransport() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        let sendAudioChunk: @Sendable (String) async throws -> Void = { _ in }

        viewModel.applicationStateOverride = .active
        viewModel.mediaRuntime.updateTransportPathState(.fastRelay)
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaSession.updateSendAudioChunk(sendAudioChunk)

        await viewModel.performStopTransmit(target)

        #expect(mediaSession.abortSendingAudioCallCount == 1)
        #expect(mediaSession.stopSendingAudioCallCount == 0)
        #expect(mediaSession.sendAudioChunkConfiguredWhenAbortSendingAudio == true)
        #expect(mediaSession.sendAudioChunkWasClearedAfterAbortSendingAudio)
        #expect(viewModel.mediaServices.sendAudioChunk() == nil)
    }

    @MainActor
    @Test func abortTransmitDrainsCaptureTailBeforeClearingAudioTransport() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        let sendAudioChunk: @Sendable (String) async throws -> Void = { _ in }

        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaSession.updateSendAudioChunk(sendAudioChunk)

        await viewModel.performAbortTransmit(target)

        #expect(mediaSession.stopSendingAudioCallCount == 1)
        #expect(mediaSession.sendAudioChunkConfiguredWhenStopSendingAudio == true)
        #expect(mediaSession.sendAudioChunkWasClearedAfterStopSendingAudio)
        #expect(viewModel.mediaServices.sendAudioChunk() == nil)
    }

    @MainActor
    @Test func firstAudioPlaybackAckClearsSenderExpectation() async throws {
        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "peer-user"
            )
        ]
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        try await sendAudioChunk("payload-1")

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] != nil)
        let ackPayload = TurboAudioPlaybackStartedPayload(
            ackId: "ack-1",
            channelId: "channel-1",
            senderDeviceId: client.deviceID,
            receiverDeviceId: "peer-device",
            transport: "relay-websocket",
            transportDigest: AudioChunkPayloadCodec.transportDigest("payload-1"),
            encryptedSequenceNumber: nil
        )
        let envelope = try TurboSignalEnvelope.audioPlaybackStarted(
            channelId: "channel-1",
            fromUserId: "peer-user",
            fromDeviceId: "peer-device",
            toUserId: "sender-user",
            toDeviceId: client.deviceID,
            payload: ackPayload
        )
        viewModel.handleIncomingSignal(envelope)

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains("First audio playback ACK received")
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.first_audio_playback_ack_missing"
            }
        )
    }

    @MainActor
    @Test func firstAudioPlaybackAckDoesNotRearmForSameTransmitTarget() async throws {
        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        try await sendAudioChunk("payload-1")

        let ackPayload = TurboAudioPlaybackStartedPayload(
            ackId: "ack-1",
            channelId: "channel-1",
            senderDeviceId: client.deviceID,
            receiverDeviceId: "peer-device",
            transport: "relay-websocket",
            transportDigest: AudioChunkPayloadCodec.transportDigest("payload-1"),
            encryptedSequenceNumber: nil
        )
        viewModel.handleAudioPlaybackStartedAck(
            ackPayload,
            contactID: contactID,
            source: .backendWebSocket
        )

        try await sendAudioChunk("payload-2")

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(
            viewModel.firstAudioPlaybackAckCompletedKeys.contains(
                FirstAudioPlaybackAckSentKey(
                    contactID: contactID,
                    channelID: "channel-1",
                    senderDeviceID: client.deviceID,
                    receiverDeviceID: "peer-device"
                )
            )
        )
    }

    @MainActor
    @Test func firstAudioPlaybackAckRearmsForNextTransmitAttempt() async throws {
        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        try await sendAudioChunk("payload-1")
        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-1",
                channelId: "channel-1",
                senderDeviceId: client.deviceID,
                receiverDeviceId: "peer-device",
                transport: "relay-websocket",
                transportDigest: AudioChunkPayloadCodec.transportDigest("payload-1"),
                encryptedSequenceNumber: nil
            ),
            contactID: contactID,
            source: .backendWebSocket
        )

        viewModel.startTransmitStartupTiming(
            for: TransmitRequestContext(
                contactID: contactID,
                contactHandle: "@peer",
                backendChannelID: "channel-1",
                remoteUserID: "peer-user",
                channelUUID: nil,
                usesLocalHTTPBackend: false,
                backendSupportsWebSocket: true
            ),
            source: "test-next-press"
        )
        try await sendAudioChunk("payload-2")

        let expectation = try #require(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID])
        #expect(expectation.transportDigest == AudioChunkPayloadCodec.transportDigest("payload-2"))
        #expect(
            !viewModel.firstAudioPlaybackAckCompletedKeys.contains(
                FirstAudioPlaybackAckSentKey(
                    contactID: contactID,
                    channelID: "channel-1",
                    senderDeviceID: client.deviceID,
                    receiverDeviceID: "peer-device"
                )
            )
        )
    }

    @MainActor
    @Test func duplicateFirstAudioPlaybackAckAfterCompletionDoesNotRecordViolation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let completedKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "sender-device",
            receiverDeviceID: "receiver-device"
        )
        viewModel.firstAudioPlaybackAckCompletedKeys.insert(completedKey)

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-duplicate",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "direct-quic",
                transportDigest: "later-payload-digest",
                encryptedSequenceNumber: nil
            ),
            contactID: contactID,
            source: .directQuicDataChannel
        )

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.first_audio_ack_without_expectation"
                    && $0.metadata["ackId"] == "ack-duplicate"
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Recorded delayed Direct QUIC audio playback ACK after completed expectation"
            )
        )
        #expect(
            viewModel.directAudioPlaybackVerifiedKeys.contains(
                completedKey
            )
        )
    }

    @MainActor
    @Test func staleNonInitialAudioPlaybackAckWithoutExpectationDoesNotRecordViolation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-stale-noninitial",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "relay-websocket",
                transportDigest: "later-payload-digest",
                encryptedSequenceNumber: 67
            ),
            contactID: contactID,
            source: .backendWebSocket
        )

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.first_audio_ack_without_expectation"
                    && $0.metadata["ackId"] == "ack-stale-noninitial"
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Ignored stale non-initial audio playback ACK without pending expectation"
            )
        )
    }

    @MainActor
    @Test func websocketFallbackSlowOutboundSendRecordsNoticeInsteadOfContractViolation() {
        let viewModel = PTTViewModel()

        viewModel.recordMediaSessionEvent(
            "Outbound audio transport send was slow",
            metadata: [
                "diagnosticLevel": "notice",
                "elapsedMilliseconds": "350",
                "invariantID": "media.outbound_audio_transport_send_slow",
                "payloadLength": "256",
                "pendingPayloadCount": "0",
                "reason": "ordered-fallback-slow-send",
                "transportDigest": "digest-1",
            ]
        )

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.outbound_audio_transport_send_slow"
            }
        )
        let entry = viewModel.diagnostics.entries.first {
            $0.message == "Outbound audio transport send was slow"
        }
        #expect(entry?.level == .notice)
        #expect(entry?.metadata["reason"] == "ordered-fallback-slow-send")
    }

    @MainActor
    @Test func engineRejectsLocalAudioAfterTransmitStopBeforeAppSend() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let joined = JoinedConversationEvidence(
            friend: SelectedFriendEvidence(contactID: ContactID(contactID.uuidString), handle: "@peer"),
            channelID: "channel-1",
            localDeviceID: "sender-device",
            peerDevice: .ready(PeerDeviceEvidence(deviceID: "receiver-device")),
            receiverAddressability: .foreground(PeerDeviceEvidence(deviceID: "receiver-device")),
            readiness: .ready(
                JoinedReadinessEvidence(
                    backendMembershipObserved: BackendMembershipEvidence(
                        channelID: "channel-1",
                        localDeviceID: "sender-device",
                        peerDeviceID: "receiver-device",
                        observedAtTick: 1
                    ),
                    transport: .directQuic
                )
            )
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "receiver-device",
            channelID: "channel-1"
        )

        viewModel.receiveEngineEvent(.backend(.joined(joined)), source: "test-joined")
        viewModel.receiveEngineEvent(
            .backend(.localTransmitObserved("local-channel-1")),
            source: "test-active"
        )
        #expect(
            viewModel.syncEngineLocalAudioCaptured(
                payload: "payload-active",
                target: target,
                source: "test-active"
            )
        )

        viewModel.sendEngineIntent(.endTalk, source: "test-release")

        #expect(
            !viewModel.syncEngineLocalAudioCaptured(
                payload: "payload-stale",
                target: target,
                source: "test-stale"
            )
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "engine.local_audio_requires_active_transmit_epoch"
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Dropped local audio captured after transmit stopped"
            )
        )
    }

    @MainActor
    @Test func duplicateRemoteTransmitStartDoesNotResetReceiveAudioEpoch() {
        let viewModel = PTTViewModel()
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        #expect(
            viewModel.mediaRuntime.acceptMediaEncryptionReceiveSequence(
                42,
                for: contactID
            ) == .accepted
        )
        let ackSentKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "peer-device",
            receiverDeviceID: "self-device"
        )
        viewModel.firstAudioPlaybackAckSentKeys.insert(ackSentKey)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-1",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "start"
            )
        )

        #expect(viewModel.firstAudioPlaybackAckSentKeys.contains(ackSentKey))
        #expect(
            viewModel.mediaRuntime.acceptMediaEncryptionReceiveSequence(
                42,
                for: contactID
            ) == .duplicate
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Skipped remote audio epoch reset for duplicate transmit control"
                    && $0.metadata["source"] == RemoteReceiveActivitySource.transmitStartSignal.rawValue
            }
        )
    }

    @MainActor
    @Test func directSelectedFallbackAudioIngressIsAcceptedAsStandbyRedundancy() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        viewModel.mediaRuntime.updateTransportPathState(.direct)

        viewModel.recordIncomingAudioStandbyIngressIfNeeded(
            contactID: contactID,
            channelID: "channel-1",
            incomingAudioTransport: .mediaRelayPacket
        )

        #expect(viewModel.diagnostics.invariantViolations.isEmpty)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Accepted standby audio while Direct transport is selected"
                    && $0.metadata["incomingTransport"] == "media-relay-packet"
                    && $0.metadata["selectedTransport"] == "direct"
            }
        )
    }

    @MainActor
    @Test func firstAudioPlaybackAckAcceptsLaterDirectPacketSequence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let completedKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "sender-device",
            receiverDeviceID: "receiver-device"
        )
        viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] =
            FirstAudioPlaybackAckExpectation(
                ackID: "expected-ack",
                contactID: contactID,
                channelID: "channel-1",
                senderDeviceID: "sender-device",
                receiverDeviceID: "receiver-device",
                transportDigest: "first-packet-digest",
                encryptedSequenceNumber: 0,
                queuedAt: Date(),
                deliveredTransports: ["direct-quic"]
            )

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-later-packet",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "direct-quic",
                transportDigest: "later-packet-digest",
                encryptedSequenceNumber: 60
            ),
            contactID: contactID,
            source: .directQuicDataChannel
        )

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(viewModel.firstAudioPlaybackAckCompletedKeys.contains(completedKey))
        #expect(viewModel.directAudioPlaybackVerifiedKeys.contains(completedKey))
        #expect(viewModel.diagnosticsTranscript.contains("First audio playback ACK received"))
        #expect(!viewModel.diagnosticsTranscript.contains("Ignored mismatched audio playback ACK"))
    }

    @MainActor
    @Test func firstAudioPlaybackAckAcceptsPacketRelayFallbackWebSocketAck() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let completedKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "sender-device",
            receiverDeviceID: "receiver-device"
        )
        viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] =
            FirstAudioPlaybackAckExpectation(
                ackID: "expected-ack",
                contactID: contactID,
                channelID: "channel-1",
                senderDeviceID: "sender-device",
                receiverDeviceID: "receiver-device",
                transportDigest: "packet-digest",
                encryptedSequenceNumber: nil,
                queuedAt: Date(),
                deliveredTransports: ["media-relay-packet"]
            )

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-fallback",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "relay-websocket",
                transportDigest: "fallback-websocket-digest",
                encryptedSequenceNumber: nil
            ),
            contactID: contactID,
            source: .backendWebSocket
        )

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(viewModel.firstAudioPlaybackAckCompletedKeys.contains(completedKey))
        #expect(viewModel.diagnosticsTranscript.contains("First audio playback ACK received"))
        #expect(!viewModel.diagnosticsTranscript.contains("Ignored mismatched audio playback ACK"))
    }

    @MainActor
    @Test func firstAudioPlaybackAckAcceptsLaterOrderedRelayPayloadDigest() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let completedKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "sender-device",
            receiverDeviceID: "receiver-device"
        )
        viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] =
            FirstAudioPlaybackAckExpectation(
                ackID: "expected-ack",
                contactID: contactID,
                channelID: "channel-1",
                senderDeviceID: "sender-device",
                receiverDeviceID: "receiver-device",
                transportDigest: "first-websocket-digest",
                encryptedSequenceNumber: nil,
                queuedAt: Date(),
                deliveredTransports: ["relay-websocket"]
            )

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-later-websocket-payload",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "relay-websocket",
                transportDigest: "later-websocket-digest",
                encryptedSequenceNumber: nil
            ),
            contactID: contactID,
            source: .backendWebSocket
        )

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(viewModel.firstAudioPlaybackAckCompletedKeys.contains(completedKey))
        #expect(viewModel.diagnosticsTranscript.contains("First audio playback ACK received"))
        #expect(!viewModel.diagnosticsTranscript.contains("Ignored mismatched audio playback ACK"))
    }

    @MainActor
    @Test func firstAudioPlaybackAckRejectsOlderDirectPacketSequence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let completedKey = FirstAudioPlaybackAckSentKey(
            contactID: contactID,
            channelID: "channel-1",
            senderDeviceID: "sender-device",
            receiverDeviceID: "receiver-device"
        )
        viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] =
            FirstAudioPlaybackAckExpectation(
                ackID: "expected-ack",
                contactID: contactID,
                channelID: "channel-1",
                senderDeviceID: "sender-device",
                receiverDeviceID: "receiver-device",
                transportDigest: "current-packet-digest",
                encryptedSequenceNumber: 60,
                queuedAt: Date(),
                deliveredTransports: ["direct-quic"]
            )

        viewModel.handleAudioPlaybackStartedAck(
            TurboAudioPlaybackStartedPayload(
                ackId: "ack-stale-packet",
                channelId: "channel-1",
                senderDeviceId: "sender-device",
                receiverDeviceId: "receiver-device",
                transport: "direct-quic",
                transportDigest: "older-packet-digest",
                encryptedSequenceNumber: 40
            ),
            contactID: contactID,
            source: .directQuicDataChannel
        )

        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] != nil)
        #expect(!viewModel.firstAudioPlaybackAckCompletedKeys.contains(completedKey))
        #expect(!viewModel.directAudioPlaybackVerifiedKeys.contains(completedKey))
        #expect(viewModel.diagnosticsTranscript.contains("Ignored mismatched audio playback ACK"))
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "media.audio_playback_ack_mismatch"
                    && $0.metadata["contractName"] == "media.first_audio_ack_matches_pending_expectation"
                    && $0.metadata["ackId"] == "ack-stale-packet"
            }
        )
    }

    @MainActor
    @Test func outgoingAudioSendDropsWhenTransmitTargetIsNoLongerCurrent() async throws {
        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        viewModel.sendEngineIntent(.endTalk, source: "test-release")

        try await sendAudioChunk("payload-after-stop")

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(viewModel.firstAudioPlaybackAckExpectationsByContactID[contactID] == nil)
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "effect.outgoing_audio_send_without_current_target"
                    && $0.metadata["contractName"] == "effect.outgoing_audio_send_requires_current_target"
                    && $0.metadata["engineMatches"] == "false"
            }
        )
    }

    @MainActor
    @Test func missingFirstAudioPlaybackAckKeepsActiveOpusTransmitPolicy() async throws {
        guard OpusVoiceCodec.isAvailable() else { return }

        let previousRelayOnlyForced = TurboDirectPathDebugOverride.isRelayOnlyForced()
        TurboDirectPathDebugOverride.setRelayOnlyForced(true)
        defer {
            TurboDirectPathDebugOverride.setRelayOnlyForced(previousRelayOnlyForced)
        }

        let viewModel = PTTViewModel()
        viewModel.firstAudioPlaybackAckTimeoutNanoseconds = 20_000_000
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.enableSentSignalCaptureForTesting()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "sender-user",
            mode: "cloud"
        )
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        let mediaSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        _ = viewModel.mediaRuntime.markVoiceMediaCapabilities(
            VoiceMediaCapabilities(
                codecs: [VoiceMediaCapabilities.opusCodec],
                features: [VoiceMediaCapabilities.opusFrameV2Feature]
            ),
            for: contactID,
            peerDeviceID: "peer-device",
            source: "test"
        )
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-1",
            localDeviceID: client.deviceID,
            peerDeviceID: "peer-device"
        )

        viewModel.configureOutgoingAudioRoute(target: target)
        #expect(mediaSession.outboundVoiceMediaPolicyUpdates.last == .opusV2)
        let sendAudioChunk = try #require(viewModel.mediaRuntime.sendAudioChunk)
        try await sendAudioChunk("payload-1")

        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(viewModel.mediaRuntime.outboundVoiceMediaPayloadFormat(for: contactID) == .opusV2)
        #expect(mediaSession.outboundVoiceMediaPolicyUpdates.last == .opusV2)
        #expect(
            !viewModel.diagnosticsTranscript.contains("Downgraded outbound voice media policy")
        )
        viewModel.clearFirstAudioPlaybackAckExpectations()
    }

    @Test func mediaEncryptionReceiveSequenceAcceptsBoundedOutOfOrderAuthenticatedPacket() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(runtime.acceptMediaEncryptionReceiveSequence(2, for: contactID) == .accepted)
        #expect(runtime.acceptMediaEncryptionReceiveSequence(2, for: contactID) == .duplicate)
        #expect(runtime.acceptMediaEncryptionReceiveSequence(1, for: contactID) == .accepted)
        #expect(runtime.acceptMediaEncryptionReceiveSequence(1, for: contactID) == .duplicate)
    }

    @Test func mediaEncryptionReceiveSequenceStillRejectsOutsideReorderWindow() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(runtime.acceptMediaEncryptionReceiveSequence(300, for: contactID) == .accepted)
        #expect(runtime.acceptMediaEncryptionReceiveSequence(1, for: contactID) == .replayOrReordered)
    }

    @Test func incomingAudioPlaybackGateKeepsSlowSequentialRelayWebSocketFallbackFrames() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: 38,
                transport: .relayWebSocket,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )

        let decision = runtime.acceptIncomingAudioForPlayback(
            contactID: contactID,
            sequenceNumber: 39,
            transport: .relayWebSocket,
            nowNanoseconds: 2_300_000_000
        )

        #expect(decision.shouldPlay)
        #expect(decision.dropReason == nil)
    }

    @Test func incomingAudioPlaybackGateUsesActualFrameDurationForOrderedFallback() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: 0,
                transport: .mediaRelayTcp,
                frameDurationNanoseconds: 100_000_000,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )

        let decision = runtime.acceptIncomingAudioForPlayback(
            contactID: contactID,
            sequenceNumber: 1,
            transport: .mediaRelayTcp,
            frameDurationNanoseconds: 100_000_000,
            nowNanoseconds: 1_308_000_000
        )

        #expect(decision.shouldPlay)
    }

    @Test func incomingAudioPlaybackGateAcceptsNewestFrameAfterBacklogCatchup() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        _ = runtime.acceptIncomingAudioForPlayback(
            contactID: contactID,
            sequenceNumber: 38,
            transport: .relayWebSocket,
            nowNanoseconds: 1_000_000_000
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: 100,
                transport: .relayWebSocket,
                nowNanoseconds: 2_300_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: 99,
                transport: .relayWebSocket,
                nowNanoseconds: 2_340_000_000
            ).dropReason == .duplicateOrStaleSequence
        )
    }

    @Test func incomingAudioPlaybackGateDoesNotDropPacketMediaAsOrderedBacklog() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: contactID,
                sequenceNumber: 38,
                transport: .mediaRelayPacket,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )

        let decision = runtime.acceptIncomingAudioForPlayback(
            contactID: contactID,
            sequenceNumber: 39,
            transport: .mediaRelayPacket,
            nowNanoseconds: 2_300_000_000
        )

        #expect(decision.shouldPlay)
        let directContactID = UUID()
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 38,
                transport: .directQuic,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 39,
                transport: .directQuic,
                nowNanoseconds: 2_300_000_000
            ).shouldPlay
        )
    }

    @Test func incomingAudioPlaybackGateAcceptsPacketMediaReorderBeforePlayoutBuffer() {
        let runtime = MediaRuntimeState()
        let directContactID = UUID()

        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 40,
                transport: .directQuic,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 42,
                transport: .directQuic,
                nowNanoseconds: 1_020_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 41,
                transport: .directQuic,
                nowNanoseconds: 1_030_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: directContactID,
                sequenceNumber: 42,
                transport: .directQuic,
                nowNanoseconds: 1_040_000_000
            ).dropReason == .duplicateOrStaleSequence
        )

        let relayContactID = UUID()
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: relayContactID,
                sequenceNumber: 10,
                transport: .mediaRelayPacket,
                nowNanoseconds: 1_000_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: relayContactID,
                sequenceNumber: 12,
                transport: .mediaRelayPacket,
                nowNanoseconds: 1_020_000_000
            ).shouldPlay
        )
        #expect(
            runtime.acceptIncomingAudioForPlayback(
                contactID: relayContactID,
                sequenceNumber: 11,
                transport: .mediaRelayPacket,
                nowNanoseconds: 1_030_000_000
            ).shouldPlay
        )
    }

    @MainActor
    @Test func mediaEncryptionSealConfiguresSessionBeforeSendingWhenPeerIdentityIsAdvertised() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: localPrivateKey,
            registration: localRegistration
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "device-b",
            channelID: "channel-1"
        )
        let plaintext = Data("pcm-audio".utf8).base64EncodedString()

        let outgoing = try viewModel.sealOutgoingMediaPayloadIfPossible(plaintext, target: target)

        #expect(MediaEncryptedAudioPacket.isEncodedPacket(outgoing))
        #expect(!outgoing.contains(plaintext))
        let session = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        let context = session.context(
            senderDeviceID: session.localDeviceID,
            receiverDeviceID: session.peerDeviceID
        )
        let peerOpenKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: context
        )
        #expect(
            try MediaEndToEndEncryption.openTransportPayload(
                outgoing,
                using: peerOpenKey,
                context: context
            ) == plaintext
        )
    }

    @MainActor
    @Test func mediaEncryptionSealFallsBackToPlaintextWhenRequiredSessionCannotBeConfigured() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "device-b",
            channelID: "channel-1"
        )

        let outgoing = try viewModel.sealOutgoingMediaPayloadIfPossible("plaintext", target: target)

        #expect(outgoing == "plaintext")
        #expect(viewModel.diagnosticsTranscript.contains("Sending plaintext media payload because E2EE session is unavailable"))
    }

    @MainActor
    @Test func mediaEncryptionAcceptsIncomingPlaintextWhenPeerIdentityIsAdvertised() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )

        let opened = try viewModel.openIncomingMediaPayloadIfPossible(
            "plaintext",
            channelID: "channel-1",
            fromDeviceID: "device-b",
            contactID: contactID
        )

        #expect(opened == "plaintext")
        #expect(viewModel.diagnosticsTranscript.contains("Accepted plaintext media payload during opportunistic E2EE fallback"))
    }

    @MainActor
    @Test func mediaEncryptionReadinessWaitsForConfiguredReceiveSession() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )

        #expect(
            !viewModel.localReceiverMediaEncryptionReadyForLiveMedia(
                contactID: contactID,
                channelID: "channel",
                peerDeviceID: "peer-device"
            )
        )

        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: localPrivateKey,
            registration: localRegistration
        )

        #expect(
            viewModel.localReceiverMediaEncryptionReadyForLiveMedia(
                contactID: contactID,
                channelID: "channel",
                peerDeviceID: "peer-device"
            )
        )
        #expect(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID) != nil)
    }

    @MainActor
    @Test func mediaEncryptionSessionSurvivesTransientMissingPeerIdentity() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: localPrivateKey,
            registration: localRegistration
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        viewModel.configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: "channel",
            peerDeviceID: "peer-device"
        )
        let session = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        let context = session.context(senderDeviceID: "peer-device", receiverDeviceID: session.localDeviceID)
        let peerSealKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: context
        )
        let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
            "pcm-audio",
            using: peerSealKey,
            keyID: session.keyID,
            sequenceNumber: 0,
            context: context
        )

        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerHasActiveDevice: false
                )
            )
        )
        viewModel.configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: "channel",
            peerDeviceID: "peer-device"
        )

        #expect(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID) != nil)
        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                encrypted,
                channelID: "channel",
                fromDeviceID: "peer-device",
                contactID: contactID
            ) == "pcm-audio"
        )
        #expect(
            viewModel.diagnosticsTranscript
                .contains("Preserved existing media E2EE session while peer identity is transiently unavailable")
        )
    }

    @MainActor
    @Test func mediaEncryptionSessionIsStableForSameChannelPeerDuringIdentityRefresh() throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let originalLocalPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let refreshedLocalPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let originalLocalRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: originalLocalPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: originalLocalPrivateKey.publicKey.rawRepresentation
            )
        )
        let refreshedLocalRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: refreshedLocalPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: refreshedLocalPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: originalLocalPrivateKey,
            registration: originalLocalRegistration
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        viewModel.configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: "channel",
            peerDeviceID: "peer-device"
        )
        let originalSession = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        let context = originalSession.context(
            senderDeviceID: "peer-device",
            receiverDeviceID: originalSession.localDeviceID
        )
        let peerSealKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: originalLocalRegistration,
            context: context
        )
        let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
            "pcm-audio",
            using: peerSealKey,
            keyID: originalSession.keyID,
            sequenceNumber: 0,
            context: context
        )

        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: refreshedLocalPrivateKey,
            registration: refreshedLocalRegistration
        )
        viewModel.configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: "channel",
            peerDeviceID: "peer-device"
        )

        let preservedSession = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        #expect(preservedSession.keyID == originalSession.keyID)
        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                encrypted,
                channelID: "channel",
                fromDeviceID: "peer-device",
                contactID: contactID
            ) == "pcm-audio"
        )
        #expect(
            viewModel.diagnosticsTranscript
                .contains("Preserved existing media E2EE session for stable channel peer")
        )
    }

    @MainActor
    @Test func incomingAudioDoesNotLogPreservedMediaEncryptionSessionPerPacket() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let mediaSession = RecordingMediaSession()
        let localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let localRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: localPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: localPrivateKey.publicKey.rawRepresentation
            )
        )
        let peerRegistration = MediaEncryptionIdentityRegistrationMetadata(
            publicKeyBase64: peerPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            fingerprint: MediaEncryptionIdentityManager.fingerprint(
                forPublicKey: peerPrivateKey.publicKey.rawRepresentation
            )
        )
        viewModel.mediaEncryptionLocalIdentity = MediaEncryptionLocalIdentity(
            privateKey: localPrivateKey,
            registration: localRegistration
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.applicationStateOverride = .active
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload(
                        scheme: peerRegistration.scheme,
                        publicKeyBase64: peerRegistration.publicKeyBase64,
                        fingerprint: peerRegistration.fingerprint,
                        status: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        viewModel.configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: "channel",
            peerDeviceID: "peer-device"
        )
        let session = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        let context = session.context(senderDeviceID: "peer-device", receiverDeviceID: session.localDeviceID)
        let peerSealKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: peerPrivateKey,
            peerIdentity: localRegistration,
            context: context
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerHasActiveDevice: false
                )
            )
        )

        let preservedLogMessage = "Preserved existing media E2EE session"
        let preservedLogCountBeforeAudio = viewModel.diagnosticsTranscript
            .components(separatedBy: preservedLogMessage)
            .count
        for sequenceNumber in UInt64(0)..<3 {
            let encrypted = try MediaEndToEndEncryption.sealTransportPayload(
                "pcm-audio-\(sequenceNumber)",
                using: peerSealKey,
                keyID: session.keyID,
                sequenceNumber: sequenceNumber,
                context: context
            )
            await viewModel.handleIncomingAudioPayload(
                encrypted,
                channelID: "channel",
                fromUserID: "peer-user",
                fromDeviceID: "peer-device",
                contactID: contactID,
                incomingAudioTransport: .directQuic
            )
        }

        #expect(mediaSession.receivedRemoteAudioChunks == ["pcm-audio-0", "pcm-audio-1", "pcm-audio-2"])
        #expect(
            viewModel.diagnosticsTranscript
                .components(separatedBy: preservedLogMessage)
                .count == preservedLogCountBeforeAudio
        )
    }

    @Test func channelReadinessDecodesBackendPeerMediaEncryptionIdentity() throws {
        let peerPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicKeyData = peerPrivateKey.publicKey.rawRepresentation
        let peerFingerprint = MediaEncryptionIdentityManager.fingerprint(forPublicKey: peerPublicKeyData)
        let json = """
        {
          "channelId": "channel-1",
          "peerUserId": "peer-user",
          "selfHasActiveDevice": true,
          "peerHasActiveDevice": true,
          "readiness": { "kind": "ready" },
          "audioReadiness": {
            "self": { "kind": "ready" },
            "peer": { "kind": "ready" },
            "peerTargetDeviceId": "peer-device"
          },
          "wakeReadiness": {
            "self": { "kind": "unavailable" },
            "peer": { "kind": "unavailable" }
          },
          "peerMediaEncryptionIdentity": {
            "scheme": "x25519-v1",
            "publicKeyBase64": "\(peerPublicKeyData.base64EncodedString())",
            "fingerprint": "\(peerFingerprint.uppercased())",
            "status": "active"
          }
        }
        """

        let readiness = try JSONDecoder().decode(
            TurboChannelReadinessResponse.self,
            from: Data(json.utf8)
        )

        #expect(readiness.peerMediaEncryptionRegistration?.scheme == "x25519-v1")
        #expect(readiness.peerMediaEncryptionRegistration?.publicKeyBase64 == peerPublicKeyData.base64EncodedString())
        #expect(readiness.peerMediaEncryptionRegistration?.fingerprint == peerFingerprint)
    }

    @Test func mediaRuntimeReceiverPrewarmRequestHandlingIsIdempotent() {
        let runtime = MediaRuntimeState()

        #expect(runtime.markReceiverPrewarmRequestHandled("request-1"))
        #expect(!runtime.markReceiverPrewarmRequestHandled("request-1"))
        #expect(runtime.markReceiverPrewarmRequestHandled("request-2"))
    }

    @MainActor
    @Test func selectedFriendPrewarmHintForUnselectedContactDefersHiddenMediaShell() async throws {
        let contactID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        let payload = TurboSelectedFriendPrewarmPayload(
            requestId: "selected-prewarm-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "",
            reason: "selected-contact"
        )
        let envelope = try TurboSignalEnvelope.selectedFriendPrewarm(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        await viewModel.ingestBackendWebSocketSignal(envelope)

        #expect(viewModel.diagnosticsTranscript.contains("Selected friend prewarm hint received"))
        #expect(viewModel.diagnosticsTranscript.contains("Deferred selected friend prewarm hint until contact selection"))
        #expect(!viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline started"))
    }

    @MainActor
    @Test func selectedFriendPrewarmHintBindsKnownPTTTokenForUnselectedContact() async throws {
        let contactID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-peer"
            )
        ]
        viewModel.pttSystemPolicyCoordinator.send(
            .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )
        var uploads: [PTTTokenUploadRequest] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            guard case .uploadEphemeralToken(let request) = effect else { return }
            uploads.append(request)
            viewModel.pttSystemPolicyCoordinator.send(.tokenUploadFinished(request))
        }

        let payload = TurboSelectedFriendPrewarmPayload(
            requestId: "selected-prewarm-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "",
            reason: "selected-contact"
        )
        let envelope = try TurboSignalEnvelope.selectedFriendPrewarm(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        await viewModel.ingestBackendWebSocketSignal(envelope)

        try await waitForScenario(
            "selected friend prewarm binds known PTT token",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            uploads == [
                PTTTokenUploadRequest(
                    backendChannelID: "channel-1",
                    tokenHex: "deadbeef"
                )
            ]
        }

        #expect(viewModel.selectedContactId == nil)
        #expect(viewModel.pttSystemPolicyCoordinator.state.uploadedBackendChannelID == "channel-1")
        #expect(viewModel.diagnosticsTranscript.contains("Binding known PTT token to selected friend prewarm channel"))
        #expect(!viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline started"))
    }

    @Test func receiverPrewarmAckFreshnessExpiresForDirectAudio() {
        let contactID = UUID()
        let runtime = MediaRuntimeState()
        let now = Date()
        let requestID = runtime.receiverPrewarmRequestID(for: contactID)
        runtime.markReceiverPrewarmAckReceived(
            contactID: contactID,
            requestID: requestID,
            receivedAt: now.addingTimeInterval(-31)
        )

        #expect(runtime.receiverPrewarmRequestIsAcknowledged(for: contactID))
        #expect(
            !runtime.receiverPrewarmRequestIsAcknowledged(
                for: contactID,
                maximumAge: 30,
                now: now
            )
        )
    }

    @Test func replacingReceiverPrewarmRequestInvalidatesStaleAck() {
        let contactID = UUID()
        let runtime = MediaRuntimeState()
        let firstRequestID = runtime.receiverPrewarmRequestID(for: contactID)
        runtime.markReceiverPrewarmAckReceived(contactID: contactID, requestID: firstRequestID)

        runtime.replaceReceiverPrewarmRequestID(for: contactID, requestID: "request-2")

        #expect(!runtime.receiverPrewarmRequestIsAcknowledged(for: contactID))
        runtime.markReceiverPrewarmAckReceived(contactID: contactID, requestID: "request-2")
        #expect(runtime.receiverPrewarmRequestIsAcknowledged(for: contactID))
    }

    @MainActor
    @Test func transmitStartupTimingSummaryIncludesFirstAudioStages() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.recordTransmitStartupTiming(
            stage: "system-handoff-requested",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )
        viewModel.recordTransmitStartupTiming(
            stage: "system-audio-session-activated",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )
        viewModel.recordTransmitStartupTimingForMediaEvent(
            "Captured local audio buffer",
            metadata: ["frameLength": "4800"]
        )
        viewModel.recordTransmitStartupTimingForMediaEvent(
            "Delivered outbound audio transport payload",
            metadata: ["decodedChunkCount": "1"]
        )
        viewModel.recordTransmitStartupTimingSummary(
            reason: "test",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )

        let summary = viewModel.diagnostics.entries.first {
            $0.message == "Transmit startup timing summary"
        }
        #expect(summary != nil)
        #expect(summary?.metadata["reason"] == "test")
        #expect(summary?.metadata["system-audio-session-activatedMs"] != nil)
        #expect(summary?.metadata["first-audio-capturedMs"] != nil)
        #expect(summary?.metadata["first-audio-deliveredMs"] != nil)
        #expect(summary?.metadata["appleActivationDeltaMs"] != nil)
        #expect(summary?.metadata["firstAudioTransportDeltaMs"] != nil)
    }

    @Test func reconciledTeardownClearsWhenBackendMembershipAndDevicePTTEvidenceAreGone() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markReconciledTeardown(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(
                status: .idle,
                canTransmit: false,
                selfJoined: false,
                peerJoined: false,
                peerDeviceConnected: false
            ),
            localDevicePTTEvidenceEstablished: false,
            localDevicePTTEvidenceCleared: true
        )

        #expect(coordinator.pendingAction == .none)
    }

    @MainActor
    @Test func selectedSyncClearsDetachedExplicitLeaveAfterBackendMembershipIsGone() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.clearEngineConversationForTesting()
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)
        viewModel.statusMessage = "Disconnecting..."

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase != .waitingForPeer)
        #expect(viewModel.statusMessage != "Disconnecting...")
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Recovered local Device PTT state after backend membership became absent"
            )
        )
    }

    @MainActor
    @Test func selectedSyncClearsStaleBackendConnectAfterJoinIsEstablished() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueConnect(contactID: contactID)
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID, backendChannelID: "channel")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Recovered stale backend connect after local join was established"
            )
        )
    }

    @MainActor
    @Test func selectedSyncPreservesAcceptedOutgoingJoinWhileBackendJoinSettles() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.clearEngineConversationForTesting()
        viewModel.conversationActionCoordinator.queueJoin(
            contactID: contactID,
            channelUUID: channelUUID
        )
        viewModel.backendRuntime.markBackendJoinSettling(for: contactID)
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel",
                        handle: "@blake",
                        displayName: "Blake",
                        hasOutgoingBeep: true,
                        requestCount: 1,
                        badgeStatus: "outgoing-beep"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .outgoingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasOutgoingBeep: true
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt != nil)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Recovered stale local join during outgoing Beep"
            )
        )
    }

    @Test func backendJoinedStateDoesNotClearPendingJoinBeforeDevicePTTEvidenceEstablishes() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localDevicePTTEvidenceEstablished: false,
            localDevicePTTEvidenceCleared: false
        )

        #expect(coordinator.pendingJoinContactID == contactID)
    }

    @Test func replacingPendingJoinWithBackendConnectClearsLocalJoinAttempt() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.queueConnect(contactID: contactID)

        #expect(coordinator.pendingAction == .connect(.requestingBackend(contactID: contactID)))
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func devicePTTEvidenceEstablishmentClearsPendingJoinAfterBackendShowsJoined() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID, channelUUID: UUID())
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localDevicePTTEvidenceEstablished: true,
            localDevicePTTEvidenceCleared: false
        )

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func devicePTTEvidenceEstablishmentClearsPendingBackendConnectAfterBackendShowsJoined() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localDevicePTTEvidenceEstablished: true,
            localDevicePTTEvidenceCleared: false
        )

        #expect(coordinator.pendingAction == .none)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func successfulJoinClearsPendingBackendConnect() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)
        coordinator.clearAfterSuccessfulJoin(for: contactID)

        #expect(coordinator.pendingAction == .none)
        #expect(coordinator.localJoinAttempt == nil)
    }

    @Test func partialLocalSessionWithoutSystemSessionRestoresWhenBackendReady() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .friendReadyToConnect))
        #expect(
            projection.reconciliationAction
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func selectedConversationStateWaitsForRemoteAudioReadinessBeforeEnablingTransmit() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .unknown)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateBecomesReadyWhenRemoteAudioReadinessArrives() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedConversationStateUsesAuthoritativeBackendReadyDuringBackendSignalingJoinRecovery() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                directMediaPathActive: true,
                backendConvergence: BackendConversationConvergenceState(joinPhase: .signalingRecovery),
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.detail == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedConversationStateStillWaitsDuringBackendSignalingJoinRecoveryBeforeBackendReady() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                backendConvergence: BackendConversationConvergenceState(joinPhase: .signalingRecovery),
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .waitingForPeer, canTransmit: false),
                    readiness: makeChannelReadiness(status: .waitingForSelf, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.detail == .waitingForPeer(reason: .backendConversationTransition))
        #expect(state.statusMessage == "Connecting...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateShowsWakeReadyDuringBackendSignalingJoinRecoveryWhenBackendReadyAndPeerWakeCapable() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                backendConvergence: BackendConversationConvergenceState(joinPhase: .signalingRecovery),
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.allowsHoldToTalk)
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateDoesNotShowWakeReadyWhenBackendDropsSelfMembership() {
        let contactID = UUID()
        let projection = ConversationStateMachine.projection(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .waitingForPeer,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                backendConvergence: BackendConversationConvergenceState(joinPhase: .signalingRecovery),
                hadConnectedDevicePTTContinuity: true,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .inactive,
                        selfHasActiveDevice: false,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(projection.devicePTTContinuity == .connected)
        #expect(projection.connectedControlPlane == .unavailable)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .devicePTTTransition))
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
        #expect(projection.selectedConversationState.canTransmitNow == false)
        #expect(projection.selectedConversationState.allowsHoldToTalk == false)
        #expect(projection.reconciliationAction == .none)
    }

    @Test func selectedConversationStateWaitsWhenConnectedContinuityLosesBackendTransmitAuthority() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .waitingForPeer,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                backendConvergence: BackendConversationConvergenceState(
                    controlPlaneContinuity: .reconnectGrace
                ),
                hadConnectedDevicePTTContinuity: true,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .waitingForPeer, canTransmit: false),
                    readiness: makeChannelReadiness(status: .waitingForSelf, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.detail == .waitingForPeer(reason: .backendConversationTransition))
        #expect(state.statusMessage == "Connecting...")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
    }

    @Test func selectedConversationStateShowsWakeReadyWhenWakeCapabilityIsAvailableButRemoteAudioIsNotReady() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedConversationStateStillWaitsForLocalAudioPrewarmBeforeContinuityExists() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .closed,
                localMediaWarmupState: .cold,
                localRelayTransportReady: true,
                hadConnectedDevicePTTContinuity: false,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.detail == .waitingForPeer(reason: .localAudioPrewarm))
        #expect(state.statusMessage == "Connecting...")
        #expect(state.allowsHoldToTalk == false)
    }

    @Test func selectedConversationStateBlocksHoldToTalkWhenRemoteAudioExplicitlyWaitsDespiteBackendReady() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .waiting,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: state,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.detail == .waitingForPeer(reason: .remoteAudioPrewarm))
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedConversationStateShowsWakeReadyWhenBackendReadyAndLocalMediaIsCold() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .idle,
                localMediaWarmupState: .cold,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedConversationStateWaitsForRemoteAudioReadinessWhenWakeCapabilityIsUnavailable() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(!state.canTransmitNow)
        #expect(!state.allowsHoldToTalk)
    }

    @Test func incomingReceiverReadySignalUpdatesRemoteReadinessState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .waiting)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "test"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .ready)
    }

    @Test func channelReadinessSnapshotDoesNotTreatWakeCapableReceiverAsReadyForLiveTransmit() {
        let snapshot = ChannelReadinessSnapshot(
            channelState: makeChannelState(status: .ready, canTransmit: true),
            readiness: makeChannelReadiness(
                status: .ready,
                remoteAudioReadiness: .wakeCapable,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
            )
        )

        #expect(!snapshot.remoteAudioReadyForLiveTransmit)
    }

    @Test func fetchedWaitingReadinessDoesNotPreserveWakeCapabilityWhenBackendReportsUnavailable() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .waiting)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func fetchedUnknownReadinessDoesNotPreserveWakeCapabilityWhenBackendReportsUnavailable() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func wakeCapableReceiverFallbackDoesNotPreserveRoutableReadyDevicePTTSession() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            localAudioReadiness: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            selfHasActiveDevice: true,
            peerHasActiveDevice: false,
            localAudioReadiness: .ready,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            peerMembershipPresent: true,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(merged?.statusView == .waitingForPeer)
        #expect(merged?.canTransmit == false)
        #expect(merged?.selfHasActiveDevice == true)
        #expect(merged?.peerHasActiveDevice == false)
        #expect(merged?.localAudioReadiness == .ready)
        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @MainActor
    @Test func effectiveConversationMembershipPreservesWakeCapableFallbackWhenRefreshDropsFriendMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existingChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let regressedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let effectiveChannelState = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existingChannelState,
            incoming: regressedChannelState
        )

        let existingReadiness = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetchedReadiness = makeChannelReadiness(
            status: .waitingForPeer,
            peerHasActiveDevice: false,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existingReadiness,
            fetched: fetchedReadiness,
            peerDeviceConnected: effectiveChannelState.membership.peerDeviceConnected,
            peerMembershipPresent: effectiveChannelState.membership.hasPeerMembership,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(effectiveChannelState.membership == .both(peerDeviceConnected: true))
        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func summaryContactsRemainAuthoritativeWithoutTracking() {
        let summaryOnly = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: [],
            summaryContactIDs: [summaryOnly],
            selectedContactID: nil,
            activeChannelID: nil,
            mediaSessionContactID: nil,
            pendingJoinContactID: nil,
            beepContactIDs: []
        )

        #expect(ids == [summaryOnly])
    }

    @Test func requestContactsRemainAuthoritativeWithoutTracking() {
        let beepOnly = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: [],
            summaryContactIDs: [],
            selectedContactID: nil,
            activeChannelID: nil,
            mediaSessionContactID: nil,
            pendingJoinContactID: nil,
            beepContactIDs: [beepOnly]
        )

        #expect(ids == [beepOnly])
    }

    @Test func backendReadyWithoutDevicePTTEvidenceDoesNotAutoRestoreWithoutContinuity() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func backendWaitingForSelfWithMembershipRestoresMissingDevicePTTEvidence() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(
            projection.selectedConversationState.detail
                == .waitingForPeer(reason: .friendReadyToConnect)
        )
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
        #expect(
            projection.reconciliationAction
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func staleLocalSessionWithoutBackendMembershipTearsDownEvenWhenWakeRecoveryRemainsAvailable() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func wakeActivatedSessionSuppressesDriftTeardownWhileBackendMembershipRecovers() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            incomingWakeActivationState: .systemActivated,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func selfJoinedSystemMismatchDoesNotTearDownWhileBackendMembershipStillExists() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func backendInactiveAbsenceWithConnectedDevicePTTContinuityAndWakeCapabilityTearsDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .disconnecting)
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(
            projection.selectedConversationState.detail
                == .waitingForPeer(reason: .disconnecting)
        )
        #expect(projection.selectedConversationState.statusMessage == "Disconnecting...")
        #expect(
            projection.reconciliationAction
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func backendAbsenceDoesNotTearDownExplicitlyConnectedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionWhenWakeRecoveryIsUnavailable() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func settlingBackendJoinDoesNotTeardownConnectedLocalSessionDuringTransientAbsence() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            backendConvergence: BackendConversationConvergenceState(joinPhase: .settling),
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func beepThreadProjectionDoesNotTeardownActiveDevicePTTEvidenceDuringTransientBackendAbsence() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            relationship: .outgoingBeep(requestCount: 1),
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func readyFriendAudioHintDoesNotOverrideBackendTransmitAuthority() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            localMediaWarmupState: .ready,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(selectedConversationState.phase == .wakeReady)
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(selectedConversationState.allowsHoldToTalk)
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionWhenOnlyStaleWakeTokenRemains() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionDespiteStaleReadyProjection() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func peerOnlyBackendStateTearsDownStaleConnectedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func pendingJoinSuppressesDriftTeardownUntilBackendConfirmsMembership() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func pendingJoinWithTerminalBackendMembershipLossTearsDownStaleLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.devicePTTContinuity == .disconnecting)
        #expect(
            projection.reconciliationAction
                == .teardownDevicePTTSession(contactID: contactID)
        )
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .disconnecting))
    }

    @Test func stalePendingJoinAllowsRestoreWhenBackendReadyButNoLocalSessionExists() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func backendReadyPendingConnectAllowsRestoreWhenLocalJoinWasInterrupted() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func backendWaitingForSelfPendingConnectAllowsRestoreWhenLocalJoinWasSkipped() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func backendReadyWithoutLocalContinuityDoesNotAutoRestoreUnilaterally() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: true,
                    localAudioReadiness: .unknown,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
        #expect(
            ConversationStateMachine.projection(for: context, relationship: .none).selectedConversationState.phase
                == .friendReady
        )
    }

    @Test func inactiveBackendMembershipWithoutDevicePTTEvidenceClearsStaleMembership() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .clearStaleBackendMembership(contactID: contactID)
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)
        #expect(projection.selectedConversationState.phase == .idle)
        #expect(projection.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func inactiveBackendMembershipWithWaitingPeerAudioIsInFlightNotStale() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func backendReadyWithConnectedDevicePTTContinuityStillAllowsRestore() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func recentSystemLeaveBarrierSuppressesBackendReadyAutoRestoreAndCallScreen() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            devicePTTRestoreBarrier: .recentSystemLeave(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: "recent-system-leave"
            ),
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.reconciliationAction == .none)
        #expect(projection.devicePTTContinuity == .disconnecting)
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .disconnecting))
        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: projection.selectedConversationState,
            requestedExpanded: true
        ))
    }

    @Test func recentSystemLeaveWithPeerGoneClearsStaleSelfOnlyBackendMembership() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            devicePTTRestoreBarrier: .recentSystemLeave(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: "recent-system-leave"
            ),
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(
            projection.reconciliationAction
                == .clearStaleBackendMembership(contactID: contactID)
        )
        #expect(projection.devicePTTContinuity == .disconnecting)
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .disconnecting))
        #expect(!ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: projection.selectedConversationState,
            requestedExpanded: true
        ))
    }

    @Test func explicitLeaveWithConnectedDevicePTTContinuitySuppressesAutoRestore() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.explicit(contactID: contactID)),
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                != .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func reconciledTeardownWithConnectedDevicePTTContinuitySuppressesAutoRestore() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.reconciledTeardown(contactID: contactID)),
            localJoinFailure: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                != .restoreDevicePTTSession(contactID: contactID)
        )
    }

    @Test func channelLimitJoinFailureSuppressesAutomaticRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: PTTJoinFailure(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: .channelLimitReached
            ),
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func activeMatchingSystemSessionSuppressesDuplicateRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func localTransmitSuppressesDriftTeardownDuringBackendWaitingForPeer() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .transmitting,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func peerTransmitSnapshotTearsDownLocalSessionWhenBackendMembershipIsPeerOnly() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .receiving,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func selectedConversationWaitingForPeerConnectActionUsesDisabledHoldToTalkShell() {
        let state = SelectedConversationState(
            contactID: UUID(),
            contactName: "Avery",
            relationship: .incomingBeep(requestCount: 1),
            detail: .waitingForPeer(reason: .pendingJoin),
            statusMessage: "Connecting...",
            canTransmitNow: false
        )

        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: state,
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        switch action.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk shell while join is pending")
        }
        #expect(action.label == "Connecting...")
        #expect(action.isEnabled == false)
        switch action.style {
        case .muted:
            break
        case .accent, .active:
            Issue.record("Expected muted styling while join is pending")
        }
    }

    @Test func selectedConversationStateShowsFriendReadyWhenBackendReadinessWaitsForSelfWithoutMembership() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .friendReady)
        #expect(state.conversationState == .outgoingBeep)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateAllowsTransmitWhenDevicePTTSessionIsFullyAligned() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .ready, canTransmit: true),
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedConversationStateShowsWakeReadyUntilWakeCapableReceiverPublishesReady() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .ready, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Avery")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func ensureContactClearsStaleBackendChannelMetadataWhenRefreshedWithoutChannel() {
        let staleChannelID = "channel-stale"
        let existing = [
            Contact(
                id: Contact.stableID(for: "@blake"),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: staleChannelID),
                backendChannelId: staleChannelID,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "@blake",
            remoteUserId: "user-blake-2",
            channelId: "",
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(refreshed.remoteUserId == "user-blake-2")
        #expect(refreshed.backendChannelId == nil)
        #expect(refreshed.channelId != ContactDirectory.stableChannelUUID(for: staleChannelID))
    }

    @Test func backendSyncStateClearsStaleChannelStateWhenContactSummaryHasNoChannel() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.channelStates[contactID] = makeChannelState(status: .ready, canTransmit: true)

        state.applyContactSummaries([
            contactID: TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: nil,
                isOnline: true,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online"
            )
        ])

        #expect(state.channelStates[contactID] == nil)
    }

    @Test func backendSyncStateDoesNotCollapseActiveChannelStateFromAbsentSummaryMembership() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.channelStates[contactID] = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )

        state.applyContactSummaries([
            contactID: TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel",
                isOnline: true,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "absent",
                    peerDeviceConnected: nil
                )
            )
        ])

        #expect(state.channelStates[contactID]?.membership == .selfOnly)
        #expect(state.channelStates[contactID]?.statusKind == ConversationState.waitingForPeer.rawValue)
    }

    @Test func backendSyncStateRejectsRegressedChannelStateEpoch() {
        let contactID = UUID()
        var state = BackendSyncState()
        let current = makeChannelState(
            status: .ready,
            canTransmit: true,
            activeTransmitId: "transmit-current",
            stateEpoch: "2026-05-09T10:00:01Z"
        )
        let stale = makeChannelState(
            status: .idle,
            canTransmit: false,
            activeTransmitId: "transmit-stale",
            stateEpoch: "2026-05-09T10:00:00Z"
        )

        state.applyChannelState(current, for: contactID)
        state.applyChannelState(stale, for: contactID)

        #expect(state.channelStates[contactID] == current)
    }

    @Test func backendSyncStateRejectsRegressedReadinessEpoch() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.applyChannelState(
            makeChannelState(status: .ready, canTransmit: true),
            for: contactID
        )
        let current = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            activeTransmitId: "transmit-current",
            stateEpoch: "2026-05-09T10:00:01Z"
        )
        let stale = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .unknown,
            activeTransmitId: "transmit-stale",
            stateEpoch: "2026-05-09T10:00:00Z"
        )

        state.applyChannelReadiness(current, for: contactID)
        state.applyChannelReadiness(stale, for: contactID)

        #expect(state.channelReadiness[contactID] == current)
    }

    @Test func backendSyncStateRejectsReadinessOlderThanAcceptedChannelStateEpoch() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.applyChannelState(
            makeChannelState(
                status: .idle,
                canTransmit: false,
                selfJoined: false,
                peerJoined: false,
                peerDeviceConnected: false,
                stateEpoch: "2026-05-09T10:00:01Z"
            ),
            for: contactID
        )
        let stale = makeChannelReadiness(
            status: .ready,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            remoteAudioReadiness: .ready,
            peerTargetDeviceId: "peer-device",
            stateEpoch: "2026-05-09T10:00:00Z"
        )

        #expect(!state.shouldAcceptChannelReadiness(stale, for: contactID))

        state.applyChannelReadiness(stale, for: contactID)

        #expect(state.channelReadiness[contactID] == nil)
    }

    @Test func backendSyncStateAcceptsReadinessOlderThanReadyConversationStateEpoch() {
        let contactID = UUID()
        var state = BackendSyncState()
        let readiness = makeChannelReadiness(
            status: .ready,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            remoteAudioReadiness: .ready,
            peerTargetDeviceId: "peer-device",
            stateEpoch: "2026-05-09T10:00:00Z"
        )

        state.applyChannelState(
            makeChannelState(
                status: .ready,
                canTransmit: true,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true,
                stateEpoch: "2026-05-09T10:00:01Z"
            ),
            for: contactID
        )

        #expect(state.shouldAcceptChannelReadiness(readiness, for: contactID))

        state.applyChannelReadiness(readiness, for: contactID)

        #expect(state.channelReadiness[contactID] == readiness)
    }

    @Test func backendSyncPartialOutgoingUpdatePreservesIncomingBeepProjection() {
        let incomingContactID = UUID()
        let outgoingContactID = UUID()
        var state = BackendSyncSessionState()
        let incomingBeep = makeBeep(
            direction: "incoming",
            beepId: "incoming-1",
            fromHandle: "@blake",
            toHandle: "@self"
        )
        let outgoingBeep = makeBeep(direction: "outgoing", beepId: "outgoing-1")

        state.syncState.applyBeeps(
            incoming: [incomingContactID: incomingBeep],
            outgoing: [:],
            now: .now
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsPartiallyUpdated(
                incoming: nil,
                outgoing: [BackendBeepUpdate(contactID: outgoingContactID, beep: outgoingBeep)],
                now: .now
            )
        )

        #expect(transition.state.syncState.incomingBeeps[incomingContactID]?.beepId == "incoming-1")
        #expect(transition.state.syncState.outgoingBeeps[outgoingContactID]?.beepId == "outgoing-1")
        #expect(transition.state.syncState.requestContactIDs == [incomingContactID, outgoingContactID])
    }

    @Test func selectedConversationReducerSuppressesInterruptedCopyDuringBackendRestore() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )
        let requestedState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingBeep(requestCount: 1)),
            .baseStateUpdated(.outgoingBeep),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .outgoingBeep,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false,
                        hasOutgoingBeep: true
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let acceptedGap = [
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        ].reduce(requestedState) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        #expect(acceptedGap.interruptedConnectionAttemptContactID == nil)
        #expect(acceptedGap.selectedConversationState.phase == .idle)
        #expect(acceptedGap.selectedConversationState.statusMessage == "Avery is online")

        let backendRestoreCandidate = SelectedConversationReducer.reduce(
            state: acceptedGap,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: true
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        ).state

        #expect(backendRestoreCandidate.reconciliationAction == .restoreDevicePTTSession(contactID: contactID))
        #expect(backendRestoreCandidate.selectedConversationState.phase == .waitingForPeer)
        #expect(backendRestoreCandidate.selectedConversationState.statusMessage == "Connecting...")

        let restoreTransition = SelectedConversationReducer.reduce(
            state: backendRestoreCandidate,
            event: .reconcileRequested
        )
        #expect(restoreTransition.effects == [.restoreDevicePTTSession(contactID: contactID)])

        let restoreInFlight = SelectedConversationReducer.reduce(
            state: restoreTransition.state,
            event: .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        ).state

        #expect(restoreInFlight.selectedConversationState.phase == .waitingForPeer)
        #expect(restoreInFlight.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerDoesNotProjectDisconnectingWhileBackendJoinIsSettling() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let transition = SelectedConversationReducer.reduce(
            state: .initial,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .none,
                    baseState: .idle,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .idle,
                            canTransmit: false,
                            selfJoined: false,
                            peerJoined: false,
                            peerDeviceConnected: false
                        )
                    ),
                    isJoined: true,
                    activeChannelID: contactID,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    senderAutoJoinOnBeepAcceptanceEnabled: true,
                    localTransmit: .idle,
                    remoteParticipantSignalIsTransmitting: false,
                    systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
                    systemSessionMatchesContact: true,
                    mediaState: .idle,
                    localRelayTransportReady: true,
                    directMediaPathActive: false,
                    incomingWakeActivationState: nil,
                    backendConvergence: BackendConversationConvergenceState(joinPhase: .settling),
                    localJoinFailure: nil
                )
            )
        )

        #expect(transition.state.devicePTTContinuityProjection == .connected)
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.detail == .waitingForPeer(reason: .devicePTTTransition))
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerKeepsRecentLeaveBackendReadySnapshotDisconnecting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )
        let readyChannel = ChannelReadinessSnapshot(
            channelState: makeChannelState(
                status: .ready,
                canTransmit: true,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            readiness: makeChannelReadiness(
                status: .ready,
                selfHasActiveDevice: true,
                peerHasActiveDevice: true,
                remoteAudioReadiness: .ready,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
            )
        )

        let connected = SelectedConversationReducer.reduce(
            state: .initial,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .none,
                    baseState: .ready,
                    channel: readyChannel,
                    isJoined: true,
                    activeChannelID: contactID,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    senderAutoJoinOnBeepAcceptanceEnabled: true,
                    localTransmit: .idle,
                    remoteParticipantSignalIsTransmitting: false,
                    systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
                    systemSessionMatchesContact: true,
                    mediaState: .connected,
                    localRelayTransportReady: true,
                    directMediaPathActive: false,
                    incomingWakeActivationState: nil,
                    localJoinFailure: nil
                )
            )
        ).state

        #expect(connected.hadConnectedDevicePTTContinuity)

        let staleBackendReady = SelectedConversationReducer.reduce(
            state: connected,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .none,
                    baseState: .ready,
                    channel: readyChannel,
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    senderAutoJoinOnBeepAcceptanceEnabled: true,
                    localTransmit: .idle,
                    remoteParticipantSignalIsTransmitting: false,
                    systemSessionState: .none,
                    systemSessionMatchesContact: false,
                    mediaState: .idle,
                    localRelayTransportReady: true,
                    directMediaPathActive: false,
                    incomingWakeActivationState: nil,
                    devicePTTRestoreBarrier: .recentSystemLeave(
                        contactID: contactID,
                        channelUUID: channelUUID,
                        reason: "recent-system-leave"
                    ),
                    localJoinFailure: nil
                )
            )
        ).state

        #expect(staleBackendReady.devicePTTContinuityProjection == .disconnecting)
        #expect(staleBackendReady.reconciliationAction == .none)
        #expect(staleBackendReady.selectedConversationState.detail == .waitingForPeer(reason: .disconnecting))

        let reconcile = SelectedConversationReducer.reduce(
            state: staleBackendReady,
            event: .reconcileRequested
        )

        #expect(reconcile.effects.isEmpty)
    }

    @Test func selectedConversationReducerUsesBackendReadyOnlyAfterLocalAlignment() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let waitingEvents: [SelectedConversationEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let waitingState = reduceSelectedConversationState(waitingEvents)
        #expect(waitingState.selectedConversationState.phase == .waitingForPeer)
        #expect(waitingState.selectedConversationState.canTransmitNow == false)

        let joinedState = SelectedConversationReducer.reduce(
            state: waitingState,
            event: .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        ).state
        let readyState = SelectedConversationReducer.reduce(
            state: joinedState,
            event: .mediaStateUpdated(.connected)
        ).state
        let receiverReadyState = SelectedConversationReducer.reduce(
            state: readyState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            )
        ).state

        #expect(receiverReadyState.selectedConversationState.phase == .ready)
        #expect(receiverReadyState.selectedConversationState.statusMessage == "Connected")
        #expect(receiverReadyState.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerSuppressesInterruptedRetryCopyWhenWakeCapableRecoveryRemains() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let readyState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        var recoveringState = readyState
        recoveringState.devicePTT.localSession = .absent
        recoveringState.devicePTT.systemSessionState = .none
        recoveringState.devicePTT.systemSessionMatchesContact = false
        recoveringState.connection.mediaState = .closed
        recoveringState.backendReadiness.channel = ChannelReadinessSnapshot(
            channelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: false,
                peerDeviceConnected: false
            ),
            readiness: makeChannelReadiness(
                status: .waitingForPeer,
                selfHasActiveDevice: true,
                peerHasActiveDevice: false,
                remoteAudioReadiness: .unknown,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
            )
        )
        recoveringState.interruptedConnectionAttemptContactID = contactID

        let recoveredState = SelectedConversationReducer.reduce(
            state: recoveringState,
            event: .channelUpdated(recoveringState.backendReadiness.channel)
        ).state

        #expect(recoveredState.selectedConversationState.phase == .waitingForPeer)
        #expect(recoveredState.selectedConversationState.phase != .localJoinFailed)
        #expect(recoveredState.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerPrefersTransmitPhaseOverWakeReadyWhileLocallyTransmitting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.transmitting),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedConversationState.phase == .transmitting)
        #expect(state.selectedConversationState.statusMessage == "Talking to Avery")
    }

    @Test func selectedConversationReducerStoresLayeredProjectionForConnectedTransmit() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .transmitting, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.transmitting),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.devicePTTContinuityProjection == .connected)
        #expect(state.connectedExecutionProjection == .transmitting)
        #expect(state.connectedControlPlaneProjection == .transmitting)
        #expect(state.selectedConversationState.phase == .transmitting)
    }

    @Test func selectedConversationReducerUsesWakePhaseWhileLocalTransmitIsStillStarting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.starting(.awaitingSystemTransmit)),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.idle)
        ])

        #expect(state.selectedConversationState.phase == .startingTransmit)
        #expect(state.selectedConversationState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerClearsSenderAutoJoinShortcutWhenBackendFallsBackToAbsentChannelWithoutBeep() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        var armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state
        armedState.senderAutoJoinOnBeepAcceptanceDispatchInFlight = true

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedConversationState.phase == .idle)
        #expect(transition.state.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerKeepsConnectingWhileSenderAutoJoinBackendConnectIsQueued() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingBeep: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let readyTransition = SelectedConversationReducer.reduce(
            state: SelectedConversationReducer.reduce(
                state: armedState,
                event: .relationshipUpdated(.none)
            ).state,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: true
                    )
                )
            )
        )

        let queuedBackendConnect = SelectedConversationReducer.reduce(
            state: readyTransition.state,
            event: .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.requestingBackend(contactID: contactID)),
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        )

        #expect(queuedBackendConnect.effects.isEmpty)
        #expect(queuedBackendConnect.state.selectedConversationState.phase == .waitingForPeer)
        #expect(queuedBackendConnect.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!queuedBackendConnect.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerReconcileRequestClearsStaleBackendMembership() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .inactive,
                        selfHasActiveDevice: false,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.clearStaleBackendMembership(contactID: contactID)])
    }

    @Test func selectedConversationReducerReconcileRequestPreservesInFlightWaitingPeerAudioMembership() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .inactive,
                        selfHasActiveDevice: false,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .waiting,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedConversationReducerReconcileRequestTeardownsTerminalBackendAbsence() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.teardownDevicePTTSession(contactID: contactID)])
    }

    @Test func selectedConversationReducerReconcileRequestTeardownsTerminalBackendAbsenceWithOnlyStaleWakeToken() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.teardownDevicePTTSession(contactID: contactID)])
    }

    @Test func contactSummaryFallsBackToLegacyHandleForPublicIdentityFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "beepThreadProjection": {
                "kind": "none",
                "requestCount": 0
              },
              "summaryStatus": {
                "kind": "online",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "both",
                "peerDeviceConnected": true
              },
              "isActiveConversation": false,
              "badgeStatus": "online"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.publicId == "@blake")
        #expect(summary.profileName == "Blake")
    }

    @Test func channelStateDecodeFailsForInvalidMembershipPayload() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "membership": {
                "kind": "both"
              },
              "beepThreadProjection": {
                "kind": "incoming",
                "requestCount": 4
              },
              "conversationStatus": {
                "kind": "self-transmitting",
                "activeTransmitterUserId": "self"
              },
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail for invalid membership payload")
        } catch {
        }
    }

    @Test func transmitLeaseResponsesDecodeTransmitId() throws {
        let beginData = Data(
            """
            {
              "channelId": "channel",
              "status": "self-transmitting",
              "transmitId": "transmit-1",
              "startedAt": "2026-05-09T10:00:00Z",
              "expiresAt": "2026-05-09T10:00:30Z",
              "targetUserId": "peer",
              "targetDeviceId": "peer-device"
            }
            """.utf8
        )
        let renewData = Data(
            """
            {
              "channelId": "channel",
              "status": "self-transmitting",
              "transmitId": "transmit-1",
              "startedAt": "2026-05-09T10:00:00Z",
              "expiresAt": "2026-05-09T10:01:00Z"
            }
            """.utf8
        )

        let begin = try JSONDecoder().decode(TurboBeginTransmitResponse.self, from: beginData)
        let renew = try JSONDecoder().decode(TurboRenewTransmitResponse.self, from: renewData)

        #expect(begin.transmitId == "transmit-1")
        #expect(renew.transmitId == "transmit-1")
    }

    @MainActor
    @Test func backendJoinPlanUsesExistingLocalMembershipAsJoinSessionForReadyFriendJoin() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "peer",
            existingBackendChannelID: "channel",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let channel = ChannelReadinessSnapshot(
            channelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            readiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true,
                remoteAudioReadiness: .wakeCapable
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: channel
        )

        #expect(plan == .joinConversation)
    }

    @MainActor
    @Test func backendJoinOperationIDsSeparateConnectAndJoinCommands() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )

        let connect = viewModel.backendConnectOperationID(for: contact, intent: .requestConnection)
        let nextConnect = viewModel.backendConnectOperationID(for: contact, intent: .requestConnection)
        let join = viewModel.backendChannelJoinOperationID(for: contact, intent: .requestConnection)

        #expect(connect != nil)
        #expect(join != nil)
        #expect(connect != nextConnect)
        #expect(connect?.contains(contactID.uuidString.lowercased()) == true)
        #expect(connect?.contains("peer-user") == true)
        #expect(join?.contains("channel-123") == true)
        #expect(viewModel.backendConnectOperationID(for: contact, intent: .joinReadyFriend) == nil)
    }

    @Test func channelSnapshotPrefersBackendReadinessProjection() {
        let channelState = makeChannelState(status: .ready, canTransmit: true)
        let readiness = makeChannelReadiness(status: .waitingForSelf)

        let snapshot = ChannelReadinessSnapshot(channelState: channelState, readiness: readiness)

        #expect(snapshot.readinessStatus == .waitingForSelf)
        #expect(snapshot.status == .waitingForPeer)
        #expect(snapshot.canTransmit == false)
    }

    @Test func transmitReducerPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        )

        #expect(transition.state.phase == .requesting(contactID: request.contactID))
        #expect(transition.state.isPressingTalk)
        #expect(transition.effects == [.beginTransmit(request)])
    }

    @Test func transmitReducerSystemPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .systemPressRequested(request)
        )

        #expect(transition.state.phase == .requesting(contactID: request.contactID))
        #expect(transition.state.isPressingTalk)
        #expect(transition.effects == [.beginTransmit(request)])
    }

    @Test func transmitReducerBeginSuccessEmitsActivationWhileStillPressing() {
        let request = makeTransmitRequest()
        let requestingState = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        ).state
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let transition = TransmitReducer.reduce(
            state: requestingState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state.phase == .active(contactID: request.contactID))
        #expect(transition.state.activeTarget == target)
        #expect(transition.effects == [.activateTransmit(request, target)])
    }

    @Test func transmitReducerReleaseAfterGrantEmitsStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .releaseRequested
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitReducerSystemEndedWhileActiveEmitsStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitExecutionReducerIgnoresDuplicateSystemEnd() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        let state = TransmitExecutionSessionState(
            latchedTarget: target,
            pressState: .pressing,
            stopIntent: .none,
            systemTransmitState: .transmitting(startedAt: Date(timeIntervalSince1970: 100))
        )

        let firstEnd = TransmitExecutionReducer.reduce(
            state: state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: true,
                matchingActiveTarget: target
            )
        )
        let duplicateEnd = TransmitExecutionReducer.reduce(
            state: firstEnd.state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: true,
                matchingActiveTarget: target
            )
        )

        #expect(firstEnd.effects == [.handledSystemTransmitEnded(.requireFreshPress(contactID: target.contactID))])
        #expect(duplicateEnd.effects.isEmpty)
        #expect(duplicateEnd.state == firstEnd.state)
    }

    @Test func transmitRuntimeAllowsSystemTransmitActivationRetryAfterActivationReset() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBegan()

        let firstActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        runtime.clearSystemTransmitActivation(channelUUID: channelUUID)
        let activationAfterReset = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(firstActivationStart)
        #expect(activationAfterReset)
    }

    @Test func transmitReducerSystemEndedDuringStoppingDoesNotDuplicateStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let stoppingState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(
                state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
                event: .beginSucceeded(target, request)
            ).state,
            event: .releaseRequested
        ).state

        let transition = TransmitReducer.reduce(
            state: stoppingState,
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitReducerIgnoresStaleStopCompletionForNewerActiveTransmit() {
        let contactID = UUID()
        let staleTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123",
            transmitID: "transmit-1"
        )
        let currentTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123",
            transmitID: "transmit-2"
        )
        let activeState = TransmitSessionState(
            phase: .active(contactID: contactID),
            isPressingTalk: true,
            pendingRequest: nil,
            activeTarget: currentTarget,
            lastError: nil
        )

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .stopCompleted(staleTarget)
        )

        #expect(transition.state == activeState)
        #expect(transition.effects.isEmpty)
        #expect(transition.invariantViolationsEmitted == ["transmit.stale_end_overrides_newer_epoch"])
    }

    @Test func transmitRuntimePreservesLatchedTargetWhilePressRemainsActive() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == true)
        #expect(runtime.activeTarget == target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
    }

    @Test func transmitRuntimeReconcileIdleStateClearsStalePressAndTargetButKeepsStopLatch() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )
        runtime.markExplicitStopRequested()

        runtime.reconcileIdleState()

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
        #expect(runtime.explicitStopRequested)
    }

    @Test func transmitRuntimeFreshPressClearsPreviousStopLatch() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.markExplicitStopRequested()
        runtime.markPressEnded()
        runtime.reconcileIdleState()

        runtime.markPressBegan()

        #expect(runtime.isPressingTalk)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimePressEndKeepsLatchedTargetUntilCoordinatorClearsIt() {
        var runtime = TransmitRuntimeState()
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(target)

        #expect(runtime.activeTarget == target)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimeInitialOutboundAudioSendGateSurvivesReleaseUntilFirstSend() {
        var runtime = TransmitRuntimeState()

        runtime.markPressBegan()
        runtime.markPressEnded()

        let firstTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        let secondTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()

        #expect(firstTake)
        #expect(!secondTake)
    }

    @Test func transmitRuntimeInitialOutboundAudioSendGateConsumesOncePerPress() {
        var runtime = TransmitRuntimeState()

        let initialTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(!initialTake)

        runtime.markPressBegan()

        let firstPressTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        let repeatedTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()

        #expect(firstPressTake)
        #expect(!repeatedTake)

        runtime.markPressEnded()
        let postReleaseTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(!postReleaseTake)

        runtime.reconcileIdleState()
        runtime.markPressBegan()

        let nextPressTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(nextPressTake)
    }

    @Test func transmitRuntimeExplicitStopDoesNotRearmPress() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )

        runtime.markExplicitStopRequested()
        runtime.markPressEnded()
        runtime.syncActiveTarget(runtime.activeTarget)

        #expect(runtime.explicitStopRequested)
        #expect(runtime.isPressingTalk == false)
    }

    @Test func transmitTaskRuntimeCancelBeginTaskCancelsTaskAndClearsReference() async {
        let runtime = TransmitTaskRuntimeState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        runtime.replaceBeginTask(with: task, id: 1)
        runtime.cancelBeginTask(matching: 1)

        #expect(runtime.beginTask == nil)
        #expect(task.isCancelled)
        _ = await task.result
    }

    @Test func transmitTaskRuntimeCancelRenewTaskCancelsTaskAndClearsTarget() async {
        let runtime = TransmitTaskRuntimeState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        runtime.replaceRenewalTask(with: task, id: 7, target: target)
        runtime.cancelRenewalTask(matching: 7)

        #expect(runtime.renewalTask == nil)
        #expect(runtime.renewalChannelID == nil)
        #expect(task.isCancelled)
        _ = await task.result
    }

    @Test func transmitTaskReducerResetCancelsBeginAndRenewal() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "peer-device",
            channelID: request.backendChannelID
        )
        let state = TransmitTaskSessionState(
            begin: .running(id: 1, request: request),
            renewal: .running(id: 2, target: target),
            nextWorkID: 3
        )

        let transition = TransmitTaskReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(transition.state == TransmitTaskSessionState())
        #expect(
            transition.effects == [
                .cancelBegin,
                .cancelRenewal
            ]
        )
    }

    @Test func transmitTaskReducerCancelBeginOnlyCancelsBeginWork() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "peer-device",
            channelID: request.backendChannelID
        )
        let state = TransmitTaskSessionState(
            begin: .running(id: 1, request: request),
            renewal: .running(id: 2, target: target),
            nextWorkID: 3
        )

        let transition = TransmitTaskReducer.reduce(
            state: state,
            event: .cancelBegin
        )

        #expect(transition.state.begin == .idle)
        #expect(transition.state.renewal == .running(id: 2, target: target))
        #expect(transition.state.nextWorkID == 3)
        #expect(transition.effects == [.cancelBegin])
    }

    @Test func transmitTaskReducerKeepsExistingRenewalForSameTarget() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        let transition = TransmitTaskReducer.reduce(
            state: TransmitTaskSessionState(renewal: .running(id: 4, target: target), nextWorkID: 5),
            event: .renewalRequested(target)
        )

        #expect(transition.state.renewal == .running(id: 4, target: target))
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitTaskReducerIgnoresStaleRenewalFinishAfterReplacement() {
        let contactID = UUID()
        let oldTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device-old",
            channelID: "channel-123"
        )
        let newTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device-new",
            channelID: "channel-123"
        )

        let requestedTransition = TransmitTaskReducer.reduce(
            state: TransmitTaskSessionState(
                renewal: .running(id: 1, target: oldTarget),
                nextWorkID: 2
            ),
            event: .renewalRequested(newTarget)
        )

        #expect(requestedTransition.state.renewal == .running(id: 2, target: newTarget))
        #expect(
            requestedTransition.effects == [
                .cancelRenewal,
                .startRenewal(id: 2, target: newTarget)
            ]
        )

        let finishedTransition = TransmitTaskReducer.reduce(
            state: requestedTransition.state,
            event: .renewalFinished(id: 1)
        )

        #expect(finishedTransition.state.renewal == .running(id: 2, target: newTarget))
        #expect(finishedTransition.effects.isEmpty)
    }

    @MainActor
    @Test func systemTransmitClosesPrewarmedMediaSessionBeforeHandoff() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()

        #expect(viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func systemAudioActivationRefreshAbortPreventsCaptureStartAfterRelease() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.transmitRuntime.markPressEnded()
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        viewModel.isPTTAudioSessionActive = true

        await viewModel.startPendingSystemTransmitAudioCaptureIfPossible(
            channelUUID: channelUUID,
            trigger: "audio-session-activated"
        )

        #expect(!didStartBridge)
        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(mediaSession.abortSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-refreshed-after-system-activation"
            ) == nil
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @MainActor
    @Test func pendingSystemTransmitCaptureStartsAfterBackendLeasePromotion() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectedForControlCommandTesting(sessionID: "session-1")
        client.enableSentSignalCaptureForTesting()

        viewModel.applicationStateOverride = .background
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .backgroundAppPress)
        )
        viewModel.isPTTAudioSessionActive = true
        mediaSession.startSendingAudioDelayNanoseconds = 100_000_000

        await viewModel.startPendingSystemTransmitAudioCaptureIfPossible(
            channelUUID: channelUUID,
            trigger: "audio-session-activated"
        )
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-deferred-until-backend-lease"
            ) != nil
        )

        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.syncTransmitState()
        await viewModel.completeSystemTransmitActivation(channelUUID: channelUUID)

        #expect(viewModel.transmitCoordinator.state.pendingRequest == nil)
        #expect(viewModel.transmitCoordinator.state.activeTarget == target)
        #expect(mediaSession.startSendingAudioCallCount == 1)
        #expect(mediaSession.abortSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-start-completed"
            ) != nil
        )
        #expect(!viewModel.diagnosticsTranscript.contains("Cancelled stale pending system transmit audio capture"))
    }

    @MainActor
    @Test func touchReleaseCancelsPendingSystemTransmitHandoffImmediately() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        viewModel.endTransmit()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.stopTransmitRequests == [channelUUID])
        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cancelling requested system transmit handoff"
            )
        )
    }

    @MainActor
    @Test func systemTransmitActivationContinuationCancelsAfterRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )

        #expect(
            viewModel.shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "test-before-release"
            )
        )

        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.transmitRuntime.markPressEnded()
        await viewModel.transmitCoordinator.handle(.releaseRequested)

        #expect(
            !viewModel.shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "test-after-release"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cancelled stale system transmit activation continuation"
            )
        )

        _ = viewModel.shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "audio-capture-start-completed"
        )
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @MainActor
    @Test func systemTransmitActivationContinuesWhenRuntimePressLatchWasLostButCoordinatorStillPressing() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )
        viewModel.transmitRuntime.markPressEnded()

        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(viewModel.hasActiveTransmitPressIntent())
        #expect(
            viewModel.shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "test-lost-runtime-latch"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Cancelled stale system transmit activation continuation"
            )
        )
    }

    @MainActor
    @Test func currentPendingTransmitCanActivateWhenBeginTaskStateWasCleared() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.transmitRuntime.markPressBegan()
        await viewModel.transmitCoordinator.handle(.pressRequested(request))

        #expect(viewModel.transmitTaskCoordinator.state.begin.request == nil)
        #expect(
            viewModel.shouldActivateBackendTransmitLease(
                request: request,
                workID: 999
            )
        )
    }

    @MainActor
    @Test func pendingSystemHandoffCanActivateWhenRuntimePressLatchWasLost() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(
            viewModel.shouldActivateBackendTransmitLease(
                request: request,
                workID: 999
            )
        )

        viewModel.transmitRuntime.markExplicitStopRequested()
        #expect(
            !viewModel.shouldActivateBackendTransmitLease(
                request: request,
                workID: 999
            )
        )
    }

    @Test func transmitReducerReleaseBeforeGrantCancelsPendingBeginAndIgnoresLateGrant() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let releasedState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .releaseRequested
        ).state

        #expect(releasedState.phase == .idle)
        #expect(releasedState.pendingRequest == nil)
        #expect(releasedState.isPressingTalk == false)

        let transition = TransmitReducer.reduce(
            state: releasedState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state == releasedState)
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitReducerSystemBeginFailureAbortsWithoutPeerStopSignal() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .systemBeginFailed("PTChannelError(rawValue: 1)")
        )

        #expect(transition.state.phase == .idle)
        #expect(!transition.state.isPressingTalk)
        #expect(transition.state.activeTarget == nil)
        #expect(transition.effects == [.abortTransmit(target)])
    }

    @MainActor
    @Test func backendSelfTransmittingProjectionDoesNotOverrideExplicitStop() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            !viewModel.shouldAcceptBackendLocalTransmitProjection(
                backendShowsLocalTransmit: true,
                refreshedContactID: contactID,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .stopping(contactID: contactID),
                    isPressActive: false,
                    explicitStopRequested: true,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.transmitting.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .stopping(contactID: contactID),
                    isPressActive: false,
                    explicitStopRequested: true,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendSelfTransmittingProjectionDoesNotReviveIdleLocalTransmitAfterRelease() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let idleSnapshot = TransmitDomainSnapshot(
            phase: .idle,
            isPressActive: false,
            explicitStopRequested: false,
            isSystemTransmitting: false,
            activeTarget: nil,
            interruptedContactID: nil,
            requiresReleaseBeforeNextPress: false
        )

        #expect(
            !viewModel.shouldAcceptBackendLocalTransmitProjection(
                backendShowsLocalTransmit: true,
                refreshedContactID: contactID,
                transmitSnapshot: idleSnapshot
            )
        )
        #expect(
            !viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.transmitting.rawValue,
                transmitSnapshot: idleSnapshot
            )
        )
    }

    @Test func selectedConversationStateDisablesHoldToTalkWhileStoppingWithoutBackendTransmitAuthority() {
        let contactID = UUID()
        let channelState = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: "self",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.transmitting.rawValue,
            canTransmit: false
        )
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .stopping,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            directMediaPathActive: true,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(channelState: channelState, readiness: nil)
        )

        let selected = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selected.phase == .ready)
        #expect(selected.detail == .readyHoldToTalkDisabled)
        #expect(selected.statusMessage == "Connected")
        #expect(selected.canTransmitNow == false)
        #expect(selected.allowsHoldToTalk == false)
    }

    @Test func selectedConversationStateKeepsReadyAboveStaleBackendSelfTransmittingProjectionAfterRelease() {
        let contactID = UUID()
        let channelState = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: "self",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.transmitting.rawValue,
            canTransmit: false
        )
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .idle,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            directMediaPathActive: true,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(channelState: channelState, readiness: nil)
        )

        let selected = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selected.phase == .ready)
        #expect(selected.detail == .ready)
        #expect(selected.statusMessage == "Connected")
        #expect(selected.canTransmitNow == false)
    }

    @MainActor
    @Test func activeSelfTransmittingRefreshPreservesExistingPeerMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existing = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )
        let incoming = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: "self",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.transmitting.rawValue,
            canTransmit: true
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.transmitting.rawValue)
    }

    @MainActor
    @Test func failedOrClosedMediaSessionIsRecreatedBeforeReuse() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldRecreateMediaSession(connectionState: .failed("send failed")))
        #expect(viewModel.shouldRecreateMediaSession(connectionState: .closed))
        #expect(!viewModel.shouldRecreateMediaSession(connectionState: .connected))
    }

    @MainActor
    @Test func backendTransmitLeaseParserHandlesNanosecondBackendInstants() {
        let viewModel = PTTViewModel()
        let now = Date(timeIntervalSince1970: 1_778_059_200.250)

        let remaining = viewModel.backendTransmitLeaseRemainingSeconds(
            expiresAt: "2026-05-06T09:20:05.750000000Z",
            now: now
        )

        #expect(remaining.map { abs($0 - 5.5) < 0.001 } == true)
    }

    @MainActor
    @Test func backendTransmitLeaseGrantNearExpiryRequiresImmediateRenewal() {
        let viewModel = PTTViewModel()
        let now = Date(timeIntervalSince1970: 1_778_059_200)

        #expect(
            viewModel.backendTransmitLeaseNeedsImmediateRenewal(
                expiresAt: "2026-05-06T09:20:02.000000000Z",
                now: now
            )
        )
        #expect(
            !viewModel.backendTransmitLeaseNeedsImmediateRenewal(
                expiresAt: "2026-05-06T09:20:05.000000000Z",
                now: now
            )
        )
    }

    @MainActor
    @Test func localTransmitClearsSystemRemoteParticipantBeforeHandoff() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test"
        )

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == nil)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func systemTransmitBeginWhilePeerTransmittingIsRejected() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user"),
                    remoteAudioReadiness: .waiting
                )
            )
        )

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.stopTransmitRequests == [channelUUID])
        #expect(viewModel.transmitCoordinator.state.phase == .idle)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk == false)
        #expect(viewModel.transmitRuntime.isSystemTransmitting == false)
        #expect(viewModel.diagnosticsTranscript.contains("[ptt.system_begin_while_peer_transmitting]"))
        #expect(viewModel.diagnosticsTranscript.contains("Rejected system transmit begin while peer is active"))
    }

    @MainActor
    @Test func localTransmitClearRemoteParticipantCodeFiveIsNotAnError() async {
        let pttClient = RecordingPTTSystemClient()
        pttClient.activeRemoteParticipantError = NSError(domain: PTChannelErrorDomain, code: 5)
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test"
        )

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped remote participant clear because no active remote participant was present"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Failed to clear active remote participant before local transmit"
            )
        )
    }

    @MainActor
    @Test func localTransmitRemoteParticipantClearCanTimeOut() async {
        let pttClient = RecordingPTTSystemClient()
        pttClient.activeRemoteParticipantDelayNanoseconds = 500_000_000
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        let cleared = await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test",
            timeoutNanoseconds: 10_000_000
        )

        #expect(cleared == false)
        #expect(viewModel.diagnosticsTranscript.contains(
            "Timed out clearing active remote participant before local transmit"
        ))
    }

    @Test func selectedConversationStateUsesLocalTransmitWhileBackendRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: true,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        #expect(selectedConversationState.phase == .transmitting)
    }

    @Test func selectedConversationStateUsesConnectingStatusBeforeLeaseArrives() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .requesting(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .startingTransmit)
        #expect(selectedConversationState.detail == .startingTransmit(stage: .requestingLease))
        #expect(selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationStateUsesConnectingStatusWhileAwaitingSystemTransmitStart() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .startingTransmit)
        #expect(selectedConversationState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationStateUsesConnectingStatusAfterSystemTransmitBegins() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .startingTransmit)
        #expect(selectedConversationState.detail == .startingTransmit(stage: .awaitingAudioSession))
        #expect(selectedConversationState.statusMessage == "Connecting...")
    }

    @MainActor
    @Test func conversationContextTreatsLocalPressLatchAsTransmitIntent() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        await viewModel.transmitCoordinator.handle(.pressRequested(request))

        let context = viewModel.conversationContext(for: viewModel.contacts[0])

        #expect(context.localIsTransmitting)
        #expect(viewModel.isTransmitting == false)
    }

    @Test func selectedConversationStateRequiresReleaseAfterInterruptedTransmitInsteadOfWakeReady() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            localIsStopping: false,
            localRequiresFreshPress: true,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .waitingForPeer)
        #expect(selectedConversationState.statusMessage == "Release and press again.")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.label == "Release To Retry")
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedConversationStateWaitsForSystemWakeActivationBeforeShowingReceivingFromBackendProjection() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .waitingForPeer)
        #expect(selectedConversationState.detail == .waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedConversationState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedConversationState.canTransmitNow == false)
    }

    @Test func selectedConversationStateRequiresLocalAudioPrewarmBeforeHoldToTalkIsEnabled() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            localMediaWarmupState: .prewarming,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .waitingForPeer)
        #expect(selectedConversationState.statusMessage == "Connecting...")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedConversationStateKeepsWakeReadyWhenBackendReadyDuringPostReceiveMediaClose() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .closed,
            localMediaWarmupState: .cold,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .wakeReady)
        #expect(selectedConversationState.statusMessage == "Hold to talk to wake Blake")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(selectedConversationState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled)
    }

    @Test func selectedConversationStateKeepsWakeReadyWhileLocalAudioPrewarmsAfterReceive() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            localMediaWarmupState: .prewarming,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .wakeReady)
        #expect(selectedConversationState.statusMessage == "Hold to talk to wake Blake")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(selectedConversationState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled)
    }

    @MainActor
    @Test func wakeReceiveTimingSummaryIncludesActivationAndPlaybackStages() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        viewModel.recordWakeReceiveTiming(
            stage: "incoming-push-result-active-participant-returned",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmitting-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .websocket
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmit-prepare-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .websocket
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmit-refresh-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .backend
        )
        viewModel.recordWakeReceiveTiming(
            stage: "active-remote-participant-requested",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "active-remote-participant-completed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "direct-quic-audio-received",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )
        viewModel.pttWakeRuntime.bufferAudioChunk("AQI=", for: contactID)
        viewModel.recordWakeReceiveTiming(
            stage: "first-audio-buffered",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            ifAbsent: true
        )
        viewModel.pttWakeRuntime.markAudioSessionActivated(for: channelUUID)
        viewModel.recordWakeReceiveTiming(
            stage: "system-audio-activation-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )
        viewModel.recordWakeReceiveTiming(
            stage: "first-playback-buffer-scheduled",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            ifAbsent: true
        )
        viewModel.recordWakeReceiveTimingSummary(
            reason: "test",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )

        let summary = viewModel.diagnostics.entries.first {
            $0.message == "Wake receive timing summary"
        }
        #expect(summary != nil)
        #expect(summary?.metadata["reason"] == "test")
        #expect(summary?.metadata["incoming-push-result-active-participant-returnedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmit-prepare-observedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmit-refresh-observedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmitting-observedMs"] != nil)
        #expect(summary?.metadata["active-remote-participant-requestedMs"] != nil)
        #expect(summary?.metadata["active-remote-participant-completedMs"] != nil)
        #expect(summary?.metadata["direct-quic-audio-receivedMs"] != nil)
        #expect(summary?.metadata["first-audio-bufferedMs"] != nil)
        #expect(summary?.metadata["system-audio-activation-observedMs"] != nil)
        #expect(summary?.metadata["first-playback-buffer-scheduledMs"] != nil)
        #expect(summary?.metadata["wakeToSystemActivationDeltaMs"] != nil)
        #expect(summary?.metadata["firstBufferedToFirstPlaybackScheduledDeltaMs"] != nil)
        #expect(summary?.metadata["activeParticipantRequestedToDidActivateMs"] != nil)
        #expect(summary?.metadata["activeParticipantCompletedToDidActivateMs"] != nil)
        #expect(summary?.metadata["firstAudioToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerPrepareToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerRefreshToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerTransmitToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["incomingPushResultToDidActivateMs"] != nil)
    }

    @Test func wakeExecutionReducerBuffersAudioAndTracksActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let storedState = WakeExecutionReducer.reduce(
            state: WakeExecutionSessionState(),
            event: .store(
                PendingIncomingPTTPush(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: payload
                )
            ),
            maximumBufferedAudioChunks: 12
        ).state
        let bufferedState = WakeExecutionReducer.reduce(
            state: storedState,
            event: .bufferAudioChunk(contactID: contactID, payload: "AQI="),
            maximumBufferedAudioChunks: 12
        ).state
        let activatedState = WakeExecutionReducer.reduce(
            state: bufferedState,
            event: .markAudioSessionActivated(channelUUID: channelUUID),
            maximumBufferedAudioChunks: 12
        ).state

        #expect(bufferedState.bufferedAudioChunkCount(for: contactID) == 1)
        #expect(bufferedState.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(activatedState.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(activatedState.mediaSessionActivationMode(for: contactID) == .systemActivated)
    }

    @Test func wakeExecutionReducerInterruptCancelsPlaybackFallbackTask() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let awaitingState = WakeExecutionReducer.reduce(
            state: WakeExecutionSessionState(),
            event: .store(
                PendingIncomingPTTPush(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: payload,
                    hasConfirmedIncomingPush: true,
                    activationState: .awaitingSystemActivation
                )
            ),
            maximumBufferedAudioChunks: 12
        ).state
        let transition = WakeExecutionReducer.reduce(
            state: awaitingState,
            event: .markSystemActivationInterruptedByTransmitEnd(contactID: contactID),
            maximumBufferedAudioChunks: 12
        )

        #expect(
            transition.effects == [
                .cancelPlaybackFallbackTask(contactID: contactID)
            ]
        )
        #expect(
            transition.state.incomingWakeActivationState(for: contactID)
                == .systemActivationInterruptedByTransmitEnd
        )
        #expect(transition.state.pendingIncomingPush == nil)
    }

    @Test func wakeExecutionReducerClearAllCanPreserveSuppression() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let suppressedState = WakeExecutionReducer.reduce(
            state: WakeExecutionReducer.reduce(
                state: WakeExecutionSessionState(),
                event: .store(
                    PendingIncomingPTTPush(
                        contactID: contactID,
                        channelUUID: channelUUID,
                        payload: payload
                    )
                ),
                maximumBufferedAudioChunks: 12
            ).state,
            event: .suppressProvisionalWakeCandidate(contactID: contactID),
            maximumBufferedAudioChunks: 12
        ).state
        let transition = WakeExecutionReducer.reduce(
            state: suppressedState,
            event: .clearAll(clearSuppression: false),
            maximumBufferedAudioChunks: 12
        )

        #expect(transition.effects == [.cancelAllPlaybackFallbackTasks])
        #expect(transition.state.pendingIncomingPush == nil)
        #expect(transition.state.shouldSuppressProvisionalWakeCandidate(for: contactID))
    }

    @Test func receiveExecutionReducerSchedulesAndClearsRemoteActivity() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(transition.state.remoteTransmittingContactIDs == [contactID])
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 1
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: false)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(transition.effects == [.cancelRemoteSilenceTimeout(contactID: contactID)])
    }

    @Test func receiveAudioEpochBeginsOnlyForNewTransmitControl() {
        let contactID = UUID()
        var state = ReceiveExecutionSessionState()

        #expect(
            state.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitStartSignal
            )
        )

        state = ReceiveExecutionReducer.reduce(
            state: state,
            event: .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        ).state
        #expect(
            !state.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitStartSignal
            )
        )
        #expect(
            !state.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitPrepareSignal
            )
        )

        state = ReceiveExecutionReducer.reduce(
            state: state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        ).state
        #expect(
            !state.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitStartSignal
            )
        )

        state = ReceiveExecutionReducer.reduce(
            state: state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        ).state
        #expect(
            state.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitStartSignal
            )
        )

        let incomingPushState = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .incomingPush)
        ).state
        #expect(
            incomingPushState.shouldBeginRemoteAudioEpoch(
                contactID: contactID,
                source: .transmitStartSignal
            )
        )
    }

    @Test func receiveExecutionReducerPreservesPlaybackDrainAfterTransmitStop() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )
        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    phase: .drainingAudio,
                    activityGeneration: 2
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 2
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    phase: .drainingAudio,
                    activityGeneration: 3
                )
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        )

        #expect(transition.state.remoteTransmittingContactIDs == [contactID])
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    phase: .awaitingFirstAudioChunk,
                    activityGeneration: 4
                )
        )
    }

    @Test func receiveExecutionReducerTreatsLateAudioAfterObservedStopAsPlaybackDrain() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )
        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        )
        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .silenceTimeoutElapsed(contactID: contactID)
        )
        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(transition.state.remoteTransmitStoppedContactIDs == [contactID])
        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    phase: .drainingAudio,
                    activityGeneration: 1
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 1
                    )
                ]
        )
    }

    @Test func receiveExecutionReducerUsesExtendedInitialTimeoutUntilFirstAudioChunkArrives() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .incomingPush)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .incomingPush,
                    phase: .awaitingFirstAudioChunk,
                    activityGeneration: 1
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .awaitingFirstAudioChunk,
                        generation: 1
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    phase: .awaitingFirstAudioChunk,
                    activityGeneration: 2
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .awaitingFirstAudioChunk,
                        generation: 2
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    phase: .receivingAudio,
                    activityGeneration: 3
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 3
                    )
                ]
        )
    }

    @Test func receiveExecutionReducerResetCancelsSilenceTimeouts() {
        let contactID = UUID()
        let state = ReceiveExecutionSessionState(
            remoteActivityByContactID: [
                contactID: RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    phase: .awaitingFirstAudioChunk,
                    activityGeneration: 1
                )
            ]
        )

        let transition = ReceiveExecutionReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(transition.effects == [.cancelAllRemoteSilenceTimeouts])
    }

    @MainActor
    @Test func staleRemoteAudioSilenceTimerDoesNotClearNewerAudioGeneration() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.remoteAudioSilenceTimeoutNanoseconds = 40_000_000
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        let staleGeneration = viewModel.receiveExecutionCoordinator
            .state
            .remoteActivityByContactID[contactID]?
            .activityGeneration

        #expect(staleGeneration == 1)

        if let staleGeneration {
            viewModel.runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: .drainingAudio,
                    generation: staleGeneration
                )
            )
        }

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        #expect(
            viewModel.receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID]?
                .activityGeneration == 2
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Remote audio activity timed out"
            )
        )
    }

    @MainActor
    @Test func appActivationResumesInteractiveAudioPrewarmForAlignedSelectedConversation() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        await viewModel.resumeInteractiveAudioPrewarmIfNeeded(
            reason: "test",
            applicationState: .active
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func localTransmitRecoveryCancelsDeferredInteractiveAudioPrewarm() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        viewModel.transmitRuntime.markPressBegan()

        await viewModel.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
            for: contactID,
            applicationState: .active
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cancelled deferred interactive audio prewarm for local transmit"
            )
        )
    }

    @Test func interactiveMediaSessionAudioPolicyUsesPlayAndRecord() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .interactive
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .interactive
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(appManaged.shouldActivateSession == true)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func playbackOnlyMediaSessionAudioPolicyActivatesOnlyWhenAppManaged() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(appManaged.shouldActivateSession == true)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func audioChunkPayloadCodecPreservesLegacySingleChunkPayload() {
        let decoded = AudioChunkPayloadCodec.decode("chunk-1")

        #expect(decoded == ["chunk-1"])
    }

    @Test func audioChunkPayloadCodecRoundTripsBatchedPayloads() {
        let encoded = AudioChunkPayloadCodec.encode(["chunk-1", "chunk-2", "chunk-3"])
        let decoded = AudioChunkPayloadCodec.decode(encoded)

        #expect(decoded == ["chunk-1", "chunk-2", "chunk-3"])
    }

    @Test func mediaRuntimeResetKeepsPeerOpusCapabilityEvidence() {
        let contactID = UUID()
        let runtime = MediaRuntimeState()
        let opusCapabilities = VoiceMediaCapabilities(
            codecs: [VoiceMediaCapabilities.opusCodec],
            features: [VoiceMediaCapabilities.opusFrameV2Feature]
        )

        _ = runtime.markVoiceMediaCapabilities(
            opusCapabilities,
            for: contactID,
            peerDeviceID: "peer-device",
            source: "direct-quic-receiver-prewarm-ack"
        )
        runtime.reset()

        #expect(runtime.voiceMediaCapabilityEvidence(for: contactID)?.capabilities.supportsOpusV2 == true)
        let expectedPolicy: VoiceMediaPayloadFormat = OpusVoiceCodec.isAvailable() ? .opusV2 : .legacyPCM
        #expect(runtime.outboundVoiceMediaPayloadFormat(for: contactID) == expectedPolicy)
    }

    @MainActor
    @Test func outboundVoiceMediaPolicyDefaultsToLocalOpusCapability() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let matchingTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-1"
        )
        let mismatchedTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "other-peer-device",
            channelID: "channel-1"
        )
        let expectedPolicy: VoiceMediaPayloadFormat = OpusVoiceCodec.isAvailable() ? .opusV2 : .legacyPCM

        #expect(viewModel.outboundVoiceMediaPayloadFormat(for: matchingTarget) == expectedPolicy)
        #expect(viewModel.outboundVoiceMediaPayloadFormat(for: mismatchedTarget) == expectedPolicy)
    }

    @MainActor
    @Test func mediaSessionShellUsesFreshContactOpusEvidenceBeforeActiveTransmitTarget() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            )
        ]
        _ = viewModel.mediaRuntime.markVoiceMediaCapabilities(
            VoiceMediaCapabilities(
                codecs: [VoiceMediaCapabilities.opusCodec],
                features: [VoiceMediaCapabilities.opusFrameV2Feature]
            ),
            for: contactID,
            peerDeviceID: "peer-device",
            source: "receiver-ready"
        )
        let expectedPolicy: VoiceMediaPayloadFormat = OpusVoiceCodec.isAvailable() ? .opusV2 : .legacyPCM

        #expect(viewModel.prepareMediaSessionShellIfNeeded(for: contactID, reason: "test"))
        let preparedEntry = viewModel.diagnostics.entries.last {
            $0.message == "Media session shell prepared"
        }

        #expect(preparedEntry?.metadata["voiceMediaPolicy"] == expectedPolicy.rawValue)
    }

    @Test func playbackBufferReceivePlanStartsNodeWithoutDuplicatingCurrentBuffer() {
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: true
            ) == .scheduleAndStartNode
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: true,
                playbackIOCycleAvailable: true
            ) == .scheduleOnly
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: false
            ) == .deferUntilIOCycle
        )
    }

    @Test func systemActivatedPlaybackOnlyPrimesPlaybackNodeOnce() {
        #expect(
            PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .playbackOnly,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .appManaged,
                startupMode: .playbackOnly,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .interactive,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .playbackOnly,
                playbackAlreadyReady: true
            )
        )
    }

    @Test func playbackNodeReassertionDoesNotReplayWhenNodeIsAlreadyPlaying() {
        #expect(
            !PCMWebSocketMediaSession.shouldReassertPlaybackNode(
                isPlayerNodePlaying: true,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 3
            )
        )
        #expect(
            PCMWebSocketMediaSession.shouldReassertPlaybackNode(
                isPlayerNodePlaying: false,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 1
            )
        )
        #expect(
            PCMWebSocketMediaSession.shouldReassertPlaybackNode(
                isPlayerNodePlaying: false,
                pendingPlaybackBufferCount: 1,
                scheduledPlaybackBufferCount: 0
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldReassertPlaybackNode(
                isPlayerNodePlaying: false,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 0
            )
        )
    }

    @Test func lowLatencyPlaybackCushionKeepsSmallFloorWhenPlaybackDrains() {
        #expect(
            PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: .lowLatency,
                cushionPolicy: .applyTransportCushion,
                receivePlan: .scheduleOnly,
                isPlayerNodePlaying: true,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 0,
                minimumCushionBufferCount: 2
            )
        )
        #expect(
            PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: .lowLatency,
                cushionPolicy: .applyTransportCushion,
                receivePlan: .scheduleOnly,
                isPlayerNodePlaying: true,
                pendingPlaybackBufferCount: 1,
                scheduledPlaybackBufferCount: 0,
                minimumCushionBufferCount: 2
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: .lowLatency,
                cushionPolicy: .applyTransportCushion,
                receivePlan: .scheduleOnly,
                isPlayerNodePlaying: true,
                pendingPlaybackBufferCount: 2,
                scheduledPlaybackBufferCount: 0,
                minimumCushionBufferCount: 2
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: .lowLatency,
                cushionPolicy: .applyTransportCushion,
                receivePlan: .scheduleOnly,
                isPlayerNodePlaying: true,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 1,
                minimumCushionBufferCount: 2
            )
        )
        #expect(
            PCMWebSocketMediaSession.shouldBufferForPlaybackCushion(
                playbackProfile: .lowLatency,
                cushionPolicy: .applyTransportCushion,
                receivePlan: .scheduleAndStartNode,
                isPlayerNodePlaying: false,
                pendingPlaybackBufferCount: 0,
                scheduledPlaybackBufferCount: 0,
                minimumCushionBufferCount: 2
            )
        )
    }

    @Test func playbackDrainWaitsUntilDataPlayedBack() {
        #expect(PCMWebSocketMediaSession.playbackCompletionCallbackType == .dataPlayedBack)
    }

    @Test func capturedAudioBufferCopyIsIndependentForAsyncProcessing() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: 1,
                interleaved: true
            )
        )
        let source = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(VoiceFrameAccumulator.samplesPerFrame)
            )
        )
        source.frameLength = AVAudioFrameCount(VoiceFrameAccumulator.samplesPerFrame)
        let sourceSamples = try #require(source.int16ChannelData?.pointee)
        for index in 0..<VoiceFrameAccumulator.samplesPerFrame {
            sourceSamples[index] = Int16(index % Int(Int16.max))
        }

        let copied = try #require(PCMWebSocketMediaSession.copyAudioPCMBuffer(source))
        let copiedSamples = try #require(copied.int16ChannelData?.pointee)
        #expect(copied.frameLength == source.frameLength)
        #expect(copiedSamples[10] == sourceSamples[10])

        sourceSamples[10] = -1234

        #expect(copiedSamples[10] != sourceSamples[10])
        #expect(copiedSamples[10] == 10)
    }

    @Test func pcmLevelMetricsDetectsSilentAndNonSilentInt16Buffers() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let silentBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        silentBuffer.frameLength = 4

        let silentMetrics = try #require(PCMLevelMetrics.forBuffer(silentBuffer))
        #expect(silentMetrics.sampleCount == 4)
        #expect(silentMetrics.nonZeroSampleCount == 0)
        #expect(silentMetrics.isSilent)
        #expect(silentMetrics.diagnosticMetadata["pcmSilent"] == "true")

        let signalBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        signalBuffer.frameLength = 4
        let signalData = try #require(signalBuffer.int16ChannelData?.pointee)
        signalData[0] = 0
        signalData[1] = 16_384
        signalData[2] = -16_384
        signalData[3] = 8_192

        let signalMetrics = try #require(PCMLevelMetrics.forBuffer(signalBuffer))
        #expect(signalMetrics.sampleCount == 4)
        #expect(signalMetrics.nonZeroSampleCount == 3)
        #expect(!signalMetrics.isSilent)
        #expect(signalMetrics.peak == 0.5)
        #expect(signalMetrics.diagnosticMetadata["pcmSilent"] == "false")
    }

    @Test func pcmLevelMetricsDetectsSilentAndNonSilentInt16PayloadData() throws {
        let silentData = Data(count: 4 * MemoryLayout<Int16>.size)
        let silentMetrics = try #require(PCMLevelMetrics.forInt16PCMData(silentData))
        #expect(silentMetrics.sampleCount == 4)
        #expect(silentMetrics.nonZeroSampleCount == 0)
        #expect(silentMetrics.isSilent)

        let samples: [Int16] = [0, 16_384, -16_384, 8_192]
        let signalData = samples.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: samples.count * MemoryLayout<Int16>.size
            )
        }
        let signalMetrics = try #require(PCMLevelMetrics.forInt16PCMData(signalData))
        #expect(signalMetrics.sampleCount == 4)
        #expect(signalMetrics.nonZeroSampleCount == 3)
        #expect(!signalMetrics.isSilent)
        #expect(signalMetrics.peak == 0.5)
    }

    @Test func audioChunkSenderWaitsForShortPacketizationWindowUntilBatchIsFull() {
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 1,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 3,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 4,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 0,
                maximumPayloadsPerMessage: 4
            )
        )
    }

    @Test func audioChunkSenderBuffersSinglePayloadForShortPacketizationWindow() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func snapshot() -> [String] {
                payloads
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in },
            maximumPayloadsPerMessage: 4,
            payloadBatchCollectionNanoseconds: 220_000_000
        )

        async let enqueue: Void = sender.enqueue("chunk-1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let transportPayloads = await recorder.snapshot()
        #expect(transportPayloads.isEmpty)

        _ = await enqueue
        try? await Task.sleep(nanoseconds: 300_000_000)

        let flushedPayloads = await recorder.snapshot()
        #expect(flushedPayloads == ["chunk-1"])
    }

    @Test func audioChunkSenderDropsOldestQueuedPayloadsUnderBackpressure() async {
        actor Gate {
            var isOpen = false
            var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func open() {
                isOpen = true
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                for continuation in waiting {
                    continuation.resume()
                }
            }
        }

        actor Recorder {
            var payloads: [String] = []
            var events: [String] = []
            var metadataByEvent: [String: [[String: String]]] = [:]

            func appendPayload(_ payload: String) {
                payloads.append(payload)
            }

            func appendEvent(_ event: String, metadata: [String: String]) {
                events.append(event)
                metadataByEvent[event, default: []].append(metadata)
            }

            func firstMetadata(for event: String) -> [String: String]? {
                metadataByEvent[event]?.first
            }
        }

        let gate = Gate()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await gate.wait()
                await recorder.appendPayload(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: 3,
            maximumPayloadsPerMessage: 1
        )

        let firstSend = Task {
            await sender.enqueue("chunk-0")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let queuedSends = (1...6).map { index in
            Task {
                await sender.enqueue("chunk-\(index)")
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await gate.open()
        await firstSend.value
        for queuedSend in queuedSends {
            await queuedSend.value
        }
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let deliveredPayloads = await recorder.payloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-0", "chunk-4", "chunk-5", "chunk-6"])
        #expect(await recorder.events.contains("Dropped stale outbound audio transport payload"))
        let dropMetadata = await recorder.firstMetadata(
            for: "Dropped stale outbound audio transport payload"
        )
        #expect(dropMetadata?["contractKind"] == "liveness")
        #expect(dropMetadata?["invariantID"] == "media.outbound_audio_transport_backpressure_drop")
        #expect(dropMetadata?["maximumPendingPayloads"] == "3")
        #expect(dropMetadata?["pendingPayloadCount"] == "3")
        #expect(dropMetadata?["reason"] == "outbound-transport-backpressure")
        #expect(dropMetadata?["scope"] == "local")
    }

    @Test func audioChunkSenderExpiresTimedOutInFlightSendAndResumesFreshAudio() async {
        actor Delay {
            var shouldDelayNextSend = true

            func delayFirstSend() async throws {
                guard shouldDelayNextSend else { return }
                shouldDelayNextSend = false
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        actor Recorder {
            var payloads: [String] = []
            var metadataByEvent: [String: [[String: String]]] = [:]

            func appendPayload(_ payload: String) {
                payloads.append(payload)
            }

            func appendEvent(_ event: String, metadata: [String: String]) {
                metadataByEvent[event, default: []].append(metadata)
            }

            func firstMetadata(for event: String) -> [String: String]? {
                metadataByEvent[event]?.first
            }
        }

        let delay = Delay()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                try await delay.delayFirstSend()
                try Task.checkCancellation()
                await recorder.appendPayload(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: 8,
            maximumPayloadsPerMessage: 1,
            maximumInFlightSends: 1,
            sendTimeoutNanoseconds: 260_000_000,
            dropsPendingPayloadsAfterSlowSend: true
        )

        let firstSend = Task {
            await sender.enqueue("chunk-0")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let staleQueuedSend = Task {
            await sender.enqueue(["chunk-stale-1", "chunk-stale-2"])
        }
        await firstSend.value
        await staleQueuedSend.value
        await sender.enqueue("chunk-fresh")
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let deliveredPayloads = await recorder.payloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-fresh"])

        let slowMetadata = await recorder.firstMetadata(
            for: "Outbound audio transport send was slow"
        )
        #expect(slowMetadata?["invariantID"] == "media.outbound_audio_transport_send_slow")
        #expect(slowMetadata?["pendingPayloadCount"] == "0")
        let dropMetadata = await recorder.firstMetadata(
            for: "Dropped stale outbound audio transport payload"
        )
        #expect(dropMetadata?["invariantID"] == "media.outbound_audio_transport_slow_send_drop")
        #expect(dropMetadata?["droppedPayloadCount"] == "2")
    }

    @Test func audioChunkSenderAllowsBoundedInFlightPacketSends() async {
        actor Gate {
            var isOpen = false
            var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func open() {
                isOpen = true
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                for continuation in waiting {
                    continuation.resume()
                }
            }
        }

        actor Recorder {
            var startedPayloads: [String] = []
            var completedPayloads: [String] = []

            func recordStarted(_ payload: String) {
                startedPayloads.append(payload)
            }

            func recordCompleted(_ payload: String) {
                completedPayloads.append(payload)
            }
        }

        let gate = Gate()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.recordStarted(payload)
                await gate.wait()
                await recorder.recordCompleted(payload)
            },
            reportFailure: { _ in },
            maximumPendingPayloads: 8,
            maximumPayloadsPerMessage: 1,
            maximumInFlightSends: 4
        )

        let enqueueTask = Task {
            await sender.enqueue((0..<8).map { "chunk-\($0)" })
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.startedPayloads.count == 4)
        #expect(await recorder.completedPayloads.isEmpty)

        await gate.open()
        await enqueueTask.value
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let deliveredPayloads = await recorder.completedPayloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads.count == 8)
        #expect(Set(deliveredPayloads) == Set((0..<8).map { "chunk-\($0)" }))
    }

    @Test func audioChunkSenderDropsStopTailAfterBoundedDrain() async {
        actor Gate {
            var isOpen = false
            var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func open() {
                isOpen = true
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                for continuation in waiting {
                    continuation.resume()
                }
            }
        }

        actor Recorder {
            var startedPayloads: [String] = []
            var completedPayloads: [String] = []
            var metadataByEvent: [String: [[String: String]]] = [:]

            func recordStarted(_ payload: String) {
                startedPayloads.append(payload)
            }

            func recordCompleted(_ payload: String) {
                completedPayloads.append(payload)
            }

            func appendEvent(_ event: String, metadata: [String: String]) {
                metadataByEvent[event, default: []].append(metadata)
            }

            func firstMetadata(for event: String) -> [String: String]? {
                metadataByEvent[event]?.first
            }
        }

        let gate = Gate()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.recordStarted(payload)
                await gate.wait()
                try Task.checkCancellation()
                await recorder.recordCompleted(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: 8,
            maximumPayloadsPerMessage: 1,
            maximumInFlightSends: 1
        )

        let enqueueTask = Task {
            await sender.enqueue((0..<5).map { "chunk-\($0)" })
        }

        for _ in 0..<100 {
            if await recorder.startedPayloads == ["chunk-0"] { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await recorder.startedPayloads == ["chunk-0"])

        let drained = await sender.finishDraining(
            pollNanoseconds: 1_000_000,
            timeoutNanoseconds: 40_000_000
        )
        #expect(!drained)

        await gate.open()
        await enqueueTask.value
        try? await Task.sleep(nanoseconds: 5_000_000)

        #expect(await recorder.completedPayloads.isEmpty)
        let dropMetadata = await recorder.firstMetadata(
            for: "Dropped stale outbound audio transport payload"
        )
        #expect(dropMetadata?["invariantID"] == "media.outbound_audio_transport_slow_send_drop")
        #expect(dropMetadata?["droppedPayloadCount"] == "4")
        #expect(dropMetadata?["cancelledInFlightSendCount"] == "1")
        #expect(dropMetadata?["reason"] == "outbound-transport-stop-drain-timeout")
    }

    @Test func audioChunkSenderReportsNonContractStopDrainTimeoutWhenOnlyInFlightSendIsCancelled() async {
        actor Gate {
            var isOpen = false
            var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func open() {
                isOpen = true
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                for continuation in waiting {
                    continuation.resume()
                }
            }
        }

        actor Recorder {
            var startedPayloads: [String] = []
            var completedPayloads: [String] = []
            var metadataByEvent: [String: [[String: String]]] = [:]

            func recordStarted(_ payload: String) {
                startedPayloads.append(payload)
            }

            func recordCompleted(_ payload: String) {
                completedPayloads.append(payload)
            }

            func appendEvent(_ event: String, metadata: [String: String]) {
                metadataByEvent[event, default: []].append(metadata)
            }

            func firstMetadata(for event: String) -> [String: String]? {
                metadataByEvent[event]?.first
            }
        }

        let gate = Gate()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.recordStarted(payload)
                await gate.wait()
                try Task.checkCancellation()
                await recorder.recordCompleted(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, metadata in
                await recorder.appendEvent(message, metadata: metadata)
            },
            maximumPendingPayloads: 8,
            maximumPayloadsPerMessage: 1,
            maximumInFlightSends: 1
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-0")
        }

        for _ in 0..<100 {
            if await recorder.startedPayloads == ["chunk-0"] { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await recorder.startedPayloads == ["chunk-0"])

        let drained = await sender.finishDraining(
            pollNanoseconds: 1_000_000,
            timeoutNanoseconds: 40_000_000
        )
        #expect(!drained)

        await gate.open()
        await enqueueTask.value
        try? await Task.sleep(nanoseconds: 5_000_000)

        #expect(await recorder.completedPayloads.isEmpty)
        let dropMetadata = await recorder.firstMetadata(
            for: "Dropped stale outbound audio transport payload"
        )
        #expect(dropMetadata == nil)

        let drainMetadata = await recorder.firstMetadata(
            for: "Outbound audio transport stop drain timed out"
        )
        #expect(drainMetadata?["cancelledInFlightSendCount"] == "1")
        #expect(drainMetadata?["reason"] == "outbound-transport-stop-drain-timeout")
        #expect(drainMetadata?["invariantID"] == nil)
        #expect(drainMetadata?["contractKind"] == nil)
    }

    @Test func audioChunkSenderFinishDrainingWaitsForQueuedPayloadsToFlush() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func snapshot() -> [String] {
                payloads
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                try? await Task.sleep(nanoseconds: 120_000_000)
                await recorder.append(payload)
            },
            reportFailure: { _ in }
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-1")
            await sender.enqueue("chunk-2")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finishTask = Task {
            await sender.finishDraining(pollNanoseconds: 5_000_000)
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(await recorder.snapshot().isEmpty)

        await finishTask.value
        await enqueueTask.value

        let deliveredPayloads = await recorder.snapshot().flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-1", "chunk-2"])
    }

    @Test func audioChunkSenderFinishDrainingFlushesPartialBatchWithoutWaitingForFullBatchWindow() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func count() -> Int {
                payloads.count
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in },
            payloadBatchCollectionNanoseconds: 1_000_000_000
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-1")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        await sender.finishDraining(pollNanoseconds: 1_000_000)
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
        await enqueueTask.value

        #expect(await recorder.count() == 1)
        #expect(elapsedNanoseconds < 500_000_000)
    }

    @Test func captureSendStateStopsAcceptingNewBuffersDuringDrain() {
        let nowNanoseconds: UInt64 = 2_000_000_000
        let state = CaptureSendState.stopping(
            graceDeadlineNanoseconds: nowNanoseconds + 120_000_000
        )

        #expect(
            !CaptureSendState.shouldAcceptCapturedBuffer(
                state,
                nowNanoseconds: nowNanoseconds + 40_000_000
            )
        )
        #expect(
            !CaptureSendState.shouldAcceptCapturedBuffer(
                state,
                nowNanoseconds: nowNanoseconds + 121_000_000
            )
        )
    }

    @MainActor
    @Test func transmitPrepareArmsReceiverWakeWithoutMarkingRemoteTalking() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-prepare"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.payload.event == .transmitStart)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
        #expect(
            viewModel.pttWakeRuntime.timing.elapsedMilliseconds(
                for: "backend-peer-transmit-prepare-observed"
            ) != nil
        )
    }

    @MainActor
    @Test func transmitStartAfterPrepareDoesNotReassertSameSystemRemoteParticipant() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-prepare"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.map(\.name) == ["Blake"])

        viewModel.isPTTAudioSessionActive = true
        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-start"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.map(\.name) == ["Blake"])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped duplicate active remote participant set"
            )
        )
    }

    @MainActor
    @Test func channelRefreshPeerTransmittingArmsReceiverWakeWithoutMarkingRemoteTalking() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let channelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: "peer-user",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let readiness = makeChannelReadiness(
            status: .peerTransmitting(activeTransmitterUserId: "peer-user"),
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        await viewModel.prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
            contactID: contactID,
            effectiveChannelState: channelState,
            effectiveChannelReadiness: readiness
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.payload.event == .transmitStart)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
        #expect(
            viewModel.pttWakeRuntime.timing.elapsedMilliseconds(
                for: "backend-peer-transmit-refresh-observed"
            ) != nil
        )
    }

    @MainActor
    @Test func channelRefreshRecoversMissingTransmitStopWhilePreservingPlaybackDrain() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        let existingChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: "peer-user",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contactID, channelState: existingChannelState)
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user"),
                    remoteAudioReadiness: .ready
                )
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)

        let readyChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: existingChannelState,
            effectiveChannelState: readyChannelState
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contactID, channelState: readyChannelState)
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(!viewModel.selectedConversationState(for: contactID).canTransmitNow)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Recovered missing transmit-stop from channel refresh"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains("remote-audio:draining")
        )
    }

    @MainActor
    @Test func channelRefreshDoesNotRecoverMissingTransmitStopWhileWakeReceiveIsStillPending() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.isPTTAudioSessionActive = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .incomingPush)

        let connectingChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: connectingChannelState,
            effectiveChannelState: connectingChannelState
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Recovered missing transmit-stop from channel refresh"
            )
        )
    }

    @MainActor
    @Test func channelRefreshDoesNotSynthesizeTransmitStopFromLocalDirectReceiveOnly() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.isPTTAudioSessionActive = true
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitPrepareSignal)
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        let readyChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: readyChannelState,
            effectiveChannelState: readyChannelState
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Recovered missing transmit-stop from channel refresh"
            )
        )
        #expect(!viewModel.diagnosticsTranscript.contains("remote-audio:draining"))
    }

    @MainActor
    @Test func explicitTransmitStopClearsTalkingWhileDeferringReceiveTeardownUntilRemoteAudioDrain() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: ""
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring receive teardown until remote audio drain after transmit stop"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )
        #expect(pttClient.activeRemoteParticipantUpdates.isEmpty)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "duplicate"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )
        #expect(pttClient.activeRemoteParticipantUpdates.isEmpty)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
        #expect(pttClient.activeRemoteParticipantUpdates.map(\.name) == [nil])
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutDoesNotClosePlaybackWhilePeerStillTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user")
                )
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while peer transmit is authoritative"
            )
        )
        #expect(
            viewModel.diagnostics.invariantViolations.isEmpty
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func initialRemoteAudioTimeoutDoesNotClosePlaybackWhilePeerStillTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user")
                )
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .awaitingFirstAudioChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while peer transmit is authoritative"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func directQuicPrepareOnlyTimeoutDoesNotClosePlaybackWhileBackendPeerTransmitIsLive() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user")
                )
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitPrepareSignal)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .awaitingFirstAudioChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .prepared)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while peer transmit is authoritative"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutDoesNotClosePlaybackWhileLocalAudioIsDraining() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while playback is still draining"
            )
        )

        mediaSession.hasPendingPlaybackResult = false
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutSynthesizesMissingStopBeforePlaybackDrain() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-a-b",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )
        viewModel.syncEngineRemoteAudioReceived(
            originalPayload: "encrypted-audio-1",
            openedPayload: "pcm-audio-1",
            channelID: "channel-a-b",
            fromDeviceID: "peer-device",
            contactID: contactID,
            incomingAudioTransport: .directQuic,
            source: "test"
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs
                .contains(contactID)
        )
        if case .draining(let drain) = viewModel.engineSnapshot.receive {
            #expect(drain.epoch.prepare.channelID.rawValue == "channel-a-b")
        } else {
            Issue.record("expected missing stop timeout to move engine receive into playback drain")
        }
        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.selectedConversationState(for: contactID).detail == .readyHoldToTalkDisabled)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Synthesized missing remote transmit stop from audio silence timeout"
            )
        )

        mediaSession.hasPendingPlaybackResult = false
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.engineSnapshot.receive == .idle)
        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
    }

    @MainActor
    @Test func remoteAudioInitialChunkTimeoutClearsPreparedEngineWhenStopIsMissing() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-a-b",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineRemoteTransmitStarted(
            contactID: contactID,
            channelID: "channel-a-b",
            senderDeviceID: "peer-device",
            source: "test"
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .awaitingFirstAudioChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.engineSnapshot.receive == .idle)
        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs
                .contains(contactID)
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Synthesized missing remote transmit stop from audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func pendingPlaybackDrainKeepsSelectedConversationReadyWhileBlockingCounterTalk() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)

        let selectedConversationState = viewModel.selectedConversationState(for: contactID)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.statusMessage == "Connected")
        #expect(!selectedConversationState.canTransmitNow)
        #expect(!primaryAction.isEnabled)

        viewModel.beginTransmit()

        #expect(!viewModel.transmitRuntime.isPressingTalk)
        #expect(
            viewModel.diagnosticsTranscript.contains("peer-receive-still-draining")
        )
    }

    @MainActor
    @Test func playbackDrainDelegateClearsRemoteActivityAfterObservedTransmitStop() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)

        #expect(
            viewModel.receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID]?
                .phase == .drainingAudio
        )
        #expect(!viewModel.selectedConversationState(for: contactID).canTransmitNow)

        mediaSession.hasPendingPlaybackResult = false
        viewModel.mediaSessionDidDrainPendingPlayback(mediaSession)

        let selectedConversationState = viewModel.selectedConversationState(for: contactID)
        #expect(
            viewModel.receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID] == nil
        )
        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.canTransmitNow)
        #expect(viewModel.engineSnapshot.receive == .idle)
        #expect(viewModel.diagnosticsTranscript.contains("Remote playback drained"))
    }

    @MainActor
    @Test func stoppedRemoteTransmitDoesNotReviveReceivingFromStaleBackendPeerTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = false
        viewModel.backendRuntime.mode = "local-http"

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false,
                    activeTransmitId: "transmit-stale"
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user"),
                    remoteAudioReadiness: .ready,
                    activeTransmitId: "transmit-stale"
                )
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        let selectedConversationState = viewModel.selectedConversationState(for: contactID)
        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.detail == .readyHoldToTalkDisabled)
        #expect(selectedConversationState.statusMessage == "Connected")
        #expect(!selectedConversationState.canTransmitNow)
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.ready_while_backend_cannot_transmit"
            }
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)

        #expect(
            !viewModel.receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs
                .contains(contactID)
        )
        #expect(viewModel.selectedConversationState(for: contactID).phase == .receiving)
    }

    @MainActor
    @Test func lateAudioAfterObservedStopKeepsSelectedConversationReady() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"
        viewModel.remoteAudioPendingPlaybackDrainMaxNanoseconds = 80_000_000
        viewModel.remoteAudioNonAuthoritativePlaybackDrainMaxNanoseconds = 80_000_000

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
        mediaSession.hasPendingPlaybackResult = false
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteTransmitStoppedContactIDs
                .contains(contactID)
        )

        mediaSession.hasPendingPlaybackResult = true
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        let selectedConversationState = viewModel.selectedConversationState(for: contactID)
        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.statusMessage == "Connected")
        #expect(!selectedConversationState.canTransmitNow)
        #expect(viewModel.remoteTransmittingContactIDs.isEmpty)
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutSelfHealsStalePendingPlaybackDrain() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.remoteAudioPendingPlaybackDrainMaxNanoseconds = 80_000_000

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.receiving_stale_pending_playback_drain"
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutUsesShortDrainCapAfterPeerStoppedTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"
        viewModel.remoteAudioPendingPlaybackDrainMaxNanoseconds = 5_000_000_000
        viewModel.remoteAudioNonAuthoritativePlaybackDrainMaxNanoseconds = 80_000_000

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnostics.invariantViolations.isEmpty
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Kept receive media session warm after remote audio ended"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutPollsFrequentlyAfterPeerStoppedTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"
        viewModel.remoteAudioSilenceTimeoutNanoseconds = 1_500_000_000
        viewModel.remoteAudioNonAuthoritativePlaybackDrainPollNanoseconds = 50_000_000

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while playback is still draining"
            )
        )

        mediaSession.hasPendingPlaybackResult = false
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
    }

    @MainActor
    @Test func receiverReadyDuringPlaybackDrainDoesNotReassertTalkingProjection() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.backendRuntime.mode = "local-http"

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)

        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.canBeginTransmit(for: contactID) == false)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-preparing"
            )
        )

        await Task.yield()

        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.selectedConversationState(for: contactID).statusMessage == "Connected")
        #expect(viewModel.canBeginTransmit(for: contactID) == false)
    }

    @Test func remoteParticipantSignalWinsOverPlaybackDrainDuringBackendWaitingForPeerDrift() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .idle,
            remoteParticipantSignalIsTransmitting: true,
            remotePlaybackContinuity: .drainingBeforeStop,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: contactID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            directMediaPathActive: false,
            firstTalkStartupProfile: .relayWarm,
            incomingWakeActivationState: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(selectedConversationState.phase == .receiving)
        #expect(selectedConversationState.statusMessage == "Blake is talking")
        #expect(selectedConversationState.canTransmitNow == false)
    }

    @Test func remoteTransmitStopGraceProjectsConnectedDisabledWithoutBackendTransmitAuthority() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .idle,
            remoteParticipantSignalIsTransmitting: false,
            remotePlaybackContinuity: .stopped(projectionGraceActive: true),
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            directMediaPathActive: false,
            firstTalkStartupProfile: .relayWarm,
            incomingWakeActivationState: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.detail == .readyHoldToTalkDisabled)
        #expect(selectedConversationState.statusMessage == "Connected")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(!selectedConversationState.allowsHoldToTalk)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )
        #expect(!primaryAction.isEnabled)
        #expect(primaryAction.label == "Hold To Talk")
    }

    @Test func localTransmitStopProjectsReadyWithDisabledTalkAffordanceDuringBackendSettling() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .stopping,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            localRelayTransportReady: true,
            directMediaPathActive: false,
            firstTalkStartupProfile: .relayWarm,
            incomingWakeActivationState: nil,
            hadConnectedDevicePTTContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .transmitting,
                    canTransmit: false,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: nil),
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(selectedConversationState.phase == .ready)
        #expect(selectedConversationState.statusMessage == "Connected")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(selectedConversationState.allowsHoldToTalk == false)
        #expect(primaryAction.isEnabled == false)
    }

    @MainActor
    @Test func explicitTransmitStopClearsTalkingWhileDeferringReceiveTeardownAwaitingFirstAudioChunk() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: ""
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring receive teardown until remote audio drain after transmit stop"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .awaitingFirstAudioChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )
    }

    @MainActor
    @Test func interruptedWakeStateClearsAfterInteractiveMediaRecovers() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func delayedFirstAudioChunkKeepsWakeReceiveAliveUntilInitialGraceExpires() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.remoteAudioInitialChunkTimeoutNanoseconds = 300_000_000
        viewModel.remoteAudioSilenceTimeoutNanoseconds = 100_000_000
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        viewModel.markRemoteAudioActivity(for: contactID, source: .incomingPush)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.timeoutPhase
                == .drainingAudio
        )
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutClearsCompletedWakeState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
    }

    @MainActor
    @Test func transmitPrepareResetsWarmReceivePlayoutEpoch() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        viewModel.applicationStateOverride = .active
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: UUID().uuidString.lowercased(),
                channelId: "channel-123",
                fromDeviceId: "peer-device",
                reason: "transmit-system-handoff",
                directQuicAttemptId: "attempt-1"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mediaSession.beginReceiveEpochCallCount == 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Started remote audio receive epoch"
            )
        )
    }

    @MainActor
    @Test func transmitStartWithoutAudioOrStopExpiresRemoteTransmittingLatch() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.remoteAudioInitialChunkTimeoutNanoseconds = 300_000_000
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-begin"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))

        try await Task.sleep(nanoseconds: 350_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
    }

    @MainActor
    @Test func systemOriginatedBeginTransmitReassertsBackendJoinWhenDevicePTTEvidenceOutlivesBackendMembership() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .waitingForSelf)
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID && request.intent == .joinReadyFriend
            }
        )
    }

    @Test func wakePlaybackFallbackRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .active))
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .inactive) == false)
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .background) == false)
    }

    @MainActor
    @Test func wakePlaybackFallbackDefersUntilApplicationBecomesActive() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        var pendingPush = PendingIncomingPTTPush(
            contactID: contactID,
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        pendingPush.bufferedAudioChunks = ["AQI=", "AwQ="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.runWakePlaybackFallbackIfNeeded(
            for: contactID,
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .awaitingPTTActivation)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI=", "AwQ="])

        await viewModel.resumeBufferedWakePlaybackIfNeeded(
            reason: "test-active",
            applicationState: .active
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .appManagedFallback)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState != .idle)
    }

    @Test func mediaRuntimeDelaysRetryAfterRecentStartFailure() {
        let contactID = UUID()
        let context = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let runtime = MediaRuntimeState()

        runtime.markStartupInFlight(context)
        runtime.markStartupFailed(context, message: "session activation failed")

        #expect(runtime.connectionState == .failed("session activation failed"))
        #expect(runtime.shouldDelayRetry(for: context, cooldown: 0.75))
        #expect(runtime.shouldDelayRetry(for: context, now: Date().addingTimeInterval(1.0), cooldown: 0.75) == false)
    }

    @Test func selectedConversationStateUsesTransmitSignalWhileReceiverRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        #expect(selectedConversationState.phase == .receiving)
    }

    @MainActor
    @Test func selectedConversationJoinRequestDowngradesStaleFriendReadyWithoutBackendPeerMembership() async {
        let contactID = UUID()
        let coordinator = SelectedConversationCoordinator()
        var observedEffects: [SelectedConversationEffect] = []
        coordinator.effectHandler = { effect in
            observedEffects.append(effect)
        }

        coordinator.send(
            .selectedContactChanged(
                SelectedConversationSelection(
                    contactID: contactID,
                    contactName: "Blake",
                    contactIsOnline: true
                )
            )
        )
        coordinator.send(.relationshipUpdated(.none))
        coordinator.send(.baseStateUpdated(.waitingForPeer))
        coordinator.send(
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .unavailable
                    )
                )
            )
        )
        coordinator.send(
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            )
        )
        coordinator.send(.systemSessionUpdated(.none, matchesSelectedContact: false))

        #expect(coordinator.state.selectedConversationState.phase == .friendReady)

        await coordinator.handle(.joinRequested)

        #expect(observedEffects == [.requestConnection(contactID: contactID)])
    }

    @Test func selectedConversationStateShowsReceivingFromBackendTransmitWithoutSignalOrReadyAudio() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            remoteParticipantSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            incomingWakeActivationState: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)
        #expect(selectedConversationState.phase == .receiving)
        #expect(selectedConversationState.detail == .receiving)
        #expect(selectedConversationState.statusMessage == "Avery is talking")
    }

    @MainActor
    @Test func activeTransmitTargetMatchesSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func activeTransmitTargetRejectsMismatchedSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: UUID(),
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: UUID()) == nil)
    }

    @MainActor
    @Test func activeTransmitTargetFallsBackToLatchedRuntimeTargetWhilePressIsHeld() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncTransmitState()

        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func transmitProjectionDerivesRequestingPhaseFromLatchedRuntimeTarget() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncTransmitState()

        #expect(viewModel.transmitProjection.activeTarget == target)
        #expect(viewModel.transmitDomainSnapshot.phase == .requesting(contactID: contactID))
    }

    @MainActor
    @Test func syncTransmitStateClearsStaleIdlePressLatch() async {
        let viewModel = PTTViewModel()
        viewModel.transmitRuntime.markPressBegan()

        viewModel.syncTransmitState()

        #expect(viewModel.isTransmitPressActive == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitRuntime.activeTarget == nil)
    }

    @MainActor
    @Test func explicitTransmitStopFallbackClearsStaleSystemTransmittingState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                origin: .foregroundAppPress
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.pttCoordinator.state.isTransmitting)

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
    }

    @MainActor
    @Test func explicitTransmitStopLocalCompletionClearsCoordinatorAfterRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                origin: .foregroundAppPress
            )
        )
        await viewModel.transmitCoordinator.handle(
            .beginSucceeded(
                target,
                TransmitRequestContext(
                    contactID: contactID,
                    contactHandle: "@avery",
                    backendChannelID: "channel-avery",
                    remoteUserID: "user-avery",
                    channelUUID: channelUUID,
                    usesLocalHTTPBackend: false,
                    backendSupportsWebSocket: true
                )
            )
        )
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()
        viewModel.syncTransmitState()

        await viewModel.finalizeExplicitTransmitStopLocallyIfNeeded(
            target: target,
            source: "test-local-complete"
        )

        #expect(viewModel.transmitDomainSnapshot.hasTransmitIntent(for: contactID) == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        switch viewModel.transmitCoordinator.state.phase {
        case .idle:
            break
        case .requesting, .active, .stopping:
            Issue.record("Expected transmit coordinator to return to idle after local stop completion")
        }
    }

    @MainActor
    @Test func transmitDomainSnapshotSuppressesTransmitIntentAfterExplicitStop() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.syncTransmitState()

        let snapshot = viewModel.transmitDomainSnapshot

        #expect(snapshot.isPressActive == false)
        #expect(snapshot.hasTransmitIntent(for: contactID) == false)
        #expect(snapshot.isStopping(for: contactID))
    }

    @MainActor
    @Test func transmitDomainSnapshotTracksInterruptedHoldUntilRelease() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        let interruptedSnapshot = viewModel.transmitDomainSnapshot
        #expect(interruptedSnapshot.requiresFreshPress(for: contactID))
        #expect(interruptedSnapshot.hasTransmitIntent(for: contactID) == false)

        viewModel.transmitRuntime.noteTouchReleased()

        let releasedSnapshot = viewModel.transmitDomainSnapshot
        #expect(releasedSnapshot.requiresFreshPress(for: contactID) == false)
    }

    @Test func transmitRuntimeTracksSystemTransmitDurationAndClearsItOnEnd() {
        var runtime = TransmitRuntimeState()
        let beganAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 101.25)

        runtime.noteSystemTransmitBegan(at: beganAt)

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == 1250)

        runtime.noteSystemTransmitEnded()

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == nil)
    }

    @Test func transmitRuntimeTracksPendingSystemTransmitBeginState() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        #expect(runtime.pendingSystemBeginChannelUUID == channelUUID)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID))

        runtime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)

        #expect(runtime.pendingSystemBeginChannelUUID == nil)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID) == false)
    }

    @Test func transmitRuntimeHandleSystemTransmitEndedUsesReducerClassification() {
        var runtime = TransmitRuntimeState()
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        runtime.markPressBegan()
        runtime.syncActiveTarget(target)
        runtime.noteSystemTransmitBeginRequested(channelUUID: UUID())
        runtime.noteSystemTransmitBegan(at: Date(timeIntervalSince1970: 100))

        let disposition = runtime.handleSystemTransmitEnded(
            applicationStateIsActive: true,
            matchingActiveTarget: target
        )

        #expect(disposition == .requireFreshPress(contactID: target.contactID))
        #expect(runtime.requiresReleaseBeforeNextPress)
        #expect(runtime.activeTarget == target)
        #expect(runtime.pendingSystemBeginChannelUUID == nil)
        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: Date(timeIntervalSince1970: 101)) == nil)
    }

    @MainActor
    @Test func systemTransmitCallbacksClearPendingSystemBeginState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleFailedToBeginTransmitting(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 1)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)
    }

    @MainActor
    @Test func systemTransmitEndClearsPendingSystemOriginatedRequestBeforeBackendGrant() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitCoordinator.state.phase == .idle)
        #expect(viewModel.transmitCoordinator.state.pendingRequest == nil)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk == false)
    }

    @MainActor
    @Test func activeSystemTransmitEndStillRequiresFreshPressBarrier() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-avery",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-avery"
        )

        viewModel.applicationStateOverride = .active
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                origin: .foregroundAppPress
            )
        )
        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.noteSystemTransmitBegan()
        viewModel.syncPTTState()

        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")

        try await waitForScenario(
            "active system transmit end requires a fresh press",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.transmitDomainSnapshot.requiresFreshPress(for: contactID)
                && viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID)
        }

        let snapshot = viewModel.transmitDomainSnapshot
        #expect(snapshot.requiresFreshPress(for: contactID))
        #expect(snapshot.isPressActive == false)
        #expect(viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID))
    }

    @MainActor
    @Test func explicitTransmitStopFallbackIgnoresMismatchedChannel() async {
        let viewModel = PTTViewModel()
        let joinedContactID = UUID()
        let targetContactID = UUID()
        let joinedChannelUUID = UUID()
        let target = TransmitTarget(
            contactID: targetContactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: joinedContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: joinedChannelUUID,
                backendChannelId: "channel-joined",
                remoteUserId: "user-avery"
            ),
            Contact(
                id: targetContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: joinedChannelUUID,
                contactID: joinedContactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: joinedChannelUUID,
                origin: .foregroundAppPress
            )
        )
        viewModel.syncPTTState()

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting)
    }

    @Test func controlEventIngestorDeduplicatesReceiverPrewarmHintsAcrossLanes() {
        let contactID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: "request-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            reason: "direct-quic-activated",
            directQuicAttemptId: "attempt-1"
        )
        let mediaRelayEnvelope = ControlEventEnvelope.mediaRelayReceiverPrewarmAck(
            payload,
            contactID: contactID,
            localDeviceID: "local-device",
            timestamp: timestamp
        )
        let directQuicEnvelope = ControlEventEnvelope.directQuicReceiverPrewarmAck(
            payload,
            contactID: contactID,
            localDeviceID: "local-device",
            attemptID: "attempt-1",
            timestamp: timestamp
        )
        let ready = ControlEventIngestorReducer.reduce(
            state: .initial,
            event: .directQuicAttemptUpdated(contactID: contactID, attemptID: "attempt-1")
        )

        let first = ControlEventIngestorReducer.reduce(
            state: ready.state,
            event: .ingest(mediaRelayEnvelope)
        )
        let duplicate = ControlEventIngestorReducer.reduce(
            state: first.state,
            event: .ingest(directQuicEnvelope)
        )

        #expect(mediaRelayEnvelope.eventID == directQuicEnvelope.eventID)
        #expect(first.effects == [.dispatch(mediaRelayEnvelope)])
        #expect(duplicate.effects.isEmpty)
        #expect(duplicate.ignoredReason == .duplicateEvent(mediaRelayEnvelope.eventID!))
    }

    @Test func controlEventIngestorDeduplicatesAudioPlaybackAckAcrossLanes() {
        let contactID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let payload = TurboAudioPlaybackStartedPayload(
            ackId: "ack-1",
            channelId: "channel-1",
            senderDeviceId: "sender-device",
            receiverDeviceId: "receiver-device",
            transport: "direct-quic",
            transportDigest: "digest-1",
            encryptedSequenceNumber: nil,
            acceptedAtMilliseconds: 1_000
        )
        let mediaRelayEnvelope = ControlEventEnvelope.audioPlaybackStarted(
            payload,
            contactID: contactID,
            source: .mediaRelay,
            localDeviceID: "sender-device",
            remoteDeviceID: "receiver-device",
            timestamp: timestamp
        )
        let directQuicEnvelope = ControlEventEnvelope.audioPlaybackStarted(
            payload,
            contactID: contactID,
            source: .directQuicDataChannel,
            localDeviceID: "sender-device",
            remoteDeviceID: "receiver-device",
            attemptID: "attempt-1",
            timestamp: timestamp
        )

        let first = ControlEventIngestorReducer.reduce(
            state: .initial,
            event: .ingest(mediaRelayEnvelope)
        )
        let duplicate = ControlEventIngestorReducer.reduce(
            state: first.state,
            event: .ingest(directQuicEnvelope)
        )

        #expect(mediaRelayEnvelope.eventID == directQuicEnvelope.eventID)
        #expect(first.effects == [.dispatch(mediaRelayEnvelope)])
        #expect(duplicate.effects.isEmpty)
        #expect(duplicate.ignoredReason == .duplicateEvent(mediaRelayEnvelope.eventID!))
    }

    @Test func backendSyncReducerPollRefreshesSelectedChannelAfterBootstrapEstablished() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.connectionPhase = .connected(mode: "cloud", handle: "@avery")

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .pollRequested(selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshForegroundControlPlane(selectedContactID: contactID)
            ]
        )
    }

    @Test func backendSyncReducerIdleMarksStaleRemoteReceiverReadyWaitingWhenWakeCapable() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .webSocketStateChanged(.idle, selectedContactID: contactID)
        )

        #expect(
            transition.state.syncState.channelReadiness[contactID]?.remoteAudioReadiness
                == .waiting
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func backendSyncReducerIdleRefreshesSelectedConversationAfterBootstrapEstablished() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.connectionPhase = .connected(mode: "cloud", handle: "@avery")

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .webSocketStateChanged(.idle, selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
                .ensureWebSocketConnected,
                .refreshForegroundControlPlane(selectedContactID: contactID)
            ]
        )
    }

    @Test func backendSyncReducerIdleDropsStaleRemoteReceiverReadyWithoutWakeCapability() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .unavailable
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .webSocketStateChanged(.idle, selectedContactID: contactID)
        )

        #expect(
            transition.state.syncState.channelReadiness[contactID]?.remoteAudioReadiness
                == .unknown
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func receiverAudioReadinessSignalPayloadPreservesLegacyReasonPayloads() throws {
        let payload = ReceiverAudioReadinessSignalPayload.decode(from: "app-background-media-closed")

        #expect(payload.reason == .appBackgroundMediaClosed)
        #expect(payload.telemetry == nil)
    }

    @Test func receiverAudioReadinessReasonRoundTripsTypedWireValues() throws {
        let reasons: [ReceiverAudioReadinessReason] = [
            .appBackgroundMediaClosed,
            .audioRouteChange,
            .audioRoutePreference("speaker"),
            .backendReconnect,
            .backendSignalingRecovery,
            .channelRefresh,
            .directQuicReceiverPrewarm,
            .directQuicTransmitPrepare,
            .foregroundTalkPrewarm("startup"),
            .incomingPushForeground,
            .mediaState(.idle),
            .mediaState(.preparing),
            .mediaState(.connected),
            .mediaState(.closed),
            .networkChange,
            .pttSync,
            .pttWakePostActivationRefresh,
            .receiverPrewarmRequest,
            .remoteAudioEndedKeepalive,
            .telemetryRefresh,
            .websocketConnected,
            .legacy("future-reason")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for reason in reasons {
            let decoded = try decoder.decode(
                ReceiverAudioReadinessReason.self,
                from: encoder.encode(reason)
            )

            #expect(decoded == reason)
            #expect(ReceiverAudioReadinessReason(wireValue: reason.wireValue) == reason)
        }
    }

    @Test func receiverAudioReadinessSignalPayloadRoundTripsTelemetry() throws {
        let telemetry = ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 70),
            connection: .init(interface: .cellular)
        )
        let payload = ReceiverAudioReadinessSignalPayload(
            reason: .channelRefresh,
            telemetry: telemetry
        )

        let decoded = ReceiverAudioReadinessSignalPayload.decode(from: payload.wirePayload())

        #expect(decoded == payload)
    }

    @Test func controlPlaneReducerSuppressesReceiverReadyFromTransitionalMediaReason() {
        let contactID = UUID()
        let intent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .mediaState(.preparing),
            telemetry: nil
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.receiverAudioReadinessStates[contactID] == nil)
    }

    @Test func controlPlaneReducerRepublishesWhenPeerBecomesRoutableAfterSuppression() {
        let contactID = UUID()
        let intent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: nil
        )

        let firstTransition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: false,
                webSocketConnected: true
            )
        )

        #expect(
            firstTransition.state.receiverAudioReadinessStates[contactID]
                == .suppressed(intent.suppressedState)
        )
        #expect(firstTransition.effects.isEmpty)

        let secondTransition = ControlPlaneReducer.reduce(
            state: firstTransition.state,
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(secondTransition.effects == [.publishReceiverAudioReadiness(intent)])
    }

    @Test func controlPlaneReducerDoesNotRepublishWhenReceiverTelemetryChanges() {
        let contactID = UUID()
        let firstTelemetry = ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 70),
            connection: .init(interface: .wifi)
        )
        let changedTelemetry = ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 71),
            connection: .init(interface: .wifi)
        )
        let firstIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: firstTelemetry
        )
        let changedIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: changedTelemetry
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(firstIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                changedIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects.isEmpty)
    }

    @Test func controlPlaneReducerRepublishesWhenReceiverReadinessStateChanges() {
        let contactID = UUID()
        let readyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: nil
        )
        let notReadyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: false,
            reason: .mediaState(.closed),
            telemetry: nil
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(readyIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                notReadyIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects == [.publishReceiverAudioReadiness(notReadyIntent)])
    }

    @Test func controlPlaneReducerWebSocketIdlePreservesPublishedReceiverNotReady() {
        let contactID = UUID()
        let notReadyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: false,
            reason: .appBackgroundMediaClosed,
            telemetry: nil
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(notReadyIntent.publishedState)
                ]
            ),
            event: .webSocketStateChanged(.idle)
        )

        #expect(
            transition.state.receiverAudioReadinessStates[contactID]
                == .published(notReadyIntent.publishedState)
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func controlPlaneReducerWebSocketIdleClearsPublishedReceiverReady() {
        let contactID = UUID()
        let readyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: nil
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(readyIntent.publishedState)
                ]
            ),
            event: .webSocketStateChanged(.idle)
        )

        #expect(transition.state.receiverAudioReadinessStates[contactID] == nil)
        #expect(transition.effects.isEmpty)
    }

    @MainActor
    @Test func nonTransientBackendBootstrapFailureDoesNotRetry() {
        let viewModel = PTTViewModel()
        let error = TurboBackendError.invalidResponse

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .active
            ) == false
        )
    }

    @Test func backendRuntimeThrottlesPresenceHeartbeatSlots() {
        let runtime = BackendRuntimeState()
        let startedAt = Date(timeIntervalSince1970: 1_000)

        #expect(runtime.consumePresenceHeartbeatSlot(now: startedAt, minimumInterval: 4))
        #expect(runtime.consumePresenceHeartbeatSlot(now: startedAt + 1, minimumInterval: 4) == false)
        #expect(runtime.consumePresenceHeartbeatSlot(now: startedAt + 4, minimumInterval: 4))
    }

    @MainActor
    @Test func acceptingIncomingBeepProjectsConnectingBeforeBackendJoinCompletes() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: beep.channelId,
            remoteUserId: beep.fromUserId
        )
        viewModel.contacts = [contact]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        #expect(viewModel.acceptIncomingBeep(contact, reason: "test-accept"))

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.pendingConnectAcceptedIncomingBeepContactId == contactID)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
    }

    @MainActor
    @Test func clearedIncomingSummaryRemovesCountOnlyHandledSuppressionForNextBeep() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-avery",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]

        viewModel.backendSyncCoordinator.send(
            .incomingBeepHandled(
                contactID: contactID,
                beep: nil,
                requestCount: 1,
                now: .now
            )
        )

        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel-avery",
                        hasIncomingBeep: false,
                        requestCount: 0,
                        badgeStatus: "online"
                    )
                )
            ])
        )

        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel-avery",
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )

        #expect(viewModel.beepThreadProjection(for: contactID) == .incomingBeep(requestCount: 1))
        #expect(viewModel.selectedConversationState(for: contactID).detail == .incomingBeep(requestCount: 1))
        #expect(viewModel.selectedConversationState(for: contactID).statusMessage == "Avery wants to talk")
    }

    @MainActor
    @Test func contactSelectionReconcilePrefersIncomingBeepOverFallbackContact() {
        let viewModel = PTTViewModel()
        let fallbackContactID = UUID()
        let requestContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: fallbackContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            ),
            Contact(
                id: requestContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [
                    BackendBeepUpdate(
                        contactID: requestContactID,
                        beep: makeBeep(direction: "incoming", fromHandle: "@avery")
                    )
                ],
                outgoing: [],
                now: .now
            )
        )

        viewModel.reconcileContactSelectionIfNeeded(
            reason: "test",
            allowSelectingFallbackContact: true
        )

        #expect(viewModel.selectedContactId == requestContactID)
    }

    @Test func backendSyncReducerContactSummaryUpdateReplacesSnapshot() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
    }

    @Test func backendSyncReducerContactSummaryAbsentMembershipDowngradesInactiveCachedChannelState() {
        let contactID = UUID()
        let staleChannelState = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let summary = makeContactSummary(
            channelId: "channel",
            isOnline: true,
            badgeStatus: "online",
            membershipKind: "absent"
        )
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = staleChannelState
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(status: .ready)

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.channelStates[contactID]?.membership == .absent)
        #expect(transition.state.syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendSyncReducerContactSummaryFailurePreservesLastKnownSnapshot() {
        let contactID = UUID()
        let summary = TurboContactSummaryResponse(
            userId: "user-peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "outgoing-beep"
        )
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Contact sync failed: internal server error")
    }

    @Test func backendSyncReducerContactSummaryFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary
        state.syncState.connectionPhase = .connected(mode: "cloud", handle: "@avery")
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @MainActor
    @Test func trackedPresenceFallbackTargetsIncludeTrackedContactsWithoutSummaries() {
        let viewModel = PTTViewModel()
        let trackedContactID = UUID()
        let summarizedContactID = UUID()

        viewModel.contacts = [
            Contact(
                id: trackedContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            ),
            Contact(
                id: summarizedContactID,
                name: "Casey",
                handle: "@casey",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-casey",
                remoteUserId: "user-casey"
            )
        ]
        viewModel.trackContact(trackedContactID)
        viewModel.trackContact(summarizedContactID)

        let targets = viewModel.trackedPresenceFallbackTargets(
            excluding: [
                summarizedContactID: TurboContactSummaryResponse(
                    userId: "user-casey",
                    handle: "@casey",
                    displayName: "Casey",
                    channelId: "channel-casey",
                    isOnline: true,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    isActiveConversation: false,
                    badgeStatus: "online"
                )
            ]
        )

        #expect(targets.count == 1)
        #expect(targets.first?.contactID == trackedContactID)
        #expect(targets.first?.handle == "@blake")
    }

    @MainActor
    @Test func trackedPresenceFallbackClearsStaleChannelReferenceWhenSummaryIsMissing() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let originalChannelID = "channel-blake"
        let originalStableChannelUUID = ContactDirectory.stableChannelUUID(for: originalChannelID)

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: originalStableChannelUUID,
                backendChannelId: originalChannelID,
                remoteUserId: "user-blake"
            )
        ]
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: originalChannelID,
                    selfUserId: "self-user",
                    peerUserId: "user-blake",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        viewModel.clearStaleTrackedChannelReferencesMissingFromSummaries(excluding: [:])

        #expect(viewModel.contacts.first?.backendChannelId == nil)
        #expect(viewModel.contacts.first?.channelId != originalStableChannelUUID)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendClientPresenceLookupUsesCanonicalPresenceEndpoint() {
        let path = TurboBackendClient.presenceLookupPath(for: "@blake")

        #expect(path == "/v1/users/by-handle/@blake/presence")
        #expect(path.contains("/presence"))
        #expect(path.contains("/presence/") == false)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsFallbackPresenceAsOnlineWithoutSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func backendBootstrapRetryKeepsIdleSelectedConversationStatusInPrimaryChrome() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.replaceBackendConfig(with: makeUnreachableBackendConfig())
        defer { viewModel.replaceBackendBootstrapRetryTask(with: nil) }

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.updateStatusForSelectedContact()

        viewModel.scheduleBackendBootstrapRetryIfNeeded(
            trigger: "test",
            error: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        )

        #expect(viewModel.statusMessage == "Blake is online")
        #expect(viewModel.backendStatusMessage == "Reconnecting backend...")
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Scheduling backend bootstrap retry"
            }
        )
    }

    @MainActor
    @Test func receiverAudioReadinessPublishRejectsReadyFromTransitionalMediaReason() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]

        await viewModel.publishReceiverAudioReadiness(
            ReceiverAudioReadinessIntent(
                contactID: contactID,
                contactHandle: "@blake",
                backendChannelID: "channel",
                remoteUserID: "peer-user",
                currentUserID: "user-self",
                deviceID: "self-device",
                isReady: true,
                reason: .mediaState(.preparing),
                telemetry: nil
            )
        )

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(viewModel.diagnostics.invariantViolations.contains {
            $0.invariantID == "receiver.readiness_ready_requires_stable_evidence"
                && $0.metadata["source"] == "publish-effect"
                && $0.metadata["reason"] == ReceiverAudioReadinessReason.mediaState(.preparing).wireValue
        })
    }

    @MainActor
    @Test func receiverAudioReadinessPublishRejectsReadyDuringPendingLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        await viewModel.publishReceiverAudioReadiness(
            ReceiverAudioReadinessIntent(
                contactID: contactID,
                contactHandle: "@blake",
                backendChannelID: "channel",
                remoteUserID: "peer-user",
                currentUserID: "user-self",
                deviceID: "self-device",
                isReady: true,
                reason: .channelRefresh,
                telemetry: nil
            )
        )

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(viewModel.diagnostics.invariantViolations.contains {
            $0.invariantID == "receiver.readiness_ready_forbidden_during_pending_leave"
                && $0.metadata["source"] == "publish-effect"
                && $0.metadata["reason"] == ReceiverAudioReadinessReason.channelRefresh.wireValue
        })
    }

    @MainActor
    @Test func receiverAudioReadinessRepublishesOncePerRecoveryBasisWhenBackendHasNotObservedLocalReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .websocketConnected)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 2)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Republishing receiver audio readiness because backend has not observed local ready"
            )
        )

        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 2)
    }

    @MainActor
    @Test func localTransmitSuppressesReceiverReadyFromChannelRefreshAndMediaConnected() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.forceSyncEngineJoinedConversation(contactID: contactID, reason: "test")
        viewModel.syncEngineSystemTransmitBegan(target: target, source: "test")
        viewModel.syncEngineBackendTransmitAccepted(target: target, source: "test")

        #expect(viewModel.isTransmitting)
        #expect(!viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .pttSync)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .mediaState(.connected))

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.isEmpty)
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverNotReady }.count == 1)
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == false)
    }

    @MainActor
    @Test func staleReceiverAudioReadinessPublishEffectIsDroppedWhenCacheMovedOn() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]

        let readyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "user-self",
            deviceID: "self-device",
            isReady: true,
            reason: .pttSync,
            telemetry: nil
        )
        let notReadyIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "user-self",
            deviceID: "self-device",
            isReady: false,
            reason: .channelRefresh,
            telemetry: nil
        )
        viewModel.controlPlaneCoordinator.send(.receiverAudioReadinessPublished(notReadyIntent))

        await viewModel.publishReceiverAudioReadiness(
            readyIntent,
            requiringCurrentPublication: true
        )

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Dropped stale receiver audio readiness publish effect"
            )
        )
    }

    @MainActor
    @Test func staleReceiverAudioReadinessPublishCompletionDoesNotRegressCache() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()
        client.setSignalSendDelayForTesting(nanoseconds: 50_000_000)

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]

        let staleIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "user-self",
            deviceID: "self-device",
            isReady: false,
            reason: .channelRefresh,
            telemetry: nil
        )
        let currentIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "user-self",
            deviceID: "self-device",
            isReady: true,
            reason: .mediaState(.connected),
            telemetry: nil
        )
        viewModel.controlPlaneCoordinator.send(.receiverAudioReadinessPublished(staleIntent))

        async let stalePublish: Void = viewModel.publishReceiverAudioReadiness(
            staleIntent,
            requiringCurrentPublication: true
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        viewModel.controlPlaneCoordinator.send(.receiverAudioReadinessPublished(currentIntent))
        await stalePublish

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == currentIntent.publishedState)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Dropped stale receiver audio readiness publish completion"
            )
        )
    }

    @MainActor
    @Test func mediaPreparingDuringActiveReceiveSuppressesReceiverNotReadyPublish() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        let mediaSession = RecordingMediaSession()
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        await viewModel.syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .channelRefresh
        )
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)

        viewModel.mediaSession(mediaSession, didChange: .preparing)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverNotReady }.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Suppressed receiver audio readiness sync during active receive playback recovery"
            )
        )
    }

    @MainActor
    @Test func mediaPreparingDoesNotPublishReceiverReadiness() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        let mediaSession = RecordingMediaSession()
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)

        viewModel.mediaSession(mediaSession, didChange: .preparing)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.isEmpty)
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverNotReady }.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped receiver audio readiness sync for transitional media state"
            )
        )
    }

    @MainActor
    @Test func receiverReadinessSyncDropsSupersededMediaReasonWithoutClearingPublishedState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == true)

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .mediaState(.preparing))
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .mediaState(.closed))

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverNotReady }.isEmpty)
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == true)
        #expect(!viewModel.diagnostics.invariantViolations.contains {
            $0.invariantID == "receiver.readiness_ready_requires_stable_evidence"
                && $0.metadata["source"] == "sync-request"
        })
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Dropped stale receiver audio readiness sync for superseded media state"
            )
        )
    }

    @MainActor
    @Test func receiverReadinessSyncDoesNotPublishReadyDuringPendingLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        client.enableSentSignalCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .waiting,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        #expect(!viewModel.desiredLocalReceiverAudioReadiness(for: contactID))
        #expect(!viewModel.peerIsRoutableForReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .mediaState(.closed))

        #expect(client.sentSignalsForTesting().isEmpty)
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == false)
        #expect(!viewModel.diagnostics.invariantViolations.contains {
            $0.invariantID == "receiver.readiness_ready_requires_stable_evidence"
        })
    }

    @MainActor
    @Test func selectedConversationDoesNotProjectWakeFromReceiverAudioEvidenceBeforeBackendTransmitAuthority() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.syncSelectedConversationProjection()

        let projection = viewModel.selectedConversationProjection(for: contactID)

        #expect(projection.connectedControlPlane == .waiting(reason: .backendConversationTransition, statusMessage: "Connecting..."))
        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")

        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.syncSelectedConversationProjection()

        let receiverReadyProjection = viewModel.selectedConversationProjection(for: contactID)

        #expect(receiverReadyProjection.connectedControlPlane == .waiting(reason: .backendConversationTransition, statusMessage: "Connecting..."))
        #expect(receiverReadyProjection.selectedConversationState.phase == .waitingForPeer)
        #expect(receiverReadyProjection.selectedConversationState.statusMessage == "Connecting...")
    }

    @MainActor
    @Test func selectedConversationKeepsWakeFromWakeCapableReceiverBeforeBackendTransmitAuthority() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.syncSelectedConversationProjection()

        let projection = viewModel.selectedConversationProjection(for: contactID)

        #expect(projection.connectedControlPlane == .wakeReady)
        #expect(projection.selectedConversationState.phase == .wakeReady)
        #expect(projection.selectedConversationState.statusMessage == "Hold to talk to wake Blake")
    }

    @MainActor
    @Test func wakeActivatedReceiverPublishesReadyFromConnectedPlaybackSessionDespiteStaleLocalTransmitState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        let staleTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel"
        )
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(staleTarget)
        viewModel.syncTransmitState()

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel",
                    activeSpeaker: "@blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.transmitDomainSnapshot.phase == .requesting(contactID: contactID))
        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))
    }

    @MainActor
    @Test func outgoingAudioSendGateWaitsForRemoteReceiverReadinessRecovery() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel"
        )
        let waitTask = Task {
            await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
                target: target,
                timeoutNanoseconds: 500_000_000,
                pollNanoseconds: 20_000_000
            )
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready
                )
            )
        )

        #expect(await waitTask.value)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateTimesOutWhenRemoteReceiverNeverRecovers() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 120_000_000,
            pollNanoseconds: 20_000_000
        )

        #expect(!didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.outbound_audio_without_remote_receiver_ready"
            }
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateWaitsForWakeCapableReceiverRecoveryAfterTalkRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 200_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 140_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Waiting for wake-capable receiver recovery before sending initial outbound audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Continuing to hold initial outbound audio after talk release until wake-capable receiver recovery"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateReleasesWakeGraceWhileTalkIsStillActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 220_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 50_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Waiting for wake-capable receiver recovery before sending initial outbound audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateDoesNotReleaseWakeCapableAudioWithoutReceiverReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 220_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 90_000_000,
            postReleaseWakeRecoveryGraceNanoseconds: 20_000_000
        )

        #expect(!didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateTimesOutWakeCapableShortReleaseWithoutReceiverReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 180_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 90_000_000,
            postReleaseWakeRecoveryGraceNanoseconds: 40_000_000
        )

        #expect(!didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateAllowsShortPostReleaseWindowForWakeCapableReceiverRecovery() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 250_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 90_000_000,
            postReleaseWakeRecoveryGraceNanoseconds: 80_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; not sending outbound audio"
            )
        )
    }

    @MainActor
    @Test func wakeRecoveryTreatsPeerAsRoutableForReceiverReadinessWhileBackendPeerMembershipLags() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel",
                activeSpeaker: "@blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
            )
        )
        viewModel.pttWakeRuntime.markAudioSessionActivated(for: channelUUID)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.peerIsRoutableForReceiverAudioReadiness(for: contactID))
    }

    @MainActor
    @Test func localSessionAloneDoesNotMakePeerRoutableForReceiverReadiness() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))
        #expect(!viewModel.peerIsRoutableForReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)

        let publication = viewModel.localReceiverAudioReadinessPublications[contactID]
        #expect(publication?.isReady == true)
        #expect(publication?.peerWasRoutable == false)
        #expect(publication?.basis == .channelRefresh)
        #expect(publication?.telemetry?.audio != nil)
    }

    @MainActor
    @Test func wakeRecoveryReassertsBackendJoinWhenDevicePTTEvidenceOutlivesBackendMembership() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.reassertBackendJoinAfterWakeIfNeeded(for: contactID)

        #expect(
            capturedEffects == [
                .join(
                    BackendJoinRequest(
                        contactID: contactID,
                        handle: "@blake",
                        intent: .joinReadyFriend,
                        relationship: .none,
                        existingRemoteUserID: "peer-user",
                        existingBackendChannelID: "channel",
                        incomingBeep: nil,
                        outgoingBeep: nil,
                        beepCooldownRemaining: nil,
                        usesLocalHTTPBackend: false
                    )
                )
            ]
        )
    }

    @MainActor
    @Test func wakeRecoveryReassertionClearsCachedReceiverAudioReadinessPublication() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle,
            telemetry: nil
        )

        await viewModel.reassertBackendJoinAfterWakeIfNeeded(for: contactID)

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
    }

    @MainActor
    @Test func backendJoinFailureClearsPendingConnectAndSelectedWaitingState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueConnect(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.syncSelectedConversationProjection()

        await viewModel.backendCommandCoordinator.handle(
            .joinRequested(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .joinReadyFriend,
                    relationship: .none,
                    existingRemoteUserID: "peer-user",
                    existingBackendChannelID: "channel-123",
                    incomingBeep: nil,
                    outgoingBeep: nil,
                    beepCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        )

        #expect(viewModel.pendingJoinContactId == nil)
        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.backendCommandCoordinator.state.activeOperation == nil)
        #expect(viewModel.backendCommandCoordinator.state.lastError != nil)
        #expect(viewModel.statusMessage.contains("Join failed:"))
        #expect(viewModel.selectedConversationState(for: contactID).phase != .waitingForPeer)
    }

    @MainActor
    @Test func leaveInFlightSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.conversationActionCoordinator.markReconciledTeardown(contactID: contactID)

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func pendingConnectSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.conversationActionCoordinator.queueConnect(contactID: contactID)

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func publishedReceiverReadinessSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.localReceiverAudioReadinessPublications[contactID] =
            ReceiverAudioReadinessPublication(
                isReady: true,
                peerWasRoutable: true,
                basis: .channelRefresh,
                telemetry: nil
            )

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func remoteTransmitStopGraceSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.receiveExecutionRuntime.markRemoteTransmitStopProjectionGrace(for: contactID)

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .receiving,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .inactive,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func peerOnlyBackendMembershipTriggersDevicePTTEvidenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let shouldRecover = viewModel.shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover)
    }

    @MainActor
    @Test func leaveInFlightSuppressesMissingBackendMembershipRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.conversationActionCoordinator.markReconciledTeardown(contactID: contactID)

        let shouldRecover = viewModel.shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func missingBackendMembershipRecoveryReassertsJoinForActiveDevicePTTEvidence() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        let expectedJoin = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "peer-user",
            existingBackendChannelID: "channel",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false,
            deviceSessionProof: .pttSystem
        )
        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.startBackendJoinRecoveryForActiveDevicePTTEvidence(
            contactID: contactID,
            backendChannelID: "channel",
            contact: contact,
            invariantID: "selected.local_device_ptt_evidence_without_backend_membership",
            invariantMessage: "local Device PTT evidence is active, but backend membership dropped self while the peer remained joined",
            backendStatus: ConversationState.waitingForPeer.rawValue,
            backendReadiness: "inactive",
            recoveryMessage: "Repairing missing backend membership for active local Device PTT evidence",
            captureReason: "test:backend-membership:self-healed"
        )

        for _ in 0..<20 {
            if capturedEffects.contains(.join(expectedJoin))
                || viewModel.backendCommandCoordinator.state.activeOperation == .join(request: expectedJoin) {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(capturedEffects.contains(.join(expectedJoin))
            || viewModel.backendCommandCoordinator.state.activeOperation == .join(request: expectedJoin))
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.local_device_ptt_evidence_without_backend_membership"
            }
        )
    }

    @MainActor
    @Test func signalingJoinDriftSelfHealDoesNotReassertIdleBackendChannel() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(!viewModel.shouldReassertBackendJoinAfterSignalingDrift(for: contactID))
    }

    @MainActor
    @Test func signalingJoinDriftLocalConversationEvidenceFallbackPrefersReassertionForIdleBackendChannel() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(
            viewModel.shouldPreferBackendJoinReassertionForLocalConversationEvidenceAfterSignalingDrift(
                for: contactID
            )
        )
    }

    @MainActor
    @Test func signalingJoinDriftStillReassertsBackendConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        #expect(viewModel.shouldReassertBackendJoinAfterSignalingDrift(for: contactID))
    }

    @MainActor
    @Test func signalingJoinDriftReassertsRequestedBackendChannelForActiveDevicePTTEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .outgoingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(viewModel.shouldReassertBackendJoinAfterSignalingDrift(for: contactID))
    }

    @MainActor
    @Test func backendJoinReassertionDoesNotQueueWhileLeaveIsActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.reassertBackendJoin(for: contact)

        #expect(capturedEffects.isEmpty)
        #expect(viewModel.backendCommandCoordinator.state.activeOperation == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Skipped backend join reassertion while leave is active"))
    }

    @Test func backendSyncReducerRetainsChannelStateOnRefreshFailure() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Channel sync failed: timeout")
    }

    @Test func backendSyncReducerChannelFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState
        state.syncState.connectionPhase = .connected(mode: "cloud", handle: "@avery")
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @Test func backendSyncStateAcceptsBackendConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: joinedChannelState.hasIncomingBeep,
            hasOutgoingBeep: joinedChannelState.hasOutgoingBeep,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateClearsReadinessWhenChannelMembershipBecomesAbsent() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let absentChannelState = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelReadiness(
            makeChannelReadiness(
                status: .ready,
                remoteAudioReadiness: .wakeCapable,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
            ),
            for: contactID
        )
        syncState.applyChannelState(absentChannelState, for: contactID)
        syncState.applyChannelReadiness(
            makeChannelReadiness(
                status: .ready,
                peerHasActiveDevice: false,
                remoteAudioReadiness: .wakeCapable,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "stale-peer-device")
            ),
            for: contactID
        )

        #expect(syncState.channelStates[contactID] == absentChannelState)
        #expect(syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendSyncStateAcceptsBackendIncomingBeepRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: true,
            hasOutgoingBeep: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingBeep.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let friendReadyChannelState = TurboChannelStateResponse(
            channelId: "channel-1",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: true,
            hasOutgoingBeep: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingBeep.rawValue,
            canTransmit: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: friendReadyChannelState.channelId,
            selfUserId: friendReadyChannelState.selfUserId,
            peerUserId: friendReadyChannelState.peerUserId,
            peerHandle: friendReadyChannelState.peerHandle,
            selfOnline: friendReadyChannelState.selfOnline,
            peerOnline: friendReadyChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: true,
            hasOutgoingBeep: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingBeep.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(friendReadyChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerJoinedConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: false,
            hasIncomingBeep: joinedChannelState.hasIncomingBeep,
            hasOutgoingBeep: joinedChannelState.hasOutgoingBeep,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateReplacesStaleJoinedMembershipWhenBackendResetsChannel() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingBeep: true,
            hasOutgoingBeep: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingBeep.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendCommandReducerOpenFriendEmitsLookupEffect() {
        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .openFriendRequested(handle: "@avery")
        )

        #expect(transition.state.activeOperation == .openFriend(handle: "@avery"))
        #expect(transition.effects == [.openFriend(handle: "@avery")])
    }

    @Test func backendCommandReducerDeduplicatesJoinForSameContact() {
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .none,
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: request), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(request)
        )

        #expect(transition.state.activeOperation == .join(request: request))
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerQueuesUpdatedJoinForSameContact() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: inFlightRequest), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(queuedRequest)
        )

        #expect(transition.state.activeOperation == .join(request: inFlightRequest))
        #expect(transition.state.queuedJoinRequest == queuedRequest)
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerRunsQueuedJoinAfterOperationFinishes() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(
                activeOperation: .join(request: inFlightRequest),
                queuedJoinRequest: queuedRequest,
                lastError: nil
            ),
            event: .operationFinished
        )

        #expect(transition.state.activeOperation == .join(request: queuedRequest))
        #expect(transition.state.queuedJoinRequest == nil)
        #expect(transition.effects == [.join(queuedRequest)])
    }

    @Test func backendCommandReducerLeaveDropsQueuedJoin() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let leaveRequest = BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-avery")

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(
                activeOperation: .join(request: inFlightRequest),
                queuedJoinRequest: queuedRequest,
                lastError: nil
            ),
            event: .leaveRequested(leaveRequest)
        )

        #expect(transition.state.activeOperation == .leave(contactID: contactID))
        #expect(transition.state.queuedJoinRequest == nil)
        #expect(transition.effects == [.leave(leaveRequest)])
    }

    @MainActor
    @Test func staleJoinReadyFriendIntentDoesNotQueueLocalConnectBeforeBackendAccepts() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: nil,
            remoteUserId: "user-avery"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.performConnect(to: contact, intent: .joinReadyFriend)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.intent == .requestConnection
                    && request.relationship == .none
            }
        )
    }

    @MainActor
    @Test func backendJoinSkipsExistingConversationSnapshotForKnownBeepJoinIntents() {
        let viewModel = PTTViewModel()
        let incomingAccept = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: makeBeep(direction: "incoming"),
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let acceptedOutgoingJoin = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .joinAcceptedOutgoingBeep,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing", beepId: "beep-accepted"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let friendReadyJoin = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        #expect(!viewModel.backendJoinNeedsExistingConversationSnapshot(request: incomingAccept))
        #expect(!viewModel.backendJoinNeedsExistingConversationSnapshot(request: acceptedOutgoingJoin))
        #expect(viewModel.backendJoinNeedsExistingConversationSnapshot(request: friendReadyJoin))
    }

    @MainActor
    @Test func backendJoinExecutionPlanAllowsExplicitJoinReadyFriendIntentWhenPeerHasJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let existingConversationSnapshot = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.waitingForPeer.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: existingConversationSnapshot
        )

        #expect(plan == .joinConversation)
    }

    @MainActor
    @Test func backendJoinExecutionPlanAllowsAcceptedOutgoingJoinDespiteStaleBeepProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinAcceptedOutgoingBeep,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing", beepId: "beep-accepted"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let staleExistingConversationSnapshot = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: false,
                peerDeviceConnected: false,
                hasIncomingBeep: false,
                hasOutgoingBeep: true,
                requestCount: 1,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.outgoingBeep.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: staleExistingConversationSnapshot
        )

        #expect(plan == .joinConversation)
    }

    @MainActor
    @Test func backendJoinExecutionPlanRejectsStaleJoinReadyFriendIntentWithoutPeerMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let existingConversationSnapshot = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: false,
                peerDeviceConnected: false,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.idle.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: existingConversationSnapshot
        )

        #expect(plan == .beepOnly)
    }

    @MainActor
    @Test func backendJoinChannelNotFoundIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("channel not found")))
        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server(" Channel Not Found ")))
    }

    @MainActor
    @Test func backendJoinMetadataFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("missing otherUserId or otherHandle")))
        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server(" Missing OtherUserId Or OtherHandle ")))
    }

    @MainActor
    @Test func backendJoinDisconnectedDeviceSessionFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(TurboBackendError.server("device session not connected")))
        #expect(viewModel.shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(TurboBackendError.server(" Device Session Not Connected ")))
    }

    @MainActor
    @Test func unrelatedBackendJoinFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.invalidResponse))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.invalidResponse))
        #expect(!viewModel.shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func transmitLeaseLossIsTreatedAsCleanStop() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("no active transmit state for sender")))
        #expect(!viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func transmitStopMembershipLossIsTreatedAsAlreadyComplete() {
        let viewModel = PTTViewModel()

        #expect(
            viewModel.shouldTreatTransmitStopCleanupAsAlreadyComplete(
                TurboBackendError.server("not a channel member")
            )
        )
        #expect(
            viewModel.shouldTreatTransmitStopCleanupAsAlreadyComplete(
                TurboBackendError.server("no active transmit state for sender")
            )
        )
        #expect(
            !viewModel.shouldTreatTransmitStopCleanupAsAlreadyComplete(
                TurboBackendError.server("channel already transmitting")
            )
        )
    }

    @MainActor
    @Test func transmitBeginMembershipLossIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("not a channel member")))
        #expect(!viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsTaskCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(CancellationError()))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsURLSessionCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(URLError(.cancelled)))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierRejectsRealBackendFailures() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(TurboBackendError.server("boom")) == false)
    }

    @MainActor
    @Test func backendChannelReadinessMembershipLossIsAuthoritative() {
        let viewModel = PTTViewModel()

        #expect(
            viewModel.shouldTreatChannelReadinessMembershipLossAsAuthoritative(
                TurboBackendError.server("not a channel member")
            )
        )
        #expect(
            !viewModel.shouldTreatChannelReadinessMembershipLossAsAuthoritative(
                TurboBackendError.server("internal server error")
            )
        )
    }

    @Test func backendCommandReducerLeaveFailureClearsOperationAndStoresError() {
        let contactID = UUID()
        let leaveRequest = BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
        let joinedTransition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .leaveRequested(leaveRequest)
        )
        let failedTransition = BackendCommandReducer.reduce(
            state: joinedTransition.state,
            event: .operationFailed("leave failed")
        )

        #expect(joinedTransition.effects == [.leave(leaveRequest)])
        #expect(failedTransition.state.activeOperation == nil)
        #expect(failedTransition.state.lastError == "leave failed")
    }

    @MainActor
    @Test func unexpectedSystemLeaveDoesNotRequestBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(
                contactID: contactID,
                autoRejoinContactID: nil,
                shouldPropagateBackendLeave: false
            )
        )

        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func localOnlySystemChannelRecoveryLeaveDoesNotClearBackendMembershipDuringRejoin() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.recoverStaleSystemChannel(
            for: channelUUID,
            contactID: contactID,
            reason: "test-channel-limit"
        )
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 2)")

        await Task.yield()
        await Task.yield()

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func staleSystemChannelRecoveryKeepsSelectedProjectionConnectingUntilRejoin() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID, backendChannelID: "channel-1")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )
        viewModel.syncSelectedConversationProjection()

        viewModel.recoverStaleSystemChannel(
            for: channelUUID,
            contactID: contactID,
            reason: "join-failed-channel-limit"
        )

        let selectedState = viewModel.selectedConversationState(for: contactID)
        #expect(selectedState.phase == .waitingForPeer)
        #expect(selectedState.detail == .waitingForPeer(reason: .pendingJoin))
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.systemSessionState == .none)
        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.ready_without_join"
            }
        )
    }

    @MainActor
    @Test func explicitDisconnectRequestsBackendLeaveImmediately() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.performDisconnect()
        await Task.yield()
        await Task.yield()

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Backend leave requested immediately for explicit disconnect"
            }
        )
    }

    @MainActor
    @Test func disconnectRecoveryDefersWhileBackendLeaveCommandIsStillActive() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.disconnectRecoveryDelayNanoseconds = 10_000_000
        viewModel.disconnectRecoveryRetryDelayNanoseconds = 10_000_000
        viewModel.disconnectRecoveryMaxWaitNanoseconds = 200_000_000
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            guard case .leave = effect else { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        viewModel.performDisconnect()

        try await waitForScenario(
            "disconnect recovery defers while backend leave remains active",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.diagnostics.entries.contains {
                $0.message == "Deferred disconnect recovery while backend leave command is still active"
            }
        }

        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.disconnecting_timeout"
            }
        )
        #expect(viewModel.conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contactID))

        viewModel.replaceDisconnectRecoveryTask(with: nil)
    }

    @MainActor
    @Test func explicitSystemLeaveStillRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(
                contactID: contactID,
                autoRejoinContactID: nil,
                shouldPropagateBackendLeave: true
            )
        )

        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func activeSystemLeaveCallbackKeepsExplicitLeaveArmedUntilBackendLeaveConverges() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 1)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .leave(.explicit(contactID: contactID)))
        #expect(viewModel.backendCommandCoordinator.state.activeOperation == .leave(contactID: contactID))
        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Planned absent backend membership recovery"
            } == false
        )
    }

    @MainActor
    @Test func explicitSystemLeaveCallbackKeepsPendingLeaveUntilBackendLeaveFinishes() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        viewModel.backendCommandCoordinator.effectHandler = { effect in
            guard case .leave = effect else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 1)")

        try await waitForScenario(
            "explicit system leave keeps pending leave until backend leave finishes",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.conversationActionCoordinator.pendingAction == .leave(.explicit(contactID: contactID))
                && viewModel.backendCommandCoordinator.state.activeOperation == .leave(contactID: contactID)
        }

        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Planned absent backend membership recovery"
            } == false
        )
    }

    @MainActor
    @Test func systemLeaveForChannelSwitchRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let currentContactID = UUID()
        let nextContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: currentContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            ),
            Contact(
                id: nextContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-2",
                remoteUserId: "user-avery"
            )
        ]

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(
                contactID: currentContactID,
                autoRejoinContactID: nextContactID,
                shouldPropagateBackendLeave: true
            )
        )

        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: currentContactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func sameContactAutoRejoinDoesNotRequestBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(
                contactID: contactID,
                autoRejoinContactID: contactID,
                shouldPropagateBackendLeave: false
            )
        )

        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func reconciledTeardownSyncLeftChannelDoesNotRequestBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.conversationActionCoordinator.markReconciledTeardown(contactID: contactID)

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(
                contactID: contactID,
                autoRejoinContactID: nil,
                shouldPropagateBackendLeave: false
            )
        )

        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func clearStaleBackendMembershipDropsLocalProjectionWithoutBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runSelectedConversationEffect(.clearStaleBackendMembership(contactID: contactID))

        #expect(capturedEffects.isEmpty)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Cleared local stale backend membership projection without propagating backend leave"
            }
        )
    }

    @MainActor
    @Test func recentSystemLeaveWithPeerGoneClearsSelfOnlyBackendProjectionWithoutBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.markStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: "recent-system-leave"
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        #expect(viewModel.devicePTTRestoreBarrier(for: viewModel.contacts[0]).blocksAutomaticRestore)
        viewModel.syncSelectedConversationProjection()
        #expect(
            viewModel.selectedConversationCoordinator.state.reconciliationAction
                == .clearStaleBackendMembership(contactID: contactID)
        )

        await viewModel.reconcileSelectedConversationIfNeeded()

        #expect(capturedEffects.isEmpty)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .idle)
    }

    @MainActor
    @Test func clearStaleBackendMembershipClearsUnexpectedReconciledTeardown() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.markReconciledTeardown(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        await viewModel.runSelectedConversationEffect(.clearStaleBackendMembership(contactID: contactID))

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.disconnectRecoveryTask == nil)
    }

    @MainActor
    @Test func absentBackendMembershipClearsCompletedLocalLeaveWithoutForceQuit() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .idle)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
                    && $0.metadata["repairDecision"] == "executed"
                    && $0.metadata["repairAction"] == "completed-pending-leave"
                    && $0.metadata["invariantID"] == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func absentBackendMembershipClearsCompletedLocalLeaveWhenStableChannelIdRemains() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "stable-direct-channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .idle)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
                    && $0.metadata["repairDecision"] == "executed"
                    && $0.metadata["repairAction"] == "completed-pending-leave"
                    && $0.metadata["invariantID"] == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func absentBackendMembershipClearsStalePendingLocalJoinWithoutForceQuit() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .idle)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
                    && $0.metadata["repairDecision"] == "executed"
                    && $0.metadata["repairAction"] == "stale-pending-join"
                    && $0.metadata["invariantID"] == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Planned absent backend membership recovery"
                    && $0.metadata["repairDecision"] == "planned"
                    && $0.metadata["repairAction"] == "stale-pending-join"
            }
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Converged absent backend membership recovery"
                    && $0.metadata["repairDecision"] == "converged"
                    && $0.metadata["pendingActionAfterRepair"] == "none"
            }
        )
    }

    @MainActor
    @Test func absentBackendMembershipRecoveryIsIdempotentAfterStalePendingJoinClears() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()
        viewModel.syncSelectedConversationProjection()

        let plannedRepairs = viewModel.diagnostics.entries.filter {
            $0.message == "Planned absent backend membership recovery"
                && $0.metadata["repairAction"] == "stale-pending-join"
        }
        let convergedRepairs = viewModel.diagnostics.entries.filter {
            $0.message == "Converged absent backend membership recovery"
                && $0.metadata["repairAction"] == "stale-pending-join"
        }

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(plannedRepairs.count == 1)
        #expect(convergedRepairs.count == 1)
    }

    @MainActor
    @Test func absentBackendMembershipDoesNotClearPendingLocalJoinWhileBackendJoinIsSettling() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendRuntime.markBackendJoinSettling(for: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Deferred absent backend membership recovery while backend join is settling"
                    && $0.metadata["repairDecision"] == "suppressed"
                    && $0.metadata["repairSuppressionReason"] == "backend-join-settling"
                    && $0.metadata["invariantID"] == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
        #expect(
            !viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
            }
        )
    }

    @MainActor
    @Test func acceptedBackendJoinPreservesPendingLocalJoinDuringHostedVisibilityLag() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendRuntime.markBackendJoinSettling(
            for: contactID,
            now: Date(timeIntervalSinceNow: -12)
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(
            !viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
            }
        )
    }

    @MainActor
    @Test func acceptedBackendJoinProjectionMarksLocalMembershipBeforeHostedRefresh() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel",
            remoteUserId: "user-avery"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingBeep: true,
                    hasOutgoingBeep: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [
                    BackendBeepUpdate(
                        contactID: contactID,
                        beep: makeBeep(direction: "incoming", beepId: "incoming-1")
                    )
                ],
                outgoing: [
                    BackendBeepUpdate(
                        contactID: contactID,
                        beep: makeBeep(direction: "outgoing", beepId: "outgoing-1")
                    )
                ],
                now: .now
            )
        )

        guard let backend = viewModel.backendServices else {
            Issue.record("expected backend services")
            return
        }
        viewModel.applyAcceptedBackendJoinProjection(for: contact, backend: backend)

        let projected = viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID]
        #expect(projected?.membership == .both(peerDeviceConnected: true))
        #expect(projected?.status == ConversationState.waitingForPeer.rawValue)
        #expect(projected?.canTransmit == false)
        #expect(projected?.beepThreadProjection == BackendBeepThreadProjection.none)
        #expect(viewModel.incomingBeepByContactID[contactID] == nil)
        #expect(viewModel.outgoingBeepByContactID[contactID] == nil)
        #expect(viewModel.beepThreadProjection(for: contactID) == .none)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Applied accepted backend join projection"
            }
        )
    }

    @MainActor
    @Test func expiredBackendJoinSettlingClearsStalePendingLocalJoinEvenWithActiveJoinOperation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendRuntime.markBackendJoinSettling(
            for: contactID,
            now: Date(timeIntervalSinceNow: -30)
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinReadyFriend,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        viewModel.backendCommandCoordinator.send(.joinRequested(request))
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
            }
        )
    }

    @MainActor
    @Test func receivedEphemeralTokenUsesResolvedSystemChannelBackendFromEngineConversation() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: nil))
        viewModel.syncPTTState()

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleReceivedEphemeralPushToken(Data("token".utf8))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.activeChannelId == contactID)
        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "746f6b656e"
                    )
                )
            ]
        )
    }

    @Test func transmittablePrimaryActionUsesHoldToTalk() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .ready,
            isSelectedChannelJoined: true,
            canTransmitNow: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        switch action.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk primary action when transmission is available")
        }
        #expect(action.label == "Hold To Talk")
        #expect(action.isEnabled)
        switch action.style {
        case .accent:
            break
        case .muted, .active:
            Issue.record("Expected accent styling for hold-to-talk readiness")
        }
    }

    @Test func holdToTalkButtonPolicyKeepsActivePresentationWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Release To Stop")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .active:
            break
        case .accent, .muted:
            Issue.record("Expected active styling while hold gesture remains pressed")
        }
    }

    @Test func holdToTalkButtonPolicyLeavesIdleHoldPresentationUnchanged() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: false)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected idle hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Hold To Talk")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .accent:
            break
        case .active, .muted:
            Issue.record("Expected accent styling while idle and ready to talk")
        }
    }

    @Test func holdToTalkButtonPolicyKeepsHoldControlMountedWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .connect,
            label: "Connect",
            isEnabled: true,
            style: .accent
        )

        #expect(HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: true))
        #expect(!HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: false))

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)
        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected latched hold control to stay mounted while gesture remains pressed")
        }
        #expect(displayAction.label == "Release To Stop")
    }

    @MainActor
    @Test func backendJoinSettlingProjectsConnectingStateBeforeLocalSessionStarts() {
        let contactID = UUID()

        let projection = ConversationStateMachine.projection(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .outgoingBeep,
                contactName: "Blake",
                contactIsOnline: true,
                contactPresence: .connected,
                isJoined: false,
                localTransmit: .idle,
                remoteParticipantSignalIsTransmitting: false,
                activeChannelID: nil,
                systemSessionMatchesContact: false,
                systemSessionState: .none,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil,
                mediaState: .idle,
                localMediaWarmupState: .cold,
                localRelayTransportReady: true,
                directMediaPathActive: false,
                firstTalkStartupProfile: .relayWarm,
                incomingWakeActivationState: nil,
                backendConvergence: BackendConversationConvergenceState(joinPhase: .settling),
                hadConnectedDevicePTTContinuity: false,
                channel: nil
            ),
            relationship: .outgoingBeep(requestCount: 1)
        )

        #expect(projection.selectedConversationState.phase == .waitingForPeer)
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .backendConversationTransition))
        #expect(projection.selectedConversationState.statusMessage == "Connecting...")
        #expect(ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: projection.selectedConversationState,
            requestedExpanded: true
        ))
    }

    @Test func holdToTalkGestureStateRequiresReleaseAfterMachineEndsHeldPress() {
        var state = HoldToTalkGestureState()

        let didBegin = state.beginIfAllowed(isEnabled: true)
        #expect(didBegin)

        state.handleMachinePressChanged(isActive: false)

        #expect(state.isTrackingTouch == false)
        #expect(state.requiresReleaseBeforeNextPress)
        let blockedBegin = state.beginIfAllowed(isEnabled: true)
        #expect(blockedBegin == false)
    }

    @Test func holdToTalkGestureStateRearmsOnlyAfterTouchEnds() {
        var state = HoldToTalkGestureState()

        let firstBegin = state.beginIfAllowed(isEnabled: true)
        #expect(firstBegin)
        state.handleMachinePressChanged(isActive: false)

        #expect(state.endTouch() == false)
        #expect(state.requiresReleaseBeforeNextPress == false)
        let secondBegin = state.beginIfAllowed(isEnabled: true)
        #expect(secondBegin)
    }

    @Test func holdToTalkGestureStateTracksEarlyTouchBeforeActionEnables() {
        var state = HoldToTalkGestureState()

        let tracked = state.beginTrackingTouch()

        #expect(tracked)
        #expect(state.isTrackingTouch)
        let duplicateBegin = state.beginIfAllowed(isEnabled: true)
        let didEnd = state.endTouch()
        #expect(!duplicateBegin)
        #expect(didEnd)
    }

    @Test func holdToTalkGestureStateDoesNotTrackEarlyTouchUntilReleaseAfterMachineEnd() {
        var state = HoldToTalkGestureState()

        let firstBegin = state.beginTrackingTouch()
        #expect(firstBegin)
        state.handleMachinePressChanged(isActive: false)

        let blockedBegin = state.beginTrackingTouch()
        let didEnd = state.endTouch()
        let secondBegin = state.beginTrackingTouch()
        #expect(!blockedBegin)
        #expect(didEnd == false)
        #expect(secondBegin)
    }

    @Test func transmitRuntimeRequiresFreshPressAfterUnexpectedSystemEndUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == false)

        runtime.noteTouchReleased()
        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == true)
        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @Test func transmitRuntimeIdleReconcilePreservesFreshPressBarrierUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)
        runtime.reconcileIdleState()

        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.noteTouchReleased()

        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @MainActor
    @Test func devicePTTProjectionFlagsHoldToTalkWithoutTransmitCapability() {
        let projection = makeDevicePTTDiagnosticsProjection(
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "ready",
                "selectedConversationPhaseDetail": "ready",
                "selectedConversationCanTransmit": "false",
                "selectedConversationAllowsHoldToTalk": "true",
                "backendCanTransmit": "false",
                "backendReadiness": "waiting-for-peer",
                "remoteAudioReadiness": "waiting",
                "remoteWakeCapabilityKind": "unavailable"
            ]
        )

        let candidate = projection.derivedInvariantCandidates.first {
            $0.invariantID == "selected.hold_to_talk_requires_transmit_capability"
        }

        #expect(candidate?.scope == .local)
        #expect(candidate?.metadata["selectedConversationAllowsHoldToTalk"] == "true")
        #expect(candidate?.metadata["selectedConversationCanTransmit"] == "false")
    }

    @MainActor
    @Test func devicePTTProjectionSuppressesBackendReadyMissingLocalDevicePTTEvidenceDuringDisconnectingBarrier() {
        let projection = DevicePTTDiagnosticsProjection(
            selectedContactID: UUID().uuidString,
            selectedHandle: "@blake",
            selectedConversationPhase: "waitingForPeer",
            selectedConversationPhaseDetail: "disconnecting",
            selectedConversationRelationship: "none",
            selectedConversationCanTransmit: false,
            selectedConversationAllowsHoldToTalk: false,
            selectedConversationAutoJoinArmed: false,
            isJoined: false,
            isTransmitting: false,
            activeChannelID: nil,
            systemSession: "none",
            systemActiveContactID: nil,
            systemChannelUUID: nil,
            mediaState: "connected",
            transmitPhase: "idle",
            transmitActiveContactID: nil,
            transmitPressActive: false,
            transmitExplicitStopRequested: false,
            transmitSystemTransmitting: false,
            incomingWakeActivationState: nil,
            incomingWakeBufferedChunkCount: 0,
            remoteReceiveActive: false,
            remoteTransmitStopObserved: false,
            remoteTransmitStopProjectionGraceActive: false,
            remoteReceiveActivityState: nil,
            receiverAudioReadinessState: nil,
            pendingAction: "none",
            localJoinAttempt: nil,
            localJoinAttemptIssuedCount: 0,
            reconciliationAction: "none",
            hadConnectedDevicePTTContinuity: true,
            controlPlaneReconnectGraceActive: false,
            backendSignalingJoinRecoveryActive: false,
            backendJoinSettling: false,
            backendChannelStatus: "ready",
            backendReadiness: "ready",
            backendSelfJoined: true,
            backendPeerJoined: true,
            backendPeerDeviceConnected: true,
            backendActiveTransmitterUserId: nil,
            backendActiveTransmitId: nil,
            backendActiveTransmitExpiresAt: nil,
            backendServerTimestamp: nil,
            backendCanTransmit: true,
            remoteAudioReadiness: "ready",
            remoteWakeCapabilityKind: "wake-capable"
        )

        #expect(
            !projection.derivedInvariantCandidates.contains {
                $0.invariantID == "selected.backend_ready_missing_local_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func devicePTTProjectionSuppressesBackendReadyMissingLocalDevicePTTEvidenceDuringRestoreReconciliation() {
        let projection = DevicePTTDiagnosticsProjection(
            selectedContactID: UUID().uuidString,
            selectedHandle: "@blake",
            selectedConversationPhase: "waitingForPeer",
            selectedConversationPhaseDetail: "friendReadyToConnect",
            selectedConversationRelationship: "none",
            selectedConversationCanTransmit: false,
            selectedConversationAllowsHoldToTalk: false,
            selectedConversationAutoJoinArmed: false,
            isJoined: false,
            isTransmitting: false,
            activeChannelID: nil,
            systemSession: "none",
            systemActiveContactID: nil,
            systemChannelUUID: nil,
            mediaState: "connected",
            transmitPhase: "idle",
            transmitActiveContactID: nil,
            transmitPressActive: false,
            transmitExplicitStopRequested: false,
            transmitSystemTransmitting: false,
            incomingWakeActivationState: nil,
            incomingWakeBufferedChunkCount: 0,
            remoteReceiveActive: false,
            remoteTransmitStopObserved: false,
            remoteTransmitStopProjectionGraceActive: false,
            remoteReceiveActivityState: nil,
            receiverAudioReadinessState: nil,
            pendingAction: "none",
            localJoinAttempt: nil,
            localJoinAttemptIssuedCount: 0,
            reconciliationAction: "restoreDevicePTTSession(contactID: 123)",
            hadConnectedDevicePTTContinuity: true,
            controlPlaneReconnectGraceActive: false,
            backendSignalingJoinRecoveryActive: false,
            backendJoinSettling: false,
            backendChannelStatus: "ready",
            backendReadiness: "ready",
            backendSelfJoined: true,
            backendPeerJoined: true,
            backendPeerDeviceConnected: true,
            backendActiveTransmitterUserId: nil,
            backendActiveTransmitId: nil,
            backendActiveTransmitExpiresAt: nil,
            backendServerTimestamp: nil,
            backendCanTransmit: true,
            remoteAudioReadiness: "ready",
            remoteWakeCapabilityKind: "wake-capable"
        )

        #expect(
            !projection.derivedInvariantCandidates.contains {
                $0.invariantID == "selected.backend_ready_missing_local_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func acceptedBackendJoinKeepsSettlingWhenLocalSessionIsAlreadyActive() {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )

        viewModel.startLocalJoinAfterAcceptedBackendJoin(for: contact)

        #expect(client.joinRequests.isEmpty)
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(viewModel.backendRuntime.isBackendJoinSettling(for: contactID))
        #expect(viewModel.statusMessage == "Connecting...")
    }

    @MainActor
    @Test func didJoinChannelClearsPendingLocalJoinBeforeBackendRefreshCompletes() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.pendingJoinContactId == nil)
        #expect(viewModel.pttCoordinator.state.isJoined)
        #expect(viewModel.isJoined)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Cleared pending local join after PTT join callback"
            }
        )
    }

    @MainActor
    @Test func staleDidJoinWhileExplicitLeaveImmediatelyLeavesWithoutPrewarm() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.conversationActionCoordinator.markExplicitLeave(contactID: contactID)

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.leaveRequests == [channelUUID])
        #expect(viewModel.pttCoordinator.state.isJoined == false)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.statusMessage == "Disconnecting...")
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring stale PTT join while explicit leave is in flight"
            }
        )
    }

    @MainActor
    @Test func staleDidJoinAfterBackendMembershipLossImmediatelyLeavesWithoutResurrectingSession() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: "channel-123",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.leaveRequests == [channelUUID])
        #expect(viewModel.pttCoordinator.state.isJoined == false)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.statusMessage == "Disconnecting...")
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring stale PTT join after backend membership loss"
            }
        )
    }

    @MainActor
    @Test func didJoinDuringSettlingBackendJoinIsNotRejectedByStaleAbsentMembership() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.backendRuntime.markBackendJoinSettling(for: contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: "channel-123",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.leaveRequests.isEmpty)
        #expect(viewModel.pttCoordinator.state.isJoined)
        #expect(viewModel.isJoined)
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(viewModel.backendRuntime.isBackendJoinSettling(for: contactID))
        #expect(
            !viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring stale PTT join after backend membership loss"
            }
        )
    }

    @MainActor
    @Test func didJoinAfterExpiredBackendJoinSettlingIsAcceptedWhileLocalJoinAttemptIsUnresolved() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID, channelUUID: channelUUID)
        viewModel.backendRuntime.markBackendJoinSettling(
            for: contactID,
            now: Date(timeIntervalSinceNow: -30)
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: "channel-123",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: false,
                    hasOutgoingBeep: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.leaveRequests.isEmpty)
        #expect(viewModel.pttCoordinator.state.isJoined)
        #expect(viewModel.isJoined)
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(
            !viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring stale PTT join after backend membership loss"
            }
        )
    }

    @MainActor
    @Test func settlingBackendJoinSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.backendRuntime.markBackendJoinSettling(for: contactID)

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @Test func backendJoinSettlingDoesNotClearFromSelfPresenceAlone() {
        let viewModel = PTTViewModel()

        let shouldClear = viewModel.shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: false,
                peerDeviceConnected: false
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForPeer,
                selfHasActiveDevice: true,
                peerHasActiveDevice: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldClear == false)
    }

    @Test func backendJoinSettlingDoesNotClearBeforeReadyChannelVisibility() {
        let viewModel = PTTViewModel()

        let shouldClear = viewModel.shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: false
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForPeer,
                selfHasActiveDevice: true,
                peerHasActiveDevice: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldClear == false)
    }

    @Test func backendJoinSettlingClearsWhenReadyChannelBecomesVisible() {
        let viewModel = PTTViewModel()

        let shouldClear = viewModel.shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
            effectiveChannelState: makeChannelState(
                status: .ready,
                canTransmit: true,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .ready,
                selfHasActiveDevice: true,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldClear)
    }

    @Test func backendJoinSettlingDoesNotClearWhenStatusLooksReadyButReadinessStillWaitsForPeer() {
        let viewModel = PTTViewModel()

        let shouldClear = viewModel.shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
            effectiveChannelState: makeChannelState(
                status: .ready,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForPeer,
                selfHasActiveDevice: true,
                peerHasActiveDevice: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldClear == false)
    }

    @MainActor
    @Test func expiredBackendJoinSettlingAllowsMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.backendRuntime.markBackendJoinSettling(
            for: contactID,
            now: Date(timeIntervalSinceNow: -30)
        )

        let shouldRecover = viewModel.shouldRecoverMissingBackendDevicePresence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .waitingForPeer,
                canTransmit: false,
                selfJoined: true,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            effectiveChannelReadiness: makeChannelReadiness(
                status: .waitingForSelf,
                selfHasActiveDevice: false,
                peerHasActiveDevice: true
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover)
    }

    @MainActor
    @Test func backendIdleMembershipLossRecoversWhenLocalConversationHadConnectedContinuity() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.syncSelectedConversationProjection()
        #expect(viewModel.selectedConversationCoordinator.state.hadConnectedDevicePTTContinuity)

        let shouldRecover = viewModel.shouldRecoverBackendIdleMembershipLossForActiveDevicePTTEvidence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .idle,
                canTransmit: false,
                selfJoined: false,
                peerJoined: false,
                peerDeviceConnected: false
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover)
    }
}
