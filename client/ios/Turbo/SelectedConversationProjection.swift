import Foundation

struct SelectedConversationSelection: Equatable {
    let contactID: UUID
    let contactName: String
    let contactIsOnline: Bool
    let contactPresence: ContactPresencePresentation

    init(
        contactID: UUID,
        contactName: String,
        contactIsOnline: Bool,
        contactPresence: ContactPresencePresentation? = nil
    ) {
        self.contactID = contactID
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.contactPresence = contactPresence ?? (contactIsOnline ? .connected : .offline)
    }
}

struct BackendReadinessProjection: Equatable {
    var channel: ChannelReadinessSnapshot?
    var convergence: BackendConversationConvergenceState = .stable

    var backendJoinSettling: Bool {
        convergence.backendJoinSettling
    }

    var backendSignalingJoinRecoveryActive: Bool {
        convergence.backendSignalingJoinRecoveryActive
    }

    var controlPlaneReconnectGraceActive: Bool {
        convergence.controlPlaneReconnectGraceActive
    }
}

struct ConnectionProjection: Equatable {
    var remotePlaybackContinuity: RemotePlaybackContinuityState = .idle
    var mediaState: MediaConnectionState = .idle
    var mediaTransport: SelectedMediaTransportState = .defaultRelay
    var firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm
    var firstTalkReadiness: FirstTalkReadinessProjection?
    var incomingWakeActivationState: IncomingWakeActivationState?

    var remotePlaybackDrainBlocksTransmit: Bool {
        remotePlaybackContinuity.drainBlocksTransmit
    }

    var remoteTransmitStopObserved: Bool {
        remotePlaybackContinuity.stopObserved
    }

    var remoteTransmitStopProjectionGraceActive: Bool {
        remotePlaybackContinuity.stopProjectionGraceActive
    }

    var localRelayTransportReady: Bool {
        mediaTransport.fallbackReady
    }

    var directMediaPathActive: Bool {
        mediaTransport.directMediaPathActive
    }
}

struct DevicePTTProjection: Equatable {
    var localSession: DevicePTTLocalSession = .absent
    var systemSessionState: SystemPTTSessionState = .none
    var systemSessionMatchesContact = false
    var devicePTTRestoreBarrier: DevicePTTRestoreBarrier = .none
    var localJoinFailure: PTTJoinFailure?

    var isJoined: Bool {
        localSession.isJoined
    }

    var activeChannelID: UUID? {
        localSession.activeChannelID
    }
}

struct SelectedConversationProjectionState: Equatable {
    var selection: SelectedConversationSelection?
    var relationship: BeepThreadProjection = .none
    var baseState: ConversationState = .idle
    var localTransmit: LocalTransmitProjection = .idle
    var remoteParticipantSignalIsTransmitting: Bool = false
    var pendingAction: PendingConversationAction = .none
    var pendingConnectAcceptedIncomingBeep = false
    var senderAutoJoinOnBeepAcceptanceEnabled = true
    var senderAutoJoinOnBeepAcceptanceArmed = false
    var senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
    var senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
    var devicePTTRestoreDispatchInFlightContactID: UUID?
    var backendReadiness = BackendReadinessProjection()
    var devicePTT = DevicePTTProjection()
    var connection = ConnectionProjection()
    var hadConnectedDevicePTTContinuity = false
    var devicePTTContinuityProjection: DevicePTTContinuityProjection = .inactive
    var connectedExecutionProjection: ConnectedExecutionProjection?
    var connectedControlPlaneProjection: ConnectedControlPlaneProjection = .unavailable
    var selectedConversationState: SelectedConversationState = .initial
    var reconciliationAction: SelectedConversationReconciliationAction = .none
    var interruptedConnectionAttemptContactID: UUID?

    static let initial = SelectedConversationProjectionState()

    var isJoined: Bool {
        devicePTT.isJoined
    }

    var activeChannelID: UUID? {
        devicePTT.activeChannelID
    }

    var backendJoinSettling: Bool {
        backendReadiness.backendJoinSettling
    }

    var backendSignalingJoinRecoveryActive: Bool {
        backendReadiness.backendSignalingJoinRecoveryActive
    }

    var controlPlaneReconnectGraceActive: Bool {
        backendReadiness.controlPlaneReconnectGraceActive
    }
}

struct SelectedConversationSyncSnapshot: Equatable {
    let selection: SelectedConversationSelection
    let relationship: BeepThreadProjection
    let baseState: ConversationState
    let backendReadiness: BackendReadinessProjection
    let devicePTT: DevicePTTProjection
    let pendingAction: PendingConversationAction
    let pendingConnectAcceptedIncomingBeep: Bool
    let senderAutoJoinOnBeepAcceptanceEnabled: Bool
    let localTransmit: LocalTransmitProjection
    let remoteParticipantSignalIsTransmitting: Bool
    let connection: ConnectionProjection

