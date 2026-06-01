import Foundation

enum IncomingWakePlaybackMode: Equatable {
    case awaitingPTTActivation
    case appManagedFallback
    case systemActivated
}

enum IncomingWakeActivationState: Equatable {
    case signalBuffered
    case awaitingSystemActivation
    case systemActivationTimedOutWaitingForForeground
    case systemActivationInterruptedByTransmitEnd
    case appManagedFallback
    case systemActivated
}

struct WakeReceiveContext: Equatable {
    let contactID: UUID
    let channelUUID: UUID
    let payload: TurboPTTPushPayload
}

enum WakeReceiveState: Equatable {
    case idle
    case signalBuffered(WakeReceiveContext, bufferedAudioChunks: [String])
    case awaitingSystemActivation(WakeReceiveContext, bufferedAudioChunks: [String])
    case systemActivationTimedOutWaitingForForeground(WakeReceiveContext, bufferedAudioChunks: [String])
    case systemActivationInterruptedByTransmitEnd(WakeReceiveContext)
    case appManagedFallback(WakeReceiveContext, bufferedAudioChunks: [String])
    case systemActivated(WakeReceiveContext, bufferedAudioChunks: [String])

    var context: WakeReceiveContext? {
        switch self {
        case .idle:
            return nil
        case .signalBuffered(let context, _),
             .awaitingSystemActivation(let context, _),
             .systemActivationTimedOutWaitingForForeground(let context, _),
             .systemActivationInterruptedByTransmitEnd(let context),
             .appManagedFallback(let context, _),
             .systemActivated(let context, _):
            return context
        }
    }

    var activationState: IncomingWakeActivationState? {
        switch self {
        case .idle:
            return nil
        case .signalBuffered:
            return .signalBuffered
        case .awaitingSystemActivation:
            return .awaitingSystemActivation
        case .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground
        case .systemActivationInterruptedByTransmitEnd:
            return .systemActivationInterruptedByTransmitEnd
        case .appManagedFallback:
            return .appManagedFallback
        case .systemActivated:
            return .systemActivated
        }
    }

    var playbackMode: IncomingWakePlaybackMode? {
        switch self {
        case .idle:
            return nil
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return .awaitingPTTActivation
        case .systemActivationInterruptedByTransmitEnd:
            return nil
        case .appManagedFallback:
            return .appManagedFallback
        case .systemActivated:
            return .systemActivated
        }
    }

    var bufferedAudioChunks: [String] {
        switch self {
        case .idle:
            return []
        case .signalBuffered(_, let bufferedAudioChunks),
             .awaitingSystemActivation(_, let bufferedAudioChunks),
             .systemActivationTimedOutWaitingForForeground(_, let bufferedAudioChunks),
             .appManagedFallback(_, let bufferedAudioChunks),
             .systemActivated(_, let bufferedAudioChunks):
            return bufferedAudioChunks
        case .systemActivationInterruptedByTransmitEnd:
            return []
        }
    }

    var hasConfirmedIncomingPush: Bool {
        switch self {
        case .idle, .signalBuffered:
            return false
        case .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .appManagedFallback,
             .systemActivated:
            return true
        }
    }

    var allowsBufferedAudioUntilActivation: Bool {
        switch self {
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return true
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return false
        }
    }

    func storingBufferedAudioChunk(
        _ payload: String,
        maximumBufferedAudioChunks: Int
    ) -> WakeReceiveState {
        guard allowsBufferedAudioUntilActivation,
              let context else {
            return self
        }
        var nextBufferedAudioChunks = bufferedAudioChunks
        nextBufferedAudioChunks.append(payload)
        if nextBufferedAudioChunks.count > maximumBufferedAudioChunks {
            nextBufferedAudioChunks.removeFirst(
                nextBufferedAudioChunks.count - maximumBufferedAudioChunks
            )
        }

        switch self {
        case .signalBuffered:
            return .signalBuffered(context, bufferedAudioChunks: nextBufferedAudioChunks)
        case .awaitingSystemActivation:
            return .awaitingSystemActivation(context, bufferedAudioChunks: nextBufferedAudioChunks)
        case .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground(context, bufferedAudioChunks: nextBufferedAudioChunks)
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return self
        }
    }

