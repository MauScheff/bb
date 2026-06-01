import Foundation

enum TransmitPressState: Equatable {
    case idle
    case pressing
    case releaseRequired(interruptedContactID: UUID?)

    var isPressingTalk: Bool {
        guard case .pressing = self else { return false }
        return true
    }

    var requiresReleaseBeforeNextPress: Bool {
        guard case .releaseRequired = self else { return false }
        return true
    }

    var interruptedContactID: UUID? {
        guard case .releaseRequired(let interruptedContactID) = self else { return nil }
        return interruptedContactID
    }
}

enum TransmitStopIntentState: Equatable {
    case none
    case explicitStopRequested

    var explicitStopRequested: Bool {
        self == .explicitStopRequested
    }
}

enum SystemTransmitExecutionState: Equatable {
    case idle
    case beginPending(channelUUID: UUID)
    case transmitting(startedAt: Date)

    var pendingSystemBeginChannelUUID: UUID? {
        guard case .beginPending(let channelUUID) = self else { return nil }
        return channelUUID
    }

    var lastSystemTransmitBeganAt: Date? {
        guard case .transmitting(let startedAt) = self else { return nil }
        return startedAt
    }

    var hasLifecycle: Bool {
        self != .idle
    }

    var isTransmitting: Bool {
        guard case .transmitting = self else { return false }
        return true
    }
}

enum SystemTransmitActivationExecutionState: Equatable {
    case idle
    case activating(channelUUID: UUID)
    case activated(channelUUID: UUID)

    var channelUUID: UUID? {
        switch self {
        case .idle:
            return nil
        case .activating(let channelUUID), .activated(let channelUUID):
            return channelUUID
        }
    }
}

enum SystemTransmitEndDisposition: Equatable {
    case none
    case implicitRelease
    case requireFreshPress(contactID: UUID?)
}

enum InitialOutboundAudioSendGateState: Equatable {
    case idle
    case awaitingFirstSend
    case consumed

    var shouldAwaitInitialRemoteReady: Bool {
        self == .awaitingFirstSend
    }
}

enum TransmitAudioCaptureStartIntent: Equatable {
    case initial
    case systemActivationRefresh
}

enum TransmitAudioCaptureStartState: Equatable {
    case idle
    case starting(channelUUID: UUID)
    case started(channelUUID: UUID)
    case refreshing(channelUUID: UUID)
    case refreshed(channelUUID: UUID)

    var channelUUID: UUID? {
        switch self {
        case .idle:
            return nil
        case .starting(let channelUUID),
             .started(let channelUUID),
             .refreshing(let channelUUID),
             .refreshed(let channelUUID):
            return channelUUID
        }
    }
}

enum TransmitAudioCaptureStartDecision: Equatable {
    case begin
    case waitForInFlight
    case alreadyCompleted
}

enum TransmitAudioCaptureStartReservation: Equatable {
    case reserved
    case alreadyCompleted
    case cancelled
}

struct TransmitExecutionSessionState: Equatable {
    var latchedTarget: TransmitTarget?
    var pressState: TransmitPressState = .idle
    var stopIntent: TransmitStopIntentState = .none
    var systemTransmitState: SystemTransmitExecutionState = .idle
    var systemTransmitActivationState: SystemTransmitActivationExecutionState = .idle
    var initialOutboundAudioSendGateState: InitialOutboundAudioSendGateState = .idle
    var audioCaptureStartState: TransmitAudioCaptureStartState = .idle

    static let initial = TransmitExecutionSessionState()

    var activeTarget: TransmitTarget? { latchedTarget }
    var isPressingTalk: Bool { pressState.isPressingTalk }
    var explicitStopRequested: Bool { stopIntent.explicitStopRequested }
    var requiresReleaseBeforeNextPress: Bool { pressState.requiresReleaseBeforeNextPress }
    var interruptedContactID: UUID? { pressState.interruptedContactID }
    var pendingSystemBeginChannelUUID: UUID? { systemTransmitState.pendingSystemBeginChannelUUID }
    var lastSystemTransmitBeganAt: Date? { systemTransmitState.lastSystemTransmitBeganAt }
    var hasSystemTransmitLifecycle: Bool { systemTransmitState.hasLifecycle }
    var isSystemTransmitting: Bool { systemTransmitState.isTransmitting }
}

enum TransmitExecutionEvent: Equatable {
    case syncActiveTarget(TransmitTarget?)
    case markPressBegan
    case markPressEnded
    case markExplicitStopRequested
    case consumeInitialOutboundAudioSendGate
    case markUnexpectedSystemEndRequiresRelease(contactID: UUID?)
    case noteSystemTransmitBegan(Date)
    case noteSystemTransmitEnded
    case noteSystemTransmitBeginRequested(channelUUID: UUID)
    case clearPendingSystemTransmitBegin(channelUUID: UUID?)
    case beginSystemTransmitActivation(channelUUID: UUID)
    case markSystemTransmitActivationCompleted(channelUUID: UUID)
    case clearSystemTransmitActivation(channelUUID: UUID?)
    case noteTouchReleased
    case reconcileIdleState
    case reset
    case handleSystemTransmitEnded(applicationStateIsActive: Bool, matchingActiveTarget: TransmitTarget?)
}

