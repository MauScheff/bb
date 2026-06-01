import Foundation

enum BackendCommandOperation: Equatable {
    case openFriend(handle: String)
    case join(request: BackendJoinRequest)
    case leave(contactID: UUID)
}

enum BackendJoinIntent: Equatable {
    case requestConnection
    case joinReadyFriend
    case joinAcceptedOutgoingBeep
}

enum BackendJoinDeviceSessionProof: String, Equatable {
    case pttSystem = "ptt-system"
}

struct BackendJoinRequest: Equatable {
    let contactID: UUID
    let handle: String
    let intent: BackendJoinIntent
    let operationID: String?
    let joinOperationID: String?
    let relationship: BeepThreadProjection
    let existingRemoteUserID: String?
    let existingBackendChannelID: String?
    let incomingBeep: TurboBeepResponse?
    let outgoingBeep: TurboBeepResponse?
    let beepCooldownRemaining: Int?
    let usesLocalHTTPBackend: Bool
    let contactIsOnline: Bool
    let deviceSessionProof: BackendJoinDeviceSessionProof?

    init(
        contactID: UUID,
        handle: String,
        intent: BackendJoinIntent,
        operationID: String? = nil,
        joinOperationID: String? = nil,
        relationship: BeepThreadProjection,
        existingRemoteUserID: String?,
        existingBackendChannelID: String?,
        incomingBeep: TurboBeepResponse?,
        outgoingBeep: TurboBeepResponse?,
        beepCooldownRemaining: Int?,
        usesLocalHTTPBackend: Bool,
        contactIsOnline: Bool = true,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) {
        self.contactID = contactID
        self.handle = handle
        self.intent = intent
        self.operationID = operationID
        self.joinOperationID = joinOperationID
        self.relationship = relationship
        self.existingRemoteUserID = existingRemoteUserID
        self.existingBackendChannelID = existingBackendChannelID
        self.incomingBeep = incomingBeep
        self.outgoingBeep = outgoingBeep
        self.beepCooldownRemaining = beepCooldownRemaining
        self.usesLocalHTTPBackend = usesLocalHTTPBackend
        self.contactIsOnline = contactIsOnline
        self.deviceSessionProof = deviceSessionProof
    }

    static func == (lhs: BackendJoinRequest, rhs: BackendJoinRequest) -> Bool {
        lhs.contactID == rhs.contactID
            && lhs.handle == rhs.handle
            && lhs.intent == rhs.intent
            && lhs.relationship == rhs.relationship
            && lhs.existingRemoteUserID == rhs.existingRemoteUserID
            && lhs.existingBackendChannelID == rhs.existingBackendChannelID
            && lhs.incomingBeep == rhs.incomingBeep
            && lhs.outgoingBeep == rhs.outgoingBeep
            && lhs.beepCooldownRemaining == rhs.beepCooldownRemaining
            && lhs.usesLocalHTTPBackend == rhs.usesLocalHTTPBackend
            && lhs.contactIsOnline == rhs.contactIsOnline
            && lhs.deviceSessionProof == rhs.deviceSessionProof
    }
}

struct BackendLeaveRequest: Equatable {
    let contactID: UUID
    let backendChannelID: String
    let operationID: String?

    init(
        contactID: UUID,
        backendChannelID: String,
        operationID: String? = BackendCommandOperationID.make(prefix: "leave")
    ) {
        self.contactID = contactID
        self.backendChannelID = backendChannelID
        self.operationID = operationID
    }

    static func == (lhs: BackendLeaveRequest, rhs: BackendLeaveRequest) -> Bool {
        lhs.contactID == rhs.contactID
            && lhs.backendChannelID == rhs.backendChannelID
    }
}

enum BackendCommandOperationID {
    static func make(prefix: String) -> String {
        "\(prefix):\(UUID().uuidString.lowercased())"
    }
}

struct BackendCommandState: Equatable {
    var activeOperation: BackendCommandOperation?
    var queuedJoinRequest: BackendJoinRequest?
    var lastError: String?

    static let initial = BackendCommandState()
}

enum BackendCommandEvent: Equatable {
    case openFriendRequested(handle: String)
    case joinRequested(BackendJoinRequest)
    case leaveRequested(BackendLeaveRequest)
    case operationFinished
    case operationFailed(String)
    case reset
}

enum BackendCommandEffect: Equatable {
    case openFriend(handle: String)
    case join(BackendJoinRequest)
    case leave(BackendLeaveRequest)
}

struct BackendCommandTransition: Equatable {
    var state: BackendCommandState
    var effects: [BackendCommandEffect] = []
}

enum BackendCommandReducer {
    static func reduce(
        state: BackendCommandState,
        event: BackendCommandEvent
    ) -> BackendCommandTransition {
        var nextState = state
        var effects: [BackendCommandEffect] = []

        switch event {
        case .openFriendRequested(let handle):
            let operation = BackendCommandOperation.openFriend(handle: handle)
            guard nextState.activeOperation != operation else {
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.lastError = nil
            effects.append(.openFriend(handle: handle))

        case .joinRequested(let request):
            let operation = BackendCommandOperation.join(request: request)
            if case .join(let activeRequest) = nextState.activeOperation,
               activeRequest.contactID == request.contactID {
                if activeRequest == request || nextState.queuedJoinRequest == request {
                    return BackendCommandTransition(state: nextState)
                }
                if activeRequest.intent == .requestConnection,
                   request.intent == .requestConnection,
                   activeRequest.relationship == .none,
                   request.relationship.hasOutgoingBeep,
                   !request.relationship.hasIncomingBeep {
                    return BackendCommandTransition(state: nextState)
                }
                nextState.queuedJoinRequest = request
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.queuedJoinRequest = nil
            nextState.lastError = nil
            effects.append(.join(request))

        case .leaveRequested(let request):
            let operation = BackendCommandOperation.leave(contactID: request.contactID)
            guard nextState.activeOperation != operation else {
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.queuedJoinRequest = nil
            nextState.lastError = nil
            effects.append(.leave(request))

        case .operationFinished:
            if let queuedJoinRequest = nextState.queuedJoinRequest {
                nextState.activeOperation = .join(request: queuedJoinRequest)
                nextState.queuedJoinRequest = nil
                nextState.lastError = nil
                effects.append(.join(queuedJoinRequest))
            } else {
                nextState.activeOperation = nil
                nextState.lastError = nil
            }

        case .operationFailed(let message):
            if let queuedJoinRequest = nextState.queuedJoinRequest {
                nextState.activeOperation = .join(request: queuedJoinRequest)
                nextState.queuedJoinRequest = nil
                nextState.lastError = nil
                effects.append(.join(queuedJoinRequest))
            } else {
                nextState.activeOperation = nil
                nextState.lastError = message
            }

        case .reset:
            nextState = .initial
        }

        return BackendCommandTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class BackendCommandCoordinator {
    private(set) var state = BackendCommandState.initial
    var effectHandler: (@MainActor (BackendCommandEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: BackendCommandEvent) {
        let previousState = state
        let transition = BackendCommandReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
    }

    func handle(_ event: BackendCommandEvent) async {
        let previousState = state
        let transition = BackendCommandReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    private func reportTransition(
        previousState: BackendCommandState,
        event: BackendCommandEvent,
        transition: BackendCommandTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "backend-command",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