    func clearingBufferedAudioChunks() -> WakeReceiveState {
        guard let context else { return self }
        switch self {
        case .signalBuffered:
            return .signalBuffered(context, bufferedAudioChunks: [])
        case .awaitingSystemActivation:
            return .awaitingSystemActivation(context, bufferedAudioChunks: [])
        case .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground(context, bufferedAudioChunks: [])
        case .systemActivationInterruptedByTransmitEnd:
            return .systemActivationInterruptedByTransmitEnd(context)
        case .appManagedFallback:
            return .appManagedFallback(context, bufferedAudioChunks: [])
        case .systemActivated:
            return .systemActivated(context, bufferedAudioChunks: [])
        case .idle:
            return self
        }
    }

    func confirmingIncomingPush(
        channelUUID: UUID,
        payload: TurboPTTPushPayload
    ) -> WakeReceiveState {
        guard let context,
              context.channelUUID == channelUUID else {
            return self
        }
        let confirmedContext = WakeReceiveContext(
            contactID: context.contactID,
            channelUUID: context.channelUUID,
            payload: payload
        )

        switch self {
        case .signalBuffered, .awaitingSystemActivation:
            return .awaitingSystemActivation(
                confirmedContext,
                bufferedAudioChunks: bufferedAudioChunks
            )
        case .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground(
                confirmedContext,
                bufferedAudioChunks: bufferedAudioChunks
            )
        case .appManagedFallback:
            return .appManagedFallback(
                confirmedContext,
                bufferedAudioChunks: bufferedAudioChunks
            )
        case .systemActivated:
            return .systemActivated(
                confirmedContext,
                bufferedAudioChunks: bufferedAudioChunks
            )
        case .idle, .systemActivationInterruptedByTransmitEnd:
            return self
        }
    }

    func markingAudioSessionActivated(channelUUID: UUID) -> WakeReceiveState {
        guard let context,
              context.channelUUID == channelUUID else {
            return self
        }
        switch self {
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return .systemActivated(context, bufferedAudioChunks: bufferedAudioChunks)
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return self
        }
    }

    func markingFallbackDeferred(contactID: UUID) -> WakeReceiveState {
        guard let context,
              context.contactID == contactID else {
            return self
        }
        switch self {
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground(context, bufferedAudioChunks: bufferedAudioChunks)
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return self
        }
    }

    func markingSystemActivationInterruptedByTransmitEnd(contactID: UUID) -> WakeReceiveState {
        guard let context,
              context.contactID == contactID else {
            return self
        }
        switch self {
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return .systemActivationInterruptedByTransmitEnd(context)
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return self
        }
    }

    func markingAppManagedFallbackStarted(contactID: UUID) -> WakeReceiveState {
        guard let context,
              context.contactID == contactID else {
            return self
        }
        switch self {
        case .signalBuffered, .awaitingSystemActivation, .systemActivationTimedOutWaitingForForeground:
            return .appManagedFallback(context, bufferedAudioChunks: bufferedAudioChunks)
        case .idle, .systemActivationInterruptedByTransmitEnd, .appManagedFallback, .systemActivated:
            return self
        }
    }
}

struct PendingIncomingPTTPush: Equatable {
    let contactID: UUID
    let channelUUID: UUID
    let payload: TurboPTTPushPayload
    var hasConfirmedIncomingPush: Bool = false
    var playbackMode: IncomingWakePlaybackMode = .awaitingPTTActivation
    var activationState: IncomingWakeActivationState = .signalBuffered
    var bufferedAudioChunks: [String] = []

    init(
        contactID: UUID,
        channelUUID: UUID,
        payload: TurboPTTPushPayload,
        hasConfirmedIncomingPush: Bool = false,
        playbackMode: IncomingWakePlaybackMode = .awaitingPTTActivation,
        activationState: IncomingWakeActivationState = .signalBuffered,
        bufferedAudioChunks: [String] = []
    ) {
        self.contactID = contactID
        self.channelUUID = channelUUID
        self.payload = payload
        self.hasConfirmedIncomingPush = hasConfirmedIncomingPush
        self.playbackMode = playbackMode
        self.activationState = activationState
        self.bufferedAudioChunks = bufferedAudioChunks
    }

