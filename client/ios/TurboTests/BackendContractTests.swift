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
struct BackendContractTests {
    @MainActor
    @Test func selectedConversationCoordinatorDoesNotReportNoopSyncTransitions() {
        let contactID = UUID()
        let coordinator = SelectedConversationCoordinator()
        var reportedEvents: [String] = []
        coordinator.transitionReporter = { report in
            reportedEvents.append(report.eventName)
        }

        let snapshot = SelectedConversationSyncSnapshot(
            selection: SelectedConversationSelection(
                contactID: contactID,
                contactName: "Avery",
                contactIsOnline: true
            ),
            relationship: .none,
            baseState: .idle,
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

        coordinator.send(.syncUpdated(snapshot))
        coordinator.send(.syncUpdated(snapshot))

        #expect(reportedEvents == ["syncUpdated"])
    }

    @Test func telemetryEventRequestEncodesMetadataTextAndFlagsAsStrings() throws {
        let payload = TurboTelemetryEventRequest(
            eventName: "ios.invariant.violation",
            source: "ios",
            severity: "error",
            metadata: [
                "beta": "2",
                "alpha": "1",
            ],
            devTraffic: true,
            alert: true
        )

        let data = try JSONEncoder().encode(payload)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let json = rawObject as? [String: String]

        #expect(json?["eventName"] == "ios.invariant.violation")
        #expect(json?["source"] == "ios")
        #expect(json?["severity"] == "error")
        #expect(json?["devTraffic"] == "true")
        #expect(json?["alert"] == "true")
        #expect(json?["metadataText"] == #"{"alpha":"1","beta":"2"}"#)
    }

    @Test func telemetryEventRequestPrefersExplicitMetadataText() throws {
        let payload = TurboTelemetryEventRequest(
            eventName: "ios.error.backend",
            source: "ios",
            severity: "error",
            metadata: ["ignored": "value"],
            metadataText: "{\"prebuilt\":\"payload\"}",
            alert: false
        )

        let data = try JSONEncoder().encode(payload)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let json = rawObject as? [String: String]

        #expect(json?["metadataText"] == #"{"prebuilt":"payload"}"#)
        #expect(json?["devTraffic"] == "false")
        #expect(json?["alert"] == "false")
    }

    @Test func resetStateResponseDecodesBeepThreadResetShape() throws {
        let payload = """
        {
          "status": "reset-all",
          "clearedTransmitStates": 1,
          "clearedPresenceEntries": 2,
          "clearedTokenEntries": 3,
          "clearedBeepThreadAliasEntries": 4,
          "clearedBeepThreadByIdEntries": 5,
          "clearedBeepThreadByFromEntries": 6,
          "clearedBeepThreadByToEntries": 7,
          "clearedBeeps": 8,
          "clearedMemberships": 9,
          "clearedSessions": 10,
          "clearedSockets": 0,
          "clearedChannels": 11,
          "clearedChannelUserPairEntries": 12,
          "clearedWakeJobs": 13,
          "clearedWakeEventRows": 14,
          "clearedInvariantEventRows": 15,
          "clearedControlCommands": 16
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TurboResetStateResponse.self, from: payload)

        #expect(response.status == "reset-all")
        #expect(response.clearedTransmitStates == 1)
        #expect(response.clearedPresenceEntries == 2)
        #expect(response.clearedTokenEntries == 3)
        #expect(response.clearedBeepThreadAliasEntries == 4)
        #expect(response.clearedBeepThreadByIdEntries == 5)
        #expect(response.clearedBeepThreadByFromEntries == 6)
        #expect(response.clearedBeepThreadByToEntries == 7)
        #expect(response.clearedBeeps == 8)
        #expect(response.clearedSessions == 10)
        #expect(response.clearedSockets == 0)
        #expect(response.clearedChannels == 11)
    }

    @Test func preservedJoinedChannelRefreshDoesNotClearExplicitLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localDevicePTTEvidenceEstablished: true,
            localDevicePTTEvidenceCleared: false
        )

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
    }

    @Test func nonJoinedChannelRefreshClearsExplicitLeave() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(
                status: .outgoingBeep,
                canTransmit: false,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            localDevicePTTEvidenceEstablished: false,
            localDevicePTTEvidenceCleared: true
        )

        #expect(coordinator == ConversationActionCoordinatorState())
    }

    @MainActor
    @Test func selectedSyncClearsStalePendingJoinDuringOutgoingBeep() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.clearEngineConversationForTesting()
        viewModel.conversationActionCoordinator.queueJoin(
            contactID: contactID,
            channelUUID: viewModel.contacts[0].channelId
        )
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

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt == nil)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .outgoingBeep)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Recovered stale local join during outgoing Beep"
            )
        )
    }

    @MainActor
    @Test func selectedSyncKeepsOutgoingBeepConnectingShellWhileJoinTransitionEvidenceIsActive() {
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
            relationship: .outgoingBeep(requestCount: 1),
            operationID: "connect-test"
        )
        viewModel.promoteOptimisticOutgoingBeepToJoinTransition(contactID: contactID)
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

        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(viewModel.selectedConversationState(for: contactID).statusMessage == "Connecting...")
    }

    @Test func nonJoinedChannelRefreshClearsStalePendingJoin() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
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

        #expect(coordinator == ConversationActionCoordinatorState())
    }

    @Test func queueJoinRecordsLocalJoinAttemptWhenChannelIsKnown() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()
        let channelUUID = UUID()
        let now = Date(timeIntervalSince1970: 100)

        coordinator.queueJoin(contactID: contactID, channelUUID: channelUUID, now: now)

        #expect(coordinator.pendingJoinContactID == contactID)
        #expect(
            coordinator.localJoinAttempt == LocalJoinAttempt(
                contactID: contactID,
                channelUUID: channelUUID,
                issuedCount: 1,
                firstIssuedAt: now,
                lastIssuedAt: now
            )
        )
    }

    @Test func queueJoinReissuesExistingLocalJoinAttemptForSameChannel() {
        var coordinator = ConversationActionCoordinatorState()
        let contactID = UUID()
        let channelUUID = UUID()
        let firstIssuedAt = Date(timeIntervalSince1970: 100)
        let secondIssuedAt = Date(timeIntervalSince1970: 105)

        coordinator.queueJoin(contactID: contactID, channelUUID: channelUUID, now: firstIssuedAt)
        coordinator.queueJoin(contactID: contactID, channelUUID: channelUUID, now: secondIssuedAt)

        #expect(
            coordinator.localJoinAttempt == LocalJoinAttempt(
                contactID: contactID,
                channelUUID: channelUUID,
                issuedCount: 2,
                firstIssuedAt: firstIssuedAt,
                lastIssuedAt: secondIssuedAt
            )
        )
    }

    @Test func channelMatchedSystemMismatchDoesNotTearDownFreshJoin() {
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
            systemSessionMatchesContact: true,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
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

    @Test func channelLessConnectedContinuityTearsDownGhostLocalSession() {
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
            mediaState: .connected,
            localMediaWarmupState: .ready,
            hadConnectedDevicePTTContinuity: true,
            channel: nil
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownDevicePTTSession(contactID: contactID)
        )
    }

    @Test func pendingJoinWithBeepThreadProjectionDoesNotTreatAbsentMembershipAsTerminal() {
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
                    status: .incomingBeep,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingBeep: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .incomingBeep(requestCount: 1))

        #expect(projection.devicePTTContinuity == .pendingJoin)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedConversationState.detail == .waitingForPeer(reason: .pendingJoin))
    }

    @Test func selectedConversationStateShowsOnlineWhenRecoverableChannelExistsWithoutMembership() {
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
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.statusMessage == "Blake is online")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedConversationStateTreatsInactiveMembershipWithoutDevicePTTEvidenceAsStale() {
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
                    selfJoined: true,
                    peerJoined: true,
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
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false
                )
            )
        )

        let state = ConversationStateMachine.selectedConversationState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.statusMessage == "Blake is online")
        #expect(state.canTransmitNow == false)
        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .clearStaleBackendMembership(contactID: contactID)
        )
    }

    @Test func selectedConversationReducerKeepsSenderAutoJoinArmedAcrossIdleChannelGapWithoutProjectingConnecting() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = SelectedConversationReducer.reduce(
            state: .initial,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .outgoingBeep(requestCount: 1),
                    baseState: .outgoingBeep,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .outgoingBeep,
                            canTransmit: false,
                            selfJoined: false,
                            peerJoined: false,
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
        ).state

        let acceptedGap = SelectedConversationReducer.reduce(
            state: requestedState,
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

        #expect(acceptedGap.effects.isEmpty)
        #expect(acceptedGap.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(acceptedGap.state.interruptedConnectionAttemptContactID == nil)
        #expect(acceptedGap.state.selectedConversationState.phase == .idle)
        #expect(acceptedGap.state.selectedConversationState.statusMessage == "Blake is online")

        let friendReady = SelectedConversationReducer.reduce(
            state: acceptedGap.state,
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

        #expect(friendReady.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(!friendReady.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(friendReady.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(friendReady.state.interruptedConnectionAttemptContactID == nil)
        #expect(friendReady.state.selectedConversationState.phase == .waitingForPeer)
        #expect(friendReady.state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerKeepsSenderAutoJoinArmedAcrossRequestedChannelRelationshipGap() {
        let contactID = UUID()
        let selection = SelectedConversationSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = SelectedConversationReducer.reduce(
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

        let gapTransition = SelectedConversationReducer.reduce(
            state: requestedState,
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: selection,
                    relationship: .none,
                    baseState: .idle,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .outgoingBeep,
                            canTransmit: false,
                            selfJoined: false,
                            peerJoined: false,
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

        #expect(gapTransition.effects.isEmpty)
        #expect(gapTransition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!gapTransition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(gapTransition.state.selectedConversationState.phase == .idle)
        #expect(gapTransition.state.selectedConversationState.statusMessage == "Blake is online")

        let acceptedTransition = SelectedConversationReducer.reduce(
            state: gapTransition.state,
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

        #expect(acceptedTransition.effects == [.joinReadyFriend(contactID: contactID)])
        #expect(!acceptedTransition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(acceptedTransition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(acceptedTransition.state.selectedConversationState.phase == .waitingForPeer)
        #expect(acceptedTransition.state.selectedConversationState.statusMessage == "Connecting...")
    }

    @Test func selectedConversationReducerDoesNotCarrySenderAutoJoinShortcutAcrossSyncSelectionChange() {
        let firstContactID = UUID()
        let secondContactID = UUID()
        let firstSelection = SelectedConversationSelection(
            contactID: firstContactID,
            contactName: "Blake",
            contactIsOnline: true
        )
        let secondSelection = SelectedConversationSelection(
            contactID: secondContactID,
            contactName: "Kai",
            contactIsOnline: true
        )

        let armedState = SelectedConversationReducer.reduce(
            state: reduceSelectedConversationState([
                .selectedContactChanged(firstSelection),
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
            event: .syncUpdated(
                SelectedConversationSyncSnapshot(
                    selection: secondSelection,
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

        #expect(transition.effects.isEmpty)
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceArmed)
        #expect(!transition.state.senderAutoJoinOnBeepAcceptanceDispatchInFlight)
        #expect(transition.state.selectedConversationState.phase == .friendReady)
    }

    @Test func selectedConversationReducerJoinRequestDowngradesRecoverableChannelWithoutMembership() {
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
                        canTransmit: true,
                        selfJoined: false,
                        peerJoined: false,
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

        #expect(seededState.selectedConversationState.phase == .friendReady)

        let transition = SelectedConversationReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
    }

    @Test func channelStateTypedProjectionExposesMembershipAndBeepThreadProjection() {
        let channelState = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: false,
            hasIncomingBeep: false,
            hasOutgoingBeep: true,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.waitingForPeer.rawValue,
            canTransmit: false
        )

        #expect(channelState.membership == .both(peerDeviceConnected: false))
        #expect(channelState.beepThreadProjection == .outgoing(requestCount: 1))
        #expect(channelState.conversationStatus == .waitingForPeer)
    }

    @Test func contactSummaryDecodesNestedBeepThreadProjection() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "beepReachability": "foreground",
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "beepThreadProjection": {
                "kind": "mutual",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.beepThreadProjection == .mutual(requestCount: 3))
        #expect(summary.membership == .peerOnly(peerDeviceConnected: true))
        #expect(summary.beepReachability == .foreground)
        #expect(summary.badge == .incoming)
        #expect(summary.badgeKind == "incoming")
        #expect(summary.badge.conversationState == .incomingBeep)
    }

    @Test func contactSummaryDecodesHostedRequestedAliasAsOutgoingBeep() throws {
        let data = Data(
            """
            {
              "userId": "dev-user:@bau",
              "handle": "@bau",
              "publicId": "@bau",
              "displayName": "Mellow Comet",
              "profileName": "Mellow Comet",
              "channelId": "j9ipk7emsh2dbatv4eopljdjl8etqgrd",
              "isOnline": true,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": true,
              "requestCount": 1,
              "membership": {
                "kind": "absent"
              },
              "beepThreadProjection": {
                "kind": "outgoing",
                "requestCount": 1
              },
              "summaryStatus": {
                "kind": "requested"
              },
              "isActiveConversation": false,
              "badgeStatus": "requested"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.isOnline)
        #expect(summary.beepReachability == .foreground)
        #expect(summary.beepThreadProjection == .outgoing(requestCount: 1))
        #expect(summary.badge == .outgoingBeep)
        #expect(summary.badgeStatus == "outgoing-beep")
    }

    @Test func channelStateDecodesHostedRequestedAliasAsOutgoingBeep() throws {
        let data = Data(
            """
            {
              "channelId": "j9ipk7emsh2dbatv4eopljdjl8etqgrd",
              "stateEpoch": "2026-05-28T13:10:26.81550156Z",
              "serverTimestamp": "2026-05-28T13:10:26.81550156Z",
              "selfUserId": "dev-user:@mau",
              "peerUserId": "dev-user:@bau",
              "peerHandle": "@bau",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": true,
              "requestCount": 1,
              "membership": {
                "kind": "absent"
              },
              "beepThreadProjection": {
                "kind": "outgoing",
                "requestCount": 1
              },
              "conversationStatus": {
                "kind": "requested"
              },
              "status": "requested",
              "canTransmit": false
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(state.beepThreadProjection == .outgoing(requestCount: 1))
        #expect(state.statusView == .outgoingBeep)
        #expect(state.status == "outgoing-beep")
        #expect(state.conversationStatus == .outgoingBeep)
    }

    @Test func userLookupDecodesPublicIdentityFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@legacy",
              "publicId": "maurice",
              "displayName": "Maurice",
              "profileName": "Maurice",
              "shareCode": "@maurice",
              "shareLink": "https://beepbeep.to/maurice",
              "did": "did:web:beepbeep.to:id:maurice",
              "subjectKind": "agent"
            }
            """.utf8
        )

        let user = try JSONDecoder().decode(TurboUserLookupResponse.self, from: data)

        #expect(user.handle == "@legacy")
        #expect(user.publicId == "maurice")
        #expect(user.profileName == "Maurice")
        #expect(user.shareCode == "@maurice")
        #expect(user.shareLink == "https://beepbeep.to/maurice")
        #expect(user.did == "did:web:beepbeep.to:id:maurice")
        #expect(user.subjectKind == "agent")
    }

    @Test func contactSummaryDecodeFailsForInvalidNestedRelationshipKind() {
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
                "kind": "sideways",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail for invalid beepThreadProjection kind")
        } catch {
        }
    }

