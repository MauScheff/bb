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
struct BeepTests {
    @Test func alertNotificationStartupPolicyDoesNotRequestSystemPermission() {
        #expect(AlertNotificationPermissionPolicy.startupAction(for: .notDetermined) == .observeOnly)
        #expect(AlertNotificationPermissionPolicy.startupAction(for: .denied) == .observeOnly)
        #expect(AlertNotificationPermissionPolicy.startupAction(for: .authorized) == .registerForRemoteNotifications)
        #expect(AlertNotificationPermissionPolicy.startupAction(for: .provisional) == .registerForRemoteNotifications)
        #expect(AlertNotificationPermissionPolicy.startupAction(for: .ephemeral) == .registerForRemoteNotifications)
    }

    @Test func alertNotificationExplicitPolicyRequestsOnlyWhenUndetermined() {
        #expect(AlertNotificationPermissionPolicy.explicitRequestAction(for: .notDetermined) == .requestAuthorization)
        #expect(AlertNotificationPermissionPolicy.explicitRequestAction(for: .denied) == .observeOnly)
        #expect(AlertNotificationPermissionPolicy.explicitRequestAction(for: .authorized) == .registerForRemoteNotifications)
        #expect(AlertNotificationPermissionPolicy.explicitRequestAction(for: .provisional) == .registerForRemoteNotifications)
        #expect(AlertNotificationPermissionPolicy.explicitRequestAction(for: .ephemeral) == .registerForRemoteNotifications)
    }

    @Test func incomingLinkPublicIDParsesHandleLinkAndDid() {
        #expect(TurboIncomingLink.publicID(from: "maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "@maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/@maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/p/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "did:web:beepbeep.to:id:maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://api.beepbeep.to/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://api.beepbeep.to/@maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://api.beepbeep.to/p/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "did:web:api.beepbeep.to:id:maurice") == "@maurice")
    }

    @Test func incomingLinkRejectsPlaceholderUserIdentity() {
        #expect(!TurboHandle.isValidIdentityBody("user"))
        #expect(TurboIncomingLink.publicID(from: "@user") == nil)
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/user") == nil)
        #expect(TurboIncomingLink.publicID(from: "https://api.beepbeep.to/user") == nil)
        #expect(TurboIncomingLink.publicID(from: "did:web:beepbeep.to:id:user") == nil)
        #expect(TurboIncomingLink.isReservedIdentityReference("https://beepbeep.to/user"))
    }