    init(state: WakeReceiveState) {
        let context = state.context!
        self.contactID = context.contactID
        self.channelUUID = context.channelUUID
        self.payload = context.payload
        self.hasConfirmedIncomingPush = state.hasConfirmedIncomingPush
        self.playbackMode = state.playbackMode ?? .awaitingPTTActivation
        self.activationState = state.activationState ?? .signalBuffered
        self.bufferedAudioChunks = state.bufferedAudioChunks
    }
}

struct WakeExecutionSessionState: Equatable {
    var wakeReceiveState: WakeReceiveState = .idle
    var suppressedProvisionalWakeCandidateContactIDs: Set<UUID> = []

    var pendingIncomingPush: PendingIncomingPTTPush? {
        switch wakeReceiveState {
        case .idle, .systemActivationInterruptedByTransmitEnd:
            return nil
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .appManagedFallback,
             .systemActivated:
            return PendingIncomingPTTPush(state: wakeReceiveState)
        }
    }

    func shouldBufferAudioChunk(for contactID: UUID) -> Bool {
        guard let context = wakeReceiveState.context else { return false }
        return context.contactID == contactID
            && wakeReceiveState.allowsBufferedAudioUntilActivation
    }

    func hasPendingWake(for contactID: UUID) -> Bool {
        pendingIncomingPush?.contactID == contactID
    }

    func shouldSuppressProvisionalWakeCandidate(for contactID: UUID) -> Bool {
        suppressedProvisionalWakeCandidateContactIDs.contains(contactID)
    }

    func shouldIgnoreDuplicateIncomingPush(
        for contactID: UUID,
        channelUUID: UUID,
        payload: TurboPTTPushPayload
    ) -> Bool {
        guard let context = wakeReceiveState.context,
              context.contactID == contactID,
              context.channelUUID == channelUUID,
              context.payload == payload else {
            return false
        }
        return wakeReceiveState.hasConfirmedIncomingPush
    }

    func hasConfirmedIncomingPush(for contactID: UUID) -> Bool {
        guard let context = wakeReceiveState.context,
              context.contactID == contactID else {
            return false
        }
        return wakeReceiveState.hasConfirmedIncomingPush
    }

    func bufferedAudioChunks(for contactID: UUID) -> [String] {
        guard let context = wakeReceiveState.context,
              context.contactID == contactID else {
            return []
        }
        return wakeReceiveState.bufferedAudioChunks
    }

    func bufferedAudioChunkCount(for contactID: UUID) -> Int {
        bufferedAudioChunks(for: contactID).count
    }

    func incomingWakeActivationState(for contactID: UUID) -> IncomingWakeActivationState? {
        guard let context = wakeReceiveState.context,
              context.contactID == contactID else {
            return nil
        }
        return wakeReceiveState.activationState
    }

    func mediaSessionActivationMode(for contactID: UUID) -> MediaSessionActivationMode {
        guard let context = wakeReceiveState.context,
              context.contactID == contactID else {
            return .appManaged
        }
        switch wakeReceiveState.playbackMode {
        case .systemActivated:
            return .systemActivated
        case .awaitingPTTActivation, .appManagedFallback, nil:
            return .appManaged
        }
    }
}

enum WakeExecutionEvent: Equatable {
    case store(PendingIncomingPTTPush)
    case confirmIncomingPush(channelUUID: UUID, payload: TurboPTTPushPayload)
    case markAudioSessionActivated(channelUUID: UUID)
    case markAppManagedFallbackStarted(contactID: UUID)
    case markFallbackDeferredUntilForeground(contactID: UUID)
    case markSystemActivationInterruptedByTransmitEnd(contactID: UUID)
    case bufferAudioChunk(contactID: UUID, payload: String)
    case clearBufferedAudioChunks(contactID: UUID)
    case suppressProvisionalWakeCandidate(contactID: UUID)
    case clearProvisionalWakeCandidateSuppression(contactID: UUID)
    case clear(contactID: UUID)
    case clearAll(clearSuppression: Bool)
}

enum WakeExecutionEffect: Equatable {
    case cancelPlaybackFallbackTask(contactID: UUID)
    case cancelAllPlaybackFallbackTasks
}

struct WakeExecutionTransition: Equatable {
    var state: WakeExecutionSessionState
    var effects: [WakeExecutionEffect] = []
}

