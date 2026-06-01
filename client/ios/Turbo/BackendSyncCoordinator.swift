import Foundation

struct BackendContactSummaryUpdate: Equatable {
    let contactID: UUID
    let summary: TurboContactSummaryResponse
}

struct BackendBeepUpdate: Equatable {
    let contactID: UUID
    let beep: TurboBeepResponse
}

struct BackendSyncSessionState: Equatable {
    var syncState = BackendSyncState()
}

enum BackendSyncEvent: Equatable {
    case statusMessageUpdated(String)
    case bootstrapCompleted(mode: String, handle: String)
    case bootstrapFailed(String)
    case reset(statusMessage: String)
    case pollRequested(selectedContactID: UUID?)
    case webSocketStateChanged(TurboBackendClient.WebSocketConnectionState, selectedContactID: UUID?)
    case contactSummariesUpdated([BackendContactSummaryUpdate])
    case contactSummariesFailed(String)
    case channelStateUpdated(contactID: UUID, channelState: TurboChannelStateResponse)
    case channelReadinessUpdated(contactID: UUID, readiness: TurboChannelReadinessResponse)
    case channelStateCleared(contactID: UUID)
    case channelStateFailed(contactID: UUID, message: String)
    case clearAllChannelStates
    case beepsUpdated(incoming: [BackendBeepUpdate], outgoing: [BackendBeepUpdate], now: Date)
    case beepsPartiallyUpdated(incoming: [BackendBeepUpdate]?, outgoing: [BackendBeepUpdate]?, now: Date)
    case beepsFailed(String)
    case outgoingBeepSeeded(contactID: UUID, beep: TurboBeepResponse, now: Date)
    case incomingBeepHandled(contactID: UUID, beep: TurboBeepResponse?, requestCount: Int, now: Date)
}

enum BackendSyncEffect: Equatable {
    case bootstrapIfNeeded
    case ensureWebSocketConnected
    case heartbeatPresence
    case refreshContactSummaries
    case refreshBeeps
    case refreshChannelState(UUID)
    case refreshForegroundControlPlane(selectedContactID: UUID?)
}

struct BackendSyncTransition: Equatable {
    var state: BackendSyncSessionState
    var effects: [BackendSyncEffect] = []
}

enum BackendSyncReducer {
    static func reduce(
        state: BackendSyncSessionState,
        event: BackendSyncEvent
    ) -> BackendSyncTransition {
        var nextState = state
        var effects: [BackendSyncEffect] = []

        switch event {
        case .statusMessageUpdated(let message):
            nextState.syncState.statusMessage = message

        case .bootstrapCompleted(let mode, let handle):
            nextState.syncState.markBootstrapConnected(mode: mode, handle: handle)

        case .bootstrapFailed(let message):
            nextState.syncState.markBootstrapUnavailable(message: message)

        case .reset(let statusMessage):
            nextState.syncState.reset(statusMessage: statusMessage)

        case .pollRequested(let selectedContactID):
            if nextState.syncState.hasEstablishedConnection {
                effects = [
                    .ensureWebSocketConnected,
                    .heartbeatPresence,
                    .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                ]
            } else {
                effects = [.bootstrapIfNeeded]
            }

        case .webSocketStateChanged(let state, let selectedContactID):
            switch state {
            case .idle:
                nextState.syncState.invalidateRemoteReceiverReadinessAfterWebSocketIdle()
                if nextState.syncState.hasEstablishedConnection {
                    effects.append(contentsOf: [
                        .ensureWebSocketConnected,
                        .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                    ])
                }
            case .connecting:
                break
            case .connected:
                effects.append(contentsOf: [
                    .heartbeatPresence,
                    .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                ])
            }

        case .contactSummariesUpdated(let updates):
            let summaries = Dictionary(uniqueKeysWithValues: updates.map { ($0.contactID, $0.summary) })
            nextState.syncState.applyContactSummaries(summaries)

        case .contactSummariesFailed(let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .channelStateUpdated(let contactID, let channelState):
            nextState.syncState.applyChannelState(channelState, for: contactID)

        case .channelReadinessUpdated(let contactID, let readiness):
            nextState.syncState.applyChannelReadiness(readiness, for: contactID)

        case .channelStateCleared(let contactID):
            nextState.syncState.clearChannelState(for: contactID)

        case .channelStateFailed(_, let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .clearAllChannelStates:
            nextState.syncState.channelStates = [:]
            nextState.syncState.channelReadiness = [:]

        case .beepsUpdated(let incoming, let outgoing, let now):
            let incomingMap = Dictionary(uniqueKeysWithValues: incoming.map { ($0.contactID, $0.beep) })
            let outgoingMap = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.contactID, $0.beep) })
            nextState.syncState.applyBeeps(incoming: incomingMap, outgoing: outgoingMap, now: now)

        case .beepsPartiallyUpdated(let incoming, let outgoing, let now):
            let incomingMap = incoming.map {
                Dictionary(uniqueKeysWithValues: $0.map { ($0.contactID, $0.beep) })
            }
            let outgoingMap = outgoing.map {
                Dictionary(uniqueKeysWithValues: $0.map { ($0.contactID, $0.beep) })
            }
            nextState.syncState.applyPartialBeeps(incoming: incomingMap, outgoing: outgoingMap, now: now)

        case .beepsFailed(let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .outgoingBeepSeeded(let contactID, let beep, let now):
            nextState.syncState.outgoingBeeps[contactID] = beep
            nextState.syncState.beepCooldownDeadlines[contactID] = now.addingTimeInterval(30)
            nextState.syncState.beepCooldownSourceKeys[contactID] =
                BackendSyncState.beepCooldownSourceKey(for: beep)

        case .incomingBeepHandled(let contactID, let beep, let requestCount, _):
            nextState.syncState.markIncomingBeepHandled(
                contactID: contactID,
                beep: beep,
                requestCount: requestCount
            )
        }

        return BackendSyncTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class BackendSyncCoordinator {
    private(set) var state = BackendSyncSessionState()
    var effectHandler: (@MainActor (BackendSyncEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: BackendSyncEvent) {
        let previousState = state
        let transition = BackendSyncReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
    }

    func handle(_ event: BackendSyncEvent) async {
        let previousState = state
        let transition = BackendSyncReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    private func reportTransition(
        previousState: BackendSyncSessionState,
        event: BackendSyncEvent,
        transition: BackendSyncTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "backend-sync",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
