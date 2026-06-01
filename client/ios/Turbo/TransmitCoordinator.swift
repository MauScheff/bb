import Foundation

struct TransmitRequestContext: Equatable, Sendable {
    let contactID: UUID
    let contactHandle: String
    let backendChannelID: String
    let remoteUserID: String
    let channelUUID: UUID?
    let usesLocalHTTPBackend: Bool
    let backendSupportsWebSocket: Bool
    let requiresAuthoritativeBackendJoinRefresh: Bool

    init(
        contactID: UUID,
        contactHandle: String,
        backendChannelID: String,
        remoteUserID: String,
        channelUUID: UUID?,
        usesLocalHTTPBackend: Bool,
        backendSupportsWebSocket: Bool,
        requiresAuthoritativeBackendJoinRefresh: Bool = false
    ) {
        self.contactID = contactID
        self.contactHandle = contactHandle
        self.backendChannelID = backendChannelID
        self.remoteUserID = remoteUserID
        self.channelUUID = channelUUID
        self.usesLocalHTTPBackend = usesLocalHTTPBackend
        self.backendSupportsWebSocket = backendSupportsWebSocket
        self.requiresAuthoritativeBackendJoinRefresh = requiresAuthoritativeBackendJoinRefresh
    }
}

nonisolated struct TransmitTarget: Equatable, Sendable {
    let contactID: UUID
    let userID: String
    let deviceID: String
    let channelID: String
    let transmitID: String?

    init(
        contactID: UUID,
        userID: String,
        deviceID: String,
        channelID: String,
        transmitID: String? = nil
    ) {
        self.contactID = contactID
        self.userID = userID
        self.deviceID = deviceID
        self.channelID = channelID
        self.transmitID = transmitID
    }
}

enum TransmitPhase: Equatable {
    case idle
    case requesting(contactID: UUID)
    case active(contactID: UUID)
    case stopping(contactID: UUID)
}

struct TransmitSessionState: Equatable {
    var phase: TransmitPhase = .idle
    var isPressingTalk: Bool = false
    var pendingRequest: TransmitRequestContext?
    var activeTarget: TransmitTarget?
    var lastError: String?

    static let initial = TransmitSessionState()
}

enum TransmitEvent: Equatable {
    case pressRequested(TransmitRequestContext)
    case systemPressRequested(TransmitRequestContext)
    case beginSucceeded(TransmitTarget, TransmitRequestContext)
    case beginFailed(String)
    case releaseRequested
    case systemEnded
    case stopCompleted(TransmitTarget)
    case stopFailed(TransmitTarget?, String)
    case renewalFailed(String)
    case websocketDisconnected
    case systemBeginFailed(String)
}

enum TransmitEffect: Equatable {
    case beginTransmit(TransmitRequestContext)
    case activateTransmit(TransmitRequestContext, TransmitTarget)
    case stopTransmit(TransmitTarget)
    case abortTransmit(TransmitTarget)
}

struct TransmitTransition: Equatable {
    var state: TransmitSessionState
    var effects: [TransmitEffect] = []
    var invariantViolationsEmitted: [String] = []
}

enum TransmitReducer {
    static func reduce(
        state: TransmitSessionState,
        event: TransmitEvent
    ) -> TransmitTransition {
        var nextState = state
        var effects: [TransmitEffect] = []
        var invariantViolationsEmitted: [String] = []

        switch event {
        case .pressRequested(let request):
            guard canBegin(from: nextState, request: request) else {
                return TransmitTransition(state: nextState)
            }
            nextState.phase = .requesting(contactID: request.contactID)
            nextState.isPressingTalk = true
            nextState.pendingRequest = request
            nextState.lastError = nil
            effects.append(.beginTransmit(request))

        case .systemPressRequested(let request):
            guard canBegin(from: nextState, request: request) else {
                return TransmitTransition(state: nextState)
            }
            nextState.phase = .requesting(contactID: request.contactID)
            nextState.isPressingTalk = true
            nextState.pendingRequest = request
            nextState.lastError = nil
            effects.append(.beginTransmit(request))

        case .beginSucceeded(let target, let request):
            guard nextState.pendingRequest == request else {
                return TransmitTransition(state: nextState)
            }
            nextState.pendingRequest = nil
            nextState.activeTarget = target
            if nextState.isPressingTalk {
                nextState.phase = .active(contactID: request.contactID)
                effects.append(.activateTransmit(request, target))
            } else {
                nextState.phase = .stopping(contactID: request.contactID)
                effects.append(.stopTransmit(target))
            }

        case .beginFailed(let message):
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil
            nextState.lastError = message

        case .releaseRequested:
            nextState.isPressingTalk = false
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            } else if case .requesting = nextState.phase {
                nextState.phase = .idle
                nextState.pendingRequest = nil
            }

        case .systemEnded:
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            switch nextState.phase {
            case .active:
                if let activeTarget = nextState.activeTarget {
                    nextState.phase = .stopping(contactID: activeTarget.contactID)
                    effects.append(.stopTransmit(activeTarget))
                } else {
                    nextState.phase = .idle
                }
            case .requesting:
                nextState.phase = .idle
                nextState.activeTarget = nil
            case .stopping, .idle:
                break
            }

        case .renewalFailed(let message):
            nextState.lastError = message
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .systemBeginFailed(let message):
            nextState.lastError = message
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .idle
                nextState.activeTarget = nil
                effects.append(.abortTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .websocketDisconnected:
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .stopCompleted(let target):
            guard stopCompletionMatchesCurrentTarget(state: nextState, target: target) else {
                invariantViolationsEmitted.append("transmit.stale_end_overrides_newer_epoch")
                return TransmitTransition(
                    state: nextState,
                    effects: effects,
                    invariantViolationsEmitted: invariantViolationsEmitted
                )
            }
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil

        case .stopFailed(let target, let message):
            if let target,
               !stopCompletionMatchesCurrentTarget(state: nextState, target: target) {
                invariantViolationsEmitted.append("transmit.stale_end_overrides_newer_epoch")
                return TransmitTransition(
                    state: nextState,
                    effects: effects,
                    invariantViolationsEmitted: invariantViolationsEmitted
                )
            }
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil
            nextState.lastError = message
        }

        return TransmitTransition(
            state: nextState,
            effects: effects,
            invariantViolationsEmitted: invariantViolationsEmitted
        )
    }

    private static func canBegin(from state: TransmitSessionState, request: TransmitRequestContext) -> Bool {
        switch state.phase {
        case .idle:
            return true
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == request.contactID ? false : false
        }
    }

    private static func stopCompletionMatchesCurrentTarget(
        state: TransmitSessionState,
        target: TransmitTarget
    ) -> Bool {
        guard let activeTarget = state.activeTarget else { return true }
        return activeTarget == target
    }
}

@MainActor
final class TransmitCoordinator {
    private(set) var state: TransmitSessionState = .initial
    var effectHandler: (@MainActor (TransmitEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func handle(_ event: TransmitEvent) async {
        let previousState = state
        let transition = TransmitReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func reset() {
        state = .initial
    }

    private func reportTransition(
        previousState: TransmitSessionState,
        event: TransmitEvent,
        transition: TransmitTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "transmit",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects,
                invariantViolationsEmitted: transition.invariantViolationsEmitted
            )
        )
    }
}
