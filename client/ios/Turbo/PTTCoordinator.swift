import Foundation

enum PTTJoinFailureReason: Equatable {
    case channelLimitReached
    case other(message: String)

    var message: String {
        switch self {
        case .channelLimitReached:
            return "Channel limit reached"
        case .other(let message):
            return message
        }
    }

    var recoveryMessage: String {
        switch self {
        case .channelLimitReached:
            return "Reconnect failed. End conversation and retry."
        case .other(let message):
            return "Join failed: \(message)"
        }
    }

    var blocksAutomaticRestore: Bool {
        switch self {
        case .channelLimitReached:
            return true
        case .other:
            return false
        }
    }
}

struct PTTJoinFailure: Equatable {
    let contactID: UUID?
    let channelUUID: UUID
    let reason: PTTJoinFailureReason
}

enum PTTTransmissionState: Equatable {
    case idle
    case transmitting
}

enum SystemTransmitBeginOrigin: String, Equatable {
    case foregroundAppPress = "foreground-app-press"
    case foregroundSystemCallbackWithoutLocalIntent = "foreground-system-callback-without-local-intent"
    case backgroundAppPress = "background-app-press"
    case backgroundWakeHandoff = "background-wake-handoff"

    static func classify(
        applicationIsActive: Bool,
        hadPendingSystemBegin: Bool,
        hasCallbackTarget: Bool,
        hasPendingLifecycle: Bool,
        runtimeIsPressingTalk: Bool,
        coordinatorIsPressingTalk: Bool,
        hasPendingBeginOrActiveTransmit: Bool
    ) -> SystemTransmitBeginOrigin {
        let hasLocalTransmitIntent =
            hadPendingSystemBegin
            || hasCallbackTarget
            || hasPendingLifecycle
            || runtimeIsPressingTalk
            || coordinatorIsPressingTalk
            || hasPendingBeginOrActiveTransmit

        if applicationIsActive {
            return hasLocalTransmitIntent
                ? .foregroundAppPress
                : .foregroundSystemCallbackWithoutLocalIntent
        }

        return hasLocalTransmitIntent
            ? .backgroundAppPress
            : .backgroundWakeHandoff
    }

    var isSystemOriginated: Bool {
        switch self {
        case .foregroundSystemCallbackWithoutLocalIntent, .backgroundWakeHandoff:
            return true
        case .foregroundAppPress, .backgroundAppPress:
            return false
        }
    }

    var isRejectedForegroundUnownedBegin: Bool {
        self == .foregroundSystemCallbackWithoutLocalIntent
    }
}

enum SystemTransmitEndOrigin: Equatable {
    case systemCallback(source: String)
    case explicitStopReconciliation(source: String)

    var source: String {
        switch self {
        case .systemCallback(let source), .explicitStopReconciliation(let source):
            return source
        }
    }

    var kind: String {
        switch self {
        case .systemCallback:
            return "system-callback"
        case .explicitStopReconciliation:
            return "explicit-stop-reconciliation"
        }
    }

    var requiresActiveTransmission: Bool {
        switch self {
        case .systemCallback:
            return false
        case .explicitStopReconciliation:
            return true
        }
    }
}

enum PTTSystemSession: Equatable {
    case none
    case joined(channelUUID: UUID, contactID: UUID?, transmission: PTTTransmissionState)

    var channelUUID: UUID? {
        guard case .joined(let channelUUID, _, _) = self else { return nil }
        return channelUUID
    }

    var contactID: UUID? {
        guard case .joined(_, let contactID, _) = self else { return nil }
        return contactID
    }

    var isJoined: Bool {
        guard case .joined = self else { return false }
        return true
    }

    var isTransmitting: Bool {
        guard case .joined(_, _, .transmitting) = self else { return false }
        return true
    }

    var systemSessionState: SystemPTTSessionState {
        switch self {
        case .none:
            return .none
        case .joined(let channelUUID, nil, _):
            return .mismatched(channelUUID: channelUUID)
        case .joined(let channelUUID, let contactID?, _):
            return .active(contactID: contactID, channelUUID: channelUUID)
        }
    }

    func updatingTransmission(
        for channelUUID: UUID,
        to transmission: PTTTransmissionState
    ) -> PTTSystemSession {
        guard case .joined(channelUUID, let contactID, _) = self else { return self }
        return .joined(channelUUID: channelUUID, contactID: contactID, transmission: transmission)
    }
}

struct PTTSessionState: Equatable {
    private var systemSession: PTTSystemSession
    var lastError: String?
    var lastJoinFailure: PTTJoinFailure?

    static let initial = PTTSessionState()

    init(
        systemSession: PTTSystemSession = .none,
        lastError: String? = nil,
        lastJoinFailure: PTTJoinFailure? = nil
    ) {
        self.systemSession = systemSession
        self.lastError = lastError
        self.lastJoinFailure = lastJoinFailure
    }

    init(
        systemChannelUUID: UUID? = nil,
        activeContactID: UUID? = nil,
        isJoined: Bool = false,
        isTransmitting: Bool = false,
        lastError: String? = nil,
        lastJoinFailure: PTTJoinFailure? = nil
    ) {
        if let systemChannelUUID, isJoined || isTransmitting {
            systemSession = .joined(
                channelUUID: systemChannelUUID,
                contactID: activeContactID,
                transmission: isTransmitting ? .transmitting : .idle
            )
        } else {
            systemSession = .none
        }
        self.lastError = lastError
        self.lastJoinFailure = lastJoinFailure
    }