enum WakeExecutionReducer {
    static func reduce(
        state: WakeExecutionSessionState,
        event: WakeExecutionEvent,
        maximumBufferedAudioChunks: Int
    ) -> WakeExecutionTransition {
        var nextState = state
        var effects: [WakeExecutionEffect] = []

        switch event {
        case .store(let push):
            nextState.wakeReceiveState = wakeReceiveState(for: push)

        case .confirmIncomingPush(let channelUUID, let payload):
            nextState.wakeReceiveState = state.wakeReceiveState.confirmingIncomingPush(
                channelUUID: channelUUID,
                payload: payload
            )

        case .markAudioSessionActivated(let channelUUID):
            nextState.wakeReceiveState = state.wakeReceiveState.markingAudioSessionActivated(
                channelUUID: channelUUID
            )

        case .markAppManagedFallbackStarted(let contactID):
            nextState.wakeReceiveState = state.wakeReceiveState.markingAppManagedFallbackStarted(
                contactID: contactID
            )

        case .markFallbackDeferredUntilForeground(let contactID):
            nextState.wakeReceiveState = state.wakeReceiveState.markingFallbackDeferred(
                contactID: contactID
            )

        case .markSystemActivationInterruptedByTransmitEnd(let contactID):
            nextState.wakeReceiveState = state.wakeReceiveState.markingSystemActivationInterruptedByTransmitEnd(
                contactID: contactID
            )
            effects.append(.cancelPlaybackFallbackTask(contactID: contactID))

        case .bufferAudioChunk(let contactID, let payload):
            guard state.wakeReceiveState.context?.contactID == contactID else {
                break
            }
            nextState.wakeReceiveState = state.wakeReceiveState.storingBufferedAudioChunk(
                payload,
                maximumBufferedAudioChunks: maximumBufferedAudioChunks
            )

        case .clearBufferedAudioChunks(let contactID):
            guard state.wakeReceiveState.context?.contactID == contactID else {
                break
            }
            nextState.wakeReceiveState = state.wakeReceiveState.clearingBufferedAudioChunks()

        case .suppressProvisionalWakeCandidate(let contactID):
            nextState.suppressedProvisionalWakeCandidateContactIDs.insert(contactID)

        case .clearProvisionalWakeCandidateSuppression(let contactID):
            nextState.suppressedProvisionalWakeCandidateContactIDs.remove(contactID)

        case .clear(let contactID):
            effects.append(.cancelPlaybackFallbackTask(contactID: contactID))
            if state.wakeReceiveState.context?.contactID == contactID {
                nextState.wakeReceiveState = .idle
            }

        case .clearAll(let clearSuppression):
            effects.append(.cancelAllPlaybackFallbackTasks)
            nextState.wakeReceiveState = .idle
            if clearSuppression {
                nextState.suppressedProvisionalWakeCandidateContactIDs.removeAll(keepingCapacity: false)
            }
        }

        return WakeExecutionTransition(state: nextState, effects: effects)
    }

    private static func wakeReceiveState(for push: PendingIncomingPTTPush) -> WakeReceiveState {
        let context = WakeReceiveContext(
            contactID: push.contactID,
            channelUUID: push.channelUUID,
            payload: push.payload
        )
        switch push.activationState {
        case .signalBuffered:
            return .signalBuffered(
                context,
                bufferedAudioChunks: push.bufferedAudioChunks
            )
        case .awaitingSystemActivation:
            return .awaitingSystemActivation(
                context,
                bufferedAudioChunks: push.bufferedAudioChunks
            )
        case .systemActivationTimedOutWaitingForForeground:
            return .systemActivationTimedOutWaitingForForeground(
                context,
                bufferedAudioChunks: push.bufferedAudioChunks
            )
        case .systemActivationInterruptedByTransmitEnd:
            return .systemActivationInterruptedByTransmitEnd(context)
        case .appManagedFallback:
            return .appManagedFallback(
                context,
                bufferedAudioChunks: push.bufferedAudioChunks
            )
        case .systemActivated:
            return .systemActivated(
                context,
                bufferedAudioChunks: push.bufferedAudioChunks
            )
        }
    }
}

struct WakeReceiveTimingState {
    private(set) var contactID: UUID?
    private(set) var channelUUID: UUID?
    private(set) var channelID: String?
    private(set) var source: String?
    private var startedAt: Date?
    private(set) var stageElapsedMillisecondsByName: [String: Int] = [:]

    var isActive: Bool {
        startedAt != nil
    }