    init(
        selection: SelectedConversationSelection,
        relationship: BeepThreadProjection,
        baseState: ConversationState,
        channel: ChannelReadinessSnapshot?,
        localSession: DevicePTTLocalSession? = nil,
        isJoined: Bool = false,
        activeChannelID: UUID? = nil,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool,
        senderAutoJoinOnBeepAcceptanceEnabled: Bool,
        localTransmit: LocalTransmitProjection,
        remoteParticipantSignalIsTransmitting: Bool,
        remotePlaybackContinuity: RemotePlaybackContinuityState? = nil,
        systemSessionState: SystemPTTSessionState,
        systemSessionMatchesContact: Bool,
        mediaState: MediaConnectionState,
        localRelayTransportReady: Bool = true,
        directMediaPathActive: Bool = false,
        mediaTransport: SelectedMediaTransportState? = nil,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        firstTalkReadiness: FirstTalkReadinessProjection? = nil,
        incomingWakeActivationState: IncomingWakeActivationState?,
        backendConvergence: BackendConversationConvergenceState? = nil,
        devicePTTRestoreBarrier: DevicePTTRestoreBarrier,
        localJoinFailure: PTTJoinFailure?
    ) {
        self.selection = selection
        self.relationship = relationship
        self.baseState = baseState
        self.backendReadiness = BackendReadinessProjection(
            channel: channel,
            convergence: backendConvergence ?? .stable
        )
        self.devicePTT = DevicePTTProjection(
            localSession: localSession ?? DevicePTTLocalSession(
                selectedContactID: selection.contactID,
                isJoined: isJoined,
                activeChannelID: activeChannelID
            ),
            systemSessionState: systemSessionState,
            systemSessionMatchesContact: systemSessionMatchesContact,
            devicePTTRestoreBarrier: devicePTTRestoreBarrier,
            localJoinFailure: localJoinFailure
        )
        self.pendingAction = pendingAction
        self.pendingConnectAcceptedIncomingBeep = pendingConnectAcceptedIncomingBeep
        self.senderAutoJoinOnBeepAcceptanceEnabled = senderAutoJoinOnBeepAcceptanceEnabled
        self.localTransmit = localTransmit
        self.remoteParticipantSignalIsTransmitting = remoteParticipantSignalIsTransmitting
        self.connection = ConnectionProjection(
            remotePlaybackContinuity: remotePlaybackContinuity ?? .idle,
            mediaState: mediaState,
            mediaTransport: mediaTransport ?? SelectedMediaTransportState(
                localRelayTransportReady: localRelayTransportReady,
                directMediaPathActive: directMediaPathActive
            ),
            firstTalkStartupProfile: firstTalkStartupProfile,
            firstTalkReadiness: firstTalkReadiness,
            incomingWakeActivationState: incomingWakeActivationState
        )
    }

    init(
        selection: SelectedConversationSelection,
        relationship: BeepThreadProjection,
        baseState: ConversationState,
        channel: ChannelReadinessSnapshot?,
        localSession: DevicePTTLocalSession? = nil,
        isJoined: Bool = false,
        activeChannelID: UUID? = nil,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool,
        senderAutoJoinOnBeepAcceptanceEnabled: Bool,
        localTransmit: LocalTransmitProjection,
        remoteParticipantSignalIsTransmitting: Bool,
        remotePlaybackContinuity: RemotePlaybackContinuityState? = nil,
        systemSessionState: SystemPTTSessionState,
        systemSessionMatchesContact: Bool,
        mediaState: MediaConnectionState,
        localRelayTransportReady: Bool = true,
        directMediaPathActive: Bool = false,
        mediaTransport: SelectedMediaTransportState? = nil,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        firstTalkReadiness: FirstTalkReadinessProjection? = nil,
        incomingWakeActivationState: IncomingWakeActivationState?,
        backendConvergence: BackendConversationConvergenceState? = nil,
        localJoinFailure: PTTJoinFailure?
    ) {
        self.init(
            selection: selection,
            relationship: relationship,
            baseState: baseState,
            channel: channel,
            localSession: localSession,
            isJoined: isJoined,
            activeChannelID: activeChannelID,
            pendingAction: pendingAction,
            pendingConnectAcceptedIncomingBeep: pendingConnectAcceptedIncomingBeep,
            senderAutoJoinOnBeepAcceptanceEnabled: senderAutoJoinOnBeepAcceptanceEnabled,
            localTransmit: localTransmit,
            remoteParticipantSignalIsTransmitting: remoteParticipantSignalIsTransmitting,
            remotePlaybackContinuity: remotePlaybackContinuity,
            systemSessionState: systemSessionState,
            systemSessionMatchesContact: systemSessionMatchesContact,
            mediaState: mediaState,
            localRelayTransportReady: localRelayTransportReady,
            directMediaPathActive: directMediaPathActive,
            mediaTransport: mediaTransport,
            firstTalkStartupProfile: firstTalkStartupProfile,
            firstTalkReadiness: firstTalkReadiness,
            incomingWakeActivationState: incomingWakeActivationState,
            backendConvergence: backendConvergence,
            devicePTTRestoreBarrier: .none,
            localJoinFailure: localJoinFailure
        )
    }

    var isJoined: Bool {
        devicePTT.isJoined
    }

    var activeChannelID: UUID? {
        devicePTT.activeChannelID
    }

    var backendJoinSettling: Bool {
        backendReadiness.backendJoinSettling
    }

    var backendSignalingJoinRecoveryActive: Bool {
        backendReadiness.backendSignalingJoinRecoveryActive
    }

    var controlPlaneReconnectGraceActive: Bool {
        backendReadiness.controlPlaneReconnectGraceActive
    }
}

