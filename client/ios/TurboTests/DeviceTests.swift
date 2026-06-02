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
struct DeviceTests {
    @Test func audioOutputPreferenceCyclesBetweenSpeakerAndPhone() {
        #expect(AudioOutputPreference.speaker.next == .phone)
        #expect(AudioOutputPreference.phone.next == .speaker)
        #expect(AudioOutputPreference.speaker.buttonLabel == "Speaker")
        #expect(AudioOutputPreference.phone.buttonLabel == "Phone")
    }

    @Test func pttViewModelOwnsTurboEngineAndSelectionFeedsEngineSnapshot() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )

        viewModel.contacts = [contact]
        viewModel.selectContact(
            contact,
            reason: "engine-adapter-test",
            opensIncomingBeepSurface: false
        )

        if case .selected(let friend) = viewModel.engineSnapshot.conversation {
            #expect(friend.contactID.rawValue == contactID.uuidString)
            #expect(friend.handle == "@avery")
        } else {
            Issue.record("expected engine selected friend state")
        }
        #expect(viewModel.engineSnapshot.conversation.joinedEvidence == nil)
        if case .idle = viewModel.engineSnapshot.transmit {
        } else {
            Issue.record("expected idle engine transmit state")
        }
    }

    @Test func appLifecycleFeedsTurboEngineAsTypedEvent() {
        let viewModel = PTTViewModel()

        viewModel.syncEngineLifecycle(.background, reason: "engine-adapter-test")

        #expect(viewModel.engineSnapshot.lifecycle == .background)
    }

    @Test func backendRefreshGapPreservesEngineConversationWhileLocalPTTSessionIsActive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
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

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "channel-refresh")

        if case .joined(let joined) = viewModel.engineSnapshot.conversation {
            #expect(joined.channelID.rawValue == "channel-a-b")
            #expect(joined.friend.contactID.rawValue == contactID.uuidString)
            #expect(joined.readiness == .pending(.waitingForPeerDevice))
        } else {
            Issue.record("expected local PTT session evidence to preserve joined engine Conversation")
        }
        #expect(viewModel.isJoined)
        #expect(
            viewModel.engineTrace.steps.contains {
                $0.source == "backend-conversation:local-session-preserved:channel-refresh"
            }
        )
    }

    @Test func productionTransmitLifecycleFeedsEnginePhases() {
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
        let target = TransmitTarget(
            contactID: contactID,
            userID: "remote-user",
            deviceID: "peer-device",
            channelID: "channel-a-b",
            transmitID: "tx-1"
        )

        viewModel.syncEngineJoinedConversation(contactID: contactID, reason: "test")
        #expect(viewModel.isJoined)
        viewModel.syncEngineBeginTalkIntent(reason: "test")
        viewModel.syncEngineBackendTransmitAccepted(target: target, source: "test")
        #expect(viewModel.isTransmitting)
        viewModel.syncEngineSystemTransmitBegan(target: target, source: "duplicate-test")
        viewModel.syncEngineEndTalkIntent(reason: "test")
        viewModel.syncEngineSystemTransmitEnded(target: target, source: "test")
        viewModel.syncEngineBackendTransmitStopped(target: target, source: "duplicate-test")

        #expect(viewModel.engineSnapshot.transmit == .idle)
        #expect(viewModel.engineSnapshot.pttAudio == .inactive)
        #expect(!viewModel.isTransmitting)
    }

    @Test func mediaAudioRouteOptionsAllowBluetoothWithoutForcingSpeaker() {
        #expect(!MediaSessionAudioPolicy.routeCapableOptions.contains(.defaultToSpeaker))
        #expect(MediaSessionAudioPolicy.routeCapableOptions.contains(.allowBluetoothHFP))
        #expect(MediaSessionAudioPolicy.routeCapableOptions.contains(.allowBluetoothA2DP))
    }

    @MainActor
    @Test func mediaEncryptionSessionSurvivesMediaCloseForBackgroundWakeReceive() throws {
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
            channelID: "channel-1",
            peerDeviceID: "device-b"
        )
        let session = try #require(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID))
        let context = session.context(senderDeviceID: "device-b", receiverDeviceID: session.localDeviceID)
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

        viewModel.closeMediaSession()

        #expect(viewModel.mediaRuntime.mediaEncryptionSession(for: contactID) != nil)
        #expect(
            try viewModel.openIncomingMediaPayloadIfPossible(
                encrypted,
                channelID: "channel-1",
                fromDeviceID: "device-b",
                contactID: contactID
            ) == "pcm-audio"
        )
    }

    @MainActor
    @Test func pttCoordinatorPublishesJoinedStateBeforeJoinEffectsComplete() async {
        let coordinator = PTTCoordinator()
        let contactID = UUID()
        let channelUUID = UUID()
        var stateObservedBeforeEffect = false
        var effectStarted = false

        coordinator.effectHandler = { effect in
            guard case .syncJoinedChannel = effect else { return }
            effectStarted = true
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        await coordinator.handle(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test"),
            afterStateUpdate: {
                stateObservedBeforeEffect = coordinator.state.isJoined
                    && coordinator.state.activeContactID == contactID
                    && !effectStarted
            }
        )

        #expect(stateObservedBeforeEffect)
        #expect(effectStarted)
        #expect(coordinator.state.isJoined)
    }

    @Test func apnsEnvironmentResolverUsesInfoPlistValueWhenPresent() {
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "development",
                fallback: .production
            ) == .development
        )
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "production",
                fallback: .development
            ) == .production
        )
    }

    @Test func apnsEnvironmentResolverFallsBackForMissingOrInvalidInfoPlistValue() {
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: nil,
                fallback: .development
            ) == .development
        )
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "sandbox",
                fallback: .production
            ) == .production
        )
    }

    @MainActor
    @Test func selectedFriendPrewarmHintRoutesThroughControlEventIngestorOnce() async throws {
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
        await viewModel.ingestBackendWebSocketSignal(envelope)

        #expect(viewModel.controlEventIngestor.state.processedEventIDs.count == 1)
        #expect(viewModel.diagnosticsTranscript.contains("Selected friend prewarm hint received"))
        #expect(viewModel.diagnosticsTranscript.contains("Ignored control event"))
    }

    @Test func speakerOverridePlanSkipsOverrideWhenSpeakerAlreadyActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInSpeaker]
        )

        #expect(!plan.shouldApplySpeakerOverride)
    }

    @Test func speakerOverridePlanRequestsOverrideWhenReceiverIsActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInReceiver]
        )

        #expect(plan.shouldApplySpeakerOverride)
    }

    @Test func phoneOverridePlanClearsSpeakerOverrideWhenSpeakerIsActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .phone,
            category: .playAndRecord,
            outputPortTypes: [.builtInSpeaker]
        )

        #expect(!plan.shouldApplySpeakerOverride)
        #expect(plan.shouldClearSpeakerOverride)
    }

    @Test func phoneOverridePlanPreservesReceiverRoute() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .phone,
            category: .playAndRecord,
            outputPortTypes: [.builtInReceiver]
        )

        #expect(!plan.shouldApplySpeakerOverride)
        #expect(!plan.shouldClearSpeakerOverride)
    }

    @Test func speakerOverridePlanPreservesBluetoothRoute() {
        let hfpPlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.bluetoothHFP]
        )
        let a2dpPlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.bluetoothA2DP]
        )

        #expect(!hfpPlan.shouldApplySpeakerOverride)
        #expect(!a2dpPlan.shouldApplySpeakerOverride)
    }

    @Test func phoneOverridePlanPreservesBluetoothRoute() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .phone,
            category: .playAndRecord,
            outputPortTypes: [.bluetoothHFP]
        )

        #expect(!plan.shouldApplySpeakerOverride)
        #expect(!plan.shouldClearSpeakerOverride)
    }

    @Test func selectedConversationStateKeepsReadyWhileReceiveAudioSessionRewarmsAfterConnectedCall() {
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
                hadConnectedDevicePTTContinuity: true,
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

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedConversationState: state,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedConversationStateShowsWakeReadyWhenPeerBackgroundsWakeCapable() {
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
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedConversationStateDoesNotShowWakeReadyWithoutAppleSessionEvidence() {
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
                systemSessionMatchesContact: false,
                systemSessionState: .none,
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
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
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
    }

    @Test func backgroundReceiverNotReadySignalUpdatesRemoteReadinessStateToWakeCapable() {
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
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @MainActor
    @Test func receiverNotReadyBackgroundClosureReleasesLocalInteractivePrewarm() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
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
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @MainActor
    @Test func receiverReadySignalResumesLocalInteractivePrewarmAfterBackgroundClosure() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.applicationStateOverride = .active
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
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-connected"
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func receiverReadySignalDoesNotReassertDuplicateLocalReceiverReadinessAfterLifecyclePublish() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)

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
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        var capturedEffects: [ControlPlaneEffect] = []
        viewModel.controlPlaneCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle,
            telemetry: nil
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-connected"
            )
        )

        await Task.yield()
        await Task.yield()
        await Task.yield()

        let channelRefreshPublish = capturedEffects.compactMap { effect -> ReceiverAudioReadinessIntent? in
            guard case .publishReceiverAudioReadiness(let intent) = effect,
                  intent.contactID == contactID,
                  intent.reason == .channelRefresh else {
                return nil
            }
            return intent
        }.first
        #expect(channelRefreshPublish == nil)
    }

    @Test func fetchedWaitingReadinessPreservesWakeCapableWhenDevicePTTSessionRemainsRoutableAfterPeerBackgrounds() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func transmitExecutionReducerTreatsBackgroundSystemEndAsImplicitRelease() {
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

        let transition = TransmitExecutionReducer.reduce(
            state: state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: false,
                matchingActiveTarget: target
            )
        )

        #expect(transition.state.isPressingTalk == false)
        #expect(transition.state.requiresReleaseBeforeNextPress == false)
        #expect(transition.state.activeTarget == target)
        #expect(transition.state.lastSystemTransmitBeganAt == nil)
        #expect(transition.effects == [.handledSystemTransmitEnded(.implicitRelease)])
    }

    @Test func transmitExecutionReducerTreatsForegroundSystemEndAsFreshPressBarrier() {
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

        let transition = TransmitExecutionReducer.reduce(
            state: state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: true,
                matchingActiveTarget: target
            )
        )

        #expect(transition.state.isPressingTalk == false)
        #expect(transition.state.requiresReleaseBeforeNextPress == true)
        #expect(transition.state.interruptedContactID == target.contactID)
        #expect(transition.state.activeTarget == target)
        #expect(transition.effects == [.handledSystemTransmitEnded(.requireFreshPress(contactID: target.contactID))])
    }

    @Test func transmitRuntimeAllowsSystemTransmitActivationOnlyOncePerLifecycle() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBegan()

        let firstActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        let secondActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(firstActivationStart)
        #expect(!secondActivationStart)

        runtime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
        let activationAfterCompletion = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(!activationAfterCompletion)

        runtime.noteSystemTransmitEnded()
        runtime.noteSystemTransmitBegan()

        let activationAfterSystemEnd = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(activationAfterSystemEnd)
    }

    @MainActor
    @Test func systemTransmitDoesNotCloseMediaSessionDuringPTTAudioActivation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
        viewModel.isPTTAudioSessionActive = true

        #expect(!viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func appleGatedTransmitPolicyClosesPrewarmedDirectMediaBeforeAppleAudioActivation() {
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

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
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

        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID))
        #expect(viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
        #expect(viewModel.shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func pendingPTTHandoffDoesNotReassertPrewarmedDirectCaptureBeforeAudioActivation() async {
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
            trigger: "test-pre-activation"
        )

        #expect(!didStartBridge)
        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring warm Direct QUIC capture until Apple audio activation"
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshPreservesRequestingTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .requesting(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshDoesNotPreserveIdleTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            !viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .idle,
                    isPressActive: false,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshPreservesActiveTransmitLifecycleWhileHoldRemainsPressed() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .active(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @Test func mediaRuntimeResetClearsOutgoingAudioRoute() {
        let runtime = MediaRuntimeState()
        runtime.replaceSendAudioChunk(with: { _ in })

        #expect(runtime.hasSendAudioChunk)

        runtime.reset()

        #expect(!runtime.hasSendAudioChunk)
    }

    @MainActor
    @Test func pttStopFailureClassifierTreatsCodeFiveAsExpected() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 5)

        #expect(viewModel.isExpectedPTTStopFailure(error))
    }

    @MainActor
    @Test func pttRemoteParticipantClearClassifierTreatsCodeFiveAsExpected() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 5)

        #expect(viewModel.isExpectedPTTRemoteParticipantClearFailure(error))
    }

    @MainActor
    @Test func pttChannelUnavailableClassifierTreatsCodeOneAsRecoverable() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 1)

        #expect(viewModel.isRecoverablePTTChannelUnavailable(error))
    }

    @MainActor
    @Test func pttTransmissionInProgressClassifierTreatsCodeFourAsRecoverable() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 4)

        #expect(viewModel.isRecoverablePTTTransmissionInProgress(error))
    }

    @MainActor
    @Test func joinedPTTChannelRequestsHalfDuplexTransmissionMode() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
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

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.transmissionModeUpdates.count == 1)
        #expect(pttClient.transmissionModeUpdates.first?.mode == .halfDuplex)
        #expect(pttClient.transmissionModeUpdates.first?.channelUUID == channelUUID)
        #expect(viewModel.diagnosticsTranscript.contains("Updated PTT transmission mode"))
    }

    @MainActor
    @Test func backgroundSystemTransmitBeginWhileWakeReadyStartsBackendRequest() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
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
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.stopTransmitRequests.isEmpty)
        #expect(viewModel.transmitCoordinator.state.phase == .requesting(contactID: contactID))
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(viewModel.transmitRuntime.isSystemTransmitting)
        #expect(viewModel.diagnosticsTranscript.contains("[ptt.system_begin_while_peer_transmitting]") == false)
        #expect(viewModel.diagnosticsTranscript.contains("Beginning backend transmit after system-originated handoff"))
    }

    @Test func pttWakeRuntimeBuffersAudioUntilActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        #expect(runtime.shouldBufferAudioChunk(for: contactID))
        runtime.bufferAudioChunk("AQI=", for: contactID)
        runtime.bufferAudioChunk("AwQ=", for: contactID)

        let buffered = runtime.takeBufferedAudioChunks(for: contactID)

        #expect(buffered == ["AQI=", "AwQ="])
        #expect(runtime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)

        runtime.markAudioSessionActivated(for: channelUUID)

        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)
    }

    @Test func pttWakeRuntimeTracksIncomingPushAndFallbackStates() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        runtime.confirmIncomingPush(for: channelUUID, payload: payload)
        #expect(runtime.hasConfirmedIncomingPush(for: contactID))
        #expect(runtime.incomingWakeActivationState(for: contactID) == .awaitingSystemActivation)

        runtime.markFallbackDeferredUntilForeground(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationTimedOutWaitingForForeground)
        runtime.bufferAudioChunk("AQI=", for: contactID)
        #expect(runtime.bufferedAudioChunkCount(for: contactID) == 1)

        runtime.markSystemActivationInterruptedByTransmitEnd(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)
        #expect(runtime.pendingIncomingPush == nil)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)

        runtime.markAppManagedFallbackStarted(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .appManagedFallback)
    }

    @Test func pttWakeRuntimeTreatsConfirmedMatchingIncomingPushAsDuplicate() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "@blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let runtime = PTTWakeRuntimeState()
        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload,
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        #expect(
            runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        #expect(
            !runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel",
                    activeSpeaker: "@blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device-2"
                )
            )
        )
    }

    @Test func pttWakeRuntimeCanResetPlaybackFallbackTaskWithoutClearingPendingWake() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        runtime.replacePlaybackFallbackTask(for: contactID, with: Task { })
        #expect(runtime.hasPlaybackFallbackTask(for: contactID))

        runtime.clearPlaybackFallbackTask(for: contactID)

        #expect(runtime.hasPlaybackFallbackTask(for: contactID) == false)
        #expect(runtime.hasPendingWake(for: contactID))
        #expect(runtime.pendingIncomingPush?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmRecoversWithoutPTTDeactivationCallback() async {
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

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmWaitsWhilePTTAudioSessionIsStillActive() async {
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
        viewModel.isPTTAudioSessionActive = true

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotRecoverWithoutCallbackWhileBackgrounded() async {
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

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
            for: contactID,
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotResumeOnPTTDeactivationWhileBackgrounded() async {
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

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func foregroundJoinedReceivePrefersAppManagedPlaybackOverSystemActivation() {
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
        viewModel.remoteTransmittingContactIDs.insert(contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .directQuic
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .directQuic
            ) == false
        )
        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .mediaRelayPacket
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .mediaRelayPacket
            ) == false
        )
        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .mediaRelayTcp
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active,
                incomingAudioTransport: .mediaRelayTcp
            ) == false
        )
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            )
        )
    }

    @MainActor
    @Test func appleGatedForegroundJoinedReceiveUsesSystemActivatedPlayback() {
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
        viewModel.remoteTransmittingContactIDs.insert(contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.isPTTAudioSessionActive = true

        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active
            ) == false
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active
            )
        )
    }

    @Test func liveTransmitCaptureRouteRefreshRestartsRunningEngineAndTap() {
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: true,
            inputTapInstalled: true
        )

        #expect(plan.shouldStopEngine)
        #expect(plan.shouldResetEngine)
        #expect(plan.shouldRemoveInputTap)
        #expect(plan.shouldRestartEngine)
    }

    @MainActor
    @Test func incomingAudioChunkWaitsForPTTAudioActivationBeforeCreatingMediaSession() async throws {
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
                )
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI="])
    }

    @MainActor
    @Test func foregroundIncomingAudioChunkUsesExistingMediaPlaybackWithoutWake() async throws {
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
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(mediaSession.receivedRemoteAudioChunks == ["AQI="])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using app-managed wake playback for foreground audio"
            ) == false
        )
    }

    @MainActor
    @Test func appleGatedForegroundIncomingAudioChunkUsesExistingMediaPlaybackWithoutWake() async throws {
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
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(mediaSession.receivedRemoteAudioChunks == ["AQI="])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using app-managed wake playback for foreground audio"
            ) == false
        )
        #expect(
            viewModel.receiveExecutionCoordinator.state
                .remoteActivityByContactID[contactID]?.phase == .receivingAudio
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Buffered wake audio chunk until PTT activation"
            ) == false
        )

        viewModel.isPTTAudioSessionActive = true
        await viewModel.handleActivatedAudioSession(.sharedInstance())

        #expect(mediaSession.audioRouteDidChangeCallCount == 1)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Refreshed foreground receive playback after PTT audio activation"
            )
        )
    }

    @MainActor
    @Test func wakePlaybackFallbackKeepsBufferedAudioAvailableForLatePTTActivation() async throws {
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
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
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
                )
            )
        )
        viewModel.pttWakeRuntime.bufferAudioChunk("one", for: contactID)
        viewModel.pttWakeRuntime.bufferAudioChunk("two", for: contactID)

        let delayedSession = DelayedStartMediaSession(delayNanoseconds: 500_000_000)
        delayedSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: delayedSession, contactID: contactID)

        let fallbackTask = Task {
            await viewModel.runWakePlaybackFallbackIfNeeded(for: contactID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(delayedSession.startCallCount == 1)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["one", "two"])

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == [])
        #expect(
            viewModel.receiveExecutionCoordinator.state
                .remoteActivityByContactID[contactID]?.phase == .receivingAudio
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Flushing buffered wake audio after PTT activation"
            )
        )

        delayedSession.finishStart()
        await fallbackTask.value
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped app-managed playback fallback because wake activation changed during startup"
            )
        )
    }

    @MainActor
    @Test func latePTTAudioActivationPreservesForegroundAppManagedWakePlayback() async throws {
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
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
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
                playbackMode: .appManagedFallback,
                activationState: .appManagedFallback
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())

        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(mediaSession.audioRouteDidChangeCallCount == 1)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .appManagedFallback)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Preserved app-managed wake playback after late PTT audio activation"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Refreshed app-managed wake playback after late PTT audio activation"
            )
        )
    }

    @MainActor
    @Test func receiveTransmitStopDefersInteractiveAudioPrewarmUntilPTTAudioDeactivation() async throws {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
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

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)

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

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)

        await viewModel.handleDeactivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func channelRefreshRecoversMissingTransmitStopAndDefersInteractiveAudioPrewarmUntilPTTAudioDeactivation() async throws {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
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

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.remoteTransmittingContactIDs.insert(contactID)

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
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)

        await viewModel.handleDeactivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutKeepsForegroundInteractiveMediaWarm() async throws {
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
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Kept receive media session warm after remote audio ended"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Media state changed state=closed"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutKeepsForegroundInteractiveMediaWarmWhilePTTAudioIsStillActive() async throws {
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
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.isPTTAudioSessionActive = true
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
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Kept receive media session warm after remote audio ended"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Media state changed state=closed"
            )
        )
    }

    @MainActor
    @Test func foregroundMissingFirstAudioChunkUsesShortInitialTimeout() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.remoteAudioInitialChunkTimeoutNanoseconds = 5_000_000_000
        viewModel.remoteAudioForegroundInitialChunkTimeoutNanoseconds = 80_000_000
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

        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
        try await Task.sleep(nanoseconds: 160_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )
    }

    @MainActor
    @Test func backgroundAudioChunkDoesNotRearmWakeAfterSystemAudioActivation() async throws {
        let viewModel = PTTViewModel()
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

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func backgroundAudioChunkAfterPTTDeactivationBuffersActiveReceiveFlow() async throws {
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
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )
        viewModel.isPTTAudioSessionActive = false

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.phase == .receivingAudio
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(viewModel.pttWakeRuntime.bufferedAudioChunkCount(for: contactID) == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Created provisional wake candidate from signal path"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Buffered wake audio chunk until PTT activation"
            )
        )
    }

    @MainActor
    @Test func backendTransmitPrepareRearmsSuppressedBackgroundWakeAfterDirectAudioBeatsControlPlane() async throws {
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
        viewModel.pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(pttClient.activeRemoteParticipantUpdates.isEmpty)

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

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AwQ="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.bufferedAudioChunkCount(for: contactID) == 1)
    }

    @MainActor
    @Test func pttAudioActivationCreatesSystemPlaybackSessionAndFlushesBufferedWakeAudio() async throws {
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

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .systemActivated)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
    }

    @MainActor
    @Test func foregroundIncomingPTTPushReassertsBackendJoinWhenDevicePTTEvidenceOutlivesBackendMembership() async throws {
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
        client.enableReceiverAudioReadinessCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .active
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

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID && request.intent == .joinReadyFriend
            }
        )
    }

    @MainActor
    @Test func pttAudioActivationPreservesExistingAppManagedAudioSessionWhileHandingOffToSystemPlayback() async throws {
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

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

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

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func pttAudioActivationCreatesPlaybackBeforeDeferredBackendRefreshFails() async throws {
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
        pendingPush.bufferedAudioChunks = ["AQI="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.diagnosticsTranscript.contains("Deferring wake backend refresh off audio activation critical path"))
        #expect(viewModel.diagnosticsTranscript.contains("Contact sync failed"))

        let messages = viewModel.diagnostics.entries.map(\.message)
        let recreateIndex = messages.lastIndex(of: "Recreating media session after PTT audio activation")
        let deferIndex = messages.lastIndex(of: "Deferring wake backend refresh off audio activation critical path")
        let failureIndex = messages.lastIndex(of: "Contact sync failed")

        #expect(recreateIndex != nil)
        #expect(deferIndex != nil)
        #expect(failureIndex != nil)
        if let recreateIndex, let deferIndex, let failureIndex {
            #expect(recreateIndex > deferIndex)
            #expect(deferIndex > failureIndex)
        }
    }

    @Test func systemActivatedPlaybackOnlyPreservesExistingAudioSessionConfiguration() {
        let configuration = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(configuration.shouldConfigureSession == false)
        #expect(configuration.shouldActivateSession == false)
        #expect(configuration.category == .playAndRecord)
    }

    @MainActor
    @Test func closeMediaSessionPreservesAudioSessionWhileWakeActivationIsPending() {
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

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
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

        viewModel.closeMediaSession()

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @MainActor
    @Test func backgroundTransitionSuspendsIdleForegroundMediaSession() async throws {
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

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .inactive
            )
        )

        await viewModel.suspendForegroundMediaForBackgroundTransition(
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @MainActor
    @Test func proximityInactiveTransitionPreservesLiveForegroundMediaSession() async throws {
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
        viewModel.proximityMonitoringIsActive = true
        viewModel.isPhoneNearEar = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .inactive
            ) == false
        )

        await viewModel.suspendForegroundMediaForBackgroundTransition(
            reason: "application-will-resign-active",
            applicationState: .inactive
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Suspending foreground media for background transition"
            )
        )
    }

    @MainActor
    @Test func backgroundMediaClosedReadinessIntentForcesNotReadyWhileMediaIsConnected() {
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
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        let intent = viewModel.receiverAudioReadinessIntent(
            for: contactID,
            reason: .appBackgroundMediaClosed
        )

        #expect(intent?.isReady == false)
        #expect(intent?.reason == .appBackgroundMediaClosed)
    }

    @MainActor
    @Test func backgroundReceiverNotReadyRefreshUsesWakeCapableReason() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
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

        #expect(!viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        let telemetryIntent = viewModel.receiverAudioReadinessIntent(
            for: contactID,
            reason: .telemetryRefresh
        )
        let channelRefreshIntent = viewModel.receiverAudioReadinessIntent(
            for: contactID,
            reason: .channelRefresh
        )

        #expect(telemetryIntent?.isReady == false)
        #expect(telemetryIntent?.reason == .appBackgroundMediaClosed)
        #expect(channelRefreshIntent?.isReady == false)
        #expect(channelRefreshIntent?.reason == .appBackgroundMediaClosed)
    }

    @MainActor
    @Test func backgroundTransitionDoesNotSuspendActiveTransmitSession() async throws {
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
        viewModel.seedEngineActiveTransmitForTesting(
            contactID: contactID,
            channelID: "channel-123",
            localDeviceID: "local-device",
            peerDeviceID: "peer-device"
        )
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func activateTransmitStartsLeaseRenewalBeforePTTActivationCompletes() async {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()
        let contactID = UUID()

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
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-1",
            remoteUserID: "user-avery",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-1"
        )

        await viewModel.runTransmitEffect(.activateTransmit(request, target))

        #expect(viewModel.transmitTaskCoordinator.state.renewal.target == target)
        #expect(viewModel.transmitTaskRuntime.renewalTask != nil)
        #expect(viewModel.transmitTaskRuntime.renewalChannelID == "channel-1")
    }

    @MainActor
    @Test func lifecycleInterruptionCancelsActiveHoldToTalkTransmit() async throws {
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
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()
        viewModel.syncTransmitState()

        #expect(viewModel.transmitDomainSnapshot.isPressActive)

        let cancelled = viewModel.cancelActiveTransmitForLifecycleInterruption(
            reason: "application-will-resign-active"
        )

        #expect(cancelled)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitDomainSnapshot.isPressActive == false)
        #expect(viewModel.transmitDomainSnapshot.hasTransmitIntent(for: contactID) == false)

        try await waitForScenario(
            "lifecycle interruption drives transmit coordinator toward stop",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID)
                && viewModel.transmitCoordinator.state.isPressingTalk == false
        }

        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Cancelling active transmit for lifecycle interruption"
                    && $0.metadata["reason"] == "application-will-resign-active"
            }
        )
    }

    @MainActor
    @Test func foregroundSystemTransmitBeginWithoutLocalPressIsRejected() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .active
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

        #expect(viewModel.isTransmitting == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.transmitRuntime.isSystemTransmitting == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitCoordinator.state.phase == .idle)
        #expect(viewModel.diagnosticsTranscript.contains("[ptt.foreground_system_begin_without_local_press]"))
    }

    @MainActor
    @Test func systemTransmitEndCallbackClearsStuckPTTStateAfterRuntimeLifecycleAlreadyCleared() async {
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
        #expect(viewModel.transmitRuntime.hasSystemTransmitLifecycle == false)

        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
        #expect(viewModel.diagnostics.entries.contains {
            $0.message == "System transmit ended"
                && $0.metadata["runtimeHadSystemLifecycle"] == "false"
                && $0.metadata["systemWasTransmitting"] == "true"
        })
    }

    @MainActor
    @Test func backgroundSystemTransmitBeginWithoutLocalPressStartsSystemOriginatedTransmitRequest() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .background
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

        #expect(viewModel.transmitCoordinator.state.phase == .requesting(contactID: contactID))
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(viewModel.transmitCoordinator.state.pendingRequest?.channelUUID == channelUUID)
        #expect(viewModel.transmitRuntime.isPressingTalk)
    }

    @MainActor
    @Test func backgroundSystemTransmitEndActsAsImplicitReleaseWithoutFreshPressBarrier() async throws {
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

        viewModel.applicationStateOverride = .background
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
            "background system transmit end is handled as an implicit release",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.transmitRuntime.isPressingTalk == false
                && viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID)
        }

        let snapshot = viewModel.transmitDomainSnapshot
        #expect(snapshot.requiresFreshPress(for: contactID) == false)
        #expect(snapshot.isPressActive == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID))
    }

    @MainActor
    @Test func protectedDataLockPublishesOfflinePresenceBeforeBackgroundTransition() async {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()

        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundOfflinePresenceHandler = {
            probe.recordOfflineStart()
            probe.recordOfflineFinish()
        }

        await viewModel.publishLifecyclePresenceTransitionIfNeeded(
            reason: "protected-data-will-become-unavailable"
        )

        #expect(probe.offlineStarted)
        #expect(probe.offlineCount == 1)
        #expect(probe.events.contains("background-task-begin:offline-presence"))
        #expect(probe.events.contains("offline-start"))
        #expect(probe.events.contains("offline-finish"))
    }

    @MainActor
    @Test func protectedDataLockAndBackgroundTransitionDeduplicateOfflinePresencePublish() async {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()

        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: probe.events.count + 1)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundWebSocketSuspendHandler = {
            probe.recordSuspend()
        }
        viewModel.backgroundOfflinePresenceHandler = {
            probe.recordOfflineStart()
            probe.recordOfflineFinish()
        }

        await viewModel.publishLifecyclePresenceTransitionIfNeeded(
            reason: "protected-data-will-become-unavailable"
        )
        await viewModel.handleApplicationDidEnterBackground()

        #expect(probe.offlineCount == 1)
        #expect(probe.suspendCount == 1)
        #expect(viewModel.diagnosticsTranscript.contains("Skipped duplicate lifecycle presence transition"))
    }

    @MainActor
    @Test func willResignActiveSchedulingPublishesOfflinePresenceImmediately() async throws {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()

        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: probe.events.count + 1)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundOfflinePresenceHandler = {
            probe.recordOfflineStart()
            probe.recordOfflineFinish()
        }

        viewModel.scheduleApplicationWillResignActiveHandling()

        try await waitForScenario(
            "will resign active publishes offline presence",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            probe.offlineStarted
        }

        #expect(probe.offlineCount == 1)
        #expect(probe.events.contains("background-task-begin:application-will-resign-active"))
        #expect(probe.events.contains("background-task-begin:offline-presence"))
        #expect(probe.events.firstIndex(of: "background-task-begin:offline-presence")! < probe.events.firstIndex(of: "offline-finish")!)
    }

    @MainActor
    @Test func foregroundPresenceTransitionPublishesOnlineImmediately() async throws {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false)
        )
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: false
        )

        var heartbeatPath: String?
        var heartbeatCommandKind: String?
        client.controlCommandHTTPResponseForTesting = { path, envelope in
            heartbeatPath = path
            heartbeatCommandKind = envelope.commandKind
            return makePresenceHeartbeatResponseData(status: "online")
        }

        await viewModel.publishForegroundPresenceTransition(reason: "test-foreground")

        #expect(heartbeatPath == "/v1/presence/heartbeat")
        #expect(heartbeatCommandKind == "presence-heartbeat")
        #expect(viewModel.diagnosticsTranscript.contains("Foreground presence publish succeeded"))
    }

    @Test func pttReducerRestoredUnknownChannelIsMismatched() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .restoredChannel(channelUUID: channelUUID, contactID: nil)
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.systemSessionState == .mismatched(channelUUID: channelUUID))
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerJoinEmitsSyncEffect() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "push")
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.activeContactID == contactID)
        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: channelUUID))
        #expect(transition.effects == [.syncJoinedChannel(contactID: contactID)])
    }

    @Test func pttReducerLeaveEmitsSyncAndAutoRejoinEffects() {
        let contactID = UUID()
        let channelUUID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "manual")
        ).state
        let autoRejoinContactID = UUID()

        let transition = PTTReducer.reduce(
            state: joinedState,
            event: .didLeaveChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "switch",
                autoRejoinContactID: autoRejoinContactID,
                shouldPropagateBackendLeave: true
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.systemSessionState == .none)
        #expect(
            transition.effects == [
                .syncLeftChannel(
                    contactID: contactID,
                    autoRejoinContactID: autoRejoinContactID,
                    shouldPropagateBackendLeave: true
                )
            ]
        )
    }

    @Test func pttReducerSystemTransmitFailureEmitsTransmitFailureEffect() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: PTTSessionState(
                systemChannelUUID: channelUUID,
                activeContactID: UUID(),
                isJoined: true,
                isTransmitting: true,
                lastError: nil
            ),
            event: .failedToBeginTransmitting(channelUUID: channelUUID, message: "denied")
        )

        #expect(transition.state.isTransmitting == false)
        #expect(transition.state.lastError == "denied")
        #expect(transition.effects == [.handleSystemTransmitFailure("denied")])
    }

    @Test func pttSessionStateDoesNotRepresentTransmitWithoutSystemChannel() {
        let impossibleTransmittingState = PTTSessionState(
            systemChannelUUID: nil,
            activeContactID: UUID(),
            isJoined: false,
            isTransmitting: true
        )
        let impossibleJoinedState = PTTSessionState(
            systemChannelUUID: nil,
            activeContactID: UUID(),
            isJoined: true,
            isTransmitting: false
        )

        #expect(impossibleTransmittingState.systemSessionState == .none)
        #expect(impossibleTransmittingState.isJoined == false)
        #expect(impossibleTransmittingState.isTransmitting == false)
        #expect(impossibleJoinedState.systemSessionState == .none)
        #expect(impossibleJoinedState.isJoined == false)
        #expect(impossibleJoinedState.isTransmitting == false)
    }

    @Test func pttReducerExplicitStopReconciliationClearsMatchingStuckTransmission() {
        let channelUUID = UUID()
        let contactID = UUID()
        let transmittingState = PTTSessionState(
            systemChannelUUID: channelUUID,
            activeContactID: contactID,
            isJoined: true,
            isTransmitting: true
        )

        let transition = PTTReducer.reduce(
            state: transmittingState,
            event: .didEndTransmitting(
                channelUUID: channelUUID,
                origin: .explicitStopReconciliation(source: "test-fallback")
            )
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.activeContactID == contactID)
        #expect(transition.state.systemChannelUUID == channelUUID)
        #expect(transition.state.isTransmitting == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerExplicitStopReconciliationIgnoresAlreadyIdleSession() {
        let channelUUID = UUID()
        let idleState = PTTSessionState(
            systemChannelUUID: channelUUID,
            activeContactID: UUID(),
            isJoined: true,
            isTransmitting: false
        )

        let transition = PTTReducer.reduce(
            state: idleState,
            event: .didEndTransmitting(
                channelUUID: channelUUID,
                origin: .explicitStopReconciliation(source: "test-fallback")
            )
        )

        #expect(transition.state == idleState)
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerSystemEndCallbackClearsStuckTransmissionWithoutRuntimeLifecycle() {
        let channelUUID = UUID()
        let transmittingState = PTTSessionState(
            systemChannelUUID: channelUUID,
            activeContactID: UUID(),
            isJoined: true,
            isTransmitting: true
        )

        let transition = PTTReducer.reduce(
            state: transmittingState,
            event: .didEndTransmitting(
                channelUUID: channelUUID,
                origin: .systemCallback(source: "system-ui")
            )
        )

        #expect(transition.state.isTransmitting == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func systemTransmitBeginOriginClassifiesForegroundAppPress() {
        let origin = SystemTransmitBeginOrigin.classify(
            applicationIsActive: true,
            hadPendingSystemBegin: true,
            hasCallbackTarget: false,
            hasPendingLifecycle: false,
            runtimeIsPressingTalk: true,
            coordinatorIsPressingTalk: false,
            hasPendingBeginOrActiveTransmit: true
        )

        #expect(origin == .foregroundAppPress)
        #expect(origin.isSystemOriginated == false)
    }

    @Test func systemTransmitBeginOriginClassifiesForegroundUnownedCallback() {
        let origin = SystemTransmitBeginOrigin.classify(
            applicationIsActive: true,
            hadPendingSystemBegin: false,
            hasCallbackTarget: false,
            hasPendingLifecycle: false,
            runtimeIsPressingTalk: false,
            coordinatorIsPressingTalk: false,
            hasPendingBeginOrActiveTransmit: false
        )

        #expect(origin == .foregroundSystemCallbackWithoutLocalIntent)
        #expect(origin.isRejectedForegroundUnownedBegin)
    }

    @Test func systemTransmitBeginOriginClassifiesBackgroundWakeHandoff() {
        let origin = SystemTransmitBeginOrigin.classify(
            applicationIsActive: false,
            hadPendingSystemBegin: false,
            hasCallbackTarget: false,
            hasPendingLifecycle: false,
            runtimeIsPressingTalk: false,
            coordinatorIsPressingTalk: false,
            hasPendingBeginOrActiveTransmit: false
        )

        #expect(origin == .backgroundWakeHandoff)
        #expect(origin.isSystemOriginated)
    }

    @Test func pttReducerDoesNotRepresentTransmitWithoutJoinedSession() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )

        #expect(transition.state.systemSessionState == .none)
        #expect(transition.state.isJoined == false)
        #expect(transition.state.isTransmitting == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerIgnoresTransmitBeginForDifferentSystemChannel() {
        let joinedChannelUUID = UUID()
        let otherChannelUUID = UUID()
        let contactID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: joinedChannelUUID, contactID: contactID, reason: "test")
        ).state

        let transition = PTTReducer.reduce(
            state: joinedState,
            event: .didBeginTransmitting(channelUUID: otherChannelUUID, origin: .foregroundAppPress)
        )

        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: joinedChannelUUID))
        #expect(transition.state.isJoined)
        #expect(transition.state.isTransmitting == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerIgnoresTransmitFailureForDifferentSystemChannel() {
        let joinedChannelUUID = UUID()
        let otherChannelUUID = UUID()
        let contactID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: joinedChannelUUID, contactID: contactID, reason: "test")
        ).state
        let transmittingState = PTTReducer.reduce(
            state: joinedState,
            event: .didBeginTransmitting(channelUUID: joinedChannelUUID, origin: .foregroundAppPress)
        ).state

        let transition = PTTReducer.reduce(
            state: transmittingState,
            event: .failedToBeginTransmitting(channelUUID: otherChannelUUID, message: "denied")
        )

        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: joinedChannelUUID))
        #expect(transition.state.isTransmitting)
        #expect(transition.state.lastError == nil)
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerFailedJoinDoesNotClearDifferentActiveSystemSession() {
        let joinedChannelUUID = UUID()
        let failedChannelUUID = UUID()
        let contactID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: joinedChannelUUID, contactID: contactID, reason: "test")
        ).state

        let transition = PTTReducer.reduce(
            state: joinedState,
            event: .failedToJoinChannel(
                channelUUID: failedChannelUUID,
                contactID: nil,
                reason: .other(message: "denied")
            )
        )

        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: joinedChannelUUID))
        #expect(transition.state.isJoined)
        #expect(transition.state.lastError == "denied")
        #expect(
            transition.state.lastJoinFailure
                == PTTJoinFailure(
                    contactID: nil,
                    channelUUID: failedChannelUUID,
                    reason: .other(message: "denied")
                )
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerCapturesJoinFailureReasonAndContact() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .failedToJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: .channelLimitReached
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.lastError == "Channel limit reached")
        #expect(
            transition.state.lastJoinFailure
                == PTTJoinFailure(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: .channelLimitReached
                )
        )
        #expect(transition.effects == [.closeMediaSession])
    }

    @MainActor
    @Test func backendLeaveCommandRoutesThroughControlEventIngestorOnce() async {
        let contactID = UUID()
        let viewModel = PTTViewModel()
        var effects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            effects.append(effect)
        }
        let request = BackendLeaveRequest(
            contactID: contactID,
            backendChannelID: "channel-1",
            operationID: "leave-operation-1"
        )

        await viewModel.ingestBackendCommandEvent(
            .leaveRequested(request),
            contactID: contactID,
            channelID: "channel-1"
        )
        await viewModel.ingestBackendCommandEvent(
            .leaveRequested(request),
            contactID: contactID,
            channelID: "channel-1"
        )

        #expect(effects == [.leave(request)])
        #expect(viewModel.controlEventIngestor.state.processedEventIDs == Set(["backend-command:leave-operation-1"]))
        #expect(viewModel.diagnosticsTranscript.contains("Ignored control event"))
    }

    @Test func controlPlaneReducerDoesNotRepublishReadyOnFirstChannelRefreshAfterLifecyclePublish() {
        let contactID = UUID()
        let lifecycleIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .mediaState(.connected),
            telemetry: nil
        )
        let refreshIntent = ReceiverAudioReadinessIntent(
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
                    contactID: .published(lifecycleIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                refreshIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects.isEmpty)
    }

    @Test func controlPlaneReducerDoesNotRepublishLifecycleTelemetryAfterEquivalentChannelRefresh() {
        let contactID = UUID()
        let telemetry = ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 70),
            connection: .init(interface: .wifi)
        )
        let refreshIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .channelRefresh,
            telemetry: telemetry
        )
        let telemetryIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: .telemetryRefresh,
            telemetry: telemetry
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(refreshIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                telemetryIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects.isEmpty)
    }

    @MainActor
    @Test func applicationDidBecomeActiveRequestsBackendPollForSelectedContactAfterBootstrapEstablished() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(.bootstrapCompleted(mode: "cloud", handle: "@self"))

        var capturedEffects: [BackendSyncEffect] = []
        viewModel.backendSyncCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(
            capturedEffects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshForegroundControlPlane(selectedContactID: contactID)
            ]
        )
    }

    @MainActor
    @Test func applicationDidBecomeActiveCanSkipAppManagedAudioPrewarmWhenDisabled() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = false
        viewModel.applicationStateOverride = .active
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

        await viewModel.handleApplicationDidBecomeActive()

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped app-managed interactive audio prewarm after app activation"
            )
        )
    }

    @MainActor
    @Test func transientBackendBootstrapFailureRetriesWhenForegrounded() {
        let viewModel = PTTViewModel()
        let error = URLError(.timedOut)

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .active
            )
        )
    }

    @MainActor
    @Test func transientBackendBootstrapFailureDoesNotRetryInBackground() {
        let viewModel = PTTViewModel()
        let error = URLError(.timedOut)

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func transientForegroundSyncFailureRecoversConnectedControlPlane() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")

        #expect(
            viewModel.shouldRecoverBackendControlPlaneAfterSyncFailure(
                URLError(.timedOut),
                applicationState: .active
            )
        )
    }

    @MainActor
    @Test func foregroundPresencePublishingRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .active))
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .inactive) == false)
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .background) == false)
    }

    @MainActor
    @Test func presenceHeartbeatContinuesForLiveJoinedSessionOutsideForeground() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: UUID(), contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        #expect(viewModel.shouldPublishPresenceHeartbeat(applicationState: .background) == true)
        #expect(viewModel.shouldPublishPresenceHeartbeat(applicationState: .inactive) == true)
    }

    @MainActor
    @Test func presenceHeartbeatDoesNotContinueInBackgroundWithoutLiveControlPlaneNeed() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldPublishPresenceHeartbeat(applicationState: .background) == false)
        #expect(viewModel.shouldPublishPresenceHeartbeat(applicationState: .inactive) == false)
    }

    @MainActor
    @Test func pttSyncThenChannelRefreshDoesNotRepublishReceiverReadyWithinSameControlPlaneEpoch() async {
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

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .pttSync)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)

        let receiverReadySignals = client.sentSignalsForTesting().filter { $0.type == .receiverReady }
        #expect(receiverReadySignals.count == 1)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Republishing receiver audio readiness because backend has not observed local ready"
            )
        )
        #expect(
            viewModel.localReceiverAudioReadinessPublications[contactID]?.basis == .lifecycle
        )
    }

    @MainActor
    @Test func routeAndTelemetryRefreshDoNotRepublishReceiverReadyWhileBackendReadyObservationLags() async {
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
        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .audioRouteChange)
        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .telemetryRefresh)

        #expect(client.sentSignalsForTesting().filter { $0.type == .receiverReady }.count == 1)
    }

    @MainActor
    @Test func backgroundWakeReceiverAudioReadinessUsesAlignedLocalSessionWhileBackendMembershipLags() async {
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
        client.enableReceiverAudioReadinessCaptureForTesting()

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
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

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == true)
        #expect(client.receiverAudioReadinessPublishesForTesting().count == 1)
        #expect(client.receiverAudioReadinessPublishesForTesting().first?.type == TurboSignalKind.receiverReady.rawValue)
        #expect(viewModel.diagnosticsTranscript.contains("Published receiver audio readiness"))
        #expect(viewModel.diagnosticsTranscript.contains("transport=http"))
        #expect(!viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(viewModel.diagnosticsTranscript.contains("state=ready"))
    }

    @MainActor
    @Test func systemOriginatedBackgroundTransmitWaitsForWakeJoinVisibilityBeforeLease() async throws {
        let events = LockedStringEvents()
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
        let leaseFormatter = ISO8601DateFormatter()
        let leaseStartedAt = leaseFormatter.string(from: Date())
        let leaseExpiresAt = leaseFormatter.string(from: Date().addingTimeInterval(30))

        TurboBackendCriticalHTTPClient.beginTransmitOverride = { channelId in
            events.append("begin-lease")
            return TurboBeginTransmitResponse(
                channelId: channelId,
                status: "transmitting",
                transmitId: "transmit-1",
                startedAt: leaseStartedAt,
                expiresAt: leaseExpiresAt,
                targetUserId: "peer-user",
                targetDeviceId: "peer-device"
            )
        }
        defer { TurboBackendCriticalHTTPClient.beginTransmitOverride = nil }

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
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.backendCommandCoordinator.effectHandler = { effect in
            guard case .join(let request) = effect else { return }
            #expect(request.deviceSessionProof == .pttSystem)
            events.append("join-start")
            try? await Task.sleep(nanoseconds: 100_000_000)
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
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true
                    )
                )
            )
            events.append("join-visible")
            viewModel.backendCommandCoordinator.send(.operationFinished)
        }

        await viewModel.handleSystemOriginatedBeginTransmitIfNeeded(
            channelUUID: channelUUID,
            source: "test",
            origin: .backgroundWakeHandoff
        )

        for _ in 0..<40 {
            if events.snapshot().contains("begin-lease") {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(events.snapshot() == ["join-start", "join-visible", "begin-lease"])
        #expect(viewModel.backendJoinIsVisibleForCriticalOperation(contactID: contactID))
    }

    @MainActor
    @Test func systemOriginatedBackgroundTransmitRefreshesAuthoritativeJoinEvenWhenSnapshotLooksVisible() async throws {
        let events = LockedStringEvents()
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
        let leaseFormatter = ISO8601DateFormatter()
        let leaseStartedAt = leaseFormatter.string(from: Date())
        let leaseExpiresAt = leaseFormatter.string(from: Date().addingTimeInterval(30))

        TurboBackendCriticalHTTPClient.beginTransmitOverride = { channelId in
            events.append("begin-lease")
            return TurboBeginTransmitResponse(
                channelId: channelId,
                status: "transmitting",
                transmitId: "transmit-1",
                startedAt: leaseStartedAt,
                expiresAt: leaseExpiresAt,
                targetUserId: "peer-user",
                targetDeviceId: "peer-device"
            )
        }
        defer { TurboBackendCriticalHTTPClient.beginTransmitOverride = nil }

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
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true
                )
            )
        )

        viewModel.backendCommandCoordinator.effectHandler = { effect in
            guard case .join(let request) = effect else { return }
            #expect(request.deviceSessionProof == .pttSystem)
            events.append("join-start")
            try? await Task.sleep(nanoseconds: 100_000_000)
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
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true
                    )
                )
            )
            events.append("join-visible")
            viewModel.backendCommandCoordinator.send(.operationFinished)
        }

        await viewModel.handleSystemOriginatedBeginTransmitIfNeeded(
            channelUUID: channelUUID,
            source: "test",
            origin: .backgroundWakeHandoff
        )

        for _ in 0..<40 {
            if events.snapshot().contains("begin-lease") {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(events.snapshot() == ["join-start", "join-visible", "begin-lease"])
        #expect(viewModel.backendJoinIsVisibleForCriticalOperation(contactID: contactID))
    }

    @MainActor
    @Test func backgroundWakeActivationTimeoutSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "Avery",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        viewModel.applicationStateOverride = .background
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        viewModel.pttWakeRuntime.confirmIncomingPush(for: channelUUID, payload: payload)
        viewModel.pttWakeRuntime.markFallbackDeferredUntilForeground(for: contactID)

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
    @Test func backgroundWakeActivationSuppressesMissingBackendMembershipRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "Avery",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        viewModel.applicationStateOverride = .background
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        let shouldRecover = viewModel.shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .receiving,
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
    @Test func foregroundWakeActivationSuppressesMissingBackendMembershipRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "Avery",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        viewModel.applicationStateOverride = .active
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        let shouldRecover = viewModel.shouldRecoverMissingBackendMembershipForActiveDevicePTTEvidence(
            contactID: contactID,
            effectiveChannelState: makeChannelState(
                status: .receiving,
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
    @Test func pttSystemLeaveReasonClassifiesBoundaryDescriptions() {
        let userInitiated = PTTSystemLeaveReason(rawDescription: "PTChannelLeaveReason(rawValue: 1)")
        let system = PTTSystemLeaveReason(rawDescription: "PTChannelLeaveReason(rawValue: 2)")
        let simulator = PTTSystemLeaveReason.simulator

        #expect(userInitiated.isUserInitiated)
        #expect(!system.isUserInitiated)
        #expect(!simulator.isUserInitiated)
        #expect(userInitiated.description == "PTChannelLeaveReason(rawValue: 1)")
        #expect(simulator.description == "simulator")
    }

    @MainActor
    @Test func backgroundUserInitiatedSystemLeaveCallbackIsLocalOnlyWithoutExplicitLeave() async {
        let viewModel = PTTViewModel()
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

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.backendCommandCoordinator.state.activeOperation == nil)
        #expect(capturedEffects.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Treating background PTT leave as local-only continuity interruption"
            )
        )
    }

    @MainActor
    @Test func backgroundExplicitSystemLeaveCallbackRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
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

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 1)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.backendCommandCoordinator.state.activeOperation == .leave(contactID: contactID))
        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func backgroundSystemEvictionLeaveCallbackPublishesWakeReadinessWithoutBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-blake"
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
                    localAudioReadiness: .ready,
                    remoteAudioReadiness: .ready,
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 2)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(capturedEffects.isEmpty)
        let receiverNotReady = client.sentSignalsForTesting().filter { $0.type == .receiverNotReady }
        #expect(receiverNotReady.count == 1)
        #expect(receiverNotReady.first?.payload.contains("\"reason\":\"app-background-media-closed\"") == true)
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID]?.isReady == false)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Publishing receiver not-ready after background PTT system leave"
            )
        )
    }

    @Test func pttSystemPolicyReducerEmitsUploadEffectWhenChannelIsKnown() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(
            transition.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerRecordsUploadFailure() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: PTTSystemPolicyState(latestTokenHex: "deadbeef", lastTokenUploadError: nil),
            event: .tokenUploadFailed("network down")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(transition.state.lastTokenUploadError == "network down")
        #expect(transition.effects.isEmpty)
    }

    @Test func pttSystemPolicyReducerRetriesUploadWhenChannelBecomesKnownLater() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        #expect(received.state.latestTokenHex == "deadbeef")
        #expect(received.effects.isEmpty)

        let ready = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            ready.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerKeepsFailedUploadContextForRetry() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )
        let failed = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .tokenUploadFailed("network down")
        )

        #expect(failed.state.latestTokenHex == "deadbeef")
        #expect(failed.state.lastTokenUploadError == "network down")
        #expect(
            failed.state.tokenRegistration
                == .uploadFailed(
                    latestTokenHex: "deadbeef",
                    backendChannelID: "channel-1",
                    attemptedRequest: PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    ),
                    message: "network down"
                )
        )

        let retried = PTTSystemPolicyReducer.reduce(
            state: failed.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            retried.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            retried.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerDoesNotReuploadSameTokenAndChannel() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            lastTokenUploadError: nil,
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "channel-1"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(transition.effects.isEmpty)
        #expect(
            transition.state.tokenRegistration
                == .registered(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerDoesNotReuploadWhileSameTokenAndChannelUploadIsPending() {
        let state = PTTSystemPolicyState(
            tokenRegistration: .uploadPending(
                PTTTokenUploadRequest(
                    backendChannelID: "channel-1",
                    tokenHex: "deadbeef"
                )
            )
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(transition.effects.isEmpty)
        #expect(
            transition.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerReuploadsPersistedTokenForNewBackendChannel() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "old-channel"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            transition.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            transition.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerResetPreservesLatestTokenButClearsUploadedChannelBinding() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "old-channel"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(
            transition.state.tokenRegistration
                == .tokenKnown(tokenHex: "deadbeef", backendChannelID: nil)
        )
        #expect(transition.effects.isEmpty)
    }

    @MainActor
    @Test func staleMembershipPTTTokenUploadFailureIsIgnoredAfterBackendMembershipLoss() {
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
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: "channel-1",
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
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        let shouldIgnore = viewModel.shouldTreatEphemeralTokenUploadFailureAsStaleMembership(
            TurboBackendError.server("not a channel member"),
            request: PTTTokenUploadRequest(
                backendChannelID: "channel-1",
                tokenHex: "deadbeef"
            )
        )
        let shouldReportNetworkFailure = viewModel.shouldTreatEphemeralTokenUploadFailureAsStaleMembership(
            TurboBackendError.server("network down"),
            request: PTTTokenUploadRequest(
                backendChannelID: "channel-1",
                tokenHex: "deadbeef"
            )
        )

        #expect(shouldIgnore)
        #expect(!shouldReportNetworkFailure)
    }

    @MainActor
    @Test func persistedPTTSystemPolicyStateRestoresAcrossViewModelInit() async {
        let suiteName = "TurboTests.ptt-system-policy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PTTSystemPolicyPersistence.store(
            PTTSystemPolicyState(
                latestTokenHex: "deadbeef",
                uploadedTokenHex: "deadbeef",
                uploadedBackendChannelID: "old-channel"
            ),
            to: defaults
        )

        let viewModel = PTTViewModel(pttSystemPolicyDefaults: defaults)
        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(viewModel.pttSystemPolicyCoordinator.state.uploadedBackendChannelID == "old-channel")

        await viewModel.pttSystemPolicyCoordinator.handle(.backendChannelReady("channel-1"))

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )

        let restoredState = PTTSystemPolicyPersistence.load(from: defaults)
        #expect(restoredState.latestTokenHex == "deadbeef")
        #expect(restoredState.tokenRegistrationKind == "token-known")
        #expect(restoredState.uploadedBackendChannelID == nil)
    }

    @MainActor
    @Test func resetLocalDevStatePreservesPTTTokenAcrossRejoinAndTriggersFreshUpload() async {
        let suiteName = "TurboTests.ptt-system-policy-reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PTTSystemPolicyPersistence.store(
            PTTSystemPolicyState(
                latestTokenHex: "deadbeef",
                uploadedTokenHex: "deadbeef",
                uploadedBackendChannelID: "old-channel"
            ),
            to: defaults
        )

        let viewModel = PTTViewModel(pttSystemPolicyDefaults: defaults)
        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.resetLocalDevState(backendStatus: "Reconnecting...")

        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(
            viewModel.pttSystemPolicyCoordinator.state.tokenRegistration
                == .tokenKnown(tokenHex: "deadbeef", backendChannelID: nil)
        )

        let resetPersistedState = PTTSystemPolicyPersistence.load(from: defaults)
        #expect(resetPersistedState.latestTokenHex == "deadbeef")
        #expect(resetPersistedState.tokenRegistrationKind == "token-known")
        #expect(resetPersistedState.uploadedBackendChannelID == nil)

        await viewModel.pttSystemPolicyCoordinator.handle(.backendChannelReady("channel-1"))

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @MainActor
    @Test func restoredChannelFlushesDeferredPTTTokenUploadOnceBackendChannelIsKnown() async {
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
        viewModel.pttSystemPolicyCoordinator.send(
            .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleRestoredChannel(channelUUID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(viewModel.pttSystemPolicyCoordinator.state.uploadedBackendChannelID == nil)
    }

    @Test func pttWakeRuntimeUsesSystemActivatedModeAfterAudioSessionActivation() {
        let runtime = PTTWakeRuntimeState()
        let contactID = UUID()
        let otherContactID = UUID()
        let channelUUID = UUID()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-1",
                    activeSpeaker: "@blake",
                    senderUserId: "sender",
                    senderDeviceId: "device"
                )
            )
        )

        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
        runtime.markAudioSessionActivated(for: channelUUID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: otherContactID) == .appManaged)
        runtime.clear(for: contactID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
    }

    @Test func pttSystemDisplayPolicyUsesContactNameForRestoredDescriptor() {
        let channelUUID = UUID()
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        let knownName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: [contact],
            fallbackName: "Fallback"
        )
        let fallbackName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: UUID(),
            contacts: [contact],
            fallbackName: "Fallback"
        )

        #expect(knownName == "Chat with Avery")
        #expect(fallbackName == "Fallback")
    }

    @Test func pttPushPayloadParsesTransmitStart() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "transmit-start",
                "channelId": "channel-1",
                "activeSpeaker": "@blake",
                "activeSpeakerDisplayName": "Blake",
                "senderUserId": "user-blake",
                "senderDeviceId": "device-blake",
            ]
        )

        #expect(payload?.event == .transmitStart)
        #expect(payload?.channelId == "channel-1")
        #expect(payload?.participantName == "Blake")
        #expect(payload?.notificationTitle == "Blake wants to talk")
    }

    @Test func pttPushPayloadFallsBackToHandleForTransmitStartTitle() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "transmit-start",
                "channelId": "channel-1",
                "activeSpeaker": "@blake",
                "senderUserId": "user-blake",
                "senderDeviceId": "device-blake",
            ]
        )

        #expect(payload?.participantName == "@blake")
        #expect(payload?.notificationTitle == "@blake wants to talk")
    }

    @Test func pttPushPayloadParsesLeaveChannel() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "type": "leave-channel",
                "channelId": "channel-1",
            ]
        )

        #expect(payload?.event == .leaveChannel)
        #expect(payload?.channelId == "channel-1")
    }

    @Test func pttPushPayloadRejectsUnknownEvent() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "unknown-event",
                "channelId": "channel-1",
            ]
        )

        #expect(payload == nil)
    }

    @MainActor
    @Test func systemActivatedReceivePlaybackDefersUntilPTTAudioSessionIsActive() {
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
                remoteUserId: "user-avery"
            )
        ]
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.pttCoordinator.send(.didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test"))
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false

        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            ) == false
        )

        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func devicePTTProjectionFlagsWakeReadyWithoutAlignedAppleSession() {
        let projection = makeDevicePTTDiagnosticsProjection(
            fields: [
                "selectedContact": "@blake",
                "selectedConversationPhase": "wakeReady",
                "selectedConversationPhaseDetail": "wakeReady",
                "selectedConversationCanTransmit": "false",
                "selectedConversationAllowsHoldToTalk": "true",
                "isJoined": "false",
                "systemSession": "none",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable"
            ]
        )

        let invariantIDs = projection.derivedInvariantCandidates.map(\.invariantID)

        #expect(invariantIDs.contains("selected.wake_ready_requires_aligned_apple_session"))
        #expect(!invariantIDs.contains("selected.hold_to_talk_requires_transmit_capability"))
    }

    @MainActor
    @Test func devicePTTProjectionFlagsBackendReadyWithoutLocalDevicePTTEvidenceOrJoinAttempt() {
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

        let candidate = projection.derivedInvariantCandidates.first {
            $0.invariantID == "selected.backend_ready_missing_local_device_ptt_evidence"
        }

        #expect(candidate?.scope == .convergence)
        #expect(candidate?.metadata["systemSession"] == "none")
        #expect(candidate?.metadata["localJoinAttempt"] == "none")
    }

    @MainActor
    @Test func simulatorPTTClientJoinsAndTransmits() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let channelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: channelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(recorder.joinedChannelIDs == [channelID])
        #expect(recorder.joinFailures.isEmpty)
        #expect(recorder.ephemeralPushTokens.count == 1)
        #expect(recorder.ephemeralPushTokens.first?.isEmpty == false)

        try client.beginTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didBeginTransmittingChannelIDs == [channelID])
        #expect(recorder.activatedAudioSessionCategories == [.playAndRecord])

        try client.stopTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didEndTransmittingChannelIDs == [channelID])
        #expect(recorder.deactivatedAudioSessionCategories == [.playAndRecord])

        try client.leaveChannel(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.leftChannelIDs == [channelID])
    }

    @MainActor
    @Test func joinPTTChannelRetriesStalePendingJoinWithoutDevicePTTEvidence() {
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
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID, channelUUID: channelUUID)

        viewModel.joinPTTChannel(for: viewModel.contacts[0])

        #expect(client.joinRequests == [channelUUID])
        #expect(viewModel.pendingJoinContactId == contactID)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt?.issuedCount == 2)
    }

    @MainActor
    @Test func joinPTTChannelDoesNotTreatBackendEngineConversationAsAppleSessionEvidence() {
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
        viewModel.seedEngineJoinedConversationForTesting(
            contactID: contactID,
            handle: "@avery",
            backendChannelID: "channel-123"
        )

        #expect(viewModel.engineSnapshot.conversation.joinedEvidence != nil)
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(!viewModel.devicePTTEvidenceExists(for: contactID, expectedChannelUUID: channelUUID))

        viewModel.joinPTTChannel(for: contact)

        #expect(client.joinRequests == [channelUUID])
        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt?.contactID == contactID)
        #expect(viewModel.statusMessage == "Connecting...")
    }

    @MainActor
    @Test func joinPTTChannelIsBlockedByExplicitLeave() {
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

        viewModel.joinPTTChannel(for: viewModel.contacts[0])

        #expect(client.joinRequests.isEmpty)
        #expect(viewModel.conversationActionCoordinator.pendingAction == .leave(.explicit(contactID: contactID)))
        #expect(viewModel.statusMessage == "Disconnecting...")
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignored local PTT join while explicit leave is in flight"
            }
        )
    }

    @MainActor
    @Test func backgroundWakeCapableLocalSessionSuppressesMissingBackendPresenceRecovery() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.applicationStateOverride = .background

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
                peerHasActiveDevice: true,
                localWakeCapability: .wakeCapable(targetDeviceId: "self-device")
            ),
            localDevicePTTEvidenceEstablished: true
        )

        #expect(shouldRecover == false)
    }

    @MainActor
    @Test func localTransmitProjectionStaysStoppingUntilSystemTransmitEndsAfterRelease() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        #expect(viewModel.transmitDomainSnapshot.isPressActive == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting)
        #expect(viewModel.systemSessionMatches(contactID))
        #expect(viewModel.localTransmitProjection(for: contactID) == .stopping)

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.selectedConversationState(for: contactID).allowsHoldToTalk == false)
    }

    @MainActor
    @Test func beginTransmitIgnoresReentryWhileSystemTransmitIsStillActive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-a-b",
            remoteUserId: "remote-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, origin: .foregroundAppPress)
        )

        viewModel.beginTransmit()

        #expect(viewModel.transmitDomainSnapshot.isPressActive == false)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "reason=system-transmit-still-active"
            )
        )
    }

    @MainActor
    @Test func pttAccessoryButtonEventsAreEnabledForJoinedSystemChannel() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let channelUUID = UUID()
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: nil, reason: "test")
        )

        viewModel.syncPTTAccessoryButtonEvents(reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.accessoryButtonEventUpdates.count == 1)
        #expect(client.accessoryButtonEventUpdates.first?.enabled == true)
        #expect(client.accessoryButtonEventUpdates.first?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func simulatorPTTClientRejectsSecondConcurrentChannel() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let firstChannelID = UUID()
        let secondChannelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: firstChannelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        try client.joinChannel(channelUUID: secondChannelID, name: "Blake")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(recorder.joinedChannelIDs == [firstChannelID])
        #expect(recorder.ephemeralPushTokens.count == 1)
        #expect(recorder.joinFailures.count == 1)
        #expect(recorder.joinFailures.first?.channelID == secondChannelID)
        #expect((recorder.joinFailures.first?.error as NSError?)?.code == 2)
    }
}
