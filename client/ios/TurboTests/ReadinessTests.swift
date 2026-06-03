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
struct ReadinessTests {
    @Test func effectiveStateRequiresSystemAndPeerReadiness() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
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

        #expect(ConversationStateMachine.effectiveState(for: context) == .waitingForPeer)
    }

    @Test func establishedReadySessionDoesNotFlashConnectingDuringLocalWarmupRefresh() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedConversationState(
            for: ConversationDerivationContext(
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
                localMediaWarmupState: .prewarming,
                localRelayTransportReady: false,
                directMediaPathActive: false,
                hadConnectedDevicePTTContinuity: true,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        peerHasActiveDevice: false,
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
    }

    @Test func selectedConversationStateKeepsWakeReadyWhenRemoteWakeMetadataLags() {
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

    @Test func selectedConversationStateWaitsDuringSettlingJoinBeforeProjectingWakeReady() {
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
                backendConvergence: BackendConversationConvergenceState(joinPhase: .settling),
                hadConnectedDevicePTTContinuity: false,
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
        #expect(state.detail == .waitingForPeer(reason: .backendConversationTransition))
        #expect(state.statusMessage == "Connecting...")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
    }

    @Test func fetchedWaitingReadinessPreservesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
    }

    @Test func fetchedReadyReadinessReplacesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .ready)
    }

    @Test func fetchedWakeCapableDoesNotDowngradeExplicitReadySignalWhileDevicePTTSessionIsRoutable() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            peerMembershipPresent: true,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(merged?.remoteAudioReadiness == .ready)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func fetchedWakeCapableCanDowngradeReadyWhenDevicePTTSessionIsNotRoutable() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            peerMembershipPresent: true,
            existingDevicePTTSessionWasRoutable: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
    }

    @Test func transientWaitingReadinessDoesNotDowngradeRoutableReadyDevicePTTSession() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForSelf,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            remoteAudioReadiness: .ready
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            peerMembershipPresent: true,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(merged?.statusView == .ready)
        #expect(merged?.canTransmit == true)
        #expect(merged?.remoteAudioReadiness == .ready)
    }

    @Test func transientPeerConnectedFlagGapDoesNotDowngradeRoutableReadyDevicePTTSession() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            selfHasActiveDevice: true,
            peerHasActiveDevice: true,
            localAudioReadiness: .ready,
            remoteAudioReadiness: .ready
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            selfHasActiveDevice: true,
            peerHasActiveDevice: false,
            localAudioReadiness: .ready,
            remoteAudioReadiness: .unknown
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false,
            peerMembershipPresent: true,
            existingDevicePTTSessionWasRoutable: true
        )

        #expect(merged?.statusView == .ready)
        #expect(merged?.canTransmit == true)
        #expect(merged?.selfHasActiveDevice == true)
        #expect(merged?.peerHasActiveDevice == true)
        #expect(merged?.localAudioReadiness == .ready)
        #expect(merged?.remoteAudioReadiness == .ready)
    }

    @Test func fetchedWaitingReadinessDoesNotPreserveStaleWakeCapableWhenExistingSessionWasNotRoutable() {
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
            peerDeviceConnected: true
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func fetchedUnknownReadinessDoesNotPreserveWakeCapableWhenPeerMembershipIsGone() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForSelf,
            peerHasActiveDevice: false,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false,
            peerMembershipPresent: false
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func selectedConversationStateShowsFriendReadyWhenRemoteHasJoinedFirst() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .outgoingBeep,
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
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .outgoingBeep(requestCount: 1)
        )

        #expect(state.phase == .friendReady)
        #expect(state.conversationState == .outgoingBeep)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateShowsFriendReadyWhenWakeCapableRecoveryExistsWithoutMembership() {
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
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
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

    @Test func selectedConversationReadyAndLiveStatesMapToProductStatuses() {
        let readyState = SelectedConversationState(
            relationship: .none,
            detail: .friendReady,
            statusMessage: "Blake is ready to connect",
            canTransmitNow: false
        )
        let liveState = SelectedConversationState(
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        )

        #expect(readyState.displayStatus == .ready)
        #expect(liveState.displayStatus == .live)
    }

    @Test func listDisplayStatusUsesReadyForWaitingPeerAndLiveForJoinedSession() {
        #expect(
            ConversationStateMachine.displayStatus(
                for: .waitingForPeer,
                requestCount: nil,
                presence: .offline
            ) == .ready
        )
        #expect(
            ConversationStateMachine.displayStatus(
                for: .ready,
                requestCount: nil,
                presence: .connected
            ) == .live
        )
    }

    @Test func contactListPresentationUsesDedicatedSectionsWithSimplifiedAvailabilityPills() {
        let incoming = ConversationStateMachine.contactListPresentation(
            for: .incomingBeep,
            requestCount: 2,
            presence: .connected
        )
        let ready = ConversationStateMachine.contactListPresentation(
            for: .ready,
            requestCount: nil,
            presence: .reachable
        )
        let requested = ConversationStateMachine.contactListPresentation(
            for: .outgoingBeep,
            requestCount: 1,
            presence: .connected
        )
        let offline = ConversationStateMachine.contactListPresentation(
            for: .idle,
            requestCount: nil,
            presence: .offline
        )

        #expect(incoming.section == .wantsToTalk)
        #expect(incoming.availabilityPill == .online)
        #expect(incoming.statusPillText() == "Ready")
        #expect(ready.section == .readyToTalk)
        #expect(ready.availabilityPill == .online)
        #expect(ready.statusPillText() == "Online")
        #expect(ready.statusPillText(isActiveConversation: true) == "Connected")
        #expect(requested.section == .outgoingBeep)
        #expect(requested.availabilityPill == .online)
        #expect(requested.statusPillText() == "Online")
        #expect(offline.section == .contacts)
        #expect(offline.availabilityPill == .offline)
        #expect(offline.statusPillText() == "Offline")

        let reachableIdle = ConversationStateMachine.contactListPresentation(
            for: .idle,
            requestCount: nil,
            presence: .reachable
        )
        #expect(reachableIdle.section == .contacts)
        #expect(reachableIdle.displayStatus == .online)
        #expect(reachableIdle.availabilityPill == .online)
        #expect(reachableIdle.statusPillText() == "Online")
    }

    @Test func selectedConversationStateSkipsFriendReadyWhileAcceptedIncomingBeepIsStillJoining() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            pendingConnectAcceptedIncomingBeep: true,
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
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
        #expect(!state.canTransmitNow)
    }

    @Test func selectedConversationStateDoesNotReportReadyUntilLocalSessionAligns() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationReducerAutoJoinsWhenFriendReadyArrivesAfterAcceptedGap() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
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

        #expect(acceptedGap.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(acceptedGap.interruptedConnectionAttemptContactID == nil)
        #expect(acceptedGap.selectedConversationState.phase == .idle)
        #expect(acceptedGap.selectedConversationState.statusMessage == "Blake is online")

        let friendReadyTransition = SelectedConversationReducer.reduce(
            state: acceptedGap,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(friendReadyTransition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(friendReadyTransition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(friendReadyTransition.state.interruptedConnectionAttemptContactID == nil)
        #expect(friendReadyTransition.state.selectedConversationState.phase == .waitingForPeer)
    }

    @Test func selectedConversationReducerDegradesPreviouslyConnectedDevicePTTContinuityToWakeReadyOnSelfOnlyDrift() {
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

        #expect(readyState.selectedConversationState.phase == .ready)
        #expect(readyState.hadConnectedDevicePTTContinuity)

        let degradedState = SelectedConversationReducer.reduce(
            state: readyState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
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
        ).state

        #expect(degradedState.selectedConversationState.phase == .wakeReady)
        #expect(degradedState.selectedConversationState.statusMessage == "Hold to talk to wake Avery")
        #expect(degradedState.selectedConversationState.canTransmitNow == false)
        #expect(degradedState.connectedControlPlaneProjection == .wakeReady)
    }

    @Test func selectedConversationReducerJoinRequestEmitsJoinReadyFriendForFriendReadySelection() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
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

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
    }

    @Test func selectedConversationReducerAutoJoinsFriendReadyWhenSenderShortcutIsArmed() {
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

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerDoesNotAutoJoinFriendReadyWhenSenderShortcutIsDisabled() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        var seededState = reduceSelectedConversationState([
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
            .shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: false),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])
        seededState.senderAutoJoinOnBeepAcceptanceArmed = true

        let transition = SelectedConversationReducer.reduce(
            state: seededState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedConversationState.phase == .friendReady)
    }

    @Test func selectedConversationReducerKeepsSenderAutoJoinArmedAcrossAcceptedButNotYetFriendReadyGap() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = SelectedConversationReducer.reduce(
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
        let observedRequestState = [
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
            )
        ].reduce(requestedState) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        let acceptedButNotYetFriendReady = [
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
        ].reduce(observedRequestState) { state, event in
            SelectedConversationReducer.reduce(state: state, event: event).state
        }

        #expect(acceptedButNotYetFriendReady.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!acceptedButNotYetFriendReady.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(acceptedButNotYetFriendReady.selectedConversationState.phase == .idle)
        #expect(acceptedButNotYetFriendReady.selectedConversationState.statusMessage == "Blake is online")
    }

    @Test func selectedConversationReducerSkipsFriendReadyFlashWhileSenderAutoJoinIsArmed() {
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

        let acceptedState = SelectedConversationReducer.reduce(
            state: armedState,
            event: .relationshipUpdated(.none)
        ).state

        let transition = SelectedConversationReducer.reduce(
            state: acceptedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerSkipsFriendReadyFlashEvenIfOutgoingBeepThreadProjectionHasNotClearedYet() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.outgoingBeep(requestCount: 1)),
                .baseStateUpdated(.outgoingBeep),
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

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerAtomicSyncSkipsFriendReadyFlashWhileSenderAutoJoinIsArmed() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.outgoingBeep(requestCount: 1)),
                .baseStateUpdated(.outgoingBeep),
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

        let transition = SelectedConversationReducer.reduce(
            state: armedState,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .outgoingBeep(requestCount: 1),
                    baseState: .outgoingBeep,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .waitingForPeer,
                            canTransmit: false,
                            selfJoined: false,
                            peerJoined: true,
                            peerDeviceConnected: false
                        )
                    ),
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
                    localJoinFailure: nil
                )
            )
        )

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedConversationState.canTransmitNow)
    }

    @Test func selectedConversationReducerAutoJoinsOutstandingOutgoingRequestWhenPeerBecomesReady() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let outstandingState = SelectedConversationReducer.reduce(
            state: .initial,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .outgoingBeep(requestCount: 1),
                    baseState: .outgoingBeep,
                    channel: nil,
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
                    localJoinFailure: nil
                )
            )
        ).state

        let transition = SelectedConversationReducer.reduce(
            state: outstandingState,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .none,
                    baseState: .idle,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .waitingForPeer,
                            canTransmit: false,
                            selfJoined: true,
                            peerJoined: true,
                            peerDeviceConnected: true
                        )
                    ),
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
                    localJoinFailure: nil
                )
            )
        )

        #expect(transition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(transition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(transition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(transition.state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerProjectsFriendReadyFromWaitingForSelfChannelWithoutMembership() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let state = reduceSelectedConversationState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
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
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(state.selectedConversationState.phase == .friendReady)
    }

    @Test func selectedConversationReducerReconcileRequestSkipsRestoreWhenSystemSessionAlreadyMatches() {
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
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingBeep: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func friendReadyPrimaryActionAllowsConnect() {
        let action = ConversationStateMachine.primaryAction(
            selectedConversationState: SelectedConversationState(
                relationship: .outgoingBeep(requestCount: 1),
                phase: .friendReady,
                statusMessage: "Blake is ready to connect",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            beepCooldownRemaining: 20
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Connect")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func channelReadinessDecodesNestedReadinessProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "stateEpoch": "2026-05-09T10:00:02Z",
              "serverTimestamp": "2026-05-09T10:00:02Z",
              "activeTransmitId": "transmit-2",
              "readiness": {
                "kind": "peer-transmitting",
                "activeTransmitterUserId": "peer"
              },
              "audioReadiness": {
                "self": { "kind": "ready" },
                "peer": { "kind": "waiting" },
                "peerTargetDeviceId": "peer-device"
              },
              "wakeReadiness": {
                "self": { "kind": "wake-capable", "targetDeviceId": "self-device" },
                "peer": { "kind": "wake-capable", "targetDeviceId": "peer-device" }
              },
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        let readiness = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)

        #expect(readiness.statusView == .peerTransmitting(activeTransmitterUserId: "peer"))
        #expect(readiness.statusKind == "peer-transmitting")
        #expect(readiness.canTransmit == false)
        #expect(readiness.remoteAudioReadiness == .waiting)
        #expect(readiness.peerTargetDeviceId == "peer-device")
        #expect(readiness.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
        #expect(readiness.stateEpoch == "2026-05-09T10:00:02Z")
        #expect(readiness.serverTimestamp == "2026-05-09T10:00:02Z")
        #expect(readiness.activeTransmitId == "transmit-2")
    }

    @Test func channelReadinessDecodesInactiveReadinessProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": false,
              "peerHasActiveDevice": false,
              "readiness": {
                "kind": "inactive"
              },
              "audioReadiness": {
                "self": { "kind": "unknown" },
                "peer": { "kind": "unknown" }
              },
              "wakeReadiness": {
                "self": { "kind": "unavailable" },
                "peer": { "kind": "unavailable" }
              },
              "activeTransmitExpiresAt": null,
              "status": "inactive"
            }
            """.utf8
        )

        let readiness = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)

        #expect(readiness.statusView == .inactive)
        #expect(readiness.statusKind == "inactive")
        #expect(readiness.canTransmit == false)
        #expect(readiness.remoteAudioReadiness == .unknown)
        #expect(readiness.remoteWakeCapability == .unavailable)
    }

    @MainActor
    @Test func channelRefreshNotFoundPreservesFriendReadySelectionWithoutDevicePTTEvidence() {
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
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(channelId: "channel")
                )
            ])
        )
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
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: true,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                    peerTargetDeviceId: "peer-device"
                )
            )
        )
        viewModel.updateStatusForSelectedContact()

        #expect(viewModel.selectedConversationState(for: contactID).phase == .friendReady)
        #expect(
            viewModel.shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss(
                contactID: contactID,
                existing: viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID]
            )
        )
    }

    @MainActor
    @Test func transientMembershipRegressionPreservesReadyConversationWhileReceiving() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.remoteTransmittingContactIDs.insert(contactID)

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
            activeTransmitterUserId: "peer",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let incoming = TurboChannelStateResponse(
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
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        #expect(
            viewModel.shouldPreserveConversationStateDuringTransientMembershipDrift(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func inactiveReadinessMembershipLossDoesNotPreserveConversationMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let readiness = makeChannelReadiness(
            status: .inactive,
            selfHasActiveDevice: false,
            peerHasActiveDevice: false
        )

        let authoritativeLoss = viewModel.shouldHonorInactiveChannelReadinessMembershipLoss(
            contactID: contactID,
            existing: existing,
            incoming: incoming,
            readiness: readiness
        )
        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming,
            authoritativeMembershipLoss: authoritativeLoss
        )

        #expect(authoritativeLoss)
        #expect(effective.membership == .absent)
        #expect(effective.statusKind == ConversationState.idle.rawValue)
    }

    @MainActor
    @Test func readyMembershipLossPreservesConversationMembershipWhenDevicePTTSessionIsActive() {
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
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .ready,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.ready.rawValue)
    }

    @MainActor
    @Test func authoritativeReadinessMembershipLossPreservesActiveDevicePTTSession() {
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
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let authoritativeLoss =
            viewModel.shouldTreatChannelReadinessMembershipLossAsAuthoritative(
                TurboBackendError.server("not a channel member")
            )
            && viewModel.shouldHonorAuthoritativeChannelReadinessMembershipLoss(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming,
            authoritativeMembershipLoss: authoritativeLoss
        )

        #expect(!authoritativeLoss)
        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.ready.rawValue)
    }

    @MainActor
    @Test func signalingRecoveryPreservesReadyConversationDuringTransientWaitingProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendRuntime.replaceSignalingJoinRecoveryTask(with: Task {})

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.statusKind == ConversationState.ready.rawValue)
        #expect(effective.membership == .both(peerDeviceConnected: true))
    }

    @Test func selectedConversationStateDoesNotUseWakeReadyWhenOnlyLocalMembershipRemainsButPeerHasNotPublishedWakeReadiness() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
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
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
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
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
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
        #expect(!selectedConversationState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedConversationStateDoesNotUseWakeReadyWhenOnlyLocalMembershipRemainsDespitePeerWakeCapability() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
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
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
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
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
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
        #expect(selectedConversationState.statusMessage == "Connecting...")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(!selectedConversationState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
    }

    @MainActor
    @Test func selectedConversationCoordinatorSendExecutesSenderAutoJoinEffectWhenPeerBecomesReady() async {
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
        coordinator.send(.shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: true))
        coordinator.send(.relationshipUpdated(.none))
        coordinator.send(.baseStateUpdated(.idle))
        coordinator.send(.channelUpdated(nil))
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

        await coordinator.handle(.joinRequested)

        #expect(observedEffects == [.requestConnection(contactID: contactID)])
        #expect(coordinator.state.senderAutoJoinOnBeepAcceptanceArmed)

        observedEffects.removeAll()

        coordinator.send(
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(observedEffects == [.joinReadyFriend(contactID: contactID)])
        #expect(!coordinator.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(coordinator.state.selectedConversationState.phase == .waitingForPeer)
        #expect(coordinator.state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func controlPlaneReducerDoesNotRepublishRepeatedChannelRefreshReady() {
        let contactID = UUID()
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
                    contactID: .published(refreshIntent.publishedState)
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

    @MainActor
    @Test func selectedConversationIdleStatusShowsReadyToConnectWhenSummaryPresenceIsReachable() {
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
                badgeStatus: "idle",
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

        let state = viewModel.selectedConversationState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.statusMessage == "Ready to connect")
    }

    @MainActor
    @Test func readyFriendLocalConnectRequiresRoutableReceiverEvidence() {
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
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(channelId: "channel")
                )
            ])
        )
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
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(!viewModel.canQueueReadyFriendLocalConnect(for: contactID))
    }

    @MainActor
    @Test func readyFriendLocalConnectAcceptsWakeCapableReceiverEvidence() {
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
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(channelId: "channel")
                )
            ])
        )
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
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(viewModel.canQueueReadyFriendLocalConnect(for: contactID))
    }

    @MainActor
    @Test func uiProjectionAllowsVisibleCallScreenForReadyFriend() {
        let projection = UIProjectionDiagnostics(
            route: "live",
            callScreenVisible: true,
            callScreenContactHandle: "@bau",
            callScreenRequestedExpanded: false,
            callScreenMinimized: false,
            primaryActionKind: "holdToTalk",
            primaryActionLabel: "Hold To Talk",
            primaryActionEnabled: true,
            selectedConversationPhase: "ready",
            selectedConversationStatus: "Present"
        )

        #expect(projection.derivedInvariantCandidates.isEmpty)
    }
}