    var systemChannelUUID: UUID? { systemSession.channelUUID }
    var activeContactID: UUID? { systemSession.contactID }
    var isJoined: Bool { systemSession.isJoined }
    var isTransmitting: Bool { systemSession.isTransmitting }

    var systemSessionState: SystemPTTSessionState {
        systemSession.systemSessionState
    }

    fileprivate mutating func replaceSystemSession(_ systemSession: PTTSystemSession) {
        self.systemSession = systemSession
    }

    fileprivate mutating func clearSystemSession() {
        systemSession = .none
    }

    fileprivate mutating func updateTransmission(
        for channelUUID: UUID,
        to transmission: PTTTransmissionState
    ) {
        systemSession = systemSession.updatingTransmission(for: channelUUID, to: transmission)
    }
}

enum PTTEvent: Equatable {
    case restoredChannel(channelUUID: UUID, contactID: UUID?)
    case didJoinChannel(channelUUID: UUID, contactID: UUID?, reason: String)
    case didLeaveChannel(
        channelUUID: UUID,
        contactID: UUID?,
        reason: String,
        autoRejoinContactID: UUID?,
        shouldPropagateBackendLeave: Bool
    )
    case failedToJoinChannel(channelUUID: UUID, contactID: UUID?, reason: PTTJoinFailureReason)
    case failedToLeaveChannel(channelUUID: UUID, message: String)
    case didBeginTransmitting(channelUUID: UUID, origin: SystemTransmitBeginOrigin)
    case didEndTransmitting(channelUUID: UUID, origin: SystemTransmitEndOrigin)
    case failedToBeginTransmitting(channelUUID: UUID, message: String)
    case failedToStopTransmitting(channelUUID: UUID, message: String)
    case reset
}

enum PTTEffect: Equatable {
    case syncJoinedChannel(contactID: UUID?)
    case syncLeftChannel(
        contactID: UUID?,
        autoRejoinContactID: UUID?,
        shouldPropagateBackendLeave: Bool
    )
    case closeMediaSession
    case handleSystemTransmitFailure(String)
}

struct PTTTransition: Equatable {
    var state: PTTSessionState
    var effects: [PTTEffect] = []
}

enum PTTReducer {
    static func reduce(
        state: PTTSessionState,
        event: PTTEvent
    ) -> PTTTransition {
        var nextState = state
        var effects: [PTTEffect] = []

        switch event {
        case .restoredChannel(let channelUUID, let contactID):
            nextState.replaceSystemSession(
                .joined(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    transmission: .idle
                )
            )
            nextState.lastError = nil
            nextState.lastJoinFailure = nil

        case .didJoinChannel(let channelUUID, let contactID, _):
            nextState.replaceSystemSession(
                .joined(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    transmission: .idle
                )
            )
            nextState.lastError = nil
            nextState.lastJoinFailure = nil
            effects.append(.syncJoinedChannel(contactID: contactID))

        case .didLeaveChannel(
            let channelUUID,
            let contactID,
            _,
            let autoRejoinContactID,
            let shouldPropagateBackendLeave
        ):
            if nextState.systemChannelUUID == channelUUID {
                nextState.clearSystemSession()
            }
            nextState.lastError = nil
            nextState.lastJoinFailure = nil
            effects.append(
                .syncLeftChannel(
                    contactID: contactID,
                    autoRejoinContactID: autoRejoinContactID,
                    shouldPropagateBackendLeave: shouldPropagateBackendLeave
                )
            )

        case .failedToJoinChannel(let channelUUID, let contactID, let reason):
            let failureAppliesToCurrentSession =
                nextState.systemChannelUUID == nil || nextState.systemChannelUUID == channelUUID
            if failureAppliesToCurrentSession {
                nextState.clearSystemSession()
            }
            nextState.lastError = reason.message
            nextState.lastJoinFailure = PTTJoinFailure(contactID: contactID, channelUUID: channelUUID, reason: reason)
            if failureAppliesToCurrentSession {
                effects.append(.closeMediaSession)
            }

        case .failedToLeaveChannel(_, let message):
            nextState.lastError = message

        case .didBeginTransmitting(let channelUUID, _):
            if nextState.systemChannelUUID == channelUUID {
                nextState.updateTransmission(
                    for: channelUUID,
                    to: .transmitting
                )
                nextState.lastError = nil
            }

        case .didEndTransmitting(let channelUUID, let origin):
            guard nextState.systemChannelUUID == channelUUID else { break }
            guard !origin.requiresActiveTransmission || nextState.isTransmitting else { break }
            nextState.updateTransmission(
                for: channelUUID,
                to: .idle
            )

        case .failedToBeginTransmitting(let channelUUID, let message):
            if nextState.systemChannelUUID == channelUUID {
                nextState.updateTransmission(
                    for: channelUUID,
                    to: .idle
                )
                nextState.lastError = message
                effects.append(.handleSystemTransmitFailure(message))
            }

        case .failedToStopTransmitting(let channelUUID, let message):
            if nextState.systemChannelUUID == channelUUID {
                nextState.lastError = message
            }

        case .reset:
            nextState = .initial
        }

        return PTTTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class PTTCoordinator {
    private(set) var state: PTTSessionState = .initial
    var effectHandler: (@MainActor (PTTEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: PTTEvent) {
        let previousState = state
        let transition = PTTReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
    }

    func handle(
        _ event: PTTEvent,
        afterStateUpdate: (() -> Void)? = nil
    ) async {
        let previousState = state
        let transition = PTTReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        afterStateUpdate?()
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func reset() {
        state = .initial
    }

    private func reportTransition(
        previousState: PTTSessionState,
        event: PTTEvent,
        transition: PTTTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "ptt-session",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