    mutating func start(
        contactID: UUID,
        channelUUID: UUID,
        channelID: String?,
        source: String,
        at date: Date = Date()
    ) {
        self.contactID = contactID
        self.channelUUID = channelUUID
        self.channelID = channelID
        self.source = source
        startedAt = date
        stageElapsedMillisecondsByName = [:]
        _ = noteStage("wake-started", at: date)
    }

    mutating func startIfNeeded(
        contactID: UUID,
        channelUUID: UUID,
        channelID: String?,
        source: String,
        at date: Date = Date()
    ) {
        guard isActive,
              self.contactID == contactID,
              self.channelUUID == channelUUID else {
            start(
                contactID: contactID,
                channelUUID: channelUUID,
                channelID: channelID,
                source: source,
                at: date
            )
            return
        }
        updateContext(
            channelID: channelID,
            source: self.source ?? source
        )
    }

    mutating func updateContext(channelID: String?, source: String? = nil) {
        if let channelID {
            self.channelID = channelID
        }
        if let source {
            self.source = source
        }
    }

    mutating func noteStage(_ stage: String, at date: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        let elapsedMilliseconds = max(0, Int(date.timeIntervalSince(startedAt) * 1000))
        stageElapsedMillisecondsByName[stage] = elapsedMilliseconds
        return elapsedMilliseconds
    }

    mutating func noteStageIfAbsent(_ stage: String, at date: Date = Date()) -> Int? {
        guard stageElapsedMillisecondsByName[stage] == nil else {
            return stageElapsedMillisecondsByName[stage]
        }
        return noteStage(stage, at: date)
    }

    func elapsedMilliseconds(for stage: String) -> Int? {
        stageElapsedMillisecondsByName[stage]
    }

    func elapsedMilliseconds(at date: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int(date.timeIntervalSince(startedAt) * 1000))
    }

    mutating func reset() {
        contactID = nil
        channelUUID = nil
        channelID = nil
        source = nil
        startedAt = nil
        stageElapsedMillisecondsByName = [:]
    }
}

final class PTTWakeRuntimeState {
    private let maximumBufferedAudioChunks = 12
    private(set) var state = WakeExecutionSessionState()
    private(set) var timing = WakeReceiveTimingState()
    private var playbackFallbackTasks: [UUID: Task<Void, Never>] = [:]

    var wakeReceiveState: WakeReceiveState {
        state.wakeReceiveState
    }

    var pendingIncomingPush: PendingIncomingPTTPush? {
        state.pendingIncomingPush
    }

    private func apply(_ event: WakeExecutionEvent) {
        let transition = WakeExecutionReducer.reduce(
            state: state,
            event: event,
            maximumBufferedAudioChunks: maximumBufferedAudioChunks
        )
        state = transition.state
        for effect in transition.effects {
            switch effect {
            case .cancelPlaybackFallbackTask(let contactID):
                replacePlaybackFallbackTask(for: contactID, with: nil)
            case .cancelAllPlaybackFallbackTasks:
                for contactID in playbackFallbackTasks.keys {
                    replacePlaybackFallbackTask(for: contactID, with: nil)
                }
            }
        }
    }

    func store(_ push: PendingIncomingPTTPush) {
        apply(.store(push))
        timing.startIfNeeded(
            contactID: push.contactID,
            channelUUID: push.channelUUID,
            channelID: push.payload.channelId,
            source: push.hasConfirmedIncomingPush ? "incoming-push" : "provisional-signal"
        )
    }

    func confirmIncomingPush(for channelUUID: UUID, payload: TurboPTTPushPayload) {
        apply(.confirmIncomingPush(channelUUID: channelUUID, payload: payload))
        if timing.channelUUID == channelUUID {
            timing.updateContext(channelID: payload.channelId)
            _ = timing.noteStage("incoming-push-confirmed")
        }
    }

    func markAudioSessionActivated(for channelUUID: UUID) {
        apply(.markAudioSessionActivated(channelUUID: channelUUID))
        if timing.channelUUID == channelUUID {
            _ = timing.noteStage("system-audio-activation-observed")
        }
    }

    func markAppManagedFallbackStarted(for contactID: UUID) {
        apply(.markAppManagedFallbackStarted(contactID: contactID))
        if timing.contactID == contactID {
            _ = timing.noteStage("app-managed-fallback-started")
        }
    }

