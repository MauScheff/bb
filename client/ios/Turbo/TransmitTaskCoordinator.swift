import Foundation

enum BeginTransmitTaskState: Equatable {
    case idle
    case running(id: Int, request: TransmitRequestContext)

    var id: Int? {
        guard case .running(let id, _) = self else { return nil }
        return id
    }

    var request: TransmitRequestContext? {
        guard case .running(_, let request) = self else { return nil }
        return request
    }
}

enum LeaseRenewalTaskState: Equatable {
    case idle
    case running(id: Int, target: TransmitTarget)

    var id: Int? {
        guard case .running(let id, _) = self else { return nil }
        return id
    }

    var target: TransmitTarget? {
        guard case .running(_, let target) = self else { return nil }
        return target
    }

    var channelID: String? {
        target?.channelID
    }
}

struct TransmitTaskSessionState: Equatable {
    var begin: BeginTransmitTaskState = .idle
    var renewal: LeaseRenewalTaskState = .idle
    var nextWorkID: Int = 1

    var hasPendingBeginWork: Bool {
        begin.request != nil
    }

    func hasPendingBeginOrActiveTarget(activeTarget: TransmitTarget?) -> Bool {
        hasPendingBeginWork || activeTarget != nil
    }
}

enum TransmitTaskEvent: Equatable {
    case reset
    case cancelBegin
    case beginRequested(TransmitRequestContext)
    case beginFinished(id: Int)
    case renewalRequested(TransmitTarget)
    case renewalFinished(id: Int)
    case renewalCancelled
}

enum TransmitTaskEffect: Equatable {
    case cancelBegin
    case startBegin(id: Int, request: TransmitRequestContext)
    case cancelRenewal
    case startRenewal(id: Int, target: TransmitTarget)
}

struct TransmitTaskTransition: Equatable {
    var state: TransmitTaskSessionState
    var effects: [TransmitTaskEffect] = []
}

enum TransmitTaskReducer {
    static func reduce(
        state: TransmitTaskSessionState,
        event: TransmitTaskEvent
    ) -> TransmitTaskTransition {
        var nextState = state
        var effects: [TransmitTaskEffect] = []

        switch event {
        case .reset:
            if nextState.begin.request != nil {
                effects.append(.cancelBegin)
            }
            if nextState.renewal.target != nil {
                effects.append(.cancelRenewal)
            }
            nextState = TransmitTaskSessionState()

        case .cancelBegin:
            guard nextState.begin.request != nil else { break }
            nextState.begin = .idle
            effects.append(.cancelBegin)

        case .beginRequested(let request):
            if nextState.begin.request == request {
                break
            }
            if nextState.begin.request != nil {
                effects.append(.cancelBegin)
            }
            let workID = nextState.nextWorkID
            nextState.nextWorkID += 1
            nextState.begin = .running(id: workID, request: request)
            effects.append(.startBegin(id: workID, request: request))

        case .beginFinished(let id):
            guard nextState.begin.id == id else { break }
            nextState.begin = .idle

        case .renewalRequested(let target):
            if nextState.renewal.target == target {
                break
            }
            if nextState.renewal.target != nil {
                effects.append(.cancelRenewal)
            }
            let workID = nextState.nextWorkID
            nextState.nextWorkID += 1
            nextState.renewal = .running(id: workID, target: target)
            effects.append(.startRenewal(id: workID, target: target))

        case .renewalFinished(let id):
            guard nextState.renewal.id == id else { break }
            nextState.renewal = .idle

        case .renewalCancelled:
            guard nextState.renewal.target != nil else { break }
            nextState.renewal = .idle
            effects.append(.cancelRenewal)
        }

        return TransmitTaskTransition(state: nextState, effects: effects)
    }
}

final class TransmitTaskRuntimeState {
    private(set) var beginTask: Task<Void, Never>?
    private(set) var beginTaskID: Int?
    private(set) var renewalTask: Task<Void, Never>?
    private(set) var renewalTaskID: Int?
    private(set) var renewalTarget: TransmitTarget?
    private(set) var captureReassertionTask: Task<Void, Never>?

    var renewalChannelID: String? {
        renewalTarget?.channelID
    }

    func replaceBeginTask(with task: Task<Void, Never>?, id: Int) {
        beginTask?.cancel()
        beginTask = task
        beginTaskID = task == nil ? nil : id
    }

    func cancelBeginTask(matching id: Int? = nil) {
        guard id == nil || beginTaskID == id else { return }
        beginTask?.cancel()
        beginTask = nil
        beginTaskID = nil
    }

    func replaceRenewalTask(with task: Task<Void, Never>?, id: Int, target: TransmitTarget?) {
        renewalTask?.cancel()
        renewalTask = task
        renewalTaskID = task == nil ? nil : id
        renewalTarget = target
    }

    func cancelRenewalTask(matching id: Int? = nil) {
        guard id == nil || renewalTaskID == id else { return }
        renewalTask?.cancel()
        renewalTask = nil
        renewalTaskID = nil
        renewalTarget = nil
    }

    func replaceCaptureReassertionTask(with task: Task<Void, Never>?) {
        captureReassertionTask?.cancel()
        captureReassertionTask = task
    }

    func cancelCaptureReassertionTask() {
        captureReassertionTask?.cancel()
        captureReassertionTask = nil
    }

    func reset() {
        cancelBeginTask()
        cancelRenewalTask()
        cancelCaptureReassertionTask()
    }
}

@MainActor
final class TransmitTaskCoordinator {
    private(set) var state = TransmitTaskSessionState()
    var effectHandler: (@MainActor (TransmitTaskEffect) -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: TransmitTaskEvent) {
        let previousState = state
        let transition = TransmitTaskReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            effectHandler?(effect)
        }
    }

    private func reportTransition(
        previousState: TransmitTaskSessionState,
        event: TransmitTaskEvent,
        transition: TransmitTaskTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "transmit-task",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