    @Test func backendJoinRejectsPlaceholderUserContact() {
        let viewModel = PTTViewModel()
        let contact = Contact(
            id: Contact.stableID(for: "@user"),
            name: "@user",
            handle: "@user",
            isOnline: true,
            channelId: UUID(),
            remoteUserId: "user-user"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contact.id

        viewModel.requestBackendJoin(for: contact)

        #expect(viewModel.statusMessage == "Pick another handle")
        #expect(viewModel.backendStatusMessage == "That handle is only a placeholder")
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Rejected backend join for reserved contact identity"
            )
        )
    }

    @MainActor
    @Test func selectedDirectQuicPrewarmRepairsActiveDirectPathSurfacedAsFastRelay() {
        TurboDirectPathDebugOverride.setRelayOnlyForced(false)
        TurboDirectPathDebugOverride.setAutoUpgradeDisabled(false)
        defer {
            TurboDirectPathDebugOverride.setAutoUpgradeDisabled(false)
            TurboDirectPathDebugOverride.setRelayOnlyForced(false)
        }

        let contactID = UUID()
        let viewModel = PTTViewModel()
        viewModel.selectedContactDirectQuicPrewarmEnabled = true
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel",
            attemptID: "attempt-active",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-active",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        viewModel.mediaRuntime.updateTransportPathState(.fastRelay)

        #expect(viewModel.selectedContactDirectQuicPrewarmBlockReason(for: contactID) == "direct-active")
        #expect(viewModel.mediaTransportPathState == .direct)
        #expect(viewModel.mediaRuntime.directQuicUpgrade.attempt(for: contactID)?.isDirectActive == true)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "direct-quic.active_path_surfaced_as_relay"
            )
        )
    }

    @MainActor
    @Test func forcedMediaRelayKeepsActiveDirectPathSurfacedAsFastRelay() {
        TurboDirectPathDebugOverride.setRelayOnlyForced(false)
        TurboDirectPathDebugOverride.setAutoUpgradeDisabled(false)
        TurboMediaRelayDebugOverride.setForced(true)
        defer {
            TurboDirectPathDebugOverride.setAutoUpgradeDisabled(false)
            TurboDirectPathDebugOverride.setRelayOnlyForced(false)
            TurboMediaRelayDebugOverride.setForced(false)
        }

        let contactID = UUID()
        let viewModel = PTTViewModel()
        viewModel.selectedContactDirectQuicPrewarmEnabled = true
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel",
            attemptID: "attempt-active",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-active",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        viewModel.mediaRuntime.updateTransportPathState(.fastRelay)

        #expect(viewModel.selectedContactDirectQuicPrewarmBlockReason(for: contactID) == "media-relay-forced")
        #expect(viewModel.mediaTransportPathState == .fastRelay)
        #expect(!viewModel.diagnosticsTranscript.contains("direct-quic.active_path_surfaced_as_relay"))
    }

    @MainActor
    @Test func joinAcceptedControlSignalIgnoresStaleBeep() async throws {
        let contactID = UUID()
        let pttClient = RecordingPTTSystemClient()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
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
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .outgoingBeepSeeded(
                contactID: contactID,
                beep: makeBeep(direction: "outgoing", beepId: "beep-current"),
                now: Date()
            )
        )

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: "beep-old",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: "self-device",
            reason: TurboJoinAcceptedControlSignal.reason,
            roleIntent: .symmetric
        )
        let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: payload
        )

        viewModel.handleIncomingSignal(envelope)

        #expect(pttClient.joinRequests.isEmpty)
        #expect(viewModel.diagnosticsTranscript.contains("Ignored stale join accepted control signal"))
    }

    @MainActor
    @Test func acceptedIncomingBeepPublishesJoinAcceptedControlSignal() async throws {
        let contactID = UUID()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        backendClient.enableSentSignalCaptureForTesting()
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
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
        let acceptedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-accepted",
            fromHandle: "@blake",
            toHandle: "@self",
            status: "connected"
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-peer",
            existingBackendChannelID: "channel-1",
            incomingBeep: acceptedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let backend = try #require(viewModel.backendServices)

        await viewModel.publishJoinAcceptedControlSignalIfPossible(
            request: request,
            acceptedBeep: acceptedBeep,
            backend: backend
        )

        let envelope = try #require(backendClient.sentSignalsForTesting().first)
        let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
        #expect(envelope.type == .directQuicUpgradeRequest)
        #expect(envelope.channelId == "channel-1")
        #expect(envelope.fromUserId == "user-self")
        #expect(envelope.toUserId == "user-peer")
        #expect(payload.requestId == "beep-accepted")
        #expect(payload.reason == TurboJoinAcceptedControlSignal.reason)
    }

    @MainActor
    @Test func acceptedIncomingBeepTargetsWakeCapableSenderDevice() async throws {
        let contactID = UUID()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        backendClient.enableSentSignalCaptureForTesting()
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
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
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: TurboChannelReadinessResponse(
                    channelId: "channel-1",
                    peerUserId: "user-peer",
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    activeTransmitterUserId: nil,
                    activeTransmitExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    audioReadinessPayload: TurboChannelAudioReadinessPayload(
                        selfReadiness: TurboAudioReadinessStatusPayload(kind: "ready"),
                        peerReadiness: TurboAudioReadinessStatusPayload(kind: "waiting"),
                        peerTargetDeviceId: nil
                    ),
                    wakeReadinessPayload: TurboChannelWakeReadinessPayload(
                        selfWakeCapability: TurboWakeCapabilityStatusPayload(kind: "wake-capable", targetDeviceId: "self-device"),
                        peerWakeCapability: TurboWakeCapabilityStatusPayload(kind: "wake-capable", targetDeviceId: "peer-wake-device")
                    )
                )
            )
        )
        let acceptedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-accepted",
            fromHandle: "@blake",
            toHandle: "@self",
            status: "connected"
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-peer",
            existingBackendChannelID: "channel-1",
            incomingBeep: acceptedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let backend = try #require(viewModel.backendServices)

        await viewModel.publishJoinAcceptedControlSignalIfPossible(
            request: request,
            acceptedBeep: acceptedBeep,
            backend: backend
        )

        let envelope = try #require(backendClient.sentSignalsForTesting().first)
        let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
        #expect(envelope.toDeviceId == "peer-wake-device")
        #expect(payload.toDeviceId == "peer-wake-device")
        #expect(
            viewModel.diagnosticsTranscript.contains("targetDeviceId=peer-wake-device")
        )
    }

    @MainActor
    @Test func acceptedIncomingBeepUsesRecentReadinessPeerDeviceAfterTransientReadinessLoss() async throws {
        let contactID = UUID()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        backendClient.enableSentSignalCaptureForTesting()
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
            userID: "user-self",
            mode: "cloud"
        )
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

        viewModel.applyChannelReadiness(
            TurboChannelReadinessResponse(
                channelId: "channel-1",
                peerUserId: "user-peer",
                selfHasActiveDevice: true,
                peerHasActiveDevice: false,
                activeTransmitterUserId: nil,
                activeTransmitExpiresAt: nil,
                status: ConversationState.waitingForPeer.rawValue,
                audioReadinessPayload: TurboChannelAudioReadinessPayload(
                    selfReadiness: TurboAudioReadinessStatusPayload(kind: "ready"),
                    peerReadiness: TurboAudioReadinessStatusPayload(kind: "waiting"),
                    peerTargetDeviceId: nil
                ),
                wakeReadinessPayload: TurboChannelWakeReadinessPayload(
                    selfWakeCapability: TurboWakeCapabilityStatusPayload(kind: "wake-capable", targetDeviceId: "self-device"),
                    peerWakeCapability: TurboWakeCapabilityStatusPayload(kind: "wake-capable", targetDeviceId: "peer-wake-device")
                )
            ),
            for: contactID,
            reason: "test-observed-wake-device"
        )
        viewModel.applyChannelReadiness(
            TurboChannelReadinessResponse(
                channelId: "channel-1",
                peerUserId: "user-peer",
                selfHasActiveDevice: true,
                peerHasActiveDevice: false,
                activeTransmitterUserId: nil,
                activeTransmitExpiresAt: nil,
                status: ConversationState.waitingForPeer.rawValue,
                audioReadinessPayload: TurboChannelAudioReadinessPayload(
                    selfReadiness: TurboAudioReadinessStatusPayload(kind: "ready"),
                    peerReadiness: TurboAudioReadinessStatusPayload(kind: "waiting"),
                    peerTargetDeviceId: nil
                ),
                wakeReadinessPayload: TurboChannelWakeReadinessPayload(
                    selfWakeCapability: TurboWakeCapabilityStatusPayload(kind: "wake-capable", targetDeviceId: "self-device"),
                    peerWakeCapability: TurboWakeCapabilityStatusPayload(kind: "unavailable")
                )
            ),
            for: contactID,
            reason: "test-transient-readiness-loss"
        )

        let acceptedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-accepted",
            fromHandle: "@blake",
            toHandle: "@self",
            status: "connected"
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-peer",
            existingBackendChannelID: "channel-1",
            incomingBeep: acceptedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let backend = try #require(viewModel.backendServices)

        await viewModel.publishJoinAcceptedControlSignalIfPossible(
            request: request,
            acceptedBeep: acceptedBeep,
            backend: backend
        )

        let envelope = try #require(backendClient.sentSignalsForTesting().first)
        let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
        #expect(envelope.toDeviceId == "peer-wake-device")
        #expect(payload.toDeviceId == "peer-wake-device")
        #expect(viewModel.diagnosticsTranscript.contains("peerDeviceId=peer-wake-device"))
        #expect(viewModel.diagnosticsTranscript.contains("targetDeviceId=peer-wake-device"))
    }

    @MainActor
    @Test func acceptedIncomingBeepTargetsRecentSelectedFriendPrewarmDeviceWhenReadinessIsMissing() async throws {
        let contactID = UUID()
        let backendClient = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "self-device"
            )
        )
        backendClient.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        backendClient.enableSentSignalCaptureForTesting()
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: backendClient,
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
        let prewarmPayload = TurboSelectedFriendPrewarmPayload(
            requestId: "selected-prewarm-1",
            channelId: "channel-1",
            fromDeviceId: "friend-prewarm-device",
            toDeviceId: "self-device",
            reason: "selected-contact"
        )
        let prewarmEnvelope = try TurboSignalEnvelope.selectedFriendPrewarm(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "friend-prewarm-device",
            toUserId: "user-self",
            toDeviceId: "self-device",
            payload: prewarmPayload
        )
        await viewModel.ingestBackendWebSocketSignal(prewarmEnvelope)

        let acceptedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-accepted",
            fromHandle: "@blake",
            toHandle: "@self",
            status: "connected"
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@blake",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-peer",
            existingBackendChannelID: "channel-1",
            incomingBeep: acceptedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let backend = try #require(viewModel.backendServices)

        await viewModel.publishJoinAcceptedControlSignalIfPossible(
            request: request,
            acceptedBeep: acceptedBeep,
            backend: backend
        )

        let envelope = try #require(backendClient.sentSignalsForTesting().last)
        let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
        #expect(envelope.toDeviceId == "friend-prewarm-device")
        #expect(payload.toDeviceId == "friend-prewarm-device")
        #expect(viewModel.diagnosticsTranscript.contains("recordedPeerDeviceId=friend-prewarm-device"))
        #expect(viewModel.diagnosticsTranscript.contains("targetDeviceId=friend-prewarm-device"))
    }

    @MainActor
    @Test func freshOutgoingBeepStaysRequestedWhileBackendRequestIsActive() {
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
        viewModel.markOptimisticOutgoingBeepStarted(
            contactID: contactID,
            relationship: .none,
            operationID: "connect-test"
        )
        viewModel.backendCommandCoordinator.send(
            .joinRequested(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .requestConnection,
                    operationID: "connect-test",
                    joinOperationID: "join-test",
                    relationship: .none,
                    existingRemoteUserID: "user-blake",
                    existingBackendChannelID: "channel",
                    incomingBeep: nil,
                    outgoingBeep: nil,
                    beepCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.selectedConversationState(for: contactID).phase == .outgoingBeep)
        #expect(viewModel.selectedConversationState(for: contactID).statusMessage == "Beep sent to Blake")
    }

    @Test func authoritativeContactIDsIncludeTrackedSummaryBeepAndActivePeers() {
        let tracked = Set([UUID(), UUID()])
        let summary = UUID()
        let selected = UUID()
        let active = UUID()
        let media = UUID()
        let pending = UUID()
        let beep = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: tracked,
            summaryContactIDs: [summary],
            selectedContactID: selected,
            activeChannelID: active,
            mediaSessionContactID: media,
            pendingJoinContactID: pending,
            beepContactIDs: [beep]
        )

        #expect(ids == tracked.union([summary, selected, active, media, pending, beep]))
    }

    @Test func selectedConversationStateShowsFriendReadyAfterBeepHasBeenAccepted() {
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
                    peerJoined: true,
                    peerDeviceConnected: true,
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

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .friendReady)
        #expect(state.conversationState == .outgoingBeep)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateSurfacesRecoverableLocalJoinFailure() {
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

        let state = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(state.phase == .localJoinFailed)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Reconnect failed. End conversation and retry.")
    }

    @Test func backendSyncPartialBeepUpdatePreservesUnfetchedDirection() {
        let incomingContactID = UUID()
        let outgoingContactID = UUID()
        var state = BackendSyncSessionState()
        let outgoingBeep = makeBeep(direction: "outgoing", beepId: "outgoing-1")
        let incomingBeep = makeBeep(
            direction: "incoming",
            beepId: "incoming-1",
            fromHandle: "@blake",
            toHandle: "@self"
        )

        state.syncState.applyBeeps(
            incoming: [:],
            outgoing: [outgoingContactID: outgoingBeep],
            now: .now
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsPartiallyUpdated(
                incoming: [BackendBeepUpdate(contactID: incomingContactID, beep: incomingBeep)],
                outgoing: nil,
                now: .now
            )
        )

        #expect(transition.state.syncState.incomingBeeps[incomingContactID]?.beepId == "incoming-1")
        #expect(transition.state.syncState.outgoingBeeps[outgoingContactID]?.beepId == "outgoing-1")
        #expect(transition.state.syncState.requestContactIDs == [incomingContactID, outgoingContactID])
    }

    @Test func incomingBeepPrimaryActionUsesBeepBackWhenFriendIsUnavailable() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                contactPresence: .unavailable,
                relationship: .incomingBeep(requestCount: 1),
                phase: .incomingBeep,
                statusMessage: "Blake wants to talk",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Beep Back")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func idleUnavailablePrimaryActionDisablesOutgoingBeep() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                contactPresence: .unavailable,
                relationship: .none,
                phase: .idle,
                statusMessage: "Blake is unavailable",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Unavailable")
        #expect(!action.isEnabled)
        #expect(action.style == .muted)
    }

    @Test func blockedRequestedPrimaryActionAllowsBeepAgainAfterCooldownExpires() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .outgoingBeep(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Beep Again")
        #expect(action.isEnabled)
        #expect(action.style == .muted)
    }

    @Test func listConversationStatePrefersIncomingBeepOverSummaryBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingBeep: true,
            hasOutgoingBeep: false,
            requestCount: 3,
            isActiveConversation: false,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .incomingBeep)
    }

    @Test func contactSummaryTypedProjectionExposesMutualBeepThreadProjectionAndBadgeState() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingBeep: true,
            hasOutgoingBeep: true,
            requestCount: 2,
            isActiveConversation: true,
            badgeStatus: ConversationState.ready.rawValue
        )

        #expect(summary.beepThreadProjection == .mutual(requestCount: 2))
        #expect(summary.badge == .ready)
        #expect(summary.badge.conversationState == .ready)
    }

    @Test func incomingLinkParsesCanonicalSharePage() {
        let url = URL(string: "https://beepbeep.to/maurice?utm_source=test#card")!

        #expect(TurboIncomingLink.reference(from: url) == "https://beepbeep.to/maurice")
    }

    @Test func incomingLinkParsesAPISharePage() {
        let url = URL(string: "https://api.beepbeep.to/maurice?utm_source=test#card")!

        #expect(TurboIncomingLink.reference(from: url) == "https://api.beepbeep.to/maurice")
    }

    @Test func incomingLinkParsesCustomSchemeSharePage() {
        let url = URL(string: "beepbeep://p/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == "https://beepbeep.to/maurice")
    }

    @Test func incomingLinkParsesCustomSchemeDidTarget() {
        let url = URL(string: "beepbeep://id/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == "did:web:beepbeep.to:id:@maurice")
    }

    @Test func incomingLinkRejectsUnrelatedURLs() {
        let url = URL(string: "https://example.com/p/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == nil)
    }

    @Test func listConversationStateMapsBackendReadyBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel",
            isOnline: true,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            isActiveConversation: true,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .ready)
    }

    @Test func listConversationStateFallsBackToIdleForUnknownBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@casey",
            displayName: "Casey",
            channelId: nil,
            isOnline: false,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "mystery"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .idle)
    }

    @Test func selectedConversationStateSurfacesMissingSystemWakeActivationExplicitly() {
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
            incomingWakeActivationState: .systemActivationTimedOutWaitingForForeground,
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
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .waitingForPeer)
        #expect(selectedConversationState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedConversationState.statusMessage == "Wake received, but system audio never activated. Unlock to resume audio.")
        #expect(selectedConversationState.canTransmitNow == false)
    }

    @Test func selectedConversationStateSurfacesInterruptedSystemWakeActivationExplicitly() {
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
            incomingWakeActivationState: .systemActivationInterruptedByTransmitEnd,
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
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedConversationState = ConversationStateMachine.selectedConversationState(for: context, relationship: .none)

        #expect(selectedConversationState.phase == .waitingForPeer)
        #expect(selectedConversationState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedConversationState.statusMessage == "Wake ended before system audio activated.")
        #expect(selectedConversationState.canTransmitNow == false)
    }

    @MainActor
    @Test func backgroundNotificationRetiresDirectQuicSynchronously() {
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
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        _ = viewModel.directQuicProbeController()
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

        let didRetire = viewModel.retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-will-resign-active",
            applicationState: .inactive
        )

        #expect(didRetire)
        #expect(!viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.mediaRuntime.directQuicProbeController == nil)
        #expect(!viewModel.retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-did-enter-background",
            applicationState: .background
        ))
    }

    @MainActor
    @Test func backgroundNotificationSchedulingStartsLifecycleLeaseSynchronously() async {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Kai",
                handle: "@kai",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-kai",
                remoteUserId: "user-kai"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.backgroundWebSocketSuspendHandler = {
            probe.recordSuspend()
        }
        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: probe.events.count)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundActiveSessionPresenceHandler = {
            probe.recordActiveSessionStart()
            probe.recordActiveSessionFinish()
        }
        viewModel.backgroundSessionPresenceHandler = {
            probe.recordBackgroundStart()
            probe.recordBackgroundFinish()
        }

        viewModel.scheduleApplicationDidEnterBackgroundHandling()

        #expect(probe.events.first == "background-task-begin:application-did-enter-background")

        try? await waitForScenario(
            "background lifecycle task finished",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            probe.events.contains("background-task-begin:active-session-presence")
                && probe.activeSessionStarted
                && probe.events.last == "background-task-end"
        }

        #expect(probe.events.contains("background-task-begin:active-session-presence"))
        #expect(probe.activeSessionStarted)
        #expect(probe.backgroundStarted == false)
        #expect(probe.backgroundTaskEnded)
    }

    @MainActor
    @Test func applicationDidBecomeActiveClearsBadgeAndDeliveredNotifications() async {
        let viewModel = PTTViewModel()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        var deliveredNotificationFetchCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.deliveredBeepNotificationUserInfoProvider = {
            deliveredNotificationFetchCount += 1
            return []
        }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }
        viewModel.backendSyncCoordinator.effectHandler = { _ in }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(badgeCounts == [0])
        #expect(deliveredNotificationFetchCount == 1)
        #expect(clearNotificationsCallCount == 1)
    }

    @MainActor
    @Test func applicationOpenAfterBackgroundBeepNotificationDoesNotReplayForegroundBanner() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.deliveredBeepNotificationUserInfoProvider = {
            [
                [
                    "event": TurboNotificationCategory.beepEvent,
                    "fromHandle": "@avery",
                    "beepId": "beep-1",
                    "requestCount": 1,
                ]
            ]
        }
        viewModel.clearDeliveredNotifications = {}
        viewModel.backendSyncCoordinator.effectHandler = { _ in }

        await viewModel.handleApplicationDidBecomeActive()
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(
            viewModel.incomingBeepSurfaceState.surfacedBeepKeys
                == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)])
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Marked background-delivered Beep seen without foreground banner"
            )
        )
    }

    @MainActor
    @Test func foregroundActivationSuppressesIncomingBeepBannerBeforeNotificationIntakeCompletes() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]

        viewModel.beginForegroundActivationIncomingBeepBannerSuppression(reason: "test")
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(
            applicationState: .active,
            allowsSelectedContact: true
        )

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(
            viewModel.incomingBeepSurfaceState.surfacedBeepKeys
                == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)])
        )

        viewModel.endForegroundActivationIncomingBeepBannerSuppression(reason: "test")
        viewModel.reconcileIncomingBeepSurface(
            applicationState: .active,
            allowsSelectedContact: true
        )

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Started foreground activation Beep banner suppression"
            )
        )
    }

    @MainActor
    @Test func inactiveForegroundNotificationIsConsumedWithoutInAppBanner() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.applicationStateOverride = .inactive
        viewModel.protectedDataAvailableProvider = { false }
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.handleForegroundBeepNotification(
            userInfo: [
                "event": TurboNotificationCategory.beepEvent,
                "fromHandle": "@avery",
                "beepId": "beep-1",
                "requestCount": 1,
                "createdAt": "2026-04-17T19:00:00Z",
            ]
        )

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.pendingForegroundBeepSurface == nil)
        #expect(
            viewModel.backgroundDeliveredBeepReceiptsByHandle[Contact.normalizedHandle("@avery")]?
                .requestCount == 1
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Consumed delivered Beep notifications without foreground banner"
            )
        )
    }

    @MainActor
    @Test func beepNotificationBadgeCountUsesUniqueIncomingContacts() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()

        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [
                    BackendBeepUpdate(
                        contactID: firstContactID,
                        beep: makeBeep(direction: "incoming", requestCount: 3)
                    ),
                    BackendBeepUpdate(
                        contactID: secondContactID,
                        beep: makeBeep(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.pendingIncomingBeepBadgeCount == 2)
    }

    @MainActor
    @Test func beepNotificationBadgeSyncAppliesUniqueIncomingContactCountWhileBackgrounded() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [
                    BackendBeepUpdate(
                        contactID: firstContactID,
                        beep: makeBeep(direction: "incoming", requestCount: 4)
                    ),
                    BackendBeepUpdate(
                        contactID: secondContactID,
                        beep: makeBeep(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        viewModel.syncBeepNotificationBadge(applicationState: .background)

        #expect(badgeCounts == [2])
        #expect(clearNotificationsCallCount == 0)
    }

    @MainActor
    @Test func notificationOpenSelectsCachedIncomingBeepContactBeforeBackendIsReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )

        await viewModel.handleBeepNotificationResponse(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"]
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.pendingBeepNotificationHandle == "@avery")
        #expect(viewModel.pendingBeepNotificationShouldJoin)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.requestedExpandedCallSequence == 1)
        #expect(badgeCounts.first == 0)
        #expect(clearNotificationsCallCount == 1)
    }

    @MainActor
    @Test func homeAcceptRouteEstablishesSelectedContactIntentAndPrewarmBeforeJoin() async throws {
        try await assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm {
            viewModel,
            contact,
            _
            in
            #expect(viewModel.acceptIncomingBeep(contact, reason: "home-accept"))
        }
    }

    @MainActor
    @Test func detailAcceptRoutePreservesSelectedContactIntentAndPrewarmBeforeJoin() async throws {
        try await assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm {
            viewModel,
            contact,
            _
            in
            viewModel.selectContact(contact, reason: "contact-list-focused-detail")
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(viewModel.acceptIncomingBeep(contact, reason: "detail-accept"))
        }
    }

    @MainActor
    @Test func notificationAcceptRouteEstablishesSelectedContactIntentAndPrewarmBeforeJoin() async throws {
        try await assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm {
            viewModel,
            _,
            userInfo
            in
            await viewModel.handleBeepNotificationAcceptResponse(userInfo: userInfo)
        }
    }

    @MainActor
    @Test func startCallUserActivityAcceptRouteEstablishesSelectedContactIntentAndPrewarmBeforeJoin() async throws {
        try await assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm {
            viewModel,
            contact,
            _
            in
            let startCallIntent = makeStartCallIntent(handle: contact.handle, identifier: "beep-1")
            await viewModel.handleStartCallIntent(startCallIntent)
        }
    }

    @MainActor
    @Test func notificationAcceptRouteReplacesExistingDetailFocusAndPreservesIntentAndPrewarm() async throws {
        try await assertIncomingBeepAcceptRouteEstablishesIntentAndPrewarm {
            viewModel,
            _,
            userInfo
            in
            let otherContact = Contact(
                id: UUID(),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "other-channel",
                remoteUserId: "other-user"
            )
            viewModel.contacts.append(otherContact)
            viewModel.selectedContactId = otherContact.id
            viewModel.conversationActionCoordinator.select(contactID: otherContact.id)
            viewModel.updateStatusForSelectedContact()
            #expect(viewModel.selectedContactId == otherContact.id)

            await viewModel.handleBeepNotificationAcceptResponse(userInfo: userInfo)
        }
    }

    @Test func beepNotificationAcceptCompletionWaitsForHandler() {
        #expect(
            TurboNotificationCategory.shouldCompleteBeepResponseAfterHandling(
                actionIdentifier: TurboNotificationCategory.acceptBeepAction
            )
        )
        #expect(
            TurboNotificationCategory.shouldCompleteBeepResponseAfterHandling(
                actionIdentifier: UNNotificationDefaultActionIdentifier
            )
        )
    }

    @Test func beepNotificationLifecycleClearRemovesOnlyBeepNotificationsAndBadge() {
        var removedIdentifiers: [[String]] = []
        var badgeCounts: [Int] = []
        let deliveredNotifications = [
            TurboNotificationCategory.DeliveredNotificationSnapshot(
                identifier: "talk-payload",
                categoryIdentifier: "OTHER",
                userInfo: ["event": TurboNotificationCategory.beepEvent]
            ),
            TurboNotificationCategory.DeliveredNotificationSnapshot(
                identifier: "talk-category",
                categoryIdentifier: TurboNotificationCategory.beep,
                userInfo: [:]
            ),
            TurboNotificationCategory.DeliveredNotificationSnapshot(
                identifier: "other",
                categoryIdentifier: "OTHER",
                userInfo: ["event": "other"]
            ),
        ]

        TurboNotificationCategory.clearDeliveredBeepNotifications(
            deliveredNotifications: deliveredNotifications,
            additionalIdentifiers: ["current-talk"],
            removeDeliveredIdentifiers: { removedIdentifiers.append($0) },
            setBadgeCount: { badgeCounts.append($0) }
        )

        #expect(Set(removedIdentifiers.flatMap { $0 }) == Set(["talk-payload", "talk-category", "current-talk"]))
        #expect(badgeCounts == [0])
    }

    @MainActor
    @Test func notificationAcceptForOnlineIncomingBeepSelectsExpandsAndRequestsJoin() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleBeepNotificationAcceptResponse(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"]
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.requestedExpandedCallSequence == 1)
        #expect(badgeCounts.first == 0)
        #expect(clearNotificationsCallCount == 1)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingBeep(requestCount: 1)
                    && request.incomingBeep?.beepId == "beep-1"
            }
        )
    }

    @MainActor
    @Test func staleNotificationAcceptWithoutIncomingBeepDoesNotExpandOrJoin() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleBeepNotificationAcceptResponse(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "stale-beep"]
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.requestedExpandedCallContactID == nil)
        #expect(viewModel.requestedExpandedCallSequence == 0)
        #expect(
            !capturedEffects.contains {
                guard case .join = $0 else { return false }
                return true
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Ignored Beep accept without incoming Beep"
            )
        )
    }

    @MainActor
    @Test func pendingNotificationAcceptForOnlineIncomingBeepExpandsAndRequestsJoin() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.pendingBeepNotificationHandle = "@avery"
        viewModel.pendingBeepNotificationShouldJoin = true
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.openPendingBeepNotificationIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.pendingBeepNotificationHandle == nil)
        #expect(!viewModel.pendingBeepNotificationShouldJoin)
        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.requestedExpandedCallSequence == 1)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingBeep(requestCount: 1)
                    && request.incomingBeep?.beepId == "beep-1"
            }
        )
    }

    @MainActor
    @Test func notificationOpenForOnlineIncomingBeepSelectsExpandsAndRequestsJoin() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleBeepNotificationResponse(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"]
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingBeep(requestCount: 1)
                    && request.incomingBeep?.beepId == "beep-1"
            }
        )
    }

    @Test func conversationOpenIntentParsesStartCallUserActivityAsAccept() throws {
        let startCallIntent = makeStartCallIntent(handle: "@avery", identifier: "beep-1")
        let intent = TurboIncomingLink.conversationOpenIntent(fromStartCallIntent: startCallIntent)

        #expect(intent?.reference == "@avery")
        #expect(intent?.action == .accept)
    }

    @MainActor
    @Test func foregroundBeepNotificationSurfacesIncomingBeep() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.selectedContactId = contactID
        viewModel.markIncomingBeepSurfaceOpened(for: contactID, beepID: beep.beepId)

        await viewModel.handleForegroundBeepNotification(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": "@avery", "beepId": "beep-1"]
        )

        #expect(viewModel.activeIncomingBeep?.contactID == contactID)
        #expect(viewModel.activeIncomingBeep?.beepID == "beep-1")
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.requestedExpandedCallSequence == 1)
        #expect(badgeCounts.first == 0)
        #expect(clearNotificationsCallCount == 1)
    }

    @MainActor
    @Test func foregroundRepeatBeepNotificationSurfacesWhenIncomingBeepAlreadyPending() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-2",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 2,
            createdAt: "2026-04-17T19:01:00Z",
            updatedAt: "2026-04-17T19:01:00Z"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: beep.channelId,
                        handle: "@avery",
                        displayName: "Avery",
                        isOnline: false,
                        hasIncomingBeep: true,
                        requestCount: 2,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.markIncomingBeepSurfaceOpened(
            for: contactID,
            beepID: "beep-1",
            requestCount: 1
        )

        await viewModel.handleForegroundBeepNotification(
            userInfo: [
                "event": TurboNotificationCategory.beepEvent,
                "fromHandle": "@avery",
                "beepId": "beep-2",
                "requestCount": 2,
            ]
        )

        #expect(viewModel.activeIncomingBeep?.contactID == contactID)
        #expect(viewModel.activeIncomingBeep?.beepID == "beep-2")
        #expect(viewModel.activeIncomingBeep?.requestCount == 2)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Queued pending foreground incoming Beep surface from notification"
            )
        )
    }

    @MainActor
    @Test func acceptedIncomingBeepSuppressesStaleBeepResurface() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z"
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
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.backendCommandCoordinator.effectHandler = { _ in }
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: beep.channelId,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.beepThreadProjection(for: contactID).hasIncomingBeep)

        viewModel.requestBackendJoin(for: contact)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.incomingBeepByContactID[contactID] == nil)
        #expect(viewModel.beepThreadProjection(for: contactID) == .none)
        #expect(!viewModel.backendSyncCoordinator.state.syncState.requestContactIDs.contains(contactID))

        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: beep.channelId,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.beepThreadProjection(for: contactID) == .none)

        let newerBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-2",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 2,
            createdAt: "2026-04-08T00:00:10Z"
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: newerBeep.channelId,
                        hasIncomingBeep: true,
                        requestCount: 2,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: newerBeep)],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.beepThreadProjection(for: contactID) == .incomingBeep(requestCount: 2))
    }

    @MainActor
    @Test func newIncomingBeepWithResetRequestCountResurfacesAfterHandledAccept() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let originalBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z"
        )
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: originalBeep.channelId,
            remoteUserId: originalBeep.fromUserId
        )
        viewModel.contacts = [contact]
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.backendCommandCoordinator.effectHandler = { _ in }
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: originalBeep.channelId,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: originalBeep)],
                outgoing: [],
                now: .now
            )
        )

        viewModel.requestBackendJoin(for: contact)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.beepThreadProjection(for: contactID) == .none)

        let resetCountBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-2",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:10Z"
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: resetCountBeep.channelId,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: resetCountBeep)],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.incomingBeepByContactID[contactID]?.beepId == "beep-2")
        #expect(viewModel.beepThreadProjection(for: contactID) == .incomingBeep(requestCount: 1))
    }

    @Test func backendSyncReducerSeededBeepStartsCooldown() {
        let contactID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let beep = makeBeep(direction: "outgoing")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .outgoingBeepSeeded(contactID: contactID, beep: beep, now: now)
        )

        #expect(transition.state.syncState.outgoingBeeps[contactID] == beep)
        #expect(transition.state.syncState.beepCooldownDeadlines[contactID] == now.addingTimeInterval(30))
        #expect(transition.state.syncState.beepCooldownSourceKeys[contactID] == "\(beep.beepId)|\(beep.requestCount)")
    }

    @Test func backendSyncReducerBeepRefreshDoesNotRestartCooldownForSameOutgoingBeep() {
        let contactID = UUID()
        let beep = makeBeep(direction: "outgoing", beepId: "beep-1")
        let refreshedBeep = makeBeep(
            direction: "outgoing",
            beepId: "beep-1",
            requestCount: beep.requestCount,
            updatedAt: "2026-04-17T21:00:00Z"
        )
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingBeeps[contactID] = beep
        state.syncState.beepCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.beepCooldownSourceKeys[contactID] =
            "\(beep.beepId)|\(beep.requestCount)|\(beep.updatedAt ?? beep.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsUpdated(
                incoming: [],
                outgoing: [BackendBeepUpdate(contactID: contactID, beep: refreshedBeep)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.beepCooldownDeadlines[contactID] == nil)
        #expect(transition.state.syncState.beepCooldownSourceKeys[contactID] == "\(refreshedBeep.beepId)|\(refreshedBeep.requestCount)")
    }

    @Test func backendSyncReducerBeepRefreshRestartsCooldownForUpdatedOutgoingBeep() {
        let contactID = UUID()
        let originalBeep = makeBeep(direction: "outgoing", beepId: "beep-1")
        let updatedBeep = makeBeep(
            direction: "outgoing",
            beepId: "beep-1",
            requestCount: 2,
            updatedAt: "2026-04-17T21:00:00Z"
        )
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingBeeps[contactID] = originalBeep
        state.syncState.beepCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.beepCooldownSourceKeys[contactID] =
            "\(originalBeep.beepId)|\(originalBeep.requestCount)|\(originalBeep.updatedAt ?? originalBeep.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsUpdated(
                incoming: [],
                outgoing: [BackendBeepUpdate(contactID: contactID, beep: updatedBeep)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.beepCooldownDeadlines[contactID] == laterNow.addingTimeInterval(30))
        #expect(transition.state.syncState.beepCooldownSourceKeys[contactID] == "\(updatedBeep.beepId)|\(updatedBeep.requestCount)")
    }

    @Test func backendSyncReducerBeepFailurePreservesLastKnownRequests() {
        let contactID = UUID()
        let incomingBeep = makeBeep(direction: "incoming")
        let outgoingBeep = makeBeep(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingBeeps[contactID] = incomingBeep
        state.syncState.outgoingBeeps[contactID] = outgoingBeep
        state.syncState.beepCooldownDeadlines[contactID] = cooldownDeadline

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsFailed("Beep sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingBeeps[contactID] == incomingBeep)
        #expect(transition.state.syncState.outgoingBeeps[contactID] == outgoingBeep)
        #expect(transition.state.syncState.beepCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Beep sync failed: internal server error")
    }

    @Test func backendSyncReducerBeepFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let incomingBeep = makeBeep(direction: "incoming")
        let outgoingBeep = makeBeep(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingBeeps[contactID] = incomingBeep
        state.syncState.outgoingBeeps[contactID] = outgoingBeep
        state.syncState.beepCooldownDeadlines[contactID] = cooldownDeadline
        state.syncState.connectionPhase = .connected(mode: "cloud", handle: "@avery")
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .beepsFailed("Beep sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingBeeps[contactID] == incomingBeep)
        #expect(transition.state.syncState.outgoingBeeps[contactID] == outgoingBeep)
        #expect(transition.state.syncState.beepCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @MainActor
    @Test func contactPresencePresentationUsesSummaryOnlineBadgeForForegroundPeer() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel-blake",
                isOnline: true,
                hasIncomingBeep: false,
                hasOutgoingBeep: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "peer-only",
                    peerDeviceConnected: false
                )
            )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .foreground)
    }

    @MainActor
    @Test func transportPathBadgeStateIsHiddenWithoutActivePeerSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID

        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.transportPathBadgeState == nil)

        viewModel.mediaRuntime.updateTransportPathState(.direct)

        #expect(viewModel.transportPathBadgeState == nil)
    }

    @MainActor
    @Test func transportPathBadgeStateSurfacesOnlyForLivePeerSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel-blake")
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
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
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(viewModel.transportPathBadgeState == nil)

        viewModel.mediaRuntime.attach(session: StubRelayMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.markStartupSucceeded()
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
                    localAudioReadiness: .ready,
                    remoteAudioReadiness: .ready
                )
            )
        )
        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.selectedConversationState(for: contactID).phase == .ready)
        #expect(viewModel.transportPathBadgeState == .relay)

        viewModel.mediaRuntime.updateTransportPathState(.direct)

        #expect(viewModel.transportPathBadgeState == .direct)

        viewModel.mediaRuntime.updateTransportPathState(.promoting)

        #expect(viewModel.transportPathBadgeState == .relay)

        viewModel.mediaRuntime.updateTransportPathState(.recovering)

        #expect(viewModel.transportPathBadgeState == .relay)
    }

    @MainActor
    @Test func refreshBeepsFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let incomingBeep = makeBeep(direction: "incoming")
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: incomingBeep)],
                outgoing: [],
                now: .now
            )
        )

        await viewModel.refreshBeeps()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.backendSyncCoordinator.state.syncState.incomingBeeps[contactID] == incomingBeep)
    }

    @MainActor
    @Test func outgoingBeepProjectsRequestedAndCooldownBeforeBackendBeepReturns() {
        let viewModel = PTTViewModel()
        viewModel.selectedContactPrewarmPipelineEnabled = false
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
        viewModel.backendCommandCoordinator.effectHandler = { _ in }
        viewModel.contacts = [contact]
        viewModel.selectContact(contact, reason: "test")

        #expect(viewModel.beepThreadProjection(for: contactID) == .none)

        viewModel.requestBackendJoin(for: contact, intent: .requestConnection)

        #expect(viewModel.beepThreadProjection(for: contactID) == .outgoingBeep(requestCount: 1))
        #expect(viewModel.selectedConversationCoordinator.state.selectedConversationState.phase == .outgoingBeep)
        let cooldownRemaining = viewModel.beepCooldownRemaining(for: contactID)
        #expect(cooldownRemaining != nil)
        #expect((29...30).contains(cooldownRemaining ?? 0))
    }

    @MainActor
    @Test func offlineIncomingBeepBackProjectsOutgoingBeepAndCooldownBeforeBackendBeepReturns() {
        let viewModel = PTTViewModel()
        viewModel.selectedContactPrewarmPipelineEnabled = false
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: false,
            channelId: UUID(),
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.backendCommandCoordinator.effectHandler = { _ in }
        viewModel.contacts = [contact]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel",
                        handle: "@blake",
                        displayName: "Blake",
                        isOnline: false,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )
        viewModel.selectContact(contact, reason: "test")

        #expect(viewModel.beepThreadProjection(for: contactID) == .incomingBeep(requestCount: 1))

        viewModel.requestBackendJoin(for: contact, intent: .requestConnection)

        #expect(viewModel.beepThreadProjection(for: contactID) == .outgoingBeep(requestCount: 1))
        #expect(viewModel.selectedConversationCoordinator.state.selectedConversationState.phase == .outgoingBeep)
        let cooldownRemaining = viewModel.beepCooldownRemaining(for: contactID)
        #expect(cooldownRemaining != nil)
        #expect((29...30).contains(cooldownRemaining ?? 0))

        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: viewModel.selectedConversationState(for: contactID),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: cooldownRemaining
        )
        #expect(action.label == "Beep again in \(cooldownRemaining ?? 0)s")
        #expect(!action.isEnabled)
        #expect(action.style == .muted)
    }

    @MainActor
    @Test func detailFocusedOutgoingBeepPreservesRequestedStateAndIntent() async throws {
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
        client.enableSentSignalCaptureForTesting()

        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.selectedContactPrewarmPipelineEnabled = true
        viewModel.applicationStateOverride = .active
        viewModel.backendCommandCoordinator.effectHandler = { _ in }
        viewModel.contacts = [contact]

        viewModel.selectContact(contact, reason: "contact-list-focused-detail")
        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.requestBackendJoin(for: contact, intent: .requestConnection)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.beepThreadProjection(for: contactID) == .outgoingBeep(requestCount: 1))
        #expect(viewModel.selectedConversationCoordinator.state.selectedConversationState.phase == .outgoingBeep)
        #expect(viewModel.pendingConnectAcceptedIncomingBeepContactId == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains("reason=contact-list-focused-detail")
        )
        #expect(
            viewModel.diagnosticsTranscript.contains("Selected contact prewarm pipeline completed")
        )
        #expect(
            client.sentSignalsForTesting().contains { $0.type == .selectedFriendPrewarm }
        )
        let cooldownRemaining = viewModel.beepCooldownRemaining(for: contactID)
        #expect(cooldownRemaining != nil)
        #expect((29...30).contains(cooldownRemaining ?? 0))
    }

    @MainActor
    @Test func repeatedForegroundBeepNotificationPrewarmDoesNotRepublishSelectedFriendPrewarmHint() async throws {
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: beep.channelId,
            remoteUserId: beep.fromUserId
        )
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
        client.enableSentSignalCaptureForTesting()

        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.selectedContactPrewarmPipelineEnabled = true
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contact.id, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let userInfo: [AnyHashable: Any] = [
            "event": TurboNotificationCategory.beepEvent,
            "fromHandle": contact.handle,
            "beepId": beep.beepId,
        ]

        await viewModel.handleForegroundBeepNotification(userInfo: userInfo)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let firstSignalCount = client.sentSignalsForTesting().filter { $0.type == .selectedFriendPrewarm }.count

        await viewModel.handleForegroundBeepNotification(userInfo: userInfo)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let secondSignalCount = client.sentSignalsForTesting().filter { $0.type == .selectedFriendPrewarm }.count

        #expect(firstSignalCount > 0)
        #expect(secondSignalCount == firstSignalCount)
        #expect(
            viewModel.diagnosticsTranscript.contains("blockReason=duplicate-beep")
        )
    }

    @Test func backendCommandReducerCoalescesRepeatedOutgoingBeepWhileCreateIsInFlight() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            operationID: "connect:first",
            relationship: .none,
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let repeatedBeepRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            operationID: "connect:second",
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: inFlightRequest), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(repeatedBeepRequest)
        )

        #expect(transition.state.activeOperation == .join(request: inFlightRequest))
        #expect(transition.state.queuedJoinRequest == nil)
        #expect(transition.effects.isEmpty)
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsOutgoingBeepAsBeepOnly() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
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

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: nil
        )

        #expect(plan == .beepOnly)
    }

    @MainActor
    @Test func plainOutgoingBeepDoesNotQueueLocalConnectBeforeBackendAccepts() async {
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

        viewModel.performConnect(to: contact, intent: .requestConnection)
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
    @Test func incomingBeepStillQueuesLocalConnectForAccept() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
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
            channelId: channelUUID,
            backendChannelId: beep.channelId,
            remoteUserId: beep.fromUserId
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.markStaleSystemRejoinSuppression(
            channelUUID: channelUUID,
            contactID: contactID,
            reason: "recent-system-leave"
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.backendCommandCoordinator.effectHandler = { _ in }

        viewModel.performConnect(to: contact, intent: .requestConnection)

        #expect(viewModel.conversationActionCoordinator.pendingAction.pendingConnectContactID == contactID)
        #expect(viewModel.pendingConnectAcceptedIncomingBeepContactId == contactID)
        #expect(!viewModel.hasStaleSystemRejoinSuppression(channelUUID: channelUUID, contactID: contactID))
        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(viewModel.selectedConversationState(for: contactID).statusMessage == "Connecting...")
    }

    @MainActor
    @Test func offlineIncomingBeepBackDoesNotQueueLocalConnect() async {
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
            isOnline: false,
            channelId: UUID(),
            backendChannelId: beep.channelId,
            remoteUserId: beep.fromUserId
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.performConnect(to: contact, intent: .requestConnection)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.pendingConnectAcceptedIncomingBeepContactId == nil)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingBeep(requestCount: 1)
                    && request.contactIsOnline == false
            }
        )
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsConnectedCreatedBeepAsJoinConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: makeBeep(direction: "outgoing", status: "connected"),
            existingConversationSnapshot: nil
        )

        #expect(plan == .joinConversation)
    }

    @MainActor
    @Test func beepAgainRefreshesExistingOutgoingBeepAfterCooldownExpires() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
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

        #expect(viewModel.shouldRefreshExistingOutgoingBeep(for: request))
    }

    @MainActor
    @Test func beepAgainDoesNotRefreshOutgoingBeepWhileCooldownIsActive() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: 12,
            usesLocalHTTPBackend: false
        )

        #expect(!viewModel.shouldRefreshExistingOutgoingBeep(for: request))
    }

    @MainActor
    @Test func initialOutgoingBeepSkipsMetadataPrefetchBeforeBeepCreate() {
        let viewModel = PTTViewModel()
        let initialBeepRequest = BackendJoinRequest(
            contactID: UUID(),
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
        let incomingAccept = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: makeBeep(direction: "incoming"),
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let beepAgainRequest = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: makeBeep(direction: "outgoing"),
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        #expect(viewModel.shouldCreateOutgoingBeepWithoutMetadataPrefetch(for: initialBeepRequest))
        #expect(!viewModel.shouldCreateOutgoingBeepWithoutMetadataPrefetch(for: incomingAccept))
        #expect(!viewModel.shouldCreateOutgoingBeepWithoutMetadataPrefetch(for: beepAgainRequest))
    }

    @MainActor
    @Test func incomingAcceptUsesCachedBeepBeforeRefreshingBeepList() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let cachedBeep = makeBeep(
            direction: "incoming",
            beepId: "cached-beep",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: cachedBeep.fromUserId,
            existingBackendChannelID: cachedBeep.channelId,
            incomingBeep: cachedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        #expect(viewModel.cachedIncomingBeepForFastAccept(for: request)?.beepId == "cached-beep")
        #expect(
            viewModel.cachedIncomingBeepForFastAccept(
                for: request,
                excludingBeepIDs: ["cached-beep"]
            ) == nil
        )
    }

    @MainActor
    @Test func acceptedOutgoingJoinSkipsOutgoingBeepLookupWhenChannelMetadataIsKnown() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-avery",
            remoteUserId: "user-avery"
        )
        let acceptedOutgoingJoin = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinAcceptedOutgoingBeep,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let beepAgainRequest = BackendJoinRequest(
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
        let contactMissingMetadata = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: nil,
            remoteUserId: nil
        )
        let acceptedOutgoingJoinMissingMetadata = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinAcceptedOutgoingBeep,
            relationship: .outgoingBeep(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        #expect(!viewModel.shouldResolveOutgoingBeepBeforeJoin(for: acceptedOutgoingJoin, contact: contact))
        #expect(viewModel.shouldResolveOutgoingBeepBeforeJoin(for: beepAgainRequest, contact: contact))
        #expect(
            viewModel.shouldResolveOutgoingBeepBeforeJoin(
                for: acceptedOutgoingJoinMissingMetadata,
                contact: contactMissingMetadata
            )
        )
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsIncomingBeepAsJoinConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
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

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: nil
        )

        #expect(plan == .joinConversation)
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsOfflineIncomingBeepAsBeepOnly() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: makeBeep(direction: "incoming"),
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false,
            contactIsOnline: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdBeep: nil,
            existingConversationSnapshot: nil
        )

        #expect(plan == .beepOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanKeepsOutgoingBeepOnRequestPathEvenWhenPeerAlreadyJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
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
                peerDeviceConnected: true,
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
            existingConversationSnapshot: existingConversationSnapshot
        )

        #expect(plan == .beepOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanKeepsOutgoingBeepOnRequestPathWhenPeerIsJoinedButDeviceNotConnected() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
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
            existingConversationSnapshot: existingConversationSnapshot
        )

        #expect(plan == .beepOnly)
    }

    @MainActor
    @Test func beepMatcherFindsIncomingBeepByHandleWhenCachedBeepIsMissing() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let beep = TurboBeepResponse(
            beepId: "beep-1",
            fromUserId: "user-avery",
            fromHandle: "@avery",
            toUserId: "self",
            toHandle: "@blake",
            channelId: "channel-avery",
            status: "pending",
            direction: "incoming",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            subject: nil,
            targetAvailability: nil,
            shouldAutoJoinFriend: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.beepMatchesJoinRequest(beep, request: request, direction: "incoming"))
    }

    @MainActor
    @Test func staleIncomingBeepAcceptFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreIncomingBeepAcceptFailure(TurboBackendError.server("beep not found")))
        #expect(viewModel.shouldIgnoreIncomingBeepAcceptFailure(TurboBackendError.server(" Beep Not Found ")) )
    }

    @MainActor
    @Test func incomingBeepResolutionPrefersFreshPendingBeepOverCachedStaleBeep() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-1",
            incomingBeep: makeBeep(
                direction: "incoming",
                beepId: "old-cached",
                fromHandle: "@avery",
                toHandle: "@self",
                createdAt: "2026-04-08T00:00:00Z"
            ),
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let freshBeep = makeBeep(
            direction: "incoming",
            beepId: "fresh-pending",
            fromHandle: "@avery",
            toHandle: "@self",
            createdAt: "2026-04-08T00:00:02Z"
        )

        let selectedBeep = viewModel.freshestMatchingIncomingBeep(
            for: request,
            cachedBeep: request.incomingBeep,
            fetchedBeeps: [freshBeep]
        )

        #expect(selectedBeep?.beepId == "fresh-pending")
    }

    @MainActor
    @Test func incomingBeepResolutionIgnoresAcceptedFetchedBeepAndFallsBackToPendingCachedBeep() {
        let viewModel = PTTViewModel()
        let cachedBeep = makeBeep(
            direction: "incoming",
            beepId: "cached-pending",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-1",
            incomingBeep: cachedBeep,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let acceptedBeep = makeBeep(
            direction: "incoming",
            beepId: "accepted",
            fromHandle: "@avery",
            toHandle: "@self",
            status: "connected"
        )

        let selectedBeep = viewModel.freshestMatchingIncomingBeep(
            for: request,
            cachedBeep: cachedBeep,
            fetchedBeeps: [acceptedBeep]
        )

        #expect(selectedBeep?.beepId == "cached-pending")
    }

    @MainActor
    @Test func staleSupersededOutgoingBeepCancelFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreBeepNotFoundFailure(TurboBackendError.server("beep not found")))
        #expect(viewModel.shouldIgnoreBeepNotFoundFailure(TurboBackendError.server(" Beep Not Found ")))
    }

    @MainActor
    @Test func nonStaleIncomingBeepAcceptFailureIsNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreIncomingBeepAcceptFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreIncomingBeepAcceptFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func unrelatedBeepCancelFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreBeepNotFoundFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreBeepNotFoundFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func beepMatcherRejectsWrongDirection() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingBeep(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingBeep: nil,
            outgoingBeep: nil,
            beepCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let beep = TurboBeepResponse(
            beepId: "beep-1",
            fromUserId: "self",
            fromHandle: "@blake",
            toUserId: "user-avery",
            toHandle: "@avery",
            channelId: "channel-avery",
            status: "pending",
            direction: "outgoing",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            subject: nil,
            targetAvailability: nil,
            shouldAutoJoinFriend: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.beepMatchesJoinRequest(beep, request: request, direction: "incoming") == false)
    }

    @Test func incomingBeepSurfaceShowsNewestUnsurfacedBeepWhenAppIsActive() {
        let older = IncomingBeepCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-older",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )
        let newer = IncomingBeepCandidate(
            contact: Contact(
                id: UUID(),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-newer",
                fromHandle: "@blake",
                createdAt: "2026-04-17T19:02:00Z",
                updatedAt: "2026-04-17T19:02:00Z"
            )
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [older, newer],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep?.beepID == "beep-newer")
        #expect(nextState.surfacedBeepIDs == Set(["beep-newer"]))
    }

    @Test func incomingBeepSurfaceDefersUntilAppBecomesActive() {
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let backgroundState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: false
            )
        )
        let activeState = IncomingBeepSurfaceReducer.reduce(
            state: backgroundState,
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(backgroundState.activeIncomingBeep == nil)
        #expect(backgroundState.surfacedBeepIDs.isEmpty)
        #expect(activeState.activeIncomingBeep?.beepID == "beep-1")
    }

    @Test func backgroundDeliveredBeepReceiptSuppressesLaterForegroundBanner() {
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )
        let seenState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepSeenWithoutBanner(
                contactID: contactID,
                beepID: "beep-1",
                requestCount: 1
            )
        )
        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: seenState,
            event: .beepsUpdated(
                candidates: [
                    IncomingBeepCandidate(
                        contact: contact,
                        beep: makeBeep(
                            direction: "incoming",
                            beepId: "beep-1",
                            fromHandle: "@avery",
                            requestCount: 1,
                            createdAt: "2026-04-17T19:00:00Z",
                            updatedAt: "2026-04-17T19:00:00Z"
                        )
                    )
                ],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.surfacedBeepIDs == Set(["beep-1"]))
        #expect(nextState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
    }

    @Test func incomingBeepMarkSeenWithoutBannerClearsMatchingPendingForegroundSurface() {
        let contactID = UUID()
        let surface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "beep-1",
            contactName: "Avery",
            contactHandle: "@avery",
            contactIsOnline: true,
            requestCount: 1,
            recencyKey: "notification:1:beep-1"
        )
        let queuedState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .pendingForegroundBeepQueued(surface: surface, receivedAt: Date())
        )
        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: queuedState,
            event: .beepsUpdated(
                candidates: [IncomingBeepCandidate(surface: surface)],
                selectedContactID: nil,
                applicationIsActive: true,
                presentationPolicy: .markSeenWithoutBanner
            )
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.pendingForegroundBeep == nil)
        #expect(nextState.pendingForegroundBeepReceivedAt == nil)
        #expect(nextState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
    }

    @Test func incomingBeepCreatedBeforeForegroundBannerEpochDoesNotSurfaceBanner() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1"
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                toHandle: "@self",
                requestCount: 1,
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )
        let epoch = ISO8601DateFormatter().date(from: "2026-04-17T19:01:00Z")!
        let epochState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .foregroundBannerEpochStarted(epoch)
        )
        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: epochState,
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
    }

    @Test func incomingBeepCreatedAfterForegroundBannerEpochCanSurfaceBanner() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1"
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                toHandle: "@self",
                requestCount: 1,
                createdAt: "2026-04-17T19:02:00Z",
                updatedAt: "2026-04-17T19:02:00Z"
            )
        )
        let epoch = ISO8601DateFormatter().date(from: "2026-04-17T19:01:00Z")!
        let epochState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .foregroundBannerEpochStarted(epoch)
        )
        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: epochState,
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep?.beepID == "beep-1")
        #expect(nextState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
    }

    @MainActor
    @Test func foregroundRelationshipRequestCountAdvanceSurfacesWhenDetailedBeepCacheIsPreEpoch() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelID = "channel-1"
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: channelID,
            remoteUserId: "user-avery"
        )
        let staleDetailedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-3",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 3,
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        let epoch = ISO8601DateFormatter().date(from: "2026-04-17T19:01:00Z")!
        viewModel.incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: viewModel.incomingBeepSurfaceState,
            event: .foregroundBannerEpochStarted(epoch)
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: staleDetailedBeep)],
                outgoing: [],
                now: epoch
            )
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: channelID,
                        handle: "@avery",
                        displayName: "Avery",
                        isOnline: true,
                        hasIncomingBeep: true,
                        requestCount: 4,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )

        viewModel.reconcileIncomingBeepSurface(
            applicationState: .active,
            allowsSelectedContact: true
        )

        #expect(viewModel.activeIncomingBeep?.contactID == contactID)
        #expect(viewModel.activeIncomingBeep?.requestCount == 4)
        #expect(viewModel.activeIncomingBeep?.beepID.hasPrefix("relationship:") == true)
        #expect(
            viewModel.incomingBeepSurfaceState.surfacedBeepKeys.contains(
                BeepSurfaceKey(contactID: contactID, requestCount: 4)
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Activated foreground incoming Beep banner"
            )
        )
    }

    @Test func incomingBeepSurfaceCanMarkPendingBeepSeenWithoutBannerWhenAppOpens() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let openedState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true,
                presentationPolicy: .markSeenWithoutBanner
            )
        )
        let repeatedPendingState = IncomingBeepSurfaceReducer.reduce(
            state: openedState,
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let refreshedCandidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                requestCount: 2,
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:01:00Z"
            )
        )
        let newRevisionState = IncomingBeepSurfaceReducer.reduce(
            state: repeatedPendingState,
            event: .beepsUpdated(
                candidates: [refreshedCandidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(openedState.activeIncomingBeep == nil)
        #expect(openedState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
        #expect(repeatedPendingState.activeIncomingBeep == nil)
        #expect(newRevisionState.activeIncomingBeep?.requestCount == 2)
    }

    @Test func incomingBeepSurfaceNormallyDoesNotInterruptForSelectedContact() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: contactID,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.surfacedBeepIDs.isEmpty)
    }

    @Test func incomingBeepSurfaceCanInterruptForSelectedContactWhenForegroundPushArrives() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: contactID,
                applicationIsActive: true,
                allowsSelectedContact: true
            )
        )

        #expect(nextState.activeIncomingBeep?.beepID == "beep-1")
        #expect(nextState.surfacedBeepIDs == Set(["beep-1"]))
    }

    @Test func incomingBeepSurfaceCanInterruptForAlreadySurfacedBeepWhenForegroundPushArrives() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(
                activeIncomingBeep: nil,
                surfacedBeepIDs: Set(["beep-1"])
            ),
            event: .beepsUpdated(
                candidates: [candidate],
                selectedContactID: contactID,
                applicationIsActive: true,
                allowsSelectedContact: true,
                allowsAlreadySurfacedBeep: true
            )
        )

        #expect(nextState.activeIncomingBeep?.beepID == "beep-1")
        #expect(nextState.surfacedBeepIDs == Set(["beep-1"]))
    }

    @MainActor
    @Test func applicationForegroundDoesNotReplayOpenedIncomingBeepBanner() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.markIncomingBeepSurfaceOpened(for: contactID, beepID: beep.beepId)
        #expect(viewModel.activeIncomingBeep == nil)

        await viewModel.handleApplicationDidBecomeActive()

        #expect(viewModel.activeIncomingBeep == nil)
    }

    @MainActor
    @Test func automaticBeepSelectionDoesNotDismissForegroundIncomingBeepSurface() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let surface = try #require(viewModel.activeIncomingBeep)

        viewModel.reconcileContactSelectionIfNeeded(
            reason: "beep-sync",
            allowSelectingFallbackContact: false
        )

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.activeIncomingBeep == surface)
        #expect(viewModel.diagnosticsTranscript.contains("Auto-selected contact"))
    }

    @MainActor
    @Test func staleDetailedBeepDoesNotEraseActiveRelationshipForegroundBannerForSameRequest() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelID = "channel-1"
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: channelID,
            remoteUserId: "user-avery"
        )
        let staleDetailedBeep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            requestCount: 1,
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        let epoch = ISO8601DateFormatter().date(from: "2026-04-17T19:01:00Z")!

        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: viewModel.incomingBeepSurfaceState,
            event: .foregroundBannerEpochStarted(epoch)
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: channelID,
                        handle: "@avery",
                        displayName: "Avery",
                        isOnline: true,
                        hasIncomingBeep: true,
                        requestCount: 1,
                        badgeStatus: "incoming"
                    )
                )
            ])
        )

        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let surface = try #require(viewModel.activeIncomingBeep)
        #expect(surface.beepID.hasPrefix("relationship:"))

        viewModel.reconcileContactSelectionIfNeeded(
            reason: "beep-sync",
            allowSelectingFallbackContact: false
        )
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: staleDetailedBeep)],
                outgoing: [],
                now: epoch
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.activeIncomingBeep?.surfaceKey == surface.surfaceKey)
        #expect(viewModel.activeIncomingBeep?.beepID == surface.beepID)
    }

    @MainActor
    @Test func foregroundIncomingBeepBannerAutoDismissesAfterDelay() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self",
            createdAt: "2026-04-17T19:00:00Z",
            updatedAt: "2026-04-17T19:00:00Z"
        )
        viewModel.applicationStateOverride = .active
        viewModel.incomingBeepSurfaceAutoDismissDelayNanoseconds = 20_000_000
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let surface = try #require(viewModel.activeIncomingBeep)

        viewModel.scheduleIncomingBeepSurfaceAutoDismiss(surface)
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Auto-dismissed foreground incoming Beep banner"))
    }

    @Test func incomingBeepSurfaceKeepsActiveBannerStableWhenBeepSourceFlipsForSameBeep() {
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )
        let beepCandidate = IncomingBeepCandidate(
            contact: contact,
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )
        let relationshipCandidate = IncomingBeepCandidate(
            contact: contact,
            requestCount: 1,
            source: "relationship"
        )

        let initialState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [beepCandidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let relationshipProjectionState = IncomingBeepSurfaceReducer.reduce(
            state: initialState,
            event: .beepsUpdated(
                candidates: [relationshipCandidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let finalState = IncomingBeepSurfaceReducer.reduce(
            state: relationshipProjectionState,
            event: .beepsUpdated(
                candidates: [beepCandidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(initialState.activeIncomingBeep?.beepID == "beep-1")
        let surfaceKey = BeepSurfaceKey(contactID: contactID, requestCount: 1)
        #expect(relationshipProjectionState.activeIncomingBeep?.contactID == contactID)
        #expect(relationshipProjectionState.activeIncomingBeep?.requestCount == 1)
        #expect(relationshipProjectionState.activeIncomingBeep?.beepID == "beep-1")
        #expect(relationshipProjectionState.surfacedBeepKeys == Set([surfaceKey]))
        #expect(finalState.activeIncomingBeep?.beepID == "beep-1")
        #expect(finalState.surfacedBeepKeys == Set([surfaceKey]))
        #expect(finalState.surfacedBeepIDs == Set(["beep-1"]))
    }

    @Test func incomingBeepSurfaceDoesNotResurfaceSameCanonicalBeepFromDifferentSource() {
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )
        let notificationSurface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "beep-1",
            contactName: "Avery",
            contactHandle: "@avery",
            contactIsOnline: true,
            requestCount: 1,
            recencyKey: "notification:1:beep-1"
        )
        let relationshipCandidate = IncomingBeepCandidate(
            contact: contact,
            requestCount: 1,
            source: "relationship"
        )

        let visibleState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [IncomingBeepCandidate(surface: notificationSurface)],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let openedState = IncomingBeepSurfaceReducer.reduce(
            state: visibleState,
            event: .contactOpened(contactID: contactID, beepID: notificationSurface.beepID)
        )
        let relationshipProjectionState = IncomingBeepSurfaceReducer.reduce(
            state: openedState,
            event: .beepsUpdated(
                candidates: [relationshipCandidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(relationshipProjectionState.activeIncomingBeep == nil)
        #expect(
            relationshipProjectionState.surfacedBeepKeys
                == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)])
        )
    }

    @Test func incomingBeepSurfaceDoesNotShowOfflineIncomingBeepBanner() {
        let contactID = UUID()
        let offlineContact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: false,
            channelId: UUID()
        )
        let onlineContact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: offlineContact.channelId
        )

        let offlineState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [
                    IncomingBeepCandidate(
                        contact: offlineContact,
                        requestCount: 1,
                        source: "relationship"
                    )
                ],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let visibleState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [
                    IncomingBeepCandidate(
                        contact: onlineContact,
                        requestCount: 1,
                        source: "relationship"
                    )
                ],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )
        let downgradedState = IncomingBeepSurfaceReducer.reduce(
            state: visibleState,
            event: .beepsUpdated(
                candidates: [
                    IncomingBeepCandidate(
                        contact: offlineContact,
                        requestCount: 1,
                        source: "relationship"
                    )
                ],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(offlineState.activeIncomingBeep == nil)
        #expect(visibleState.activeIncomingBeep?.contactID == contactID)
        #expect(downgradedState.activeIncomingBeep == nil)
    }

    @Test func foregroundNotificationSurfaceCanAppearForStaleOfflinePresence() {
        let contactID = UUID()
        let notificationSurface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "beep-2",
            contactName: "Avery",
            contactHandle: "@avery",
            contactIsOnline: false,
            requestCount: 2,
            recencyKey: "notification:2:beep-2"
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .beepsUpdated(
                candidates: [IncomingBeepCandidate(surface: notificationSurface)],
                selectedContactID: contactID,
                applicationIsActive: true,
                allowsSelectedContact: true
            )
        )

        #expect(nextState.activeIncomingBeep?.beepID == "beep-2")
        #expect(nextState.activeIncomingBeep?.requestCount == 2)
    }

    @Test func backgroundNotificationOpenConsumesForegroundIncomingBeepSurface() {
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID()
        )

        let openedState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .contactOpened(contactID: contactID, beepID: "beep-1", requestCount: 1)
        )
        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: openedState,
            event: .beepsUpdated(
                candidates: [
                    IncomingBeepCandidate(
                        contact: contact,
                        requestCount: 1,
                        source: "relationship"
                    )
                ],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.surfacedBeepKeys == Set([BeepSurfaceKey(contactID: contactID, requestCount: 1)]))
    }

    @Test func incomingBeepAcceptStateDeduplicatesRacingSurfacesByCanonicalKey() {
        let contactID = UUID()
        let beepSurface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "beep-1",
            contactName: "Avery",
            contactHandle: "@avery",
            contactIsOnline: true,
            requestCount: 1,
            recencyKey: "beep"
        )
        let relationshipSurface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "relationship:\(contactID.uuidString):1",
            contactName: "Avery",
            contactHandle: "@avery",
            contactIsOnline: true,
            requestCount: 1,
            recencyKey: "relationship"
        )

        let acceptingState = IncomingBeepSurfaceReducer.reduce(
            state: IncomingBeepSurfaceState(),
            event: .incomingBeepAcceptStarted(beepSurface)
        )
        let duplicateAcceptState = IncomingBeepSurfaceReducer.reduce(
            state: acceptingState,
            event: .incomingBeepAcceptStarted(relationshipSurface)
        )

        #expect(acceptingState.pendingAcceptBeep == beepSurface)
        #expect(duplicateAcceptState.pendingAcceptBeep == beepSurface)
        #expect(duplicateAcceptState.isAccepting(relationshipSurface))
    }

    @Test func canonicalIncomingBeepCarriesSubjectAndSentTimestampFromBeep() {
        let contactID = UUID()
        let candidate = IncomingBeepCandidate(
            contact: Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            beep: makeBeep(
                direction: "incoming",
                beepId: "beep-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                subject: "Can we talk?"
            )
        )

        #expect(candidate.beep.subject == "Can we talk?")
        #expect(candidate.beep.sentAt == "2026-04-17T19:00:00Z")
        #expect(candidate.surface.subject == "Can we talk?")
        #expect(candidate.surface.sentAt == "2026-04-17T19:00:00Z")
    }

    @Test func openingBeepContactClearsBannerAndMarksBeepSurfaced() {
        let contactID = UUID()
        let beepID = "beep-1"
        let initialState = IncomingBeepSurfaceState(
            activeIncomingBeep: IncomingBeepSurface(
                contactID: contactID,
                beepID: beepID,
                contactName: "Avery",
                contactHandle: "@avery",
                contactIsOnline: true,
                requestCount: 1,
                recencyKey: "2026-04-17T19:00:00Z"
            ),
            surfacedBeepIDs: []
        )

        let nextState = IncomingBeepSurfaceReducer.reduce(
            state: initialState,
            event: .contactOpened(contactID: contactID, beepID: beepID)
        )

        #expect(nextState.activeIncomingBeep == nil)
        #expect(nextState.surfacedBeepIDs == Set([beepID]))
    }

    @MainActor
    @Test func acceptingActiveIncomingBeepSelectsContactAndRequestsJoin() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.acceptActiveIncomingBeep()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.requestedExpandedCallContactID == contactID)
        #expect(viewModel.requestedExpandedCallSequence == 1)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingBeep(requestCount: 1)
                    && request.incomingBeep?.beepId == "beep-1"
            }
        )
    }

    @MainActor
    @Test func visibleForegroundBeepAcceptUsesRenderedSurfaceSnapshot() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let renderedSurface = try #require(viewModel.activeIncomingBeep)
        viewModel.incomingBeepSurfaceState.activeIncomingBeep = nil

        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.acceptIncomingBeepSurface(renderedSurface)
        try await Task.sleep(nanoseconds: 50_000_000)

        let joinEffects = capturedEffects.filter {
            guard case .join = $0 else { return false }
            return true
        }
        #expect(joinEffects.count == 1)
        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Foreground incoming Beep banner accepted"))
    }

    @MainActor
    @Test func acceptingActiveIncomingBeepIsOneShotForRacingSurfaces() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let firstSurface = try #require(viewModel.activeIncomingBeep)
        let racingRelationshipSurface = IncomingBeepSurface(
            contactID: contactID,
            beepID: "relationship:\(contactID.uuidString):1",
            contactName: firstSurface.contactName,
            contactHandle: firstSurface.contactHandle,
            contactIsOnline: firstSurface.contactIsOnline,
            requestCount: firstSurface.requestCount,
            recencyKey: "relationship:1:\(contactID.uuidString)"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.acceptActiveIncomingBeep()
        viewModel.incomingBeepSurfaceState.activeIncomingBeep = racingRelationshipSurface
        viewModel.acceptActiveIncomingBeep()
        try await Task.sleep(nanoseconds: 50_000_000)

        let joinEffects = capturedEffects.filter {
            guard case .join = $0 else { return false }
            return true
        }
        #expect(joinEffects.count == 1)
        #expect(viewModel.activeIncomingBeep == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Ignored repeated foreground incoming Beep banner accept"
            )
        )
    }

    @MainActor
    @Test func foregroundBeepBannerAcceptWaitsForBeepProjection() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let beep = makeBeep(
            direction: "incoming",
            beepId: "beep-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: beep.channelId,
                remoteUserId: beep.fromUserId
            )
        ]
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.queuePendingForegroundBeepSurface(
            for: try #require(viewModel.contacts.first),
            beepID: beep.beepId,
            requestCount: 1,
            reason: "test-notification-before-projection"
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        let renderedSurface = try #require(viewModel.activeIncomingBeep)

        viewModel.acceptIncomingBeepSurface(renderedSurface)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.pendingForegroundBeepAcceptSurface?.id == renderedSurface.id)
        #expect(capturedEffects.filter { if case .join = $0 { true } else { false } }.isEmpty)

        viewModel.backendSyncCoordinator.send(
            .beepsUpdated(
                incoming: [BackendBeepUpdate(contactID: contactID, beep: beep)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileIncomingBeepSurface(applicationState: .active)
        try await Task.sleep(nanoseconds: 50_000_000)

        let joinEffects = capturedEffects.filter {
            guard case .join = $0 else { return false }
            return true
        }
        #expect(joinEffects.count == 1)
        #expect(viewModel.pendingForegroundBeepAcceptSurface == nil)
        #expect(viewModel.activeIncomingBeep == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Completing pending foreground incoming Beep banner accept"))
        #expect(viewModel.diagnosticsTranscript.contains("Foreground incoming Beep banner accepted"))
    }

    @MainActor
    @Test func stalePTTLeaveFailureAfterTeardownDoesNotSurfaceError() async {
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

        viewModel.handleFailedToLeaveChannel(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 1)
        )

        try? await waitForScenario(
            "stale leave failure ignored",
            participants: [viewModel],
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 10_000_000
        ) {
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignored stale PTT leave failure after teardown completed"
            }
        }

        #expect(viewModel.pttCoordinator.state.lastError == nil)
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(!viewModel.statusMessage.hasPrefix("Leave failed:"))
    }

    @MainActor
    @Test func recoveredPTTInitFailureDoesNotSurfaceInTopChrome() {
        let client = RecordingPTTSystemClient()
        client.isReady = false

        let viewModel = PTTViewModel(pttSystemClient: client)
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed")

        #expect(viewModel.diagnostics.latestError?.message == "PTT init failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == "ptt: PTT init failed")

        client.isReady = true

        #expect(viewModel.diagnostics.latestError?.message == "PTT init failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func directQuicPathLostDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(
            .media,
            level: .error,
            message: "Direct QUIC media path lost",
            metadata: ["reason": "consent-timeout"]
        )

        #expect(viewModel.diagnostics.latestError?.message == "Direct QUIC media path lost")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func idleBackendConnectionFailureDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.backend, level: .error, message: "Backend connection failed")

        #expect(viewModel.diagnostics.latestError?.message == "Backend connection failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func activeSessionBackendConnectionFailureSurfacesInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.seedEngineJoinedConversationForTesting(contactID: UUID())
        viewModel.backendStatusMessage = "Backend unavailable"
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.backend, level: .error, message: "Backend connection failed")

        #expect(viewModel.topChromeDiagnosticsErrorText == "backend: Backend connection failed")
    }

    @MainActor
    @Test func recoveredActiveSessionBackendConnectionFailureDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.seedEngineJoinedConversationForTesting(contactID: UUID())
        viewModel.backendRuntime.isReady = true
        viewModel.backendStatusMessage = "Connected"
        viewModel.statusMessage = "Connected"
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.backend, level: .error, message: "Backend connection failed")

        #expect(viewModel.diagnostics.latestError?.message == "Backend connection failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func recoveredActiveSessionChannelRefreshFailureDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.seedEngineJoinedConversationForTesting(contactID: UUID())
        viewModel.backendRuntime.isReady = true
        viewModel.backendStatusMessage = "Connected"
        viewModel.statusMessage = "Connected"
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.channel, level: .error, message: "Channel state refresh failed")

        #expect(viewModel.diagnostics.latestError?.message == "Channel state refresh failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func requestedExpandedCallPresentationStateClearsOtherFocusedDetailOnAcceptRoute() {
        let viewModel = PTTViewModel()
        let requestedContactID = UUID()
        let otherFocusedContactID = UUID()
        let contentView = ContentView(viewModel: viewModel)

        #expect(
            contentView.requestedExpandedCallPresentationState(
                requestedContactID: requestedContactID,
                focusedContactID: otherFocusedContactID,
                minimizedCallContactID: nil
            ) == RequestedExpandedCallPresentationState(
                focusedContactID: nil,
                minimizedCallContactID: nil
            )
        )
    }

    @MainActor
    @Test func recoveredBackendReadyMissingRemoteAudioSignalDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "backend says the peer is ready and connected, but selectedConversationPhase is still waitingForPeer on remote audio prewarm"
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }
}