    func markFallbackDeferredUntilForeground(for contactID: UUID) {
        apply(.markFallbackDeferredUntilForeground(contactID: contactID))
        if timing.contactID == contactID {
            _ = timing.noteStage("fallback-deferred-until-foreground")
        }
    }

    func markSystemActivationInterruptedByTransmitEnd(for contactID: UUID) {
        apply(.markSystemActivationInterruptedByTransmitEnd(contactID: contactID))
        if timing.contactID == contactID {
            _ = timing.noteStage("system-activation-interrupted-by-transmit-end")
        }
    }

    func shouldBufferAudioChunk(for contactID: UUID) -> Bool {
        state.shouldBufferAudioChunk(for: contactID)
    }

    func hasPendingWake(for contactID: UUID) -> Bool {
        state.hasPendingWake(for: contactID)
    }

    func suppressProvisionalWakeCandidate(for contactID: UUID) {
        apply(.suppressProvisionalWakeCandidate(contactID: contactID))
    }

    func clearProvisionalWakeCandidateSuppression(for contactID: UUID) {
        apply(.clearProvisionalWakeCandidateSuppression(contactID: contactID))
    }

    func shouldSuppressProvisionalWakeCandidate(for contactID: UUID) -> Bool {
        state.shouldSuppressProvisionalWakeCandidate(for: contactID)
    }

    func shouldIgnoreDuplicateIncomingPush(
        for contactID: UUID,
        channelUUID: UUID,
        payload: TurboPTTPushPayload
    ) -> Bool {
        state.shouldIgnoreDuplicateIncomingPush(
            for: contactID,
            channelUUID: channelUUID,
            payload: payload
        )
    }

    func hasConfirmedIncomingPush(for contactID: UUID) -> Bool {
        state.hasConfirmedIncomingPush(for: contactID)
    }

    func bufferAudioChunk(_ payload: String, for contactID: UUID) {
        apply(.bufferAudioChunk(contactID: contactID, payload: payload))
        if timing.contactID == contactID {
            _ = timing.noteStageIfAbsent("first-audio-buffered")
            _ = timing.noteStage("latest-audio-buffered")
        }
    }

    func takeBufferedAudioChunks(for contactID: UUID) -> [String] {
        let bufferedAudioChunks = state.bufferedAudioChunks(for: contactID)
        apply(.clearBufferedAudioChunks(contactID: contactID))
        return bufferedAudioChunks
    }

    func noteTimingStage(
        _ stage: String,
        for contactID: UUID,
        ifAbsent: Bool = false
    ) {
        guard timing.contactID == contactID else { return }
        if ifAbsent {
            _ = timing.noteStageIfAbsent(stage)
        } else {
            _ = timing.noteStage(stage)
        }
    }

    func beginTiming(
        contactID: UUID,
        channelUUID: UUID,
        channelID: String?,
        source: String
    ) {
        timing.startIfNeeded(
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: channelID,
            source: source
        )
    }

    func resetTiming(for contactID: UUID) {
        guard timing.contactID == contactID else { return }
        timing.reset()
    }

    func bufferedAudioChunkCount(for contactID: UUID) -> Int {
        state.bufferedAudioChunkCount(for: contactID)
    }

    func replacePlaybackFallbackTask(for contactID: UUID, with task: Task<Void, Never>?) {
        playbackFallbackTasks[contactID]?.cancel()
        if let task {
            playbackFallbackTasks[contactID] = task
        } else {
            playbackFallbackTasks.removeValue(forKey: contactID)
        }
    }

    func hasPlaybackFallbackTask(for contactID: UUID) -> Bool {
        playbackFallbackTasks[contactID] != nil
    }

    func clearPlaybackFallbackTask(for contactID: UUID) {
        replacePlaybackFallbackTask(for: contactID, with: nil)
    }

    func clear(for contactID: UUID) {
        apply(.clear(contactID: contactID))
        resetTiming(for: contactID)
    }

    func clearAll(clearSuppression: Bool = true) {
        apply(.clearAll(clearSuppression: clearSuppression))
        timing.reset()
    }

    func incomingWakeActivationState(for contactID: UUID) -> IncomingWakeActivationState? {
        state.incomingWakeActivationState(for: contactID)
    }

    func mediaSessionActivationMode(for contactID: UUID) -> MediaSessionActivationMode {
        state.mediaSessionActivationMode(for: contactID)
    }
}