enum SelectedConversationEvent: Equatable {
    case syncUpdated(SelectedConversationSyncSnapshot)
    case selectedContactChanged(SelectedConversationSelection?)
    case relationshipUpdated(BeepThreadProjection)
    case baseStateUpdated(ConversationState)
    case channelUpdated(ChannelReadinessSnapshot?)
    case localSessionUpdated(
        isJoined: Bool,
        activeChannelID: UUID?,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool,
        localJoinFailure: PTTJoinFailure?
    )
    case shortcutPolicyUpdated(senderAutoJoinOnBeepAcceptanceEnabled: Bool)
    case localTransmitUpdated(LocalTransmitProjection)
    case remoteParticipantSignalTransmittingUpdated(Bool)
    case systemSessionUpdated(SystemPTTSessionState, matchesSelectedContact: Bool)
    case mediaStateUpdated(MediaConnectionState)
    case incomingWakeActivationStateUpdated(IncomingWakeActivationState?)
    case senderAutoJoinCancelled(contactID: UUID)
    case connectionAttemptTimedOut(contactID: UUID)
    case devicePTTTeardownCompleted(contactID: UUID)
    case joinRequested
    case disconnectRequested
    case reconcileRequested
}

enum SelectedConversationEffect: Equatable {
    case requestConnection(contactID: UUID)
    case joinReadyFriend(contactID: UUID)
    case disconnect(contactID: UUID)
    case restoreDevicePTTSession(contactID: UUID)
    case teardownDevicePTTSession(contactID: UUID)
    case clearStaleBackendMembership(contactID: UUID)
}

struct SelectedConversationTransition: Equatable {
    var state: SelectedConversationProjectionState
    var effects: [SelectedConversationEffect] = []
}