    @Test func channelStateDecodesNestedMembershipAndBeepThreadProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "stateEpoch": "2026-05-09T10:00:01Z",
              "serverTimestamp": "2026-05-09T10:00:01Z",
              "activeTransmitId": "transmit-1",
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingBeep": false,
              "hasOutgoingBeep": false,
              "requestCount": 0,
              "membership": {
                "kind": "both",
                "peerDeviceConnected": true
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

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .both(peerDeviceConnected: true))
        #expect(channelState.beepThreadProjection == .incoming(requestCount: 4))
        #expect(channelState.statusView == .selfTransmitting(activeTransmitterUserId: "self"))
        #expect(channelState.statusKind == "self-transmitting")
        #expect(channelState.conversationStatus == .transmitting)
        #expect(channelState.stateEpoch == "2026-05-09T10:00:01Z")
        #expect(channelState.serverTimestamp == "2026-05-09T10:00:01Z")
        #expect(channelState.activeTransmitId == "transmit-1")
    }

    @MainActor
    @Test func channelRefreshFailurePreservesJoinedSelectedConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        #expect(viewModel.hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID))
    }

    @MainActor
    @Test func channelRefreshFailureDoesNotPreserveIdleSelectedConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID

        #expect(!viewModel.hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID))
    }

    @MainActor
    @Test func authoritativeChannelLossPreservesJoinedSelectedConversationWithLocalConversationEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        let existing = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )

        #expect(
            viewModel.shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss(
                contactID: contactID,
                existing: existing
            )
        )
    }

    @MainActor
    @Test func authoritativeChannelLossDoesNotPreserveEmptyInactiveSelectedConversation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        let existing = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        #expect(
            !viewModel.shouldPreserveSelectedConversationAfterAuthoritativeChannelLoss(
                contactID: contactID,
                existing: existing
            )
        )
    }

    @MainActor
    @Test func channelRefreshNotFoundClearsOrphanedJoinedSystemSession() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        viewModel.clearDevicePTTSessionAfterAuthoritativeChannelLoss(
            contactID: contactID,
            backendChannelID: "channel",
            error: TurboBackendError.server("channel not found")
        )

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(viewModel.isJoined == false)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(viewModel.conversationActionCoordinator.pendingAction == .none)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Clearing Device PTT session after authoritative channel loss"))
    }

    @MainActor
    @Test func idleChannelRegressionDoesNotPreserveWithoutConversationEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

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
            !viewModel.shouldPreserveConversationStateDuringTransientMembershipDrift(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func authoritativeMembershipLossDoesNotPreserveConversationMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

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

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming,
            authoritativeMembershipLoss: true
        )

        #expect(effective.membership == .absent)
        #expect(effective.statusKind == ConversationState.idle.rawValue)
    }

    @MainActor
    @Test func authoritativeMembershipLossIsDeferredDuringRequestHandshake() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let existing = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: true
        )
        let incoming = makeChannelState(
            status: .incomingBeep,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingBeep: true
        )

        #expect(
            !viewModel.shouldHonorAuthoritativeChannelReadinessMembershipLoss(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func authoritativeMembershipLossIsDeferredForChannelMatchedSystemSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: nil, reason: "test")
        )

        let existing = makeChannelState(status: .waitingForPeer, canTransmit: false)
        let incoming = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        #expect(viewModel.systemSessionMatches(contactID))
        #expect(viewModel.hasLocalConversationEvidenceForChannelRefreshRecovery(contactID: contactID))
        #expect(
            !viewModel.shouldHonorAuthoritativeChannelReadinessMembershipLoss(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func idleMembershipLossDoesNotPreserveConversationMembershipWithoutLocalConversationEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .idle,
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

        #expect(effective.membership == .absent)
        #expect(effective.statusKind == ConversationState.idle.rawValue)
    }

    @MainActor
    @Test func idleMembershipLossPreservesConversationMembershipWhenDevicePTTSessionIsActive() {
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

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.ready.rawValue)
    }

    @MainActor
    @Test func selfMembershipDriftPreservesConversationMembershipWhenFriendRemainsJoined() {
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

        let existing = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let incoming = TurboChannelStateResponse(
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
            status: "connecting",
            canTransmit: false
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == TurboChannelMembership.both(peerDeviceConnected: true))
        #expect(effective.statusKind == "connecting")
    }

    @MainActor
    @Test func waitingFriendOnlyMembershipDriftPreservesConversationMembership() {
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

        let existing = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let incoming = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.waitingForPeer.rawValue)
    }

    @MainActor
    @Test func selfMembershipDriftDoesNotPreserveWithoutLocalConversationEvidence() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let existing = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let incoming = TurboChannelStateResponse(
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
            status: "connecting",
            canTransmit: false
        )

        let effective = viewModel.effectiveChannelStatePreservingConversationMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == TurboChannelMembership.peerOnly(peerDeviceConnected: true))
        #expect(effective.statusKind == "connecting")
    }

    @MainActor
    @Test func signalingRecoveryPreservesWaitingSelfOnlyConversationDuringIdleRegression() {
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
        viewModel.backendRuntime.replaceSignalingJoinRecoveryTask(with: Task {})

        let existing = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let incoming = makeChannelState(
            status: .idle,
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

        #expect(effective.membership == .selfOnly)
        #expect(effective.statusKind == ConversationState.waitingForPeer.rawValue)
    }

    @MainActor
    @Test func duplicateDidJoinForActiveChannelDoesNotReplayJoinSideEffects() async {
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
        viewModel.handleDidJoinChannel(channelUUID, reason: "duplicate")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.transmissionModeUpdates.count == 1)
        #expect(pttClient.accessoryButtonEventUpdates.count == 1)
        #expect(
            viewModel.diagnostics.entries.filter { $0.message == "Joined channel" }.count == 1
        )
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Ignoring duplicate PTT join for active channel"
            }
        )
    }

    @Test func selectedConversationStateWaitsWhenOnlyLocalMembershipRemainsEvenIfPeerCanStillWake() {
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
        #expect(selectedConversationState.conversationState == .waitingForPeer)
        #expect(selectedConversationState.statusMessage == "Connecting...")
        #expect(selectedConversationState.canTransmitNow == false)
        #expect(!selectedConversationState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
    }

    @MainActor
    @Test func conversationParticipantTelemetryPublishesOnlyWhenTelemetryChanges() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
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
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
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
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.localConversationNetworkInterface = .wifi

        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "test")
        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "same")

        #expect(client.sentSignalsForTesting().count == 1)
        let first = try #require(client.sentSignalsForTesting().first)
        #expect(first.type == .conversationParticipantTelemetry)
        #expect(first.channelId == "channel")
        #expect(first.fromDeviceId == "self-device")
        #expect(first.toUserId == "peer-user")
        let firstPayload = try JSONDecoder().decode(
            ConversationParticipantTelemetry.self,
            from: Data(first.payload.utf8)
        )
        #expect(firstPayload.connection?.interface == .wifi)

        viewModel.localConversationNetworkInterface = .cellular
        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "network-change")

        #expect(client.sentSignalsForTesting().count == 2)
        let second = try #require(client.sentSignalsForTesting().last)
        let secondPayload = try JSONDecoder().decode(
            ConversationParticipantTelemetry.self,
            from: Data(second.payload.utf8)
        )
        #expect(secondPayload.connection?.interface == .cellular)
    }

    @MainActor
    @Test func conversationParticipantTelemetryRepublishesUnchangedTelemetryAfterLivenessInterval() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
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
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
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
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.localConversationNetworkInterface = .wifi

        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "initial")
        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "too-soon")
        #expect(client.sentSignalsForTesting().count == 1)

        viewModel.lastPublishedConversationParticipantTelemetryAtByContactID[contactID] = Date()
            .addingTimeInterval(-(viewModel.conversationParticipantTelemetryRepublishIntervalSeconds + 1))
        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "liveness")

        #expect(client.sentSignalsForTesting().count == 2)
        #expect(viewModel.diagnosticsTranscript.contains("republished=true"))
    }

    @MainActor
    @Test func conversationParticipantTelemetryRepublishesSoonerWhileRemoteTelemetryIsMissing() async throws {
        let contactID = UUID()
        let channelUUID = UUID()
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
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
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
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)
        viewModel.localConversationNetworkInterface = .wifi

        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "initial")
        viewModel.lastPublishedConversationParticipantTelemetryAtByContactID[contactID] = Date()
            .addingTimeInterval(-(viewModel.conversationParticipantTelemetryMissingRemoteRepublishIntervalSeconds + 0.1))
        await viewModel.publishConversationParticipantTelemetryIfNeeded(reason: "remote-telemetry-missing")

        #expect(client.sentSignalsForTesting().count == 2)
    }

    @MainActor
    @Test func incomingConversationParticipantTelemetrySignalUpdatesRemoteTelemetry() throws {
        let contactID = UUID()
        let channelUUID = UUID()
        let viewModel = PTTViewModel()
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
        let telemetry = ConversationParticipantTelemetry(
            audio: .init(routeName: "Bluetooth", volumePercent: 42),
            connection: .init(interface: .cellular)
        )
        let payload = String(
            data: try JSONEncoder().encode(telemetry),
            encoding: .utf8
        )!

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .conversationParticipantTelemetry,
                channelId: "channel",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: payload
            )
        )

        #expect(viewModel.conversationParticipantTelemetry(for: contactID) == telemetry)
    }

    @Test func controlPlaneReducerRunsPostWakeRepairAtMostOncePerContact() {
        let contactID = UUID()
        let firstTransition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .postWakeRepairRequested(contactID: contactID)
        )
        let secondTransition = ControlPlaneReducer.reduce(
            state: firstTransition.state,
            event: .postWakeRepairRequested(contactID: contactID)
        )

        #expect(firstTransition.state.postWakeRepairContactIDs == [contactID])
        #expect(
            firstTransition.effects == [
                .performPostWakeRepair(contactID: contactID)
            ]
        )
        #expect(secondTransition.state.postWakeRepairContactIDs == [contactID])
        #expect(secondTransition.effects.isEmpty)
    }

    @MainActor
    @Test func transientSyncFailurePreservesActiveLocalSessionInsteadOfRebuildingControlPlane() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.seedEngineJoinedConversationForTesting(contactID: contactID)

        #expect(viewModel.selectedLocalSessionAppearsActive())
        #expect(
            viewModel.shouldRecoverBackendControlPlaneAfterSyncFailure(
                URLError(.timedOut),
                applicationState: .active
            ) == false
        )
    }

    @MainActor
    @Test func transientSyncFailureDoesNotRecoverDisconnectedControlPlane() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setWebSocketConnectionStateForTesting(.idle)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")

        #expect(
            viewModel.shouldRecoverBackendControlPlaneAfterSyncFailure(
                URLError(.timedOut),
                applicationState: .active
            ) == false
        )
    }

    @MainActor
    @Test func contactPresencePresentationTreatsIdleDisconnectedSummaryAsReachable() {
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

        #expect(viewModel.contactPresencePresentation(for: contactID) == .reachable)
        #expect(viewModel.selectedConversationPresenceIsOnline(for: contactID) == false)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsWakeCapableSummaryAsReachable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
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
            isOnline: false,
            hasIncomingBeep: false,
            hasOutgoingBeep: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "idle",
            beepReachability: .wakeCapable,
            membershipPayload: TurboChannelMembershipPayload(
                kind: "absent",
                peerDeviceConnected: nil
            )
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .reachable)
        #expect(viewModel.selectedConversationPresenceIsOnline(for: contactID) == false)
    }

    @MainActor
    @Test func contactPresencePresentationKeepsAbsentChannelSnapshotOnline() {
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
            membershipPayload: TurboChannelMembershipPayload(kind: "absent", peerDeviceConnected: nil)
        )
        let channelState = TurboChannelStateResponse(
            channelId: "channel-blake",
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
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contactID, channelState: channelState)
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func selectedConversationStateIgnoresCachedChannelStateWithoutMatchingSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-stale",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: false)
            )
        )

        let state = viewModel.selectedConversationState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.canTransmitNow == false)
    }

    @MainActor
    @Test func absentSummaryMembershipTearsDownStaleJoinedSystemSession() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
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
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel",
                        isOnline: true,
                        badgeStatus: "online",
                        membershipKind: "absent"
                    )
                )
            ])
        )
        await viewModel.reconcileSelectedConversationIfNeeded()

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID]?.membership == .absent)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
    }

    @MainActor
    @Test func selectedSyncPreservesPendingJoinWithUnresolvedLocalJoinAttemptAfterSettlingTTL() {
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

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == contactID)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt?.contactID == contactID)
        #expect(viewModel.selectedConversationState(for: contactID).phase == .waitingForPeer)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Deferred absent backend membership recovery while local join is unresolved"
                    && $0.metadata["preserveReason"] == "unresolved-local-join-attempt"
                    && $0.metadata["repairDecision"] == "suppressed"
                    && $0.metadata["repairSuppressionReason"] == "unresolved-local-join-attempt"
                    && $0.metadata["invariantID"] == "selected.backend_absent_pending_local_action_without_device_ptt_evidence"
            }
        )
    }

    @MainActor
    @Test func selectedSyncClearsExhaustedUnresolvedLocalJoinAttempt() {
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
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.conversationActionCoordinator.queueJoin(contactID: contactID, channelUUID: channelUUID)
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
        )

        viewModel.syncSelectedConversationProjection()

        #expect(viewModel.conversationActionCoordinator.pendingJoinContactID == nil)
        #expect(viewModel.conversationActionCoordinator.localJoinAttempt == nil)
        #expect(
            viewModel.diagnostics.entries.contains {
                $0.message == "Recovered local Device PTT state after backend membership became absent"
            }
        )
    }

    @MainActor
    @Test func failedJoinChannelLimitRecoversStaleSystemChannelAndRetriesJoin() async {
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

        let error = NSError(domain: PTChannelErrorDomain, code: 2)
        viewModel.handleFailedToJoinChannel(channelUUID, error: error)
        try? await Task.sleep(nanoseconds: 400_000_000)

        #expect(client.leaveRequests == [channelUUID])
        #expect(client.joinRequests == [channelUUID])
        #expect(viewModel.pttCoordinator.state.lastJoinFailure == nil)
        #expect(viewModel.pendingJoinContactId == contactID)
    }
}