enum TransmitExecutionEffect: Equatable {
    case handledSystemTransmitEnded(SystemTransmitEndDisposition)
}

struct TransmitExecutionTransition: Equatable {
    var state: TransmitExecutionSessionState
    var effects: [TransmitExecutionEffect] = []
}

enum TransmitExecutionReducer {
    static func reduce(
        state: TransmitExecutionSessionState,
        event: TransmitExecutionEvent
    ) -> TransmitExecutionTransition {
        var nextState = state
        var effects: [TransmitExecutionEffect] = []

        switch event {
        case .syncActiveTarget(let activeTarget):
            syncLatchedTarget(&nextState, activeTarget)

        case .markPressBegan:
            guard !nextState.requiresReleaseBeforeNextPress else { break }
            nextState.pressState = .pressing
            nextState.stopIntent = .none
            nextState.initialOutboundAudioSendGateState = .awaitingFirstSend

        case .markPressEnded:
            guard case .pressing = nextState.pressState else { break }
            nextState.pressState = .idle

        case .markExplicitStopRequested:
            nextState.stopIntent = .explicitStopRequested

        case .consumeInitialOutboundAudioSendGate:
            guard nextState.initialOutboundAudioSendGateState.shouldAwaitInitialRemoteReady else { break }
            nextState.initialOutboundAudioSendGateState = .consumed

        case .markUnexpectedSystemEndRequiresRelease(let contactID):
            nextState.pressState = .releaseRequired(interruptedContactID: contactID)

        case .noteSystemTransmitBegan(let beganAt):
            nextState.systemTransmitState = .transmitting(startedAt: beganAt)
            nextState.systemTransmitActivationState = .idle

        case .noteSystemTransmitEnded:
            nextState.systemTransmitState = .idle
            nextState.systemTransmitActivationState = .idle

        case .noteSystemTransmitBeginRequested(let channelUUID):
            nextState.systemTransmitState = .beginPending(channelUUID: channelUUID)
            nextState.systemTransmitActivationState = .idle

        case .clearPendingSystemTransmitBegin(let channelUUID):
            guard case .beginPending(let pendingChannelUUID) = nextState.systemTransmitState else { break }
            guard channelUUID == nil || pendingChannelUUID == channelUUID else { break }
            nextState.systemTransmitState = .idle

        case .beginSystemTransmitActivation(let channelUUID):
            nextState.systemTransmitActivationState = .activating(channelUUID: channelUUID)

        case .markSystemTransmitActivationCompleted(let channelUUID):
            guard nextState.systemTransmitActivationState.channelUUID == channelUUID else { break }
            nextState.systemTransmitActivationState = .activated(channelUUID: channelUUID)

        case .clearSystemTransmitActivation(let channelUUID):
            guard channelUUID == nil || nextState.systemTransmitActivationState.channelUUID == channelUUID else { break }
            nextState.systemTransmitActivationState = .idle

        case .noteTouchReleased:
            guard nextState.requiresReleaseBeforeNextPress else { break }
            nextState.pressState = .idle

        case .reconcileIdleState:
            nextState.systemTransmitState = .idle
            nextState.systemTransmitActivationState = .idle
            nextState.initialOutboundAudioSendGateState = .idle
            if case .pressing = nextState.pressState {
                nextState.pressState = .idle
            }
            nextState.latchedTarget = nil

        case .reset:
            nextState = .initial

        case .handleSystemTransmitEnded(let applicationStateIsActive, let matchingActiveTarget):
            guard nextState.hasSystemTransmitLifecycle else { break }
            let disposition: SystemTransmitEndDisposition
            if !applicationStateIsActive,
               !nextState.explicitStopRequested,
               matchingActiveTarget != nil,
               nextState.isPressingTalk {
                nextState.pressState = .idle
                syncLatchedTarget(&nextState, matchingActiveTarget)
                disposition = .implicitRelease
            } else if !nextState.explicitStopRequested,
                      matchingActiveTarget != nil,
                      nextState.isPressingTalk {
                nextState.pressState = .releaseRequired(
                    interruptedContactID: matchingActiveTarget?.contactID
                )
                syncLatchedTarget(&nextState, matchingActiveTarget)
                disposition = .requireFreshPress(contactID: matchingActiveTarget?.contactID)
            } else {
                disposition = .none
            }
            nextState.systemTransmitState = .idle
            nextState.systemTransmitActivationState = .idle
            effects.append(.handledSystemTransmitEnded(disposition))
        }

        return TransmitExecutionTransition(state: nextState, effects: effects)
    }

    private static func syncLatchedTarget(
        _ state: inout TransmitExecutionSessionState,
        _ activeTarget: TransmitTarget?
    ) {
        if let activeTarget {
            state.latchedTarget = activeTarget
        } else if !state.isPressingTalk {
            state.latchedTarget = nil
        }
    }
}