enum SelectedConversationReducer {
    static func reduce(
        state: SelectedConversationProjectionState,
        event: SelectedConversationEvent
    ) -> SelectedConversationTransition {
        var nextState = state
        var effects: [SelectedConversationEffect] = []

        switch event {
        case .syncUpdated(let snapshot):
            if nextState.selection?.contactID == snapshot.selection.contactID {
                nextState.selection = snapshot.selection
            } else {
                var resetState = SelectedConversationProjectionState.initial
                resetState.selection = snapshot.selection
                nextState = resetState
            }
            nextState.relationship = snapshot.relationship
            nextState.baseState = snapshot.baseState
            nextState.backendReadiness = snapshot.backendReadiness
            applyLocalSessionUpdate(
                to: &nextState,
                localSession: snapshot.devicePTT.localSession,
                pendingAction: snapshot.pendingAction,
                pendingConnectAcceptedIncomingBeep: snapshot.pendingConnectAcceptedIncomingBeep,
                localJoinFailure: snapshot.devicePTT.localJoinFailure
            )
            applyShortcutPolicyUpdate(
                to: &nextState,
                senderAutoJoinOnBeepAcceptanceEnabled: snapshot.senderAutoJoinOnBeepAcceptanceEnabled
            )
            nextState.localTransmit = snapshot.localTransmit
            nextState.remoteParticipantSignalIsTransmitting = snapshot.remoteParticipantSignalIsTransmitting
            nextState.devicePTT.systemSessionState = snapshot.devicePTT.systemSessionState
            nextState.devicePTT.systemSessionMatchesContact = snapshot.devicePTT.systemSessionMatchesContact
            nextState.connection = snapshot.connection
            nextState.devicePTT.devicePTTRestoreBarrier = snapshot.devicePTT.devicePTTRestoreBarrier
        case .selectedContactChanged(let selection):
            switch selection {
            case .none:
                nextState = .initial
            case .some(let selection):
                if nextState.selection?.contactID == selection.contactID {
                    nextState.selection = selection
                } else {
                    var resetState = SelectedConversationProjectionState.initial
                    resetState.selection = selection
                    nextState = resetState
                }
            }
        case .relationshipUpdated(let relationship):
            nextState.relationship = relationship
        case .baseStateUpdated(let baseState):
            nextState.baseState = baseState
        case .channelUpdated(let channel):
            nextState.backendReadiness.channel = channel
        case .localSessionUpdated(
            let isJoined,
            let activeChannelID,
            let pendingAction,
            let pendingConnectAcceptedIncomingBeep,
            let localJoinFailure
        ):
            let localSession = nextState.selection.map {
                DevicePTTLocalSession(
                    selectedContactID: $0.contactID,
                    isJoined: isJoined,
                    activeChannelID: activeChannelID
                )
            } ?? .absent
            applyLocalSessionUpdate(
                to: &nextState,
                localSession: localSession,
                pendingAction: pendingAction,
                pendingConnectAcceptedIncomingBeep: pendingConnectAcceptedIncomingBeep,
                localJoinFailure: localJoinFailure
            )
        case .shortcutPolicyUpdated(let senderAutoJoinOnBeepAcceptanceEnabled):
            applyShortcutPolicyUpdate(
                to: &nextState,
                senderAutoJoinOnBeepAcceptanceEnabled: senderAutoJoinOnBeepAcceptanceEnabled
            )
        case .localTransmitUpdated(let localTransmit):
            nextState.localTransmit = localTransmit
        case .remoteParticipantSignalTransmittingUpdated(let remoteParticipantSignalIsTransmitting):
            nextState.remoteParticipantSignalIsTransmitting = remoteParticipantSignalIsTransmitting
        case .systemSessionUpdated(let systemSessionState, let matchesSelectedContact):
            nextState.devicePTT.systemSessionState = systemSessionState
            nextState.devicePTT.systemSessionMatchesContact = matchesSelectedContact
        case .mediaStateUpdated(let mediaState):
            nextState.connection.mediaState = mediaState
        case .incomingWakeActivationStateUpdated(let incomingWakeActivationState):
            nextState.connection.incomingWakeActivationState = incomingWakeActivationState
        case .senderAutoJoinCancelled(let contactID):
            if nextState.selection?.contactID == contactID {
                nextState.senderAutoJoinOnBeepAcceptanceArmed = false
                nextState.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
                nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
            }
        case .connectionAttemptTimedOut(let contactID):
            guard nextState.selection?.contactID == contactID,
                  isInterruptibleConnectionAttempt(nextState.selectedConversationState) else {
                return SelectedConversationTransition(state: nextState)
            }
            nextState.senderAutoJoinOnBeepAcceptanceArmed = false
            nextState.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
            nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
            nextState.interruptedConnectionAttemptContactID = contactID
            recomputeDerivedState(&nextState)
            return SelectedConversationTransition(state: nextState)
        case .devicePTTTeardownCompleted(let contactID):
            guard nextState.selection?.contactID == contactID else {
                return SelectedConversationTransition(state: nextState)
            }
            nextState.hadConnectedDevicePTTContinuity = false
            nextState.devicePTT.localSession = .absent
            nextState.devicePTT.systemSessionState = .none
            nextState.devicePTT.systemSessionMatchesContact = false
            nextState.devicePTTContinuityProjection = .inactive
            nextState.connectedExecutionProjection = nil
            nextState.connectedControlPlaneProjection = .unavailable
            nextState.reconciliationAction = .none
            if nextState.devicePTTRestoreDispatchInFlightContactID == contactID {
                nextState.devicePTTRestoreDispatchInFlightContactID = nil
            }
            recomputeDerivedState(&nextState)
            return SelectedConversationTransition(state: nextState)
        case .joinRequested:
            recomputeDerivedState(&nextState)
            if let effect = joinEffect(for: nextState) {
                nextState.interruptedConnectionAttemptContactID = nil
                if shouldArmSenderAutoJoinShortcut(state: nextState, effect: effect) {
                    nextState.senderAutoJoinOnBeepAcceptanceArmed = true
                    nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
                } else if case .joinReadyFriend = effect {
                    nextState.senderAutoJoinOnBeepAcceptanceArmed = false
                    nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
                }
                effects.append(effect)
            }
            return SelectedConversationTransition(state: nextState, effects: effects)
        case .disconnectRequested:
            nextState.interruptedConnectionAttemptContactID = nil
            recomputeDerivedState(&nextState)
            if let effect = disconnectEffect(for: nextState) {
                effects.append(effect)
            }
            return SelectedConversationTransition(state: nextState, effects: effects)
        case .reconcileRequested:
            recomputeDerivedState(&nextState)
            if let effect = reconciliationEffect(for: nextState) {
                if case .restoreDevicePTTSession(let contactID) = effect {
                    nextState.devicePTTRestoreDispatchInFlightContactID = contactID
                }
                effects.append(effect)
            }
            return SelectedConversationTransition(state: nextState, effects: effects)
        }

        recomputeDerivedState(&nextState)
        if shouldArmSenderAutoJoinForOutstandingOutgoingBeep(state: nextState) {
            nextState.senderAutoJoinOnBeepAcceptanceArmed = true
            nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = true
        } else if nextState.relationship.hasOutgoingBeep,
                  nextState.senderAutoJoinOnBeepAcceptanceArmed {
            nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = true
        }
        if shouldClearSenderAutoJoinShortcut(state: nextState) {
            if nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep,
               let contactID = nextState.selection?.contactID {
                nextState.interruptedConnectionAttemptContactID = contactID
            }
            nextState.senderAutoJoinOnBeepAcceptanceArmed = false
            nextState.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
            nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
        }
        if let effect = autoJoinReadyFriendEffect(for: nextState) {
            nextState.senderAutoJoinOnBeepAcceptanceArmed = false
            nextState.senderAutoJoinOnBeepAcceptanceDispatchInFlight = true
            nextState.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
            nextState.interruptedConnectionAttemptContactID = nil
            if let selection = nextState.selection {
                nextState.selectedConversationState = SelectedConversationState(
                    contactID: selection.contactID,
                    contactName: selection.contactName,
                    relationship: nextState.relationship,
                    detail: .waitingForPeer(reason: .pendingJoin),
                    statusMessage: "Connecting...",
                    canTransmitNow: false
                )
            }
            effects.append(effect)
        } else if shouldProjectSenderAutoJoinConnecting(state: nextState),
                  let selection = nextState.selection {
            nextState.selectedConversationState = SelectedConversationState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: nextState.relationship,
                detail: .waitingForPeer(reason: .pendingJoin),
                statusMessage: "Connecting...",
                canTransmitNow: false
            )
        }
        return SelectedConversationTransition(state: nextState, effects: effects)
    }

    private static func recomputeDerivedState(_ state: inout SelectedConversationProjectionState) {
        guard let selection = state.selection else {
            state.hadConnectedDevicePTTContinuity = false
            state.devicePTTContinuityProjection = .inactive
            state.connectedExecutionProjection = nil
            state.connectedControlPlaneProjection = .unavailable
            state.selectedConversationState = .initial
            state.reconciliationAction = .none
            return
        }

        let hadConnectedDevicePTTContinuity = state.hadConnectedDevicePTTContinuity

        let context = ConversationDerivationContext(
            contactID: selection.contactID,
            selectedContactID: selection.contactID,
            baseState: state.baseState,
            contactName: selection.contactName,
            contactIsOnline: selection.contactIsOnline,
            contactPresence: selection.contactPresence,
            localSession: state.devicePTT.localSession,
            isJoined: state.isJoined,
            localTransmit: state.localTransmit,
            remoteParticipantSignalIsTransmitting: state.remoteParticipantSignalIsTransmitting,
            remotePlaybackContinuity: state.connection.remotePlaybackContinuity,
            activeChannelID: state.activeChannelID,
            systemSessionMatchesContact: state.devicePTT.systemSessionMatchesContact,
            systemSessionState: state.devicePTT.systemSessionState,
            pendingAction: state.pendingAction,
            pendingConnectAcceptedIncomingBeep: state.pendingConnectAcceptedIncomingBeep,
            localJoinFailure: state.devicePTT.localJoinFailure,
            mediaState: state.connection.mediaState,
            localMediaWarmupState: {
                switch state.connection.mediaState {
                case .idle, .closed:
                    return .cold
                case .preparing:
                    return .prewarming
                case .connected:
                    return .ready
                case .failed:
                    return .failed
                }
            }(),
            mediaTransport: state.connection.mediaTransport,
            firstTalkStartupProfile: state.connection.firstTalkStartupProfile,
            firstTalkReadiness: state.connection.firstTalkReadiness,
            incomingWakeActivationState: state.connection.incomingWakeActivationState,
            backendConvergence: state.backendReadiness.convergence,
            devicePTTRestoreBarrier: state.devicePTT.devicePTTRestoreBarrier,
            hadConnectedDevicePTTContinuity: hadConnectedDevicePTTContinuity,
            channel: state.backendReadiness.channel
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: state.relationship
        )
        state.hadConnectedDevicePTTContinuity = updatedConnectedDevicePTTContinuity(
            previous: hadConnectedDevicePTTContinuity,
            projection: projection,
            channel: state.backendReadiness.channel
        )
        state.devicePTTContinuityProjection = projection.devicePTTContinuity
        state.connectedExecutionProjection = projection.connectedExecution
        state.connectedControlPlaneProjection = projection.connectedControlPlane
        state.selectedConversationState = projection.selectedConversationState
        state.reconciliationAction = projection.reconciliationAction
        clearCompletedDevicePTTRestoreDispatchIfNeeded(&state)
        clearCompletedInterruptedConnectionAttemptIfNeeded(&state)

        if shouldProjectWakeReadyForConnectedDegradation(
            state: state,
            projection: projection
        ) {
            state.connectedControlPlaneProjection = .wakeReady
            state.selectedConversationState = SelectedConversationState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: state.relationship,
                detail: .wakeReady,
                statusMessage: "Hold to talk to wake \(selection.contactName)",
                canTransmitNow: false
            )
        }

        if let interruptedContactID = state.interruptedConnectionAttemptContactID,
           interruptedContactID == selection.contactID,
           shouldProjectInterruptedConnectionAttempt(state) {
            state.selectedConversationState = SelectedConversationState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: state.relationship,
                detail: .localJoinFailed(recoveryMessage: "Connection interrupted"),
                statusMessage: "Connection interrupted",
                canTransmitNow: false
            )
        }
    }

    private static func applyLocalSessionUpdate(
        to state: inout SelectedConversationProjectionState,
        localSession: DevicePTTLocalSession,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool,
        localJoinFailure: PTTJoinFailure?
    ) {
        state.devicePTT.localSession = localSession
        state.pendingAction = pendingAction
        state.pendingConnectAcceptedIncomingBeep = pendingConnectAcceptedIncomingBeep
        state.devicePTT.localJoinFailure = localJoinFailure
        if localSession.isJoined || localSession.activeChannelID != nil {
            state.interruptedConnectionAttemptContactID = nil
            state.senderAutoJoinOnBeepAcceptanceArmed = false
            state.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
            state.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
        } else if pendingAction.pendingJoinContactID != nil {
            state.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
        }
    }

    private static func clearCompletedDevicePTTRestoreDispatchIfNeeded(
        _ state: inout SelectedConversationProjectionState
    ) {
        guard let contactID = state.devicePTTRestoreDispatchInFlightContactID else { return }
        guard state.selection?.contactID == contactID else {
            state.devicePTTRestoreDispatchInFlightContactID = nil
            return
        }

        if state.isJoined
            || state.activeChannelID == contactID
            || state.devicePTT.systemSessionMatchesContact
            || state.devicePTT.localJoinFailure?.contactID == contactID
            || state.pendingAction.isLeaveInFlight(for: contactID) {
            state.devicePTTRestoreDispatchInFlightContactID = nil
            return
        }

        guard case .restoreDevicePTTSession(let actionContactID) = state.reconciliationAction,
              actionContactID == contactID else {
            state.devicePTTRestoreDispatchInFlightContactID = nil
            return
        }
    }

    private static func clearCompletedInterruptedConnectionAttemptIfNeeded(
        _ state: inout SelectedConversationProjectionState
    ) {
        guard let contactID = state.interruptedConnectionAttemptContactID else { return }
        guard state.selection?.contactID == contactID else {
            state.interruptedConnectionAttemptContactID = nil
            return
        }

        if state.isJoined
            || state.activeChannelID == contactID
            || state.devicePTT.systemSessionMatchesContact
            || state.devicePTTContinuityProjection == .connected {
            state.interruptedConnectionAttemptContactID = nil
            return
        }

        switch state.selectedConversationState.phase {
        case .wakeReady, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession,
             .systemMismatch:
            state.interruptedConnectionAttemptContactID = nil
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .waitingForPeer, .localJoinFailed:
            break
        }
    }

    private static func applyShortcutPolicyUpdate(
        to state: inout SelectedConversationProjectionState,
        senderAutoJoinOnBeepAcceptanceEnabled: Bool
    ) {
        state.senderAutoJoinOnBeepAcceptanceEnabled = senderAutoJoinOnBeepAcceptanceEnabled
        if !senderAutoJoinOnBeepAcceptanceEnabled {
            state.senderAutoJoinOnBeepAcceptanceArmed = false
            state.senderAutoJoinOnBeepAcceptanceDispatchInFlight = false
            state.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep = false
        }
    }

    private static func updatedConnectedDevicePTTContinuity(
        previous: Bool,
        projection: SelectedConversationProjection,
        channel: ChannelReadinessSnapshot?
    ) -> Bool {
        if projection.devicePTTContinuity == .inactive,
           channel?.membership.hasLocalMembership != true {
            switch projection.selectedConversationState.phase {
            case .idle, .outgoingBeep, .incomingBeep, .friendReady:
                return false
            case .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
                break
            }
        }

        if projection.devicePTTContinuity == .connected {
            switch projection.selectedConversationState.phase {
            case .wakeReady, .ready, .startingTransmit, .transmitting, .receiving:
                return true
            case .idle, .outgoingBeep, .incomingBeep, .friendReady, .waitingForPeer, .localJoinFailed, .blockedByOtherSession, .systemMismatch:
                break
            }
        }

        return previous
    }

    private static func shouldClearSenderAutoJoinShortcut(
        state: SelectedConversationProjectionState
    ) -> Bool {
        guard state.senderAutoJoinOnBeepAcceptanceArmed
                || state.senderAutoJoinOnBeepAcceptanceDispatchInFlight else { return false }
        guard state.pendingAction.pendingConnectContactID == nil else { return false }
        guard state.pendingAction.pendingJoinContactID == nil else { return false }
        guard !state.pendingConnectAcceptedIncomingBeep else { return false }
        guard state.devicePTTContinuityProjection == .inactive else { return false }
        guard state.relationship == .none else { return false }
        if let channel = state.backendReadiness.channel {
            guard !channelStillShowsOutstandingRequest(channel) else { return false }
            guard channel.membership == .absent else { return false }
            if state.senderAutoJoinOnBeepAcceptanceArmed,
               !state.senderAutoJoinOnBeepAcceptanceDispatchInFlight {
                return false
            }
        } else if state.senderAutoJoinOnBeepAcceptanceArmed,
                  !state.senderAutoJoinOnBeepAcceptanceDispatchInFlight,
                  !state.senderAutoJoinOnBeepAcceptanceObservedOutgoingBeep {
            return false
        }
        return true
    }

    private static func channelStillShowsOutstandingRequest(
        _ channel: ChannelReadinessSnapshot
    ) -> Bool {
        if channel.beepThreadProjection != .none {
            return true
        }
        switch channel.status {
        case .outgoingBeep, .incomingBeep:
            return true
        case .idle, .waitingForPeer, .ready, .transmitting, .receiving, .none:
            return false
        }
    }

    private static func shouldProjectWakeReadyForConnectedDegradation(
        state: SelectedConversationProjectionState,
        projection: SelectedConversationProjection
    ) -> Bool {
        guard state.hadConnectedDevicePTTContinuity,
              projection.devicePTTContinuity == .connected,
              projection.connectedExecution == nil,
              state.connection.mediaTransport.isReadyForTransmit,
              !state.backendJoinSettling,
              state.backendReadiness.channel?.membership == .selfOnly,
              case .wakeCapable = state.backendReadiness.channel?.remoteWakeCapability,
              case .waitingForPeer(reason: .backendConversationTransition) = projection.selectedConversationState.detail else {
            return false
        }

        return true
    }

    private static func joinEffect(for state: SelectedConversationProjectionState) -> SelectedConversationEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        if state.interruptedConnectionAttemptContactID == contactID {
            if friendReadyJoinIsAuthoritative(state) {
                return .joinReadyFriend(contactID: contactID)
            }
            return .requestConnection(contactID: contactID)
        }

        switch (state.devicePTTContinuityProjection, state.selectedConversationState.phase) {
        case (.inactive, .idle), (.inactive, .outgoingBeep), (.inactive, .incomingBeep):
            return .requestConnection(contactID: contactID)
        case (.inactive, .friendReady):
            if friendReadyJoinIsAuthoritative(state) {
                return .joinReadyFriend(contactID: contactID)
            }
            return .requestConnection(contactID: contactID)
        case (.transitioning, _), (.connected, _), (.blockedByOtherSession, _), (.systemMismatch, _), (.localJoinFailed, _), (.pendingJoin, _), (.disconnecting, _), (.inactive, _):
            return nil
        }
    }

    private static func friendReadyJoinIsAuthoritative(_ state: SelectedConversationProjectionState) -> Bool {
        guard let channel = state.backendReadiness.channel else { return false }
        guard channel.membership.hasPeerMembership else { return false }
        return channel.beepThreadProjection == .none
    }

    private static func isInterruptibleConnectionAttempt(
        _ selectedConversationState: SelectedConversationState
    ) -> Bool {
        switch selectedConversationState.detail {
        case .waitingForPeer(reason: .pendingJoin),
             .waitingForPeer(reason: .backendConversationTransition),
             .waitingForPeer(reason: .devicePTTTransition),
             .waitingForPeer(reason: .friendReadyToConnect):
            return true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .wakeReady,
             .waitingForPeer, .localJoinFailed, .ready, .readyHoldToTalkDisabled,
             .startingTransmit, .transmitting, .receiving, .blockedByOtherSession,
             .systemMismatch:
            return false
        }
    }

    private static func shouldProjectInterruptedConnectionAttempt(
        _ state: SelectedConversationProjectionState
    ) -> Bool {
        guard let contactID = state.selection?.contactID else { return false }
        guard state.interruptedConnectionAttemptContactID == contactID else { return false }
        guard !state.isJoined, state.activeChannelID == nil else { return false }
        guard state.devicePTT.systemSessionState == .none else { return false }
        if case .restoreDevicePTTSession(contactID) = state.reconciliationAction {
            return false
        }
        if state.devicePTTRestoreDispatchInFlightContactID == contactID {
            return false
        }
        if shouldPreserveWakeCapableRecoveryAfterInterruptedConnectionAttempt(state) {
            return false
        }
        if state.pendingAction.pendingJoinContactID == contactID,
           state.backendReadiness.channel?.membership.hasPeerMembership == true,
           state.devicePTT.localJoinFailure?.contactID != contactID {
            return false
        }
        switch state.selectedConversationState.detail {
        case .waitingForPeer(reason: .pendingJoin),
             .waitingForPeer(reason: .backendConversationTransition),
             .waitingForPeer(reason: .devicePTTTransition),
             .waitingForPeer(reason: .friendReadyToConnect):
            return true
        case .localJoinFailed:
            return true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .wakeReady,
             .waitingForPeer, .ready, .readyHoldToTalkDisabled, .startingTransmit,
             .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func shouldPreserveWakeCapableRecoveryAfterInterruptedConnectionAttempt(
        _ state: SelectedConversationProjectionState
    ) -> Bool {
        guard state.hadConnectedDevicePTTContinuity else { return false }
        guard state.relationship == .none else { return false }
        guard state.pendingAction == .none else { return false }
        guard state.backendReadiness.channel?.membership.hasLocalMembership == true else { return false }
        guard case .wakeCapable = state.backendReadiness.channel?.remoteWakeCapability else { return false }
        guard let channelStatus = state.backendReadiness.channel?.status else { return false }

        switch channelStatus {
        case .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        case .idle, .outgoingBeep, .incomingBeep:
            return false
        }
    }

    private static func shouldArmSenderAutoJoinShortcut(
        state: SelectedConversationProjectionState,
        effect: SelectedConversationEffect
    ) -> Bool {
        guard state.senderAutoJoinOnBeepAcceptanceEnabled else { return false }
        guard case .requestConnection = effect else { return false }
        switch state.selectedConversationState.phase {
        case .idle, .outgoingBeep:
            return true
        case .incomingBeep, .friendReady, .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func shouldArmSenderAutoJoinForOutstandingOutgoingBeep(
        state: SelectedConversationProjectionState
    ) -> Bool {
        guard state.senderAutoJoinOnBeepAcceptanceEnabled else { return false }
        guard !state.senderAutoJoinOnBeepAcceptanceArmed else { return false }
        guard !state.senderAutoJoinOnBeepAcceptanceDispatchInFlight else { return false }
        guard state.relationship.hasOutgoingBeep else { return false }
        guard state.selection != nil else { return false }
        if state.interruptedConnectionAttemptContactID == state.selection?.contactID {
            return false
        }
        guard state.pendingAction.pendingConnectContactID == nil else { return false }
        guard state.pendingAction.pendingJoinContactID == nil else { return false }
        guard !state.pendingConnectAcceptedIncomingBeep else { return false }
        guard state.devicePTTContinuityProjection == .inactive else { return false }
        guard !state.isJoined, state.activeChannelID == nil else { return false }

        switch state.selectedConversationState.phase {
        case .idle, .outgoingBeep, .friendReady:
            return true
        case .incomingBeep, .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func autoJoinReadyFriendEffect(for state: SelectedConversationProjectionState) -> SelectedConversationEffect? {
        guard state.senderAutoJoinOnBeepAcceptanceEnabled else { return nil }
        if state.interruptedConnectionAttemptContactID == state.selection?.contactID {
            guard state.pendingAction.pendingConnectContactID == nil else { return nil }
            guard state.pendingAction.pendingJoinContactID == nil else { return nil }
            guard state.devicePTTContinuityProjection == .inactive else { return nil }
            guard state.selection?.contactID == state.selectedConversationState.contactID else { return nil }
            guard state.selectedConversationState.phase == .friendReady else { return nil }
            guard friendReadyJoinIsAuthoritative(state) else { return nil }
            guard let contactID = state.selection?.contactID else { return nil }
            return .joinReadyFriend(contactID: contactID)
        }
        guard state.senderAutoJoinOnBeepAcceptanceArmed else { return nil }
        guard state.pendingAction.pendingConnectContactID == nil else { return nil }
        guard state.pendingAction.pendingJoinContactID == nil else { return nil }
        guard state.devicePTTContinuityProjection == .inactive else { return nil }
        guard state.selection?.contactID == state.selectedConversationState.contactID else { return nil }
        guard state.selectedConversationState.phase == .friendReady else { return nil }
        guard friendReadyJoinIsAuthoritative(state) else { return nil }
        guard let contactID = state.selection?.contactID else { return nil }
        return .joinReadyFriend(contactID: contactID)
    }

    private static func shouldProjectSenderAutoJoinConnecting(
        state: SelectedConversationProjectionState
    ) -> Bool {
        guard state.senderAutoJoinOnBeepAcceptanceEnabled else { return false }
        guard state.senderAutoJoinOnBeepAcceptanceArmed
                || state.senderAutoJoinOnBeepAcceptanceDispatchInFlight else { return false }
        if state.interruptedConnectionAttemptContactID == state.selection?.contactID {
            return false
        }
        if state.senderAutoJoinOnBeepAcceptanceArmed {
            guard state.pendingAction.pendingConnectContactID == nil else { return false }
            guard state.pendingAction.pendingJoinContactID == nil else { return false }
        }
        guard state.devicePTTContinuityProjection == .inactive else { return false }

        switch state.selectedConversationState.detail {
        case .friendReady, .waitingForPeer(reason: .friendReadyToConnect):
            return true
        case .outgoingBeep, .incomingBeep, .waitingForPeer, .wakeReady, .localJoinFailed,
             .ready, .readyHoldToTalkDisabled, .startingTransmit, .transmitting,
             .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        case .idle:
            return false
        }
    }

    private static func disconnectEffect(for state: SelectedConversationProjectionState) -> SelectedConversationEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        if state.pendingAction.isLeaveInFlight(for: contactID) {
            return nil
        }

        let hasLocalOrSystemSession =
            state.isJoined
            || state.activeChannelID == contactID
            || state.devicePTT.systemSessionState != .none
            || state.pendingAction.pendingJoinContactID == contactID

        guard hasLocalOrSystemSession else { return nil }
        return .disconnect(contactID: contactID)
    }

    private static func reconciliationEffect(for state: SelectedConversationProjectionState) -> SelectedConversationEffect? {
        switch (state.devicePTTContinuityProjection, state.reconciliationAction) {
        case (_, .none):
            return nil
        case (.connected, .restoreDevicePTTSession), (.disconnecting, .restoreDevicePTTSession):
            return nil
        case (_, .restoreDevicePTTSession(let contactID)):
            if state.devicePTTRestoreDispatchInFlightContactID == contactID {
                return nil
            }
            return .restoreDevicePTTSession(contactID: contactID)
        case (_, .teardownDevicePTTSession(let contactID)):
            if state.pendingAction.isLeaveInFlight(for: contactID) {
                return nil
            }
            return .teardownDevicePTTSession(contactID: contactID)
        case (_, .clearStaleBackendMembership(let contactID)):
            if state.pendingAction.isLeaveInFlight(for: contactID) {
                return nil
            }
            return .clearStaleBackendMembership(contactID: contactID)
        }
    }
}

@MainActor
final class SelectedConversationCoordinator {
    private(set) var state: SelectedConversationProjectionState = .initial
    var effectHandler: (@MainActor (SelectedConversationEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?
    private var queuedEffectTask: Task<Void, Never>?

    func reset() {
        queuedEffectTask?.cancel()
        queuedEffectTask = nil
        state = .initial
    }

    func send(_ event: SelectedConversationEvent) {
        let previousState = state
        let transition = SelectedConversationReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        enqueueEffects(transition.effects)
    }

    func handle(_ event: SelectedConversationEvent) async {
        let previousState = state
        let transition = SelectedConversationReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        await runEffects(transition.effects)
    }

    private func reportTransition(
        previousState: SelectedConversationProjectionState,
        event: SelectedConversationEvent,
        transition: SelectedConversationTransition
    ) {
        guard transition.state != previousState || !transition.effects.isEmpty else {
            return
        }
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "selected-conversation-projection",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }

    private func enqueueEffects(_ effects: [SelectedConversationEffect]) {
        guard !effects.isEmpty else { return }
        let previousTask = queuedEffectTask
        queuedEffectTask = Task { @MainActor [effects] in
            _ = await previousTask?.value
            await self.runEffects(effects)
        }
    }

    private func runEffects(_ effects: [SelectedConversationEffect]) async {
        guard !effects.isEmpty else { return }
        for effect in effects {
            await effectHandler?(effect)
        }
    }
}

private extension SelectedConversationState {
    static let initial = SelectedConversationState(
        relationship: .none,
        phase: .idle,
        statusMessage: "Ready to connect",
        canTransmitNow: false
    )
}
