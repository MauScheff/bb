//
//  PTTViewModelRuntime.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import CryptoKit
import Foundation

struct BufferedForegroundReceiveAudioChunk: Equatable {
    let payload: String
    let incomingMediaPayload: String
    let channelID: String
    let fromUserID: String
    let fromDeviceID: String
    let transport: IncomingAudioPayloadTransport
    let playbackSequenceNumber: UInt64?
    let localQueueDelayNanoseconds: UInt64
    let senderSentAtMilliseconds: Int64?
    let frameDurationNanoseconds: UInt64?
    let ingressSource: String
}

struct BufferedForegroundReceiveAudioChunkResult: Equatable {
    let bufferedChunkCount: Int
    let droppedChunkCount: Int
}

struct ForegroundSystemReceivePlaybackFallbackState: Equatable {
    let channelID: String
    let reason: String
    var isPlaybackReady: Bool
}

final class BackendRuntimeState {
    private static let backendJoinSettlingTTL: TimeInterval = 20
    private static let receiverAudioReadinessDeliveryRecoveryTTL: TimeInterval = 5

    var pollTask: Task<Void, Never>?
    var bootstrapRetryTask: Task<Void, Never>?
    var signalingJoinRecoveryTask: Task<Void, Never>?
    var config = TurboBackendConfig.load()
    var client: TurboBackendClient?
    var currentUserID: String?
    var currentPublicID: String?
    var currentShareCode: String?
    var currentShareLink: String?
    var currentProfileName: String?
    var isReady: Bool = false
    var mode: String = "unknown"
    var telemetryEnabled: Bool = false
    var trackedContactIDs: Set<UUID> = []
    private var lastPresenceHeartbeatSentAt: Date?
    private var backendJoinSettlingStartedAtByContactID: [UUID: Date] = [:]
    private var receiverAudioReadinessDeliveryRecoveryStartedAtByContactID: [UUID: Date] = [:]
    var transportFaults = TransportFaultRuntimeState()

    var hasClient: Bool {
        client != nil
    }

    var isWebSocketConnected: Bool {
        client?.isWebSocketConnected == true
    }

    func applyAuthenticatedSession(
        client: TurboBackendClient,
        userID: String,
        mode: String,
        telemetryEnabled: Bool,
        publicID: String? = nil,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil
    ) {
        self.client = client
        currentUserID = userID
        currentPublicID = publicID
        currentProfileName = profileName
        currentShareCode = shareCode ?? publicID
        currentShareLink = shareLink
        isReady = true
        self.mode = mode
        self.telemetryEnabled = telemetryEnabled
    }

    func disconnectForReconnect() {
        client?.disconnectWebSocket()
        client = nil
        currentUserID = nil
        currentPublicID = nil
        currentShareCode = nil
        currentShareLink = nil
        currentProfileName = nil
        isReady = false
        mode = "unknown"
        telemetryEnabled = false
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        signalingJoinRecoveryTask?.cancel()
        signalingJoinRecoveryTask = nil
        pollTask?.cancel()
        pollTask = nil
        lastPresenceHeartbeatSentAt = nil
        backendJoinSettlingStartedAtByContactID.removeAll()
        receiverAudioReadinessDeliveryRecoveryStartedAtByContactID.removeAll()
    }

    func replaceConfig(with config: TurboBackendConfig?) {
        self.config = config
    }

    func replacePollTask(with task: Task<Void, Never>?) {
        pollTask?.cancel()
        pollTask = task
    }

    func replaceBootstrapRetryTask(with task: Task<Void, Never>?) {
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = task
    }

    func replaceSignalingJoinRecoveryTask(with task: Task<Void, Never>?) {
        signalingJoinRecoveryTask?.cancel()
        signalingJoinRecoveryTask = task
    }

    func storeAuthenticatedUserID(_ userID: String) {
        currentUserID = userID
    }

    func storeCurrentProfileName(_ profileName: String?) {
        currentProfileName = profileName
    }

    func track(contactID: UUID) {
        trackedContactIDs.insert(contactID)
    }

    func untrack(contactID: UUID) {
        trackedContactIDs.remove(contactID)
    }

    func clearTrackedContacts() {
        trackedContactIDs = []
    }

    func consumePresenceHeartbeatSlot(
        now: Date = Date(),
        minimumInterval: TimeInterval
    ) -> Bool {
        if let lastPresenceHeartbeatSentAt,
           now.timeIntervalSince(lastPresenceHeartbeatSentAt) < minimumInterval {
            return false
        }
        lastPresenceHeartbeatSentAt = now
        return true
    }

    func markPresenceHeartbeatSent(at date: Date = Date()) {
        lastPresenceHeartbeatSentAt = date
    }

    func markBackendJoinSettling(for contactID: UUID, now: Date = Date()) {
        pruneExpiredBackendJoinSettling(now: now)
        backendJoinSettlingStartedAtByContactID[contactID] = now
    }

    func clearBackendJoinSettling(for contactID: UUID) {
        backendJoinSettlingStartedAtByContactID[contactID] = nil
    }

    func reserveReceiverAudioReadinessDeliveryRecovery(
        for contactID: UUID,
        now: Date = Date(),
        ttl: TimeInterval = BackendRuntimeState.receiverAudioReadinessDeliveryRecoveryTTL
    ) -> Bool {
        pruneExpiredReceiverAudioReadinessDeliveryRecovery(now: now, ttl: ttl)
        if let startedAt = receiverAudioReadinessDeliveryRecoveryStartedAtByContactID[contactID],
           now.timeIntervalSince(startedAt) < ttl {
            return false
        }
        receiverAudioReadinessDeliveryRecoveryStartedAtByContactID[contactID] = now
        return true
    }

    func isBackendJoinSettling(
        for contactID: UUID,
        now: Date = Date(),
        ttl: TimeInterval = BackendRuntimeState.backendJoinSettlingTTL
    ) -> Bool {
        pruneExpiredBackendJoinSettling(now: now, ttl: ttl)
        guard let startedAt = backendJoinSettlingStartedAtByContactID[contactID] else {
            return false
        }
        return now.timeIntervalSince(startedAt) < ttl
    }

    private func pruneExpiredBackendJoinSettling(
        now: Date,
        ttl: TimeInterval = BackendRuntimeState.backendJoinSettlingTTL
    ) {
        backendJoinSettlingStartedAtByContactID = backendJoinSettlingStartedAtByContactID.filter { _, startedAt in
            now.timeIntervalSince(startedAt) < ttl
        }
    }

    private func pruneExpiredReceiverAudioReadinessDeliveryRecovery(
        now: Date,
        ttl: TimeInterval = BackendRuntimeState.receiverAudioReadinessDeliveryRecoveryTTL
    ) {
        receiverAudioReadinessDeliveryRecoveryStartedAtByContactID =
            receiverAudioReadinessDeliveryRecoveryStartedAtByContactID.filter { _, startedAt in
                now.timeIntervalSince(startedAt) < ttl
            }
    }
}

enum TransportFaultHTTPRoute: String, CaseIterable {
    case contactSummaries = "contact-summaries"
    case incomingBeeps = "incoming-beeps"
    case outgoingBeeps = "outgoing-beeps"
    case channelState = "channel-state"
    case channelReadiness = "channel-readiness"
    case renewTransmit = "renew-transmit"
}

struct TransportFaultSignalDeliveryPlan: Equatable {
    let delayMilliseconds: Int
    let duplicateDeliveries: Int
    let shouldDrop: Bool
}

enum TransportFaultWebSocketReorderResult {
    case deliver([TurboSignalEnvelope])
    case buffered
}

final class TransportFaultRuntimeState {
    private struct DelayRule: Equatable {
        let milliseconds: Int
        var remainingMatches: Int
    }

    private struct WebSocketReorderRule {
        let kind: TurboSignalKind?
        let count: Int
        var buffered: [TurboSignalEnvelope] = []
    }

    private var httpDelayRules: [TransportFaultHTTPRoute: DelayRule] = [:]
    private var webSocketDelayRules: [TurboSignalKind: DelayRule] = [:]
    private var webSocketDropCounts: [TurboSignalKind: Int] = [:]
    private var webSocketDuplicateCounts: [TurboSignalKind: Int] = [:]
    private var webSocketReorderRule: WebSocketReorderRule?

    func reset() {
        httpDelayRules = [:]
        webSocketDelayRules = [:]
        webSocketDropCounts = [:]
        webSocketDuplicateCounts = [:]
        webSocketReorderRule = nil
    }

    func setHTTPDelay(route: TransportFaultHTTPRoute, milliseconds: Int, count: Int) {
        precondition(milliseconds >= 0, "HTTP delay must be non-negative")
        precondition(count >= 1, "HTTP delay count must be at least 1")
        httpDelayRules[route] = DelayRule(milliseconds: milliseconds, remainingMatches: count)
    }

    func consumeHTTPDelay(for route: TransportFaultHTTPRoute) -> Int {
        consumeDelay(from: &httpDelayRules, key: route)
    }

    func setWebSocketSignalDelay(kind: TurboSignalKind, milliseconds: Int, count: Int) {
        precondition(milliseconds >= 0, "WebSocket signal delay must be non-negative")
        precondition(count >= 1, "WebSocket signal delay count must be at least 1")
        webSocketDelayRules[kind] = DelayRule(milliseconds: milliseconds, remainingMatches: count)
    }

    func dropNextWebSocketSignals(kind: TurboSignalKind, count: Int) {
        precondition(count >= 1, "Dropped signal count must be at least 1")
        webSocketDropCounts[kind] = count
    }

    func duplicateNextWebSocketSignals(kind: TurboSignalKind, count: Int) {
        precondition(count >= 1, "Duplicated signal count must be at least 1")
        webSocketDuplicateCounts[kind] = count
    }

    func reorderNextWebSocketSignals(kind: TurboSignalKind?, count: Int) {
        precondition(count >= 2, "Reordered signal count must be at least 2")
        webSocketReorderRule = WebSocketReorderRule(kind: kind, count: count)
    }

    func consumeWebSocketReorderResult(for envelope: TurboSignalEnvelope) -> TransportFaultWebSocketReorderResult {
        guard var rule = webSocketReorderRule else {
            return .deliver([envelope])
        }

        if let kind = rule.kind, envelope.type != kind {
            return .deliver([envelope])
        }

        rule.buffered.append(envelope)
        if rule.buffered.count < rule.count {
            webSocketReorderRule = rule
            return .buffered
        }

        webSocketReorderRule = nil
        return .deliver(rule.buffered.reversed())
    }

    func consumeWebSocketSignalDeliveryPlan(for kind: TurboSignalKind) -> TransportFaultSignalDeliveryPlan {
        if consumeCount(from: &webSocketDropCounts, key: kind) {
            return TransportFaultSignalDeliveryPlan(
                delayMilliseconds: 0,
                duplicateDeliveries: 0,
                shouldDrop: true
            )
        }

        let delayMilliseconds = consumeDelay(from: &webSocketDelayRules, key: kind)
        let duplicateDeliveries = consumeCount(from: &webSocketDuplicateCounts, key: kind) ? 1 : 0

        return TransportFaultSignalDeliveryPlan(
            delayMilliseconds: delayMilliseconds,
            duplicateDeliveries: duplicateDeliveries,
            shouldDrop: false
        )
    }

    private func consumeDelay<Key: Hashable>(
        from rules: inout [Key: DelayRule],
        key: Key
    ) -> Int {
        guard var rule = rules[key] else { return 0 }
        let milliseconds = rule.milliseconds
        rule.remainingMatches -= 1
        if rule.remainingMatches <= 0 {
            rules.removeValue(forKey: key)
        } else {
            rules[key] = rule
        }
        return milliseconds
    }

    private func consumeCount<Key: Hashable>(
        from counts: inout [Key: Int],
        key: Key
    ) -> Bool {
        guard let remaining = counts[key], remaining > 0 else {
            return false
        }
        if remaining == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = remaining - 1
        }
        return true
    }
}

struct TransmitStartupTimingState {
    private(set) var pressRequestedAt: Date?
    private(set) var contactID: UUID?
    private(set) var channelUUID: UUID?
    private(set) var backendChannelID: String?
    private(set) var source: String?
    private(set) var stageElapsedMillisecondsByName: [String: Int] = [:]

    mutating func start(
        contactID: UUID,
        channelUUID: UUID?,
        backendChannelID: String,
        source: String,
        at date: Date = Date()
    ) {
        pressRequestedAt = date
        self.contactID = contactID
        self.channelUUID = channelUUID
        self.backendChannelID = backendChannelID
        self.source = source
        stageElapsedMillisecondsByName = [:]
    }

    func elapsedMilliseconds(at date: Date = Date()) -> Int? {
        guard let pressRequestedAt else { return nil }
        return Int(date.timeIntervalSince(pressRequestedAt) * 1000)
    }

    mutating func noteStage(_ stage: String, at date: Date = Date()) -> Int? {
        guard let elapsed = elapsedMilliseconds(at: date) else { return nil }
        stageElapsedMillisecondsByName[stage] = elapsed
        return elapsed
    }

    mutating func noteStageIfAbsent(_ stage: String, at date: Date = Date()) -> Int? {
        if let existing = stageElapsedMillisecondsByName[stage] {
            return existing
        }
        return noteStage(stage, at: date)
    }

    func elapsedMilliseconds(for stage: String) -> Int? {
        stageElapsedMillisecondsByName[stage]
    }

    mutating func reset() {
        pressRequestedAt = nil
        contactID = nil
        channelUUID = nil
        backendChannelID = nil
        source = nil
        stageElapsedMillisecondsByName = [:]
    }
}

struct TransmitRuntimeState {
    private(set) var executionState: TransmitExecutionSessionState = .initial
    private(set) var hasPendingControlPlaneBeginHandoff = false

    var activeTarget: TransmitTarget? {
        executionState.activeTarget
    }

    var pendingSystemBeginChannelUUID: UUID? {
        executionState.pendingSystemBeginChannelUUID
    }

    var isPressingTalk: Bool {
        executionState.isPressingTalk
    }

    var explicitStopRequested: Bool {
        executionState.explicitStopRequested
    }

    var requiresReleaseBeforeNextPress: Bool {
        executionState.requiresReleaseBeforeNextPress
    }

    var interruptedContactID: UUID? {
        executionState.interruptedContactID
    }

    var lastSystemTransmitBeganAt: Date? {
        executionState.lastSystemTransmitBeganAt
    }

    var hasSystemTransmitLifecycle: Bool {
        executionState.hasSystemTransmitLifecycle
    }

    var isSystemTransmitting: Bool {
        executionState.isSystemTransmitting
    }

    var shouldAwaitInitialOutboundAudioSendGate: Bool {
        executionState.initialOutboundAudioSendGateState.shouldAwaitInitialRemoteReady
    }

    var audioCaptureStartState: TransmitAudioCaptureStartState {
        executionState.audioCaptureStartState
    }

    mutating func syncActiveTarget(_ activeTarget: TransmitTarget?) {
        reduce(.syncActiveTarget(activeTarget))
    }

    mutating func markPressBegan() {
        reduce(.markPressBegan)
        executionState.audioCaptureStartState = .idle
    }

    mutating func markControlPlaneBeginHandoffRequested() {
        hasPendingControlPlaneBeginHandoff = true
    }

    mutating func markControlPlaneBeginHandoffCompleted() {
        hasPendingControlPlaneBeginHandoff = false
    }

    mutating func markPressEnded() {
        reduce(.markPressEnded)
    }

    mutating func markUnexpectedSystemEndRequiresRelease(contactID: UUID?) {
        reduce(.markUnexpectedSystemEndRequiresRelease(contactID: contactID))
    }

    mutating func noteSystemTransmitBegan(at date: Date = Date()) {
        reduce(.noteSystemTransmitBegan(date))
    }

    mutating func noteSystemTransmitEnded() {
        reduce(.noteSystemTransmitEnded)
        executionState.audioCaptureStartState = .idle
    }

    mutating func noteSystemTransmitBeginRequested(channelUUID: UUID) {
        reduce(.noteSystemTransmitBeginRequested(channelUUID: channelUUID))
    }

    mutating func clearPendingSystemTransmitBegin(channelUUID: UUID? = nil) {
        reduce(.clearPendingSystemTransmitBegin(channelUUID: channelUUID))
    }

    func isSystemTransmitBeginPending(channelUUID: UUID) -> Bool {
        pendingSystemBeginChannelUUID == channelUUID
    }

    mutating func beginSystemTransmitActivationIfNeeded(channelUUID: UUID) -> Bool {
        switch executionState.systemTransmitActivationState {
        case .idle:
            reduce(.beginSystemTransmitActivation(channelUUID: channelUUID))
            return true
        case .activating(let existingChannelUUID), .activated(let existingChannelUUID):
            guard existingChannelUUID != channelUUID else { return false }
            reduce(.beginSystemTransmitActivation(channelUUID: channelUUID))
            return true
        }
    }

    mutating func noteSystemTransmitActivationCompleted(channelUUID: UUID) {
        reduce(.markSystemTransmitActivationCompleted(channelUUID: channelUUID))
    }

    mutating func clearSystemTransmitActivation(channelUUID: UUID? = nil) {
        reduce(.clearSystemTransmitActivation(channelUUID: channelUUID))
    }

    func currentSystemTransmitDurationMilliseconds(at date: Date = Date()) -> Int? {
        guard let lastSystemTransmitBeganAt else { return nil }
        return Int(date.timeIntervalSince(lastSystemTransmitBeganAt) * 1000)
    }

    mutating func noteTouchReleased() {
        reduce(.noteTouchReleased)
    }

    mutating func reconcileIdleState() {
        reduce(.reconcileIdleState)
        hasPendingControlPlaneBeginHandoff = false
        executionState.audioCaptureStartState = .idle
    }

    mutating func markExplicitStopRequested() {
        reduce(.markExplicitStopRequested)
    }

    mutating func takeShouldAwaitInitialOutboundAudioSendGate() -> Bool {
        let shouldAwait = shouldAwaitInitialOutboundAudioSendGate
        guard shouldAwait else { return false }
        reduce(.consumeInitialOutboundAudioSendGate)
        return true
    }

    mutating func reset() {
        reduce(.reset)
        hasPendingControlPlaneBeginHandoff = false
        executionState.audioCaptureStartState = .idle
    }

    mutating func handleSystemTransmitEnded(
        applicationStateIsActive: Bool,
        matchingActiveTarget: TransmitTarget?
    ) -> SystemTransmitEndDisposition {
        let effects = reduce(
            .handleSystemTransmitEnded(
                applicationStateIsActive: applicationStateIsActive,
                matchingActiveTarget: matchingActiveTarget
            )
        )
        guard case .handledSystemTransmitEnded(let disposition)? = effects.last else {
            return .none
        }
        executionState.audioCaptureStartState = .idle
        return disposition
    }

    mutating func beginAudioCaptureStartIfNeeded(
        channelUUID: UUID,
        intent: TransmitAudioCaptureStartIntent
    ) -> TransmitAudioCaptureStartDecision {
        switch (executionState.audioCaptureStartState, intent) {
        case (.idle, .initial):
            executionState.audioCaptureStartState = .starting(channelUUID: channelUUID)
            return .begin
        case (.idle, .systemActivationRefresh):
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        case (.starting(let existing), _) where existing == channelUUID:
            return .waitForInFlight
        case (.refreshing(let existing), _) where existing == channelUUID:
            return .waitForInFlight
        case (.started(let existing), .initial) where existing == channelUUID:
            return .alreadyCompleted
        case (.started(let existing), .systemActivationRefresh) where existing == channelUUID:
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        case (.refreshed(let existing), _) where existing == channelUUID:
            return .alreadyCompleted
        case (.started, .initial):
            executionState.audioCaptureStartState = .starting(channelUUID: channelUUID)
            return .begin
        case (.started, .systemActivationRefresh):
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        case (.starting, .initial):
            executionState.audioCaptureStartState = .starting(channelUUID: channelUUID)
            return .begin
        case (.starting, .systemActivationRefresh):
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        case (.refreshing, .initial):
            executionState.audioCaptureStartState = .starting(channelUUID: channelUUID)
            return .begin
        case (.refreshing, .systemActivationRefresh):
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        case (.refreshed, .initial):
            executionState.audioCaptureStartState = .starting(channelUUID: channelUUID)
            return .begin
        case (.refreshed, .systemActivationRefresh):
            executionState.audioCaptureStartState = .refreshing(channelUUID: channelUUID)
            return .begin
        }
    }

    mutating func noteAudioCaptureStartCompleted(
        channelUUID: UUID,
        intent: TransmitAudioCaptureStartIntent
    ) {
        switch (executionState.audioCaptureStartState, intent) {
        case (.starting(let existing), .initial) where existing == channelUUID:
            executionState.audioCaptureStartState = .started(channelUUID: channelUUID)
        case (.refreshing(let existing), .systemActivationRefresh) where existing == channelUUID:
            executionState.audioCaptureStartState = .refreshed(channelUUID: channelUUID)
        default:
            break
        }
    }

    mutating func clearAudioCaptureStartIfInFlight(
        channelUUID: UUID,
        intent: TransmitAudioCaptureStartIntent
    ) {
        switch (executionState.audioCaptureStartState, intent) {
        case (.starting(let existing), .initial) where existing == channelUUID:
            executionState.audioCaptureStartState = .idle
        case (.refreshing(let existing), .systemActivationRefresh) where existing == channelUUID:
            executionState.audioCaptureStartState = .started(channelUUID: channelUUID)
        default:
            break
        }
    }

    @discardableResult
    private mutating func reduce(_ event: TransmitExecutionEvent) -> [TransmitExecutionEffect] {
        let transition = TransmitExecutionReducer.reduce(
            state: executionState,
            event: event
        )
        executionState = transition.state
        return transition.effects
    }
}

enum TransmitDomainPhase: Equatable {
    case idle
    case requesting(contactID: UUID)
    case active(contactID: UUID)
    case stopping(contactID: UUID)
}

struct TransmitDomainSnapshot: Equatable {
    let phase: TransmitDomainPhase
    let isPressActive: Bool
    let explicitStopRequested: Bool
    let isSystemTransmitting: Bool
    let activeTarget: TransmitTarget?
    let interruptedContactID: UUID?
    let requiresReleaseBeforeNextPress: Bool

    var activeContactID: UUID? {
        switch phase {
        case .idle:
            return nil
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID
        }
    }

    func hasTransmitIntent(for contactID: UUID) -> Bool {
        guard !explicitStopRequested else { return false }
        switch phase {
        case .requesting(let activeContactID), .active(let activeContactID):
            return activeContactID == contactID
        case .idle, .stopping:
            return false
        }
    }

    func isStopping(for contactID: UUID) -> Bool {
        guard explicitStopRequested else { return false }
        switch phase {
        case .stopping(let activeContactID):
            return activeContactID == contactID
        case .idle, .requesting, .active:
            return false
        }
    }

    func requiresFreshPress(for contactID: UUID) -> Bool {
        requiresReleaseBeforeNextPress && interruptedContactID == contactID
    }

    func localTransmitProjection(
        for contactID: UUID,
        mediaState: MediaConnectionState,
        pttAudioSessionActive: Bool
    ) -> LocalTransmitProjection {
        LocalTransmitProjection.fromRuntimeState(
            isTransmitting: hasTransmitIntent(for: contactID),
            isStopping: isStopping(for: contactID),
            requiresFreshPress: requiresFreshPress(for: contactID),
            backendLeaseActive: activeTarget?.contactID == contactID,
            transmitPhase: phase,
            systemIsTransmitting: isSystemTransmitting,
            pttAudioSessionActive: pttAudioSessionActive,
            mediaState: mediaState
        )
    }
}

struct TransmitProjection: Equatable {
    let controlPlane: TransmitSessionState
    let execution: TransmitExecutionSessionState
    let systemChannelUUID: UUID?
    let systemActiveContactID: UUID?
    let systemIsTransmitting: Bool

    var activeTarget: TransmitTarget? {
        controlPlane.activeTarget ?? execution.activeTarget
    }

    var fallbackContactID: UUID? {
        activeTarget?.contactID
            ?? (systemIsTransmitting ? systemActiveContactID : nil)
    }

    var domainPhase: TransmitDomainPhase {
        if execution.explicitStopRequested, let contactID = fallbackContactID {
            return .stopping(contactID: contactID)
        }

        if systemIsTransmitting, let contactID = systemActiveContactID ?? fallbackContactID {
            return .active(contactID: contactID)
        }

        switch controlPlane.phase {
        case .idle:
            if let contactID = fallbackContactID, execution.isPressingTalk {
                return .requesting(contactID: contactID)
            }
            return .idle
        case .requesting(let contactID):
            return .requesting(contactID: contactID)
        case .active(let contactID):
            return execution.explicitStopRequested ? .stopping(contactID: contactID) : .active(contactID: contactID)
        case .stopping(let contactID):
            return .stopping(contactID: contactID)
        }
    }

    var domainSnapshot: TransmitDomainSnapshot {
        TransmitDomainSnapshot(
            phase: domainPhase,
            isPressActive: !execution.explicitStopRequested && (execution.isPressingTalk || controlPlane.isPressingTalk),
            explicitStopRequested: execution.explicitStopRequested,
            isSystemTransmitting: systemIsTransmitting,
            activeTarget: activeTarget,
            interruptedContactID: execution.interruptedContactID,
            requiresReleaseBeforeNextPress: execution.requiresReleaseBeforeNextPress
        )
    }

    func activeTarget(
        for systemChannelUUID: UUID,
        channelUUIDForContact: (UUID) -> UUID?
    ) -> TransmitTarget? {
        guard let activeTarget else { return nil }
        guard channelUUIDForContact(activeTarget.contactID) == systemChannelUUID else { return nil }
        return activeTarget
    }

    func hasPendingLifecycle(
        for systemChannelUUID: UUID,
        channelUUIDForContact: (UUID) -> UUID?
    ) -> Bool {
        if activeTarget(for: systemChannelUUID, channelUUIDForContact: channelUUIDForContact) != nil {
            return true
        }
        return controlPlane.pendingRequest?.channelUUID == systemChannelUUID
    }
}

enum IncomingRelayAudioDiagnosticDisposition: Equatable {
    case detailed
    case suppressedNotice
    case suppressed
}

struct IncomingAudioIngressContext: Equatable, Sendable {
    let receivedAtNanoseconds: UInt64
    let sequenceNumber: UInt64?
    let sentAtMilliseconds: Int64?
    let source: String

    init(
        receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sequenceNumber: UInt64? = nil,
        sentAtMilliseconds: Int64? = nil,
        source: String
    ) {
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.sequenceNumber = sequenceNumber
        self.sentAtMilliseconds = sentAtMilliseconds
        self.source = source
    }
}

struct IncomingAudioIngressPacket: Sendable {
    let payload: String
    let channelID: String
    let fromDeviceID: String
    let contactID: UUID
    let incomingAudioTransport: IncomingAudioPayloadTransport
    let transportSequenceNumber: UInt64?
    let ingressContext: IncomingAudioIngressContext?
    let receiveEpoch: UInt64
}

struct IncomingAudioIngressConfiguration: Sendable {
    let mediaEncryptionRequired: Bool
    let mediaEncryptionSession: MediaEncryptionSession?
    var liveAudioBacklogExpirationNanoseconds: UInt64 = 2_000_000_000
    var liveAudioSenderClockExpirationMilliseconds: Int64 = 2_000
}

struct IncomingAudioIngressAcceptedPacket: Sendable {
    let incomingMediaPayload: String
    let audioPayload: String
    let sequenceNumber: UInt64?
    let encryptedSequenceNumber: UInt64?
    let senderSentAtMilliseconds: Int64?
    let ingressReceivedAtNanoseconds: UInt64
    let admittedAtNanoseconds: UInt64
    let localQueueDelayNanoseconds: UInt64
    let frameDurationNanoseconds: UInt64?
    let transportDigest: String
    let shouldLogPlaintextFallback: Bool
}

struct IncomingAudioIngressDeferredEncryptedPacket: Sendable {
    let incomingMediaPayload: String
    let localQueueDelayNanoseconds: UInt64
}

enum IncomingAudioIngressRejection: Equatable, Sendable {
    case duplicatePlaintext(previousTransport: IncomingAudioPayloadTransport, transportDigest: String)
    case encryptedOpenFailed(errorDescription: String)
    case duplicateEncrypted(sequenceNumber: UInt64)
    case replayedEncrypted(sequenceNumber: UInt64)
    case droppedByPlaybackGate(
        decision: IncomingAudioPlaybackDecision,
        sequenceNumber: UInt64?,
        transportDigest: String,
        senderSentAtMilliseconds: Int64?,
        localQueueDelayNanoseconds: UInt64
    )
}

enum IncomingAudioIngressAdmission: Sendable {
    case accepted(IncomingAudioIngressAcceptedPacket)
    case deferredEncrypted(IncomingAudioIngressDeferredEncryptedPacket)
    case rejected(IncomingAudioIngressRejection)
}

actor IncomingAudioIngressExecutor {
    private static let mediaEncryptionReceiveSequenceWindow: UInt64 = 256
    private static let mediaEncryptionRecentReceiveSequenceLimit = 256

    private struct PlaintextPayloadKey: Hashable {
        let contactID: UUID
        let receiveEpoch: UInt64
        let channelID: String
        let fromDeviceID: String
        let digest: String
    }

    private struct PlaintextPayloadObservation {
        let transport: IncomingAudioPayloadTransport
        let receivedAt: Date
    }

    private struct EncryptedReceiveKey: Hashable {
        let contactID: UUID
        let receiveEpoch: UInt64
        let keyID: String
    }

    private struct PlaybackGateKey: Hashable {
        let contactID: UUID
        let receiveEpoch: UInt64
    }

    private var recentPlaintextPayloads: [PlaintextPayloadKey: PlaintextPayloadObservation] = [:]
    private var encryptedReceiveSequenceByKey: [EncryptedReceiveKey: UInt64] = [:]
    private var encryptedRecentReceiveSequencesByKey: [EncryptedReceiveKey: Set<UInt64>] = [:]
    private var playbackGateByKey: [PlaybackGateKey: IncomingAudioPlaybackGateState] = [:]

    func admit(
        _ packet: IncomingAudioIngressPacket,
        policy: IncomingAudioIngressConfiguration,
        nowNanoseconds: UInt64? = nil,
        now: Date? = nil
    ) -> IncomingAudioIngressAdmission {
        let nowNanoseconds = nowNanoseconds ?? DispatchTime.now().uptimeNanoseconds
        let now = now ?? Date()
        let relayWebSocketAudioPayload: TurboRelayWebSocketAudioPayload?
        if packet.incomingAudioTransport == .relayWebSocket {
            relayWebSocketAudioPayload = TurboRelayWebSocketAudioPayloadCodec.decodeIfPresent(packet.payload)
        } else {
            relayWebSocketAudioPayload = nil
        }

        let incomingMediaPayload = relayWebSocketAudioPayload?.payload ?? packet.payload
        let effectiveTransportSequenceNumber =
            packet.transportSequenceNumber
            ?? packet.ingressContext?.sequenceNumber
            ?? relayWebSocketAudioPayload?.sequenceNumber
        let senderSentAtMilliseconds =
            packet.ingressContext?.sentAtMilliseconds
            ?? relayWebSocketAudioPayload?.sentAtMilliseconds
        let ingressReceivedAtNanoseconds =
            packet.ingressContext?.receivedAtNanoseconds
            ?? nowNanoseconds
        let localQueueDelayNanoseconds =
            nowNanoseconds >= ingressReceivedAtNanoseconds
            ? nowNanoseconds - ingressReceivedAtNanoseconds
            : 0
        let liveBacklogExpirationNanoseconds = policy.liveAudioBacklogExpirationNanoseconds
        if liveBacklogExpirationNanoseconds > 0,
           localQueueDelayNanoseconds >= liveBacklogExpirationNanoseconds {
            return .rejected(
                .droppedByPlaybackGate(
                    decision: .drop(
                        .expiredLiveBacklog(
                            localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                            thresholdNanoseconds: liveBacklogExpirationNanoseconds
                        )
                    ),
                    sequenceNumber: effectiveTransportSequenceNumber,
                    transportDigest: "omitted-expired-live-backlog",
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds
                )
            )
        }
        if policy.liveAudioSenderClockExpirationMilliseconds > 0,
           let senderSentAtMilliseconds {
            let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
            if nowMilliseconds >= senderSentAtMilliseconds {
                let senderClockAgeMilliseconds = nowMilliseconds - senderSentAtMilliseconds
                if senderClockAgeMilliseconds >= policy.liveAudioSenderClockExpirationMilliseconds {
                    return .rejected(
                        .droppedByPlaybackGate(
                            decision: .drop(
                                .expiredSenderClockAge(
                                    senderClockAgeMilliseconds: senderClockAgeMilliseconds,
                                    thresholdMilliseconds: policy.liveAudioSenderClockExpirationMilliseconds
                                )
                            ),
                            sequenceNumber: effectiveTransportSequenceNumber,
                            transportDigest: "omitted-expired-sender-clock-age",
                            senderSentAtMilliseconds: senderSentAtMilliseconds,
                            localQueueDelayNanoseconds: localQueueDelayNanoseconds
                        )
                    )
                }
            }
        }

        let audioPayload: String
        let encryptedSequenceNumber: UInt64?
        let encryptedReceiveKey: EncryptedReceiveKey?
        if MediaEncryptedAudioPacket.isEncodedPacket(incomingMediaPayload) {
            guard let session = policy.mediaEncryptionSession,
                  session.channelID == packet.channelID,
                  session.peerDeviceID == packet.fromDeviceID else {
                return .deferredEncrypted(
                    IncomingAudioIngressDeferredEncryptedPacket(
                        incomingMediaPayload: incomingMediaPayload,
                        localQueueDelayNanoseconds: localQueueDelayNanoseconds
                    )
                )
            }

            let packetEnvelope: MediaEncryptedAudioPacket
            do {
                packetEnvelope = try MediaEndToEndEncryption.decodePacket(incomingMediaPayload)
                audioPayload = try MediaEndToEndEncryption.openTransportPayload(
                    incomingMediaPayload,
                    using: session.incomingSymmetricKey,
                    context: session.incomingContext
                )
            } catch {
                return .rejected(.encryptedOpenFailed(errorDescription: error.localizedDescription))
            }

            let receiveKey = EncryptedReceiveKey(
                contactID: packet.contactID,
                receiveEpoch: packet.receiveEpoch,
                keyID: session.keyID
            )
            switch encryptedSequenceAcceptance(packetEnvelope.sequenceNumber, for: receiveKey) {
            case .accepted:
                encryptedSequenceNumber = packetEnvelope.sequenceNumber
                encryptedReceiveKey = receiveKey
            case .duplicate:
                return .rejected(.duplicateEncrypted(sequenceNumber: packetEnvelope.sequenceNumber))
            case .replayOrReordered:
                return .rejected(.replayedEncrypted(sequenceNumber: packetEnvelope.sequenceNumber))
            }
        } else {
            encryptedSequenceNumber = nil
            encryptedReceiveKey = nil
            audioPayload = incomingMediaPayload
            let digest = AudioChunkPayloadCodec.transportDigest(audioPayload)
            if let previousTransport = acceptPlaintextPayload(
                contactID: packet.contactID,
                receiveEpoch: packet.receiveEpoch,
                channelID: packet.channelID,
                fromDeviceID: packet.fromDeviceID,
                transport: packet.incomingAudioTransport,
                digest: digest,
                now: now
            ) {
                return .rejected(
                    .duplicatePlaintext(
                        previousTransport: previousTransport,
                        transportDigest: digest
                    )
                )
            }
        }

        let playbackSequenceNumber = encryptedSequenceNumber ?? effectiveTransportSequenceNumber
        let frameDurationNanoseconds: UInt64?
        switch packet.incomingAudioTransport {
        case .directQuic, .mediaRelayPacket:
            frameDurationNanoseconds = nil
        case .mediaRelayTcp, .relayWebSocket:
            frameDurationNanoseconds = PCMOutgoingPayloadSplitter.durationNanoseconds(
                forEncodedPayload: audioPayload
            )
        }
        let transportDigest = AudioChunkPayloadCodec.transportDigest(audioPayload)
        let playbackDecision = acceptForPlayback(
            contactID: packet.contactID,
            receiveEpoch: packet.receiveEpoch,
            sequenceNumber: playbackSequenceNumber,
            transport: packet.incomingAudioTransport,
            frameDurationNanoseconds: frameDurationNanoseconds,
            nowNanoseconds: nowNanoseconds
        )
        guard playbackDecision.shouldPlay else {
            return .rejected(
                .droppedByPlaybackGate(
                    decision: playbackDecision,
                    sequenceNumber: playbackSequenceNumber,
                    transportDigest: transportDigest,
                    senderSentAtMilliseconds: senderSentAtMilliseconds,
                    localQueueDelayNanoseconds: localQueueDelayNanoseconds
                )
            )
        }
        if let encryptedSequenceNumber,
           let encryptedReceiveKey {
            switch acceptEncryptedSequence(encryptedSequenceNumber, for: encryptedReceiveKey) {
            case .accepted:
                break
            case .duplicate:
                return .rejected(.duplicateEncrypted(sequenceNumber: encryptedSequenceNumber))
            case .replayOrReordered:
                return .rejected(.replayedEncrypted(sequenceNumber: encryptedSequenceNumber))
            }
        }

        return .accepted(
            IncomingAudioIngressAcceptedPacket(
                incomingMediaPayload: incomingMediaPayload,
                audioPayload: audioPayload,
                sequenceNumber: playbackSequenceNumber,
                encryptedSequenceNumber: encryptedSequenceNumber,
                senderSentAtMilliseconds: senderSentAtMilliseconds,
                ingressReceivedAtNanoseconds: ingressReceivedAtNanoseconds,
                admittedAtNanoseconds: nowNanoseconds,
                localQueueDelayNanoseconds: localQueueDelayNanoseconds,
                frameDurationNanoseconds: frameDurationNanoseconds,
                transportDigest: transportDigest,
                shouldLogPlaintextFallback: !MediaEncryptedAudioPacket.isEncodedPacket(incomingMediaPayload)
                    && policy.mediaEncryptionRequired
            )
        )
    }

    func reset(contactID: UUID) {
        recentPlaintextPayloads = recentPlaintextPayloads.filter { $0.key.contactID != contactID }
        encryptedReceiveSequenceByKey = encryptedReceiveSequenceByKey.filter { $0.key.contactID != contactID }
        encryptedRecentReceiveSequencesByKey = encryptedRecentReceiveSequencesByKey.filter { $0.key.contactID != contactID }
        playbackGateByKey = playbackGateByKey.filter { $0.key.contactID != contactID }
    }

    func resetAll() {
        recentPlaintextPayloads = [:]
        encryptedReceiveSequenceByKey = [:]
        encryptedRecentReceiveSequencesByKey = [:]
        playbackGateByKey = [:]
    }

    private func acceptPlaintextPayload(
        contactID: UUID,
        receiveEpoch: UInt64,
        channelID: String,
        fromDeviceID: String,
        transport: IncomingAudioPayloadTransport,
        digest: String,
        now: Date,
        duplicateWindow: TimeInterval = 1.0
    ) -> IncomingAudioPayloadTransport? {
        let cutoff = now.addingTimeInterval(-duplicateWindow)
        recentPlaintextPayloads = recentPlaintextPayloads.filter { $0.value.receivedAt >= cutoff }
        let key = PlaintextPayloadKey(
            contactID: contactID,
            receiveEpoch: receiveEpoch,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            digest: digest
        )
        if let existing = recentPlaintextPayloads[key],
           existing.transport != transport,
           now.timeIntervalSince(existing.receivedAt) <= duplicateWindow {
            return existing.transport
        }
        recentPlaintextPayloads[key] = PlaintextPayloadObservation(
            transport: transport,
            receivedAt: now
        )
        return nil
    }

    private enum EncryptedSequenceAcceptance {
        case accepted
        case duplicate
        case replayOrReordered
    }

    private func encryptedSequenceAcceptance(
        _ sequenceNumber: UInt64,
        for key: EncryptedReceiveKey
    ) -> EncryptedSequenceAcceptance {
        if encryptedRecentReceiveSequencesByKey[key]?.contains(sequenceNumber) == true {
            return .duplicate
        }
        guard let lastSequence = encryptedReceiveSequenceByKey[key] else {
            return .accepted
        }
        if sequenceNumber > lastSequence {
            return .accepted
        }
        guard lastSequence - sequenceNumber <= Self.mediaEncryptionReceiveSequenceWindow else {
            return .replayOrReordered
        }
        return .accepted
    }

    private func acceptEncryptedSequence(
        _ sequenceNumber: UInt64,
        for key: EncryptedReceiveKey
    ) -> EncryptedSequenceAcceptance {
        switch encryptedSequenceAcceptance(sequenceNumber, for: key) {
        case .duplicate:
            return .duplicate
        case .replayOrReordered:
            return .replayOrReordered
        case .accepted:
            break
        }
        if let lastSequence = encryptedReceiveSequenceByKey[key] {
            if sequenceNumber > lastSequence {
                encryptedReceiveSequenceByKey[key] = sequenceNumber
            }
        } else {
            encryptedReceiveSequenceByKey[key] = sequenceNumber
        }
        rememberEncryptedSequence(sequenceNumber, for: key)
        return .accepted
    }

    private func rememberEncryptedSequence(
        _ sequenceNumber: UInt64,
        for key: EncryptedReceiveKey
    ) {
        var recent = encryptedRecentReceiveSequencesByKey[key] ?? []
        recent.insert(sequenceNumber)
        if recent.count > Self.mediaEncryptionRecentReceiveSequenceLimit,
           let minimum = recent.min() {
            recent.remove(minimum)
        }
        encryptedRecentReceiveSequencesByKey[key] = recent
    }

    private func acceptForPlayback(
        contactID: UUID,
        receiveEpoch: UInt64,
        sequenceNumber: UInt64?,
        transport: IncomingAudioPayloadTransport,
        frameDurationNanoseconds: UInt64? = nil,
        nowNanoseconds: UInt64
    ) -> IncomingAudioPlaybackDecision {
        guard let sequenceNumber else { return .play }
        let policy = IncomingAudioPlaybackPolicy.live(
            for: transport,
            frameDurationNanoseconds: frameDurationNanoseconds
        )
        let key = PlaybackGateKey(contactID: contactID, receiveEpoch: receiveEpoch)
        guard let previous = playbackGateByKey[key] else {
            playbackGateByKey[key] = IncomingAudioPlaybackGateState(
                sequenceNumber: sequenceNumber,
                receivedAtNanoseconds: nowNanoseconds,
                transport: transport,
                recentPacketSequences: [sequenceNumber]
            )
            return .play
        }

        switch policy.ordering {
        case .unorderedPacket:
            if previous.recentPacketSequences.contains(sequenceNumber) {
                return .drop(.duplicateOrStaleSequence)
            }
            var next = previous
            next.sequenceNumber = max(previous.sequenceNumber, sequenceNumber)
            next.receivedAtNanoseconds = nowNanoseconds
            next.transport = transport
            next.recentPacketSequences.insert(sequenceNumber)
            if next.sequenceNumber > 256 {
                let floor = next.sequenceNumber - 256
                next.recentPacketSequences = next.recentPacketSequences.filter { $0 >= floor }
            }
            playbackGateByKey[key] = next
            return .play

        case .orderedReliable(let graceFrames):
            guard sequenceNumber > previous.sequenceNumber else {
                return .drop(.duplicateOrStaleSequence)
            }
            if policy.dropsOrderedBacklog, nowNanoseconds > previous.receivedAtNanoseconds {
                let elapsedNanoseconds = nowNanoseconds - previous.receivedAtNanoseconds
                if elapsedNanoseconds > policy.maximumHoldNanoseconds {
                    let expectedAdvance = elapsedNanoseconds / max(1, policy.frameDurationNanoseconds)
                    let catchupFloor = previous.sequenceNumber
                        + expectedAdvance
                        - min(expectedAdvance, graceFrames)
                    if sequenceNumber <= catchupFloor {
                        return .drop(
                            .orderedBacklog(
                                elapsedNanoseconds: elapsedNanoseconds,
                                expectedSequenceFloor: catchupFloor
                            )
                        )
                    }
                }
            }
            var next = previous
            next.sequenceNumber = sequenceNumber
            next.receivedAtNanoseconds = nowNanoseconds
            next.transport = transport
            next.recentPacketSequences.insert(sequenceNumber)
            if next.sequenceNumber > 256 {
                let floor = next.sequenceNumber - 256
                next.recentPacketSequences = next.recentPacketSequences.filter { $0 >= floor }
            }
            playbackGateByKey[key] = next
            return .play
        }
    }
}

struct IncomingAudioIngressSummary: Equatable {
    let transport: IncomingAudioPayloadTransport
    let sampleCount: Int
    let acceptedCount: Int
    let droppedCount: Int
    let playbackAcceptedCount: Int
    let playbackRejectedCount: Int
    let maxLocalQueueDelayNanoseconds: UInt64
    let lastSequenceNumber: UInt64?
    let lastFreshnessDecision: String
    let lastPlaybackDecision: String
}

private struct IncomingAudioIngressSummaryKey: Hashable {
    let contactID: UUID
    let transport: IncomingAudioPayloadTransport
}

private struct IncomingAudioIngressSummaryState {
    var sampleCount: Int = 0
    var samplesSinceLastReport: Int = 0
    var acceptedCount: Int = 0
    var droppedCount: Int = 0
    var playbackAcceptedCount: Int = 0
    var playbackRejectedCount: Int = 0
    var maxLocalQueueDelayNanoseconds: UInt64 = 0
    var lastSequenceNumber: UInt64?
    var lastFreshnessDecision: String = "none"
    var lastPlaybackDecision: String = "none"
}

private struct DirectQuicIncomingAudioQueueDelayDiagnosticKey: Hashable {
    let contactID: UUID
    let attemptID: String
    let action: String
}

private struct IncomingAudioDiagnosticBudgetKey: Hashable {
    let contactID: UUID
    let transport: IncomingAudioPayloadTransport
    let name: String
}

struct PendingEncryptedAudioPayload: Equatable {
    let payload: String
    let channelID: String
    let fromUserID: String
    let fromDeviceID: String
    let transport: IncomingAudioPayloadTransport
    let ingressContext: IncomingAudioIngressContext?
    let receivedAt: Date
}

struct FirstAudioPlaybackAckExpectation: Equatable {
    let ackID: String
    let contactID: UUID
    let channelID: String
    let senderDeviceID: String
    let receiverDeviceID: String
    let transportDigest: String
    let encryptedSequenceNumber: UInt64?
    let queuedAt: Date
    let deliveredTransports: [String]
}

struct FirstAudioPlaybackAckSentKey: Hashable {
    let contactID: UUID
    let channelID: String
    let senderDeviceID: String
    let receiverDeviceID: String
}

private struct RecentIncomingPlaintextAudioPayloadKey: Hashable {
    let contactID: UUID
    let channelID: String
    let fromDeviceID: String
    let digest: String
}

private struct RecentIncomingPlaintextAudioPayload {
    let transport: IncomingAudioPayloadTransport
    let receivedAt: Date
}

struct IncomingAudioContinuityObservation: Equatable {
    let previousReceivedAtNanoseconds: UInt64?
    let receivedAtNanoseconds: UInt64
    let gapNanoseconds: UInt64?
    let previousTransport: IncomingAudioPayloadTransport?
}

private struct IncomingAudioContinuityState {
    let receivedAtNanoseconds: UInt64
    let transport: IncomingAudioPayloadTransport
}

struct IncomingAudioSequenceObservation: Equatable {
    let previousSequenceNumber: UInt64?
    let sequenceNumber: UInt64
    let missingSequenceCount: UInt64?
    let previousTransport: IncomingAudioPayloadTransport?
}

private struct IncomingAudioSequenceState {
    let sequenceNumber: UInt64
    let transport: IncomingAudioPayloadTransport
}

private struct IncomingPacketLossEstimateState {
    private(set) var receivedPacketCount = 0
    private(set) var missingPacketCount = 0

    mutating func observe(missingSequenceCount: UInt64?) {
        receivedPacketCount += 1
        missingPacketCount += min(Int(missingSequenceCount ?? 0), 64)
        decayIfNeeded()
    }

    var percent: Int {
        let total = receivedPacketCount + missingPacketCount
        guard total >= 10 else { return 0 }
        return min(
            OpusVoiceEncodingPolicy.maximumPacketLossPercent,
            Int((Double(missingPacketCount) * 100 / Double(total)).rounded())
        )
    }

    private mutating func decayIfNeeded() {
        let total = receivedPacketCount + missingPacketCount
        guard total > 100 else { return }
        receivedPacketCount = max(1, receivedPacketCount / 2)
        missingPacketCount /= 2
    }
}

enum IncomingAudioPlaybackDropReason: Equatable, Sendable {
    case duplicateOrStaleSequence
    case orderedBacklog(
        elapsedNanoseconds: UInt64,
        expectedSequenceFloor: UInt64
    )
    case expiredLiveBacklog(
        localQueueDelayNanoseconds: UInt64,
        thresholdNanoseconds: UInt64
    )
    case expiredSenderClockAge(
        senderClockAgeMilliseconds: Int64,
        thresholdMilliseconds: Int64
    )
}

struct IncomingAudioPlaybackDecision: Equatable, Sendable {
    let shouldPlay: Bool
    let dropReason: IncomingAudioPlaybackDropReason?

    nonisolated static let play = IncomingAudioPlaybackDecision(shouldPlay: true, dropReason: nil)

    nonisolated static func drop(_ reason: IncomingAudioPlaybackDropReason) -> IncomingAudioPlaybackDecision {
        IncomingAudioPlaybackDecision(shouldPlay: false, dropReason: reason)
    }
}

private struct IncomingAudioPlaybackGateState {
    var sequenceNumber: UInt64
    var receivedAtNanoseconds: UInt64
    var transport: IncomingAudioPayloadTransport
    var recentPacketSequences: Set<UInt64>
}

private enum IncomingAudioPlaybackOrdering {
    case unorderedPacket
    case orderedReliable(graceFrames: UInt64)
}

private struct IncomingAudioPlaybackPolicy {
    let frameDurationNanoseconds: UInt64
    let maximumHoldNanoseconds: UInt64
    let dropsOrderedBacklog: Bool
    let ordering: IncomingAudioPlaybackOrdering

    nonisolated static func live(
        for transport: IncomingAudioPayloadTransport,
        frameDurationNanoseconds overrideFrameDurationNanoseconds: UInt64? = nil
    ) -> IncomingAudioPlaybackPolicy {
        func policy(
            frameDurationNanoseconds defaultFrameDurationNanoseconds: UInt64,
            maximumHoldNanoseconds: UInt64,
            dropsOrderedBacklog: Bool = true,
            ordering: IncomingAudioPlaybackOrdering
        ) -> IncomingAudioPlaybackPolicy {
            IncomingAudioPlaybackPolicy(
                frameDurationNanoseconds: max(1, overrideFrameDurationNanoseconds ?? defaultFrameDurationNanoseconds),
                maximumHoldNanoseconds: maximumHoldNanoseconds,
                dropsOrderedBacklog: dropsOrderedBacklog,
                ordering: ordering
            )
        }

        switch transport {
        case .directQuic:
            return policy(
                frameDurationNanoseconds: 20_000_000,
                maximumHoldNanoseconds: 160_000_000,
                ordering: .unorderedPacket
            )
        case .mediaRelayPacket:
            return policy(
                frameDurationNanoseconds: 20_000_000,
                maximumHoldNanoseconds: 180_000_000,
                ordering: .unorderedPacket
            )
        case .mediaRelayTcp:
            return policy(
                frameDurationNanoseconds: 20_000_000,
                maximumHoldNanoseconds: 220_000_000,
                ordering: .orderedReliable(graceFrames: 5)
            )
        case .relayWebSocket:
            return policy(
                frameDurationNanoseconds: 20_000_000,
                maximumHoldNanoseconds: 240_000_000,
                dropsOrderedBacklog: false,
                ordering: .orderedReliable(graceFrames: 6)
            )
        }
    }
}

struct FirstTalkDirectQuicGrace: Equatable {
    let channelID: String
    let startedAt: Date
    var expired: Bool
}

struct MediaEncryptionSession: Sendable {
    let channelID: String
    let localDeviceID: String
    let peerDeviceID: String
    let localFingerprint: String
    let peerFingerprint: String
    let keyID: String
    let outgoingContext: MediaEncryptionContext
    let incomingContext: MediaEncryptionContext
    let outgoingSymmetricKey: SymmetricKey
    let incomingSymmetricKey: SymmetricKey

    init(
        channelID: String,
        localDeviceID: String,
        peerDeviceID: String,
        localFingerprint: String,
        peerFingerprint: String,
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerIdentity: MediaEncryptionIdentityRegistrationMetadata
    ) throws {
        self.channelID = channelID
        self.localDeviceID = localDeviceID
        self.peerDeviceID = peerDeviceID
        self.localFingerprint = localFingerprint
        self.peerFingerprint = peerFingerprint
        self.keyID = MediaEndToEndEncryption.keyID(
            localFingerprint: localFingerprint,
            peerFingerprint: peerFingerprint,
            channelID: channelID
        )
        let outgoingContext = MediaEncryptionContext(
            channelID: channelID,
            sessionID: MediaEndToEndEncryption.sessionID(channelID: channelID),
            senderDeviceID: localDeviceID,
            receiverDeviceID: peerDeviceID
        )
        let incomingContext = MediaEncryptionContext(
            channelID: channelID,
            sessionID: MediaEndToEndEncryption.sessionID(channelID: channelID),
            senderDeviceID: peerDeviceID,
            receiverDeviceID: localDeviceID
        )
        self.outgoingContext = outgoingContext
        self.incomingContext = incomingContext
        self.outgoingSymmetricKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: localPrivateKey,
            peerIdentity: peerIdentity,
            context: outgoingContext
        )
        self.incomingSymmetricKey = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: localPrivateKey,
            peerIdentity: peerIdentity,
            context: incomingContext
        )
    }

    func context(senderDeviceID: String, receiverDeviceID: String) -> MediaEncryptionContext {
        MediaEncryptionContext(
            channelID: channelID,
            sessionID: MediaEndToEndEncryption.sessionID(channelID: channelID),
            senderDeviceID: senderDeviceID,
            receiverDeviceID: receiverDeviceID
        )
    }
}

nonisolated final class MediaEncryptionSendSequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequenceNumber: UInt64

    init(nextSequenceNumber: UInt64 = 0) {
        self.nextSequenceNumber = nextSequenceNumber
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let sequenceNumber = nextSequenceNumber
        nextSequenceNumber += 1
        return sequenceNumber
    }

    func reset(to nextSequenceNumber: UInt64 = 0) {
        lock.lock()
        self.nextSequenceNumber = nextSequenceNumber
        lock.unlock()
    }
}

nonisolated final class OutgoingMediaPayloadSealer: @unchecked Sendable {
    private let session: MediaEncryptionSession?
    private let sequenceCounter: MediaEncryptionSendSequenceCounter?

    init(
        session: MediaEncryptionSession?,
        sequenceCounter: MediaEncryptionSendSequenceCounter?
    ) {
        self.session = session
        self.sequenceCounter = sequenceCounter
    }

    func seal(_ payload: String) throws -> String {
        guard let session, let sequenceCounter else { return payload }
        return try MediaEndToEndEncryption.sealTransportPayload(
            payload,
            using: session.outgoingSymmetricKey,
            keyID: session.keyID,
            sequenceNumber: sequenceCounter.next(),
            context: session.outgoingContext
        )
    }
}

nonisolated final class MediaHotPathEventLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumIntervalNanoseconds: UInt64
    private var lastAcceptedAtNanoseconds: UInt64?

    init(minimumIntervalNanoseconds: UInt64) {
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
    }

    func take(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastAcceptedAtNanoseconds else {
            self.lastAcceptedAtNanoseconds = nowNanoseconds
            return true
        }
        guard nowNanoseconds >= lastAcceptedAtNanoseconds,
              nowNanoseconds - lastAcceptedAtNanoseconds >= minimumIntervalNanoseconds else {
            return false
        }
        self.lastAcceptedAtNanoseconds = nowNanoseconds
        return true
    }
}

nonisolated final class MediaHotPathOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: Bool

    init(consumed: Bool = false) {
        self.consumed = consumed
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

struct MediaRelayConnectionKey: Hashable {
    let sessionID: String
    let localDeviceID: String
    let peerDeviceID: String
}

struct MediaRelayQuicUpgradeProbe {
    let key: MediaRelayConnectionKey
    let generation: UInt64
    let task: Task<Void, Never>
}

struct MediaRelayReceiverPrewarmControlKey: Hashable {
    let contactID: UUID
    let channelID: String
    let peerDeviceID: String
    let requestID: String
}

final class MediaRelayConnectionAttempt {
    let key: MediaRelayConnectionKey
    private let lock = NSLock()
    private var isFinished = false
    private var client: TurboMediaRelayClient?
    private var continuations: [CheckedContinuation<TurboMediaRelayClient?, Never>] = []

    init(key: MediaRelayConnectionKey) {
        self.key = key
    }

    func wait() async -> TurboMediaRelayClient? {
        await withCheckedContinuation { continuation in
            let resolvedClient = lock.withLock { () -> TurboMediaRelayClient?? in
                if isFinished {
                    return .some(client)
                }
                continuations.append(continuation)
                return nil
            }
            if let resolvedClient {
                continuation.resume(returning: resolvedClient)
            }
        }
    }

    func finish(_ client: TurboMediaRelayClient?) {
        let pending = lock.withLock { () -> [CheckedContinuation<TurboMediaRelayClient?, Never>] in
            guard !isFinished else { return [] }
            isFinished = true
            self.client = client
            let pending = continuations
            continuations = []
            return pending
        }
        pending.forEach { $0.resume(returning: client) }
    }
}

enum MediaRelayConnectionStart {
    case existingClient(TurboMediaRelayClient)
    case existingAttempt(MediaRelayConnectionAttempt)
    case newAttempt(MediaRelayConnectionAttempt)
}

struct DirectQuicNetworkMigrationProbe: Equatable {
    let contactID: UUID
    let attemptID: String
    let generation: UInt64
    let interface: ConversationNetworkInterface
}

nonisolated struct OutgoingAudioSendTargetToken: Equatable, Sendable {
    let target: TransmitTarget
    let generation: UInt64
}

nonisolated final class OutgoingAudioSendTargetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTarget: TransmitTarget?
    private var generation: UInt64 = 0

    func install(_ target: TransmitTarget) -> OutgoingAudioSendTargetToken {
        lock.withLock {
            generation &+= 1
            currentTarget = target
            return OutgoingAudioSendTargetToken(target: target, generation: generation)
        }
    }

    func clear() {
        lock.withLock {
            generation &+= 1
            currentTarget = nil
        }
    }

    func allows(_ token: OutgoingAudioSendTargetToken) -> Bool {
        lock.withLock {
            currentTarget == token.target && generation == token.generation
        }
    }
}

final class MediaRuntimeState {
    private static let maximumForegroundSystemReceiveBufferedAudioChunks = 300
    private static let mediaEncryptionReceiveSequenceWindow: UInt64 = 256
    private static let mediaEncryptionRecentReceiveSequenceLimit = 256

    var session: MediaSession?
    var contactID: UUID?
    var connectionState: MediaConnectionState = .idle
    var transportPathState: MediaTransportPathState = .relay
    private(set) var networkPathGeneration: UInt64 = 0
    let directQuicUpgrade = DirectQuicUpgradeRuntimeState()
    var directQuicProbeController: DirectQuicProbeController?
    var mediaRelayClient: TurboMediaRelayClient?
    private var mediaRelayConnectionKey: MediaRelayConnectionKey?
    private var mediaRelayConnectionAttempt: MediaRelayConnectionAttempt?
    private var mediaRelayQuicUpgradeProbe: MediaRelayQuicUpgradeProbe?
    private var mediaRelayQuicUpgradeFailureCounts: [MediaRelayConnectionKey: Int] = [:]
    private var suppressedMediaRelayAudioSendKeys: Set<MediaRelayConnectionKey> = []
    var directQuicPromotionTimeoutTask: Task<Void, Never>?
    var directQuicSetupLivenessTask: Task<Void, Never>?
    var directQuicAutoProbeTask: Task<Void, Never>?
    private(set) var directQuicNetworkMigrationProbe: DirectQuicNetworkMigrationProbe?
    private var directQuicNetworkMigrationTask: Task<Void, Never>?
    private var firstTalkDirectQuicGraceEntries: [(contactID: UUID, grace: FirstTalkDirectQuicGrace)] = []
    private var firstTalkDirectQuicGraceExpiryTasks: [(contactID: UUID, task: Task<Void, Never>)] = []
    let outgoingAudioSendTargetGate = OutgoingAudioSendTargetGate()
    var sendAudioChunk: (@Sendable (String) async throws -> Void)?
    var startupState: MediaSessionStartupState = .idle
    var pendingInteractivePrewarmAfterAudioDeactivationContactID: UUID?
    var interactivePrewarmRecoveryTask: Task<Void, Never>?
    private var outboundReceiverPrewarmRequestIDByContactID: [UUID: String] = [:]
    private var handledReceiverPrewarmRequestIDs: Set<String> = []
    private(set) var receiverPrewarmAckRequestIDByContactID: [UUID: String] = [:]
    private var receiverPrewarmAckReceivedAtByContactID: [UUID: Date] = [:]
    private var mediaRelayReceiverPrewarmRequestSendKeys: Set<MediaRelayReceiverPrewarmControlKey> = []
    private var mediaRelayReceiverPrewarmAckSendKeys: Set<MediaRelayReceiverPrewarmControlKey> = []
    private var directQuicUpgradeRequestSentAtByContactID: [UUID: Date] = [:]
    private(set) var directQuicWarmPongIDByContactID: [UUID: String] = [:]
    private var directQuicWarmPongReceivedAtByContactID: [UUID: Date] = [:]
    private var incomingRelayAudioDetailedReportsRemainingByContactID: [UUID: Int] = [:]
    private var incomingRelayAudioSuppressionReportedContactIDs: Set<UUID> = []
    private var directQuicIncomingAudioDetailedReportsRemainingByContactID: [UUID: Int] = [:]
    private var directQuicIncomingAudioSuppressionReportedContactIDs: Set<UUID> = []
    private var directQuicIncomingAudioQueueDelayReportsRemainingByKey:
        [DirectQuicIncomingAudioQueueDelayDiagnosticKey: Int] = [:]
    private var directQuicIncomingAudioQueueDelaySuppressionReportedKeys:
        Set<DirectQuicIncomingAudioQueueDelayDiagnosticKey> = []
    private var incomingAudioDropDiagnosticReportsRemainingByKey:
        [IncomingAudioDiagnosticBudgetKey: Int] = [:]
    private var incomingAudioDropDiagnosticSuppressionReportedKeys:
        Set<IncomingAudioDiagnosticBudgetKey> = []
    private var incomingAudioContractDiagnosticReportsRemainingByKey:
        [IncomingAudioDiagnosticBudgetKey: Int] = [:]
    private var incomingAudioContractDiagnosticSuppressionReportedKeys:
        Set<IncomingAudioDiagnosticBudgetKey> = []
    private var lastReportedMediaTransportPolicy: MediaTransportPolicy?
    private var mediaEncryptionSessionsByContactID: [UUID: MediaEncryptionSession] = [:]
    private var mediaEncryptionSendSequenceCountersByContactID: [UUID: MediaEncryptionSendSequenceCounter] = [:]
    private var mediaEncryptionReceiveSequenceByContactID: [UUID: UInt64] = [:]
    private var mediaEncryptionRecentReceiveSequencesByContactID: [UUID: Set<UInt64>] = [:]
    private var mediaEncryptionPlaintextFallbackLogKeys: Set<String> = []
    private var mediaEncryptionUnavailableLogKeys: Set<String> = []
    private var recentIncomingPlaintextAudioPayloads: [RecentIncomingPlaintextAudioPayloadKey: RecentIncomingPlaintextAudioPayload] = [:]
    private var relayWebSocketAudioSequenceByContactID: [UUID: UInt64] = [:]
    private var incomingAudioContinuityByContactID: [UUID: IncomingAudioContinuityState] = [:]
    private var incomingAudioSequenceByContactID: [UUID: IncomingAudioSequenceState] = [:]
    private var incomingPacketLossEstimateByContactID: [UUID: IncomingPacketLossEstimateState] = [:]
    private var incomingAudioPlaybackGateByContactID: [UUID: IncomingAudioPlaybackGateState] = [:]
    private var incomingAudioIngressSummariesByKey: [IncomingAudioIngressSummaryKey: IncomingAudioIngressSummaryState] = [:]
    private var incomingAudioReceiveEpochByContactID: [UUID: UInt64] = [:]
    private var voiceMediaCapabilitiesByContactID: [UUID: VoiceMediaPeerCapabilityEvidence] = [:]
    private var engineLocalAudioSequenceByContactID: [UUID: Int] = [:]
    private var engineRemoteAudioSequenceByContactID: [UUID: Int] = [:]
    private var pendingEncryptedAudioPayloadsByContactID: [UUID: [PendingEncryptedAudioPayload]] = [:]
    private var encryptedAudioRecoveryTasksByContactID: [UUID: Task<Void, Never>] = [:]
    private var foregroundSystemReceiveBufferedAudioChunksByContactID:
        [UUID: [BufferedForegroundReceiveAudioChunk]] = [:]
    private var foregroundSystemReceivePlaybackFallbackTasksByContactID:
        [UUID: Task<Void, Never>] = [:]
    private var foregroundSystemReceivePlaybackFallbackActiveByContactID:
        [UUID: ForegroundSystemReceivePlaybackFallbackState] = [:]

    var hasSession: Bool {
        session != nil
    }

    var hasSendAudioChunk: Bool {
        sendAudioChunk != nil
    }

    var hasActiveMediaRelayClient: Bool {
        mediaRelayClient != nil
    }

    var hasInFlightMediaRelayConnection: Bool {
        mediaRelayConnectionAttempt != nil
    }

    func attach(session: MediaSession, contactID: UUID) {
        self.session = session
        self.contactID = contactID
    }

    func bufferForegroundSystemReceiveAudioChunk(
        _ chunk: BufferedForegroundReceiveAudioChunk,
        for contactID: UUID
    ) -> BufferedForegroundReceiveAudioChunkResult {
        var chunks = foregroundSystemReceiveBufferedAudioChunksByContactID[contactID] ?? []
        chunks.append(chunk)
        let droppedChunkCount: Int
        if chunks.count > Self.maximumForegroundSystemReceiveBufferedAudioChunks {
            droppedChunkCount = chunks.count - Self.maximumForegroundSystemReceiveBufferedAudioChunks
            chunks.removeFirst(droppedChunkCount)
        } else {
            droppedChunkCount = 0
        }
        foregroundSystemReceiveBufferedAudioChunksByContactID[contactID] = chunks
        return BufferedForegroundReceiveAudioChunkResult(
            bufferedChunkCount: chunks.count,
            droppedChunkCount: droppedChunkCount
        )
    }

    func takeForegroundSystemReceiveAudioChunks(
        for contactID: UUID
    ) -> [BufferedForegroundReceiveAudioChunk] {
        let chunks = foregroundSystemReceiveBufferedAudioChunksByContactID[contactID] ?? []
        foregroundSystemReceiveBufferedAudioChunksByContactID[contactID] = nil
        replaceForegroundSystemReceivePlaybackFallbackTask(for: contactID, with: nil)
        return chunks
    }

    func foregroundSystemReceiveBufferedAudioChunkCount(for contactID: UUID) -> Int {
        foregroundSystemReceiveBufferedAudioChunksByContactID[contactID]?.count ?? 0
    }

    func clearForegroundSystemReceiveAudioChunks(for contactID: UUID) {
        foregroundSystemReceiveBufferedAudioChunksByContactID[contactID] = nil
        foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID] = nil
        replaceForegroundSystemReceivePlaybackFallbackTask(for: contactID, with: nil)
    }

    func activateForegroundSystemReceivePlaybackFallback(
        for contactID: UUID,
        channelID: String,
        reason: String
    ) {
        foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID] =
            ForegroundSystemReceivePlaybackFallbackState(
                channelID: channelID,
                reason: reason,
                isPlaybackReady: false
            )
    }

    @discardableResult
    func markForegroundSystemReceivePlaybackFallbackReady(
        for contactID: UUID,
        channelID: String
    ) -> Bool {
        guard var state = foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID],
              state.channelID == channelID else {
            return false
        }
        state.isPlaybackReady = true
        foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID] = state
        return true
    }

    func hasActiveForegroundSystemReceivePlaybackFallback(
        for contactID: UUID,
        channelID: String? = nil
    ) -> Bool {
        guard let state = foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID] else {
            return false
        }
        guard let channelID else { return true }
        return state.channelID == channelID
    }

    func hasReadyForegroundSystemReceivePlaybackFallback(
        for contactID: UUID,
        channelID: String? = nil
    ) -> Bool {
        guard let state = foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID],
              state.isPlaybackReady else {
            return false
        }
        guard let channelID else { return true }
        return state.channelID == channelID
    }

    func deactivateForegroundSystemReceivePlaybackFallback(for contactID: UUID) {
        foregroundSystemReceivePlaybackFallbackActiveByContactID[contactID] = nil
    }

    func hasForegroundSystemReceivePlaybackFallbackTask(for contactID: UUID) -> Bool {
        foregroundSystemReceivePlaybackFallbackTasksByContactID[contactID] != nil
    }

    func replaceForegroundSystemReceivePlaybackFallbackTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        foregroundSystemReceivePlaybackFallbackTasksByContactID[contactID]?.cancel()
        if let task {
            foregroundSystemReceivePlaybackFallbackTasksByContactID[contactID] = task
        } else {
            foregroundSystemReceivePlaybackFallbackTasksByContactID.removeValue(forKey: contactID)
        }
    }

    func updateConnectionState(_ state: MediaConnectionState) {
        connectionState = state
        switch state {
        case .connected, .closed, .idle:
            startupState = .idle
        case .failed(let message):
            if case .starting(let context) = startupState {
                startupState = .failed(
                    MediaSessionStartupFailure(
                        context: context,
                        message: message,
                        occurredAt: Date()
                    )
                )
            }
        case .preparing:
            break
        }
    }

    func replaceSendAudioChunk(with handler: (@Sendable (String) async throws -> Void)?) {
        if handler == nil {
            outgoingAudioSendTargetGate.clear()
        }
        sendAudioChunk = handler
    }

    func markStartupInFlight(_ context: MediaSessionStartupContext) {
        startupState = .starting(context)
        connectionState = .preparing
    }

    func markStartupSucceeded() {
        startupState = .idle
        connectionState = .connected
    }

    func markStartupFailed(
        _ context: MediaSessionStartupContext,
        message: String
    ) {
        startupState = .failed(
            MediaSessionStartupFailure(
                context: context,
                message: message,
                occurredAt: Date()
            )
        )
        connectionState = .failed(message)
    }

    func isStartupInFlight(for context: MediaSessionStartupContext) -> Bool {
        guard case .starting(let activeContext) = startupState else { return false }
        return activeContext == context
    }

    func shouldDelayRetry(
        for context: MediaSessionStartupContext,
        now: Date = Date(),
        cooldown: TimeInterval
    ) -> Bool {
        guard case .failed(let failure) = startupState else { return false }
        guard failure.context == context else { return false }
        return now.timeIntervalSince(failure.occurredAt) < cooldown
    }

    func reset(
        deactivateAudioSession: Bool = true,
        preserveDirectQuic: Bool = false,
        preserveMediaRelay: Bool = false
    ) {
        let preservedVoiceMediaCapabilities = voiceMediaCapabilitiesByContactID
        interactivePrewarmRecoveryTask?.cancel()
        interactivePrewarmRecoveryTask = nil
        if !preserveDirectQuic {
            directQuicPromotionTimeoutTask?.cancel()
            directQuicPromotionTimeoutTask = nil
            directQuicSetupLivenessTask?.cancel()
            directQuicSetupLivenessTask = nil
            directQuicAutoProbeTask?.cancel()
            directQuicAutoProbeTask = nil
            directQuicNetworkMigrationTask?.cancel()
            directQuicNetworkMigrationTask = nil
            directQuicNetworkMigrationProbe = nil
            directQuicProbeController?.cancel(reason: "media-runtime-reset")
            directQuicProbeController = nil
        }
        if !preserveMediaRelay {
            mediaRelayConnectionAttempt?.finish(nil)
            mediaRelayConnectionAttempt = nil
            mediaRelayConnectionKey = nil
            mediaRelayClient?.close()
            mediaRelayClient = nil
        }
        suppressedMediaRelayAudioSendKeys = []
        firstTalkDirectQuicGraceExpiryTasks.forEach { $0.task.cancel() }
        firstTalkDirectQuicGraceExpiryTasks = []
        session?.close(deactivateAudioSession: deactivateAudioSession)
        session = nil
        contactID = nil
        connectionState = .idle
        if preserveDirectQuic {
            // Keep the active direct path surfaced through a media-session handoff.
        } else if preserveMediaRelay {
            transportPathState = activeMediaRelayPathState()
        } else {
            transportPathState = .relay
        }
        if !preserveDirectQuic {
            directQuicUpgrade.reset()
            directQuicWarmPongIDByContactID = [:]
            directQuicWarmPongReceivedAtByContactID = [:]
        }
        if !(preserveDirectQuic || preserveMediaRelay) {
            outboundReceiverPrewarmRequestIDByContactID = [:]
            handledReceiverPrewarmRequestIDs = []
            receiverPrewarmAckRequestIDByContactID = [:]
            receiverPrewarmAckReceivedAtByContactID = [:]
            mediaRelayReceiverPrewarmRequestSendKeys = []
            mediaRelayReceiverPrewarmAckSendKeys = []
        }
        firstTalkDirectQuicGraceEntries = []
        incomingRelayAudioDetailedReportsRemainingByContactID = [:]
        incomingRelayAudioSuppressionReportedContactIDs = []
        directQuicIncomingAudioDetailedReportsRemainingByContactID = [:]
        directQuicIncomingAudioSuppressionReportedContactIDs = []
        directQuicIncomingAudioQueueDelayReportsRemainingByKey = [:]
        directQuicIncomingAudioQueueDelaySuppressionReportedKeys = []
        incomingAudioDropDiagnosticReportsRemainingByKey = [:]
        incomingAudioDropDiagnosticSuppressionReportedKeys = []
        incomingAudioContractDiagnosticReportsRemainingByKey = [:]
        incomingAudioContractDiagnosticSuppressionReportedKeys = []
        lastReportedMediaTransportPolicy = nil
        recentIncomingPlaintextAudioPayloads = [:]
        relayWebSocketAudioSequenceByContactID = [:]
        incomingAudioContinuityByContactID = [:]
        incomingAudioSequenceByContactID = [:]
        incomingPacketLossEstimateByContactID = [:]
        incomingAudioIngressSummariesByKey = [:]
        incomingAudioReceiveEpochByContactID = [:]
        voiceMediaCapabilitiesByContactID = preservedVoiceMediaCapabilities
        engineLocalAudioSequenceByContactID = [:]
        engineRemoteAudioSequenceByContactID = [:]
        outgoingAudioSendTargetGate.clear()
        sendAudioChunk = nil
        startupState = .idle
        pendingEncryptedAudioPayloadsByContactID = [:]
        encryptedAudioRecoveryTasksByContactID.values.forEach { $0.cancel() }
        encryptedAudioRecoveryTasksByContactID = [:]
    }

    func resetIncomingRelayAudioDiagnostics(
        for contactID: UUID,
        detailedReportLimit: Int = 3
    ) {
        incomingRelayAudioDetailedReportsRemainingByContactID[contactID] = max(0, detailedReportLimit)
        incomingRelayAudioSuppressionReportedContactIDs.remove(contactID)
    }

    func consumeIncomingRelayAudioDiagnosticDisposition(
        for contactID: UUID,
        detailedReportLimit: Int = 3
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let currentRemaining =
            incomingRelayAudioDetailedReportsRemainingByContactID[contactID]
            ?? max(0, detailedReportLimit)
        if currentRemaining > 0 {
            incomingRelayAudioDetailedReportsRemainingByContactID[contactID] = currentRemaining - 1
            return .detailed
        }

        if incomingRelayAudioSuppressionReportedContactIDs.insert(contactID).inserted {
            return .suppressedNotice
        }
        return .suppressed
    }

    func consumeDirectQuicIncomingAudioDiagnosticDisposition(
        for contactID: UUID,
        detailedReportLimit: Int = 3
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let currentRemaining =
            directQuicIncomingAudioDetailedReportsRemainingByContactID[contactID]
            ?? max(0, detailedReportLimit)
        if currentRemaining > 0 {
            directQuicIncomingAudioDetailedReportsRemainingByContactID[contactID] = currentRemaining - 1
            return .detailed
        }

        if directQuicIncomingAudioSuppressionReportedContactIDs.insert(contactID).inserted {
            return .suppressedNotice
        }
        return .suppressed
    }

    func resetDirectQuicIncomingAudioQueueDelayDiagnostics(for contactID: UUID) {
        directQuicIncomingAudioQueueDelayReportsRemainingByKey =
            directQuicIncomingAudioQueueDelayReportsRemainingByKey.filter {
                $0.key.contactID != contactID
            }
        directQuicIncomingAudioQueueDelaySuppressionReportedKeys =
            directQuicIncomingAudioQueueDelaySuppressionReportedKeys.filter {
                $0.contactID != contactID
            }
    }

    func consumeDirectQuicIncomingAudioQueueDelayDiagnosticDisposition(
        for contactID: UUID,
        attemptID: String,
        action: String,
        detailedReportLimit: Int = 3
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let key = DirectQuicIncomingAudioQueueDelayDiagnosticKey(
            contactID: contactID,
            attemptID: attemptID,
            action: action
        )
        let currentRemaining =
            directQuicIncomingAudioQueueDelayReportsRemainingByKey[key]
            ?? max(0, detailedReportLimit)
        if currentRemaining > 0 {
            directQuicIncomingAudioQueueDelayReportsRemainingByKey[key] = currentRemaining - 1
            return .detailed
        }

        if directQuicIncomingAudioQueueDelaySuppressionReportedKeys.insert(key).inserted {
            return .suppressedNotice
        }
        return .suppressed
    }

    func consumeIncomingAudioDropDiagnosticDisposition(
        for contactID: UUID,
        transport: IncomingAudioPayloadTransport,
        reason: String,
        detailedReportLimit: Int = 1
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let key = IncomingAudioDiagnosticBudgetKey(
            contactID: contactID,
            transport: transport,
            name: reason
        )
        return Self.consumeDiagnosticDisposition(
            key: key,
            detailedReportLimit: detailedReportLimit,
            reportsRemainingByKey: &incomingAudioDropDiagnosticReportsRemainingByKey,
            suppressionReportedKeys: &incomingAudioDropDiagnosticSuppressionReportedKeys
        )
    }

    func consumeIncomingAudioContractDiagnosticDisposition(
        for contactID: UUID,
        transport: IncomingAudioPayloadTransport,
        invariantID: String,
        detailedReportLimit: Int = 1
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let key = IncomingAudioDiagnosticBudgetKey(
            contactID: contactID,
            transport: transport,
            name: invariantID
        )
        return Self.consumeDiagnosticDisposition(
            key: key,
            detailedReportLimit: detailedReportLimit,
            reportsRemainingByKey: &incomingAudioContractDiagnosticReportsRemainingByKey,
            suppressionReportedKeys: &incomingAudioContractDiagnosticSuppressionReportedKeys
        )
    }

    private static func consumeDiagnosticDisposition(
        key: IncomingAudioDiagnosticBudgetKey,
        detailedReportLimit: Int,
        reportsRemainingByKey: inout [IncomingAudioDiagnosticBudgetKey: Int],
        suppressionReportedKeys: inout Set<IncomingAudioDiagnosticBudgetKey>
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let currentRemaining = reportsRemainingByKey[key] ?? max(0, detailedReportLimit)
        if currentRemaining > 0 {
            reportsRemainingByKey[key] = currentRemaining - 1
            return .detailed
        }

        if suppressionReportedKeys.insert(key).inserted {
            return .suppressedNotice
        }
        return .suppressed
    }

    func shouldReportMediaTransportPolicy(_ policy: MediaTransportPolicy) -> Bool {
        guard lastReportedMediaTransportPolicy != policy else { return false }
        lastReportedMediaTransportPolicy = policy
        return true
    }

    func shouldSendDirectQuicUpgradeRequest(
        for contactID: UUID,
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let sentAt = directQuicUpgradeRequestSentAtByContactID[contactID] else {
            return true
        }
        return now.timeIntervalSince(sentAt) >= minimumInterval
    }

    @discardableResult
    func reserveDirectQuicUpgradeRequestSend(
        for contactID: UUID,
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard shouldSendDirectQuicUpgradeRequest(
            for: contactID,
            minimumInterval: minimumInterval,
            now: now
        ) else {
            return false
        }
        directQuicUpgradeRequestSentAtByContactID[contactID] = now
        return true
    }

    func markDirectQuicUpgradeRequestSent(for contactID: UUID, at date: Date = Date()) {
        directQuicUpgradeRequestSentAtByContactID[contactID] = date
    }

    func clearDirectQuicUpgradeRequestThrottle(for contactID: UUID) {
        directQuicUpgradeRequestSentAtByContactID.removeValue(forKey: contactID)
    }

    func requestInteractivePrewarmAfterAudioDeactivation(for contactID: UUID) {
        pendingInteractivePrewarmAfterAudioDeactivationContactID = contactID
    }

    func takePendingInteractivePrewarmAfterAudioDeactivationContactID() -> UUID? {
        defer { pendingInteractivePrewarmAfterAudioDeactivationContactID = nil }
        return pendingInteractivePrewarmAfterAudioDeactivationContactID
    }

    func replaceInteractivePrewarmRecoveryTask(with task: Task<Void, Never>?) {
        interactivePrewarmRecoveryTask?.cancel()
        interactivePrewarmRecoveryTask = task
    }

    func replaceDirectQuicPromotionTimeoutTask(with task: Task<Void, Never>?) {
        directQuicPromotionTimeoutTask?.cancel()
        directQuicPromotionTimeoutTask = task
    }

    func replaceDirectQuicSetupLivenessTask(with task: Task<Void, Never>?) {
        directQuicSetupLivenessTask?.cancel()
        directQuicSetupLivenessTask = task
    }

    func replaceDirectQuicAutoProbeTask(with task: Task<Void, Never>?) {
        directQuicAutoProbeTask?.cancel()
        directQuicAutoProbeTask = task
    }

    func replaceDirectQuicNetworkMigrationProbe(
        _ probe: DirectQuicNetworkMigrationProbe,
        with task: Task<Void, Never>
    ) {
        directQuicNetworkMigrationTask?.cancel()
        directQuicNetworkMigrationProbe = probe
        directQuicNetworkMigrationTask = task
    }

    @discardableResult
    func clearDirectQuicNetworkMigrationProbe(
        contactID: UUID,
        attemptID: String,
        generation: UInt64? = nil
    ) -> DirectQuicNetworkMigrationProbe? {
        guard let probe = directQuicNetworkMigrationProbe,
              probe.contactID == contactID,
              probe.attemptID == attemptID,
              generation == nil || probe.generation == generation else {
            return nil
        }
        directQuicNetworkMigrationTask?.cancel()
        directQuicNetworkMigrationTask = nil
        directQuicNetworkMigrationProbe = nil
        return probe
    }

    func hasDirectQuicNetworkMigrationProbe(
        contactID: UUID,
        attemptID: String,
        generation: UInt64? = nil
    ) -> Bool {
        guard let probe = directQuicNetworkMigrationProbe,
              probe.contactID == contactID,
              probe.attemptID == attemptID else {
            return false
        }
        return generation == nil || probe.generation == generation
    }

    func firstTalkDirectQuicGrace(
        for contactID: UUID,
        channelID: String
    ) -> FirstTalkDirectQuicGrace? {
        guard let grace = firstTalkDirectQuicGraceEntries.first(where: { $0.contactID == contactID })?.grace,
              grace.channelID == channelID else {
            return nil
        }
        return grace
    }

    func markFirstTalkDirectQuicGraceStartedIfNeeded(
        for contactID: UUID,
        channelID: String,
        now: Date = Date()
    ) -> FirstTalkDirectQuicGrace {
        if let existing = firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        ) {
            return existing
        }
        clearFirstTalkDirectQuicGrace(for: contactID)
        let grace = FirstTalkDirectQuicGrace(
            channelID: channelID,
            startedAt: now,
            expired: false
        )
        firstTalkDirectQuicGraceEntries.append((contactID: contactID, grace: grace))
        return grace
    }

    func expireFirstTalkDirectQuicGrace(
        for contactID: UUID,
        channelID: String
    ) {
        guard var grace = firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        ) else {
            return
        }
        grace.expired = true
        if let index = firstTalkDirectQuicGraceEntries.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceEntries[index] = (contactID: contactID, grace: grace)
        }
        firstTalkDirectQuicGraceExpiryTasks.removeAll { $0.contactID == contactID }
    }

    func replaceFirstTalkDirectQuicGraceExpiryTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        if let index = firstTalkDirectQuicGraceExpiryTasks.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceExpiryTasks[index].task.cancel()
            firstTalkDirectQuicGraceExpiryTasks.remove(at: index)
        }
        if let task {
            firstTalkDirectQuicGraceExpiryTasks.append((contactID: contactID, task: task))
        }
    }

    func hasFirstTalkDirectQuicGraceExpiryTask(for contactID: UUID) -> Bool {
        firstTalkDirectQuicGraceExpiryTasks.contains { $0.contactID == contactID }
    }

    func clearFirstTalkDirectQuicGrace(for contactID: UUID) {
        firstTalkDirectQuicGraceEntries.removeAll { $0.contactID == contactID }
        if let index = firstTalkDirectQuicGraceExpiryTasks.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceExpiryTasks[index].task.cancel()
            firstTalkDirectQuicGraceExpiryTasks.remove(at: index)
        }
    }

    func updateTransportPathState(_ state: MediaTransportPathState) {
        transportPathState = state
    }

    func advanceNetworkPathGeneration() -> UInt64 {
        networkPathGeneration &+= 1
        return networkPathGeneration
    }

    func activeMediaRelayPathState(for transport: TurboMediaRelayTransport? = nil) -> MediaTransportPathState {
        guard mediaRelayClient != nil || transport != nil else { return .relay }
        if transport == .tcpTls {
            return .fastRelayTcp
        }
        return mediaRelayClient?.currentMediaMode() == .tcpOrdered ? .fastRelayTcp : .fastRelay
    }

    func surfacedTransportPathState(
        for transition: DirectQuicUpgradeTransition
    ) -> MediaTransportPathState {
        guard hasActiveMediaRelayClient else {
            return transition.pathState
        }

        switch transition {
        case .directActivated:
            return .direct
        case .enteredPromoting, .updatedPromoting, .recovering, .fellBackToRelay:
            return activeMediaRelayPathState()
        }
    }

    func replaceDirectQuicProbeController(with controller: DirectQuicProbeController?) {
        directQuicProbeController?.cancel(reason: "replaced")
        directQuicProbeController = controller
    }

    func replaceMediaRelayClient(with client: TurboMediaRelayClient?) {
        mediaRelayConnectionAttempt?.finish(nil)
        mediaRelayConnectionAttempt = nil
        mediaRelayConnectionKey = nil
        if mediaRelayClient !== client {
            mediaRelayClient?.close()
        }
        mediaRelayClient = client
    }

    func existingMediaRelayClient(for key: MediaRelayConnectionKey) -> TurboMediaRelayClient? {
        guard mediaRelayConnectionKey == key else { return nil }
        return mediaRelayClient
    }

    func currentMediaRelayConnectionKey() -> MediaRelayConnectionKey? {
        mediaRelayConnectionKey
    }

    func mediaRelayConnectionStart(for key: MediaRelayConnectionKey) -> MediaRelayConnectionStart {
        if let mediaRelayClient,
           mediaRelayConnectionKey == key {
            return .existingClient(mediaRelayClient)
        }
        if let mediaRelayConnectionAttempt,
           mediaRelayConnectionAttempt.key == key {
            return .existingAttempt(mediaRelayConnectionAttempt)
        }
        mediaRelayConnectionAttempt?.finish(nil)
        if mediaRelayConnectionKey != key {
            mediaRelayClient?.close()
            mediaRelayClient = nil
            mediaRelayConnectionKey = nil
        }
        let attempt = MediaRelayConnectionAttempt(key: key)
        mediaRelayConnectionAttempt = attempt
        return .newAttempt(attempt)
    }

    func finishMediaRelayConnectionAttempt(
        _ attempt: MediaRelayConnectionAttempt,
        client: TurboMediaRelayClient?
    ) -> Bool {
        guard mediaRelayConnectionAttempt === attempt else {
            client?.close()
            attempt.finish(nil)
            return false
        }
        mediaRelayConnectionAttempt = nil
        guard let client else {
            attempt.finish(nil)
            return true
        }
        if mediaRelayClient !== client {
            mediaRelayClient?.close()
        }
        mediaRelayClient = client
        mediaRelayConnectionKey = attempt.key
        suppressedMediaRelayAudioSendKeys.remove(attempt.key)
        attempt.finish(client)
        return true
    }

    func scheduleMediaRelayQuicUpgradeProbe(
        for key: MediaRelayConnectionKey,
        generation: UInt64,
        task: Task<Void, Never>
    ) {
        mediaRelayQuicUpgradeProbe?.task.cancel()
        mediaRelayQuicUpgradeProbe = MediaRelayQuicUpgradeProbe(
            key: key,
            generation: generation,
            task: task
        )
    }

    func hasScheduledMediaRelayQuicUpgradeProbe(for key: MediaRelayConnectionKey, generation: UInt64) -> Bool {
        mediaRelayQuicUpgradeProbe?.key == key && mediaRelayQuicUpgradeProbe?.generation == generation
    }

    func clearMediaRelayQuicUpgradeProbe(for key: MediaRelayConnectionKey, generation: UInt64) {
        guard mediaRelayQuicUpgradeProbe?.key == key,
              mediaRelayQuicUpgradeProbe?.generation == generation else {
            return
        }
        mediaRelayQuicUpgradeProbe = nil
    }

    func cancelMediaRelayQuicUpgradeProbe() {
        mediaRelayQuicUpgradeProbe?.task.cancel()
        mediaRelayQuicUpgradeProbe = nil
    }

    func recordMediaRelayQuicUpgradeFailure(for key: MediaRelayConnectionKey) -> Int {
        let failures = (mediaRelayQuicUpgradeFailureCounts[key] ?? 0) + 1
        mediaRelayQuicUpgradeFailureCounts[key] = failures
        return failures
    }

    func clearMediaRelayQuicUpgradeFailures(for key: MediaRelayConnectionKey) {
        mediaRelayQuicUpgradeFailureCounts.removeValue(forKey: key)
    }

    func mediaRelayQuicUpgradeFailureCount(for key: MediaRelayConnectionKey) -> Int {
        mediaRelayQuicUpgradeFailureCounts[key] ?? 0
    }

    func clearMediaRelayClient(matching key: MediaRelayConnectionKey, client: TurboMediaRelayClient) {
        guard mediaRelayConnectionKey == key else { return }
        guard mediaRelayClient === client else { return }
        mediaRelayClient?.close()
        mediaRelayClient = nil
        mediaRelayConnectionKey = nil
        cancelMediaRelayQuicUpgradeProbe()
        mediaRelayQuicUpgradeFailureCounts.removeValue(forKey: key)
        if transportPathState.isFastRelay {
            transportPathState = .relay
        }
    }

    func suppressMediaRelayAudioSend(for key: MediaRelayConnectionKey) {
        suppressedMediaRelayAudioSendKeys.insert(key)
    }

    func clearMediaRelayAudioSendSuppression(for key: MediaRelayConnectionKey) -> Bool {
        suppressedMediaRelayAudioSendKeys.remove(key) != nil
    }

    func isMediaRelayAudioSendSuppressed(for key: MediaRelayConnectionKey) -> Bool {
        suppressedMediaRelayAudioSendKeys.contains(key)
    }

    func receiverPrewarmRequestID(for contactID: UUID) -> String {
        if let existing = outboundReceiverPrewarmRequestIDByContactID[contactID] {
            return existing
        }
        let requestID = UUID().uuidString.lowercased()
        outboundReceiverPrewarmRequestIDByContactID[contactID] = requestID
        return requestID
    }

    func replaceReceiverPrewarmRequestID(for contactID: UUID, requestID: String) {
        let previousRequestID = outboundReceiverPrewarmRequestIDByContactID[contactID]
        outboundReceiverPrewarmRequestIDByContactID[contactID] = requestID
        receiverPrewarmAckRequestIDByContactID[contactID] = nil
        receiverPrewarmAckReceivedAtByContactID[contactID] = nil
        directQuicWarmPongIDByContactID[contactID] = nil
        directQuicWarmPongReceivedAtByContactID[contactID] = nil
        if previousRequestID != requestID {
            clearMediaRelayReceiverPrewarmSendState(for: contactID)
        }
    }

    func receiverPrewarmRequestIsAcknowledged(
        for contactID: UUID,
        maximumAge: TimeInterval? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let requestID = outboundReceiverPrewarmRequestIDByContactID[contactID],
              let ackRequestID = receiverPrewarmAckRequestIDByContactID[contactID] else {
            return false
        }
        guard requestID == ackRequestID else { return false }
        if let maximumAge {
            guard let receivedAt = receiverPrewarmAckReceivedAtByContactID[contactID] else {
                return false
            }
            return now.timeIntervalSince(receivedAt) <= maximumAge
        }
        return true
    }

    func hasReceiverPrewarmRequest(for contactID: UUID) -> Bool {
        outboundReceiverPrewarmRequestIDByContactID[contactID] != nil
    }

    func markReceiverPrewarmRequestHandled(_ requestID: String) -> Bool {
        handledReceiverPrewarmRequestIDs.insert(requestID).inserted
    }

    func markReceiverPrewarmAckReceived(
        contactID: UUID,
        requestID: String,
        receivedAt: Date = Date()
    ) {
        receiverPrewarmAckRequestIDByContactID[contactID] = requestID
        receiverPrewarmAckReceivedAtByContactID[contactID] = receivedAt
    }

    @discardableResult
    func reserveMediaRelayReceiverPrewarmRequestSend(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        requestID: String
    ) -> Bool {
        mediaRelayReceiverPrewarmRequestSendKeys.insert(
            MediaRelayReceiverPrewarmControlKey(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                requestID: requestID
            )
        ).inserted
    }

    func clearMediaRelayReceiverPrewarmRequestSend(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        requestID: String
    ) {
        mediaRelayReceiverPrewarmRequestSendKeys.remove(
            MediaRelayReceiverPrewarmControlKey(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                requestID: requestID
            )
        )
    }

    @discardableResult
    func reserveMediaRelayReceiverPrewarmAckSend(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        requestID: String
    ) -> Bool {
        mediaRelayReceiverPrewarmAckSendKeys.insert(
            MediaRelayReceiverPrewarmControlKey(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                requestID: requestID
            )
        ).inserted
    }

    func clearMediaRelayReceiverPrewarmAckSend(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        requestID: String
    ) {
        mediaRelayReceiverPrewarmAckSendKeys.remove(
            MediaRelayReceiverPrewarmControlKey(
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                requestID: requestID
            )
        )
    }

    private func clearMediaRelayReceiverPrewarmSendState(for contactID: UUID) {
        mediaRelayReceiverPrewarmRequestSendKeys = Set(
            mediaRelayReceiverPrewarmRequestSendKeys.filter { $0.contactID != contactID }
        )
        mediaRelayReceiverPrewarmAckSendKeys = Set(
            mediaRelayReceiverPrewarmAckSendKeys.filter { $0.contactID != contactID }
        )
    }

    func markDirectQuicWarmPongReceived(
        contactID: UUID,
        pingID: String?,
        receivedAt: Date = Date()
    ) {
        directQuicWarmPongIDByContactID[contactID] = pingID ?? ""
        directQuicWarmPongReceivedAtByContactID[contactID] = receivedAt
    }

    func directQuicWarmPongIsFresh(
        for contactID: UUID,
        maximumAge: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard directQuicWarmPongIDByContactID[contactID] != nil,
              let receivedAt = directQuicWarmPongReceivedAtByContactID[contactID] else {
            return false
        }
        return now.timeIntervalSince(receivedAt) <= maximumAge
    }

    func clearReceiverPrewarmState(for contactID: UUID) {
        outboundReceiverPrewarmRequestIDByContactID[contactID] = nil
        receiverPrewarmAckRequestIDByContactID[contactID] = nil
        receiverPrewarmAckReceivedAtByContactID[contactID] = nil
        directQuicWarmPongIDByContactID[contactID] = nil
        directQuicWarmPongReceivedAtByContactID[contactID] = nil
        clearMediaRelayReceiverPrewarmSendState(for: contactID)
    }

    func setMediaEncryptionSession(_ session: MediaEncryptionSession?, for contactID: UUID) {
        mediaEncryptionSessionsByContactID[contactID] = session
        if session == nil {
            mediaEncryptionSendSequenceCountersByContactID[contactID] = nil
        } else if let counter = mediaEncryptionSendSequenceCountersByContactID[contactID] {
            counter.reset()
        } else {
            mediaEncryptionSendSequenceCountersByContactID[contactID] = MediaEncryptionSendSequenceCounter()
        }
        mediaEncryptionReceiveSequenceByContactID[contactID] = nil
        incomingAudioPlaybackGateByContactID[contactID] = nil
    }

    func mediaEncryptionSession(for contactID: UUID) -> MediaEncryptionSession? {
        mediaEncryptionSessionsByContactID[contactID]
    }

    func resetMediaEncryptionState() {
        mediaEncryptionSessionsByContactID = [:]
        mediaEncryptionSendSequenceCountersByContactID = [:]
        mediaEncryptionReceiveSequenceByContactID = [:]
        mediaEncryptionRecentReceiveSequencesByContactID = [:]
        mediaEncryptionPlaintextFallbackLogKeys = []
        mediaEncryptionUnavailableLogKeys = []
        recentIncomingPlaintextAudioPayloads = [:]
        incomingAudioPlaybackGateByContactID = [:]
        incomingAudioReceiveEpochByContactID = [:]
        foregroundSystemReceiveBufferedAudioChunksByContactID = [:]
        foregroundSystemReceivePlaybackFallbackTasksByContactID.values.forEach { $0.cancel() }
        foregroundSystemReceivePlaybackFallbackTasksByContactID = [:]
        foregroundSystemReceivePlaybackFallbackActiveByContactID = [:]
        pendingEncryptedAudioPayloadsByContactID = [:]
        encryptedAudioRecoveryTasksByContactID.values.forEach { $0.cancel() }
        encryptedAudioRecoveryTasksByContactID = [:]
    }

    func takeShouldLogMediaEncryptionPlaintextFallback(
        contactID: UUID,
        direction: String
    ) -> Bool {
        mediaEncryptionPlaintextFallbackLogKeys.insert("\(direction):\(contactID.uuidString)").inserted
    }

    func takeShouldLogMediaEncryptionUnavailable(
        contactID: UUID,
        reason: String
    ) -> Bool {
        mediaEncryptionUnavailableLogKeys.insert("\(reason):\(contactID.uuidString)").inserted
    }

    func nextMediaEncryptionSendSequence(for contactID: UUID) -> UInt64 {
        mediaEncryptionSendSequenceCounter(for: contactID).next()
    }

    func mediaEncryptionSendSequenceCounter(for contactID: UUID) -> MediaEncryptionSendSequenceCounter {
        if let counter = mediaEncryptionSendSequenceCountersByContactID[contactID] {
            return counter
        }
        let counter = MediaEncryptionSendSequenceCounter()
        mediaEncryptionSendSequenceCountersByContactID[contactID] = counter
        return counter
    }

    func nextRelayWebSocketAudioSequence(for contactID: UUID) -> UInt64 {
        let sequence = (relayWebSocketAudioSequenceByContactID[contactID] ?? 0) + 1
        relayWebSocketAudioSequenceByContactID[contactID] = sequence
        return sequence
    }

    func nextEngineLocalAudioSequence(for contactID: UUID) -> Int {
        let sequence = engineLocalAudioSequenceByContactID[contactID] ?? 0
        engineLocalAudioSequenceByContactID[contactID] = sequence + 1
        return sequence
    }

    func nextEngineRemoteAudioSequence(for contactID: UUID) -> Int {
        let sequence = engineRemoteAudioSequenceByContactID[contactID] ?? 0
        engineRemoteAudioSequenceByContactID[contactID] = sequence + 1
        return sequence
    }

    func observeIncomingAudioIngress(
        contactID: UUID,
        transport: IncomingAudioPayloadTransport,
        sequenceNumber: UInt64?,
        localQueueDelayNanoseconds: UInt64,
        freshnessDecision: String,
        playbackAccepted: Bool,
        reportEvery sampleInterval: Int = 64
    ) -> IncomingAudioIngressSummary? {
        let key = IncomingAudioIngressSummaryKey(contactID: contactID, transport: transport)
        var state = incomingAudioIngressSummariesByKey[key] ?? IncomingAudioIngressSummaryState()
        let previousFreshnessDecision = state.lastFreshnessDecision
        let previousPlaybackDecision = state.lastPlaybackDecision
        state.sampleCount += 1
        state.samplesSinceLastReport += 1
        state.maxLocalQueueDelayNanoseconds = max(
            state.maxLocalQueueDelayNanoseconds,
            localQueueDelayNanoseconds
        )
        state.lastSequenceNumber = sequenceNumber
        state.lastFreshnessDecision = freshnessDecision
        state.lastPlaybackDecision = playbackAccepted ? "accepted" : "rejected"
        if freshnessDecision.hasPrefix("dropped") {
            state.droppedCount += 1
        } else {
            state.acceptedCount += 1
        }
        if playbackAccepted {
            state.playbackAcceptedCount += 1
        } else {
            state.playbackRejectedCount += 1
        }

        let playbackDecision = playbackAccepted ? "accepted" : "rejected"
        let decisionChanged =
            state.sampleCount > 1
            && (
                freshnessDecision != previousFreshnessDecision
                || playbackDecision != previousPlaybackDecision
            )
        let shouldReport =
            state.sampleCount == 1
            || decisionChanged
            || state.samplesSinceLastReport >= max(1, sampleInterval)
        guard shouldReport else {
            incomingAudioIngressSummariesByKey[key] = state
            return nil
        }
        state.samplesSinceLastReport = 0
        incomingAudioIngressSummariesByKey[key] = state
        return IncomingAudioIngressSummary(
            transport: transport,
            sampleCount: state.sampleCount,
            acceptedCount: state.acceptedCount,
            droppedCount: state.droppedCount,
            playbackAcceptedCount: state.playbackAcceptedCount,
            playbackRejectedCount: state.playbackRejectedCount,
            maxLocalQueueDelayNanoseconds: state.maxLocalQueueDelayNanoseconds,
            lastSequenceNumber: state.lastSequenceNumber,
            lastFreshnessDecision: state.lastFreshnessDecision,
            lastPlaybackDecision: state.lastPlaybackDecision
        )
    }

    func resetMediaEncryptionReceiveSequence(for contactID: UUID) {
        mediaEncryptionReceiveSequenceByContactID[contactID] = nil
        mediaEncryptionRecentReceiveSequencesByContactID[contactID] = nil
        engineRemoteAudioSequenceByContactID[contactID] = nil
        incomingAudioPlaybackGateByContactID[contactID] = nil
        incomingAudioReceiveEpochByContactID[contactID] =
            (incomingAudioReceiveEpochByContactID[contactID] ?? 0) + 1
        incomingAudioIngressSummariesByKey = incomingAudioIngressSummariesByKey.filter {
            $0.key.contactID != contactID
        }
        incomingAudioDropDiagnosticReportsRemainingByKey =
            incomingAudioDropDiagnosticReportsRemainingByKey.filter {
                $0.key.contactID != contactID
            }
        incomingAudioDropDiagnosticSuppressionReportedKeys =
            incomingAudioDropDiagnosticSuppressionReportedKeys.filter {
                $0.contactID != contactID
            }
        incomingAudioContractDiagnosticReportsRemainingByKey =
            incomingAudioContractDiagnosticReportsRemainingByKey.filter {
                $0.key.contactID != contactID
            }
        incomingAudioContractDiagnosticSuppressionReportedKeys =
            incomingAudioContractDiagnosticSuppressionReportedKeys.filter {
                $0.contactID != contactID
            }
    }

    func incomingAudioReceiveEpoch(for contactID: UUID) -> UInt64 {
        incomingAudioReceiveEpochByContactID[contactID] ?? 0
    }

    enum MediaEncryptionReceiveSequenceAcceptance: Equatable {
        case accepted
        case duplicate
        case replayOrReordered
    }

    func acceptMediaEncryptionReceiveSequence(
        _ sequenceNumber: UInt64,
        for contactID: UUID
    ) -> MediaEncryptionReceiveSequenceAcceptance {
        if mediaEncryptionRecentReceiveSequencesByContactID[contactID]?.contains(sequenceNumber) == true {
            return .duplicate
        }
        guard let lastSequence = mediaEncryptionReceiveSequenceByContactID[contactID] else {
            mediaEncryptionReceiveSequenceByContactID[contactID] = sequenceNumber
            rememberMediaEncryptionReceiveSequence(sequenceNumber, for: contactID)
            return .accepted
        }
        if sequenceNumber > lastSequence {
            mediaEncryptionReceiveSequenceByContactID[contactID] = sequenceNumber
            rememberMediaEncryptionReceiveSequence(sequenceNumber, for: contactID)
            return .accepted
        }

        guard lastSequence - sequenceNumber <= Self.mediaEncryptionReceiveSequenceWindow else {
            return .replayOrReordered
        }

        rememberMediaEncryptionReceiveSequence(sequenceNumber, for: contactID)
        return .accepted
    }

    private func rememberMediaEncryptionReceiveSequence(
        _ sequenceNumber: UInt64,
        for contactID: UUID
    ) {
        var recent = mediaEncryptionRecentReceiveSequencesByContactID[contactID] ?? []
        recent.insert(sequenceNumber)
        if recent.count > Self.mediaEncryptionRecentReceiveSequenceLimit,
           let minimum = recent.min() {
            recent.remove(minimum)
        }
        mediaEncryptionRecentReceiveSequencesByContactID[contactID] = recent
    }

    struct PlaintextAudioDuplicateDecision: Equatable {
        let shouldAccept: Bool
        let previousTransport: IncomingAudioPayloadTransport?
    }

    func acceptIncomingPlaintextAudioPayload(
        contactID: UUID,
        channelID: String,
        fromDeviceID: String,
        transport: IncomingAudioPayloadTransport,
        digest: String,
        now: Date = Date(),
        duplicateWindow: TimeInterval = 1.0
    ) -> PlaintextAudioDuplicateDecision {
        let cutoff = now.addingTimeInterval(-duplicateWindow)
        recentIncomingPlaintextAudioPayloads = recentIncomingPlaintextAudioPayloads.filter {
            $0.value.receivedAt >= cutoff
        }
        let key = RecentIncomingPlaintextAudioPayloadKey(
            contactID: contactID,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            digest: digest
        )
        if let existing = recentIncomingPlaintextAudioPayloads[key],
           existing.transport != transport,
           now.timeIntervalSince(existing.receivedAt) <= duplicateWindow {
            return PlaintextAudioDuplicateDecision(
                shouldAccept: false,
                previousTransport: existing.transport
            )
        }
        recentIncomingPlaintextAudioPayloads[key] = RecentIncomingPlaintextAudioPayload(
            transport: transport,
            receivedAt: now
        )
        return PlaintextAudioDuplicateDecision(shouldAccept: true, previousTransport: nil)
    }

    func observeIncomingAudioContinuity(
        contactID: UUID,
        transport: IncomingAudioPayloadTransport,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> IncomingAudioContinuityObservation {
        let previous = incomingAudioContinuityByContactID[contactID]
        incomingAudioContinuityByContactID[contactID] = IncomingAudioContinuityState(
            receivedAtNanoseconds: nowNanoseconds,
            transport: transport
        )
        let gapNanoseconds = previous.map {
            nowNanoseconds >= $0.receivedAtNanoseconds
                ? nowNanoseconds - $0.receivedAtNanoseconds
                : 0
        }
        return IncomingAudioContinuityObservation(
            previousReceivedAtNanoseconds: previous?.receivedAtNanoseconds,
            receivedAtNanoseconds: nowNanoseconds,
            gapNanoseconds: gapNanoseconds,
            previousTransport: previous?.transport
        )
    }

    func clearIncomingAudioContinuity(for contactID: UUID) {
        incomingAudioContinuityByContactID[contactID] = nil
    }

    func observeIncomingAudioSequence(
        contactID: UUID,
        transport: IncomingAudioPayloadTransport,
        sequenceNumber: UInt64
    ) -> IncomingAudioSequenceObservation {
        let previous = incomingAudioSequenceByContactID[contactID]
        let shouldAdvanceSequenceState =
            !transport.isUnreliablePacketMedia
            || previous.map { sequenceNumber > $0.sequenceNumber } ?? true
        if shouldAdvanceSequenceState {
            incomingAudioSequenceByContactID[contactID] = IncomingAudioSequenceState(
                sequenceNumber: sequenceNumber,
                transport: transport
            )
        }
        let missingSequenceCount = previous.flatMap { previous -> UInt64? in
            guard sequenceNumber > previous.sequenceNumber else { return nil }
            let sequenceAdvance = sequenceNumber - previous.sequenceNumber
            guard sequenceAdvance > 1 else { return nil }
            return sequenceAdvance - 1
        }
        let observation = IncomingAudioSequenceObservation(
            previousSequenceNumber: previous?.sequenceNumber,
            sequenceNumber: sequenceNumber,
            missingSequenceCount: missingSequenceCount,
            previousTransport: previous?.transport
        )
        if transport.isUnreliablePacketMedia {
            var lossEstimate = incomingPacketLossEstimateByContactID[contactID]
                ?? IncomingPacketLossEstimateState()
            lossEstimate.observe(missingSequenceCount: missingSequenceCount)
            incomingPacketLossEstimateByContactID[contactID] = lossEstimate
        }
        return observation
    }

    func clearIncomingAudioSequence(for contactID: UUID) {
        incomingAudioSequenceByContactID[contactID] = nil
        incomingPacketLossEstimateByContactID[contactID] = nil
    }

    func observedPacketLossPercent(for contactID: UUID) -> Int {
        incomingPacketLossEstimateByContactID[contactID]?.percent ?? 0
    }

    func acceptIncomingAudioForPlayback(
        contactID: UUID,
        sequenceNumber: UInt64?,
        transport: IncomingAudioPayloadTransport,
        frameDurationNanoseconds: UInt64? = nil,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> IncomingAudioPlaybackDecision {
        guard let sequenceNumber else { return .play }
        let policy = IncomingAudioPlaybackPolicy.live(
            for: transport,
            frameDurationNanoseconds: frameDurationNanoseconds
        )
        guard let previous = incomingAudioPlaybackGateByContactID[contactID] else {
            incomingAudioPlaybackGateByContactID[contactID] = IncomingAudioPlaybackGateState(
                sequenceNumber: sequenceNumber,
                receivedAtNanoseconds: nowNanoseconds,
                transport: transport,
                recentPacketSequences: [sequenceNumber]
            )
            return .play
        }

        switch policy.ordering {
        case .unorderedPacket:
            if previous.recentPacketSequences.contains(sequenceNumber) {
                return .drop(.duplicateOrStaleSequence)
            }
            var next = previous
            next.sequenceNumber = max(previous.sequenceNumber, sequenceNumber)
            next.receivedAtNanoseconds = nowNanoseconds
            next.transport = transport
            next.recentPacketSequences.insert(sequenceNumber)
            if next.sequenceNumber > 256 {
                let floor = next.sequenceNumber - 256
                next.recentPacketSequences = next.recentPacketSequences.filter { $0 >= floor }
            }
            incomingAudioPlaybackGateByContactID[contactID] = next
            return .play

        case .orderedReliable(let graceFrames):
            guard sequenceNumber > previous.sequenceNumber else {
                return .drop(.duplicateOrStaleSequence)
            }
            if policy.dropsOrderedBacklog, nowNanoseconds > previous.receivedAtNanoseconds {
                let elapsedNanoseconds = nowNanoseconds - previous.receivedAtNanoseconds
                if elapsedNanoseconds > policy.maximumHoldNanoseconds {
                    let expectedAdvance = elapsedNanoseconds / max(1, policy.frameDurationNanoseconds)
                    let catchupFloor = previous.sequenceNumber
                        + expectedAdvance
                        - min(expectedAdvance, graceFrames)
                    if sequenceNumber <= catchupFloor {
                        return .drop(
                            .orderedBacklog(
                                elapsedNanoseconds: elapsedNanoseconds,
                                expectedSequenceFloor: catchupFloor
                            )
                        )
                    }
                }
            }
            var next = previous
            next.sequenceNumber = sequenceNumber
            next.receivedAtNanoseconds = nowNanoseconds
            next.transport = transport
            next.recentPacketSequences.insert(sequenceNumber)
            if next.sequenceNumber > 256 {
                let floor = next.sequenceNumber - 256
                next.recentPacketSequences = next.recentPacketSequences.filter { $0 >= floor }
            }
            incomingAudioPlaybackGateByContactID[contactID] = next
            return .play
        }
    }

    func markVoiceMediaCapabilities(
        _ capabilities: VoiceMediaCapabilities,
        for contactID: UUID,
        peerDeviceID: String,
        source: String,
        observedAt: Date = Date()
    ) -> Bool {
        let evidence = VoiceMediaPeerCapabilityEvidence(
            capabilities: capabilities,
            observedAt: observedAt,
            source: source,
            peerDeviceID: peerDeviceID
        )
        let changed = voiceMediaCapabilitiesByContactID[contactID] != evidence
        voiceMediaCapabilitiesByContactID[contactID] = evidence
        return changed
    }

    func voiceMediaCapabilityEvidence(
        for contactID: UUID
    ) -> VoiceMediaPeerCapabilityEvidence? {
        voiceMediaCapabilitiesByContactID[contactID]
    }

    func outboundVoiceMediaPayloadFormat(for contactID: UUID) -> VoiceMediaPayloadFormat {
        VoiceMediaNegotiator.outboundPayloadFormat()
    }

    func enqueuePendingEncryptedAudioPayload(
        _ payload: PendingEncryptedAudioPayload,
        for contactID: UUID,
        maxCount: Int
    ) -> Int {
        var pending = pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
        pending.append(payload)
        if pending.count > maxCount {
            pending.removeFirst(pending.count - maxCount)
        }
        pendingEncryptedAudioPayloadsByContactID[contactID] = pending
        return pending.count
    }

    func drainPendingEncryptedAudioPayloads(for contactID: UUID) -> [PendingEncryptedAudioPayload] {
        let pending = pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
        pendingEncryptedAudioPayloadsByContactID[contactID] = nil
        return pending
    }

    func pendingEncryptedAudioPayloads(for contactID: UUID) -> [PendingEncryptedAudioPayload] {
        pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
    }

    func discardPendingEncryptedAudioPayloads(for contactID: UUID) -> Int {
        let count = pendingEncryptedAudioPayloadsByContactID[contactID]?.count ?? 0
        pendingEncryptedAudioPayloadsByContactID[contactID] = nil
        return count
    }

    func hasEncryptedAudioRecoveryTask(for contactID: UUID) -> Bool {
        encryptedAudioRecoveryTasksByContactID[contactID] != nil
    }

    func replaceEncryptedAudioRecoveryTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        encryptedAudioRecoveryTasksByContactID[contactID]?.cancel()
        encryptedAudioRecoveryTasksByContactID[contactID] = task
    }

    func clearEncryptedAudioRecoveryTask(for contactID: UUID) {
        encryptedAudioRecoveryTasksByContactID[contactID] = nil
    }
}

enum MediaTransportPathState: String, Codable, Equatable {
    case relay
    case fastRelay = "fast-relay"
    case fastRelayTcp = "fast-relay-tcp"
    case promoting
    case direct
    case recovering

    var label: String {
        switch self {
        case .relay:
            return "Relayed"
        case .fastRelay:
            return "Fast Relay"
        case .fastRelayTcp:
            return "Fast Relay TCP"
        case .promoting:
            return "Promoting"
        case .direct:
            return "Direct"
        case .recovering:
            return "Recovering"
        }
    }

    var showsSecureIcon: Bool {
        switch self {
        case .relay, .fastRelay, .fastRelayTcp, .direct:
            return true
        case .promoting, .recovering:
            return false
        }
    }

    var isFastRelay: Bool {
        self == .fastRelay || self == .fastRelayTcp
    }
}

enum MediaTransportReadinessEvidence: String, Equatable {
    case directQuicActive
    case mediaRelayClient
    case webSocketConnected
    case localHTTPBackend
    case webSocketUnsupportedBackend
    case controlPlaneReconnectGrace
}

enum MediaTransportUnavailableReason: String, Equatable {
    case backendUnavailable
    case webSocketDisconnected
    case directPromotionNoFallback
    case directRecoveryNoFallback
    case noTransportReady
}

enum MediaTransportFallbackState: Equatable {
    case ready(path: MediaTransportPathState, evidence: MediaTransportReadinessEvidence)
    case unavailable(reason: MediaTransportUnavailableReason)

    static let defaultRelay = MediaTransportFallbackState.ready(
        path: .relay,
        evidence: .webSocketConnected
    )

    var isReady: Bool {
        switch self {
        case .ready:
            return true
        case .unavailable:
            return false
        }
    }

    var pathState: MediaTransportPathState? {
        switch self {
        case .ready(let path, _):
            return path
        case .unavailable:
            return nil
        }
    }

    var evidenceValue: String {
        switch self {
        case .ready(_, let evidence):
            return evidence.rawValue
        case .unavailable(let reason):
            return reason.rawValue
        }
    }
}

enum SelectedMediaTransportState: Equatable {
    case direct(fallback: MediaTransportFallbackState)
    case fastRelay(evidence: MediaTransportReadinessEvidence)
    case fastRelayTcp(evidence: MediaTransportReadinessEvidence)
    case relay(evidence: MediaTransportReadinessEvidence)
    case promoting(fallback: MediaTransportFallbackState)
    case recovering(reason: String?, fallback: MediaTransportFallbackState)
    case unavailable(reason: MediaTransportUnavailableReason)

    static let defaultRelay = SelectedMediaTransportState.relay(evidence: .webSocketConnected)

    init(
        pathState: MediaTransportPathState,
        directActive: Bool,
        fallback: MediaTransportFallbackState,
        recoveryReason: String? = nil
    ) {
        if directActive {
            self = .direct(fallback: fallback)
            return
        }

        switch pathState {
        case .direct:
            self = fallback.isReady
                ? .promoting(fallback: fallback)
                : .unavailable(reason: .noTransportReady)
        case .fastRelay:
            self = .fastRelay(evidence: .mediaRelayClient)
        case .fastRelayTcp:
            self = .fastRelayTcp(evidence: .mediaRelayClient)
        case .relay:
            switch fallback {
            case .ready(_, let evidence):
                self = .relay(evidence: evidence)
            case .unavailable(let reason):
                self = .unavailable(reason: reason)
            }
        case .promoting:
            self = .promoting(fallback: fallback)
        case .recovering:
            self = .recovering(reason: recoveryReason, fallback: fallback)
        }
    }

    init(
        localRelayTransportReady: Bool,
        directMediaPathActive: Bool
    ) {
        let fallback: MediaTransportFallbackState = localRelayTransportReady
            ? .defaultRelay
            : .unavailable(reason: .webSocketDisconnected)
        self.init(
            pathState: directMediaPathActive ? .direct : .relay,
            directActive: directMediaPathActive,
            fallback: fallback
        )
    }

    var directMediaPathActive: Bool {
        switch self {
        case .direct:
            return true
        case .fastRelay, .fastRelayTcp, .relay, .promoting, .recovering, .unavailable:
            return false
        }
    }

    var fallbackReady: Bool {
        switch self {
        case .direct(let fallback),
             .promoting(let fallback),
             .recovering(_, let fallback):
            return fallback.isReady
        case .fastRelay, .fastRelayTcp, .relay:
            return true
        case .unavailable:
            return false
        }
    }

    var isReadyForTransmit: Bool {
        directMediaPathActive || fallbackReady
    }

    var pathState: MediaTransportPathState {
        switch self {
        case .direct:
            return .direct
        case .fastRelay:
            return .fastRelay
        case .fastRelayTcp:
            return .fastRelayTcp
        case .relay:
            return .relay
        case .promoting:
            return .promoting
        case .recovering:
            return .recovering
        case .unavailable:
            return .relay
        }
    }

    var diagnosticsValue: String {
        switch self {
        case .direct:
            return "direct"
        case .fastRelay:
            return "fast-relay"
        case .fastRelayTcp:
            return "fast-relay-tcp"
        case .relay:
            return "relay"
        case .promoting:
            return "promoting"
        case .recovering:
            return "recovering"
        case .unavailable:
            return "unavailable"
        }
    }

    var fallbackDiagnosticsValue: String {
        switch self {
        case .direct(let fallback),
             .promoting(let fallback),
             .recovering(_, let fallback):
            return fallback.evidenceValue
        case .fastRelay(let evidence),
             .fastRelayTcp(let evidence),
             .relay(let evidence):
            return evidence.rawValue
        case .unavailable(let reason):
            return reason.rawValue
        }
    }
}

struct FirstTalkReadinessProjection: Equatable {
    let blockers: Set<FirstTalkReadinessBlocker>

    init(blockers: Set<FirstTalkReadinessBlocker> = []) {
        self.blockers = blockers
    }

    init(
        localMediaWarm: Bool,
        receiverWarm: Bool,
        transportWarm: Bool
    ) {
        var blockers: Set<FirstTalkReadinessBlocker> = []
        if !localMediaWarm {
            blockers.insert(.localMedia)
        }
        if !receiverWarm {
            blockers.insert(.receiver)
        }
        if !transportWarm {
            blockers.insert(.transport)
        }
        self.init(blockers: blockers)
    }

    var localMediaWarm: Bool {
        !blockers.contains(.localMedia)
    }

    var receiverWarm: Bool {
        !blockers.contains(.receiver)
    }

    var transportWarm: Bool {
        !blockers.contains(.transport)
    }

    var isReady: Bool {
        blockers.isEmpty
    }
}

nonisolated enum FirstTalkReadinessBlocker: Hashable {
    case localMedia
    case receiver
    case transport
}

struct MediaSessionStartupContext: Equatable {
    let contactID: UUID
    let activationMode: MediaSessionActivationMode
    let startupMode: MediaSessionStartupMode
}

struct MediaSessionStartupFailure: Equatable {
    let context: MediaSessionStartupContext
    let message: String
    let occurredAt: Date
}

enum MediaSessionStartupState: Equatable {
    case idle
    case starting(MediaSessionStartupContext)
    case failed(MediaSessionStartupFailure)
}

enum ReceiverAudioReadinessPublicationBasis: Equatable {
    case lifecycle
    case channelRefresh
    case webSocketReconnect

    var suppressesEquivalentLifecyclePublish: Bool {
        switch self {
        case .channelRefresh, .webSocketReconnect:
            return true
        case .lifecycle:
            return false
        }
    }
}

struct ReceiverAudioReadinessPublication: Equatable {
    let isReady: Bool
    let peerWasRoutable: Bool
    let basis: ReceiverAudioReadinessPublicationBasis
    let telemetry: ConversationParticipantTelemetry?

    func isSemanticallyEquivalent(to other: ReceiverAudioReadinessPublication) -> Bool {
        isReady == other.isReady
            && peerWasRoutable == other.peerWasRoutable
    }
}

struct BackendServices {
    let client: TurboBackendClient
    let criticalHTTPClient: TurboBackendCriticalHTTPClient
    let currentUserID: String?
    let mode: String
    let telemetryEnabled: Bool

    var supportsWebSocket: Bool { client.supportsWebSocket }
    var supportsDirectQuicUpgrade: Bool { client.supportsDirectQuicUpgrade }
    var supportsMediaEndToEndEncryption: Bool { client.supportsMediaEndToEndEncryption }
    var supportsSignalSessionIds: Bool { client.supportsSignalSessionIds }
    var supportsTransmitIds: Bool { client.supportsTransmitIds }
    var supportsProjectionEpochs: Bool { client.supportsProjectionEpochs }
    var isWebSocketConnected: Bool { client.isWebSocketConnected }
    var isWebSocketSuspended: Bool { client.isWebSocketSuspended }
    var webSocketSessionID: String? { client.webSocketSessionID }
    var controlCommandTransportPolicy: TurboControlCommandTransportPolicy { client.controlCommandTransportPolicy }
    var shouldSendHTTPPresenceHeartbeat: Bool {
        if controlCommandTransportPolicy == .httpOnly {
            return true
        }
        guard supportsWebSocket else {
            return true
        }
        guard client.canSendPresenceCommandsOverWebSocket else {
            return true
        }
        return !isWebSocketConnected || webSocketSessionID == nil
    }
    var deviceID: String { client.deviceID }
    var usesLocalHTTPBackend: Bool { mode == "local-http" }
    var directQuicPolicy: TurboDirectQuicPolicy? { client.directQuicPolicy }

    func fetchRuntimeConfig() async throws -> TurboBackendRuntimeConfig {
        try await client.fetchRuntimeConfig()
    }

    func authenticate() async throws -> TurboAuthSessionResponse {
        try await client.authenticate()
    }

    func registerDevice(
        label: String?,
        alertPushToken: String?,
        alertPushEnvironment: TurboAPNSEnvironment?,
        directQuicIdentity: DirectQuicIdentityRegistrationMetadata? = nil,
        mediaEncryptionIdentity: MediaEncryptionIdentityRegistrationMetadata? = nil
    ) async throws -> TurboDeviceRegistrationResponse {
        try await client.registerDevice(
            label: label,
            alertPushToken: alertPushToken,
            alertPushEnvironment: alertPushEnvironment,
            directQuicIdentity: directQuicIdentity,
            mediaEncryptionIdentity: mediaEncryptionIdentity
        )
    }

    func resetDevState() async throws -> TurboResetStateResponse {
        try await client.resetDevState()
    }

    func resetAllDevState() async throws -> TurboResetStateResponse {
        try await client.resetAllDevState()
    }

    func seedDevUsers() async throws -> TurboSeedResponse {
        try await client.seedDevUsers()
    }

    func uploadDiagnostics(
        _ payload: TurboDiagnosticsUploadRequest,
        timeoutInterval: TimeInterval = 30
    ) async throws -> TurboDiagnosticsUploadResponse {
        try await client.uploadDiagnostics(payload, timeoutInterval: timeoutInterval)
    }

    func latestDiagnostics(deviceId: String) async throws -> TurboLatestDiagnosticsResponse {
        try await client.latestDiagnostics(deviceId: deviceId)
    }

    func uploadTelemetry(_ payload: TurboTelemetryEventRequest) async throws -> TurboTelemetryUploadResponse {
        try await client.uploadTelemetry(payload)
    }

    func heartbeatPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.heartbeatPresence()
    }

    func foregroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.foregroundPresence()
    }

    func offlinePresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.offlinePresence()
    }

    func backgroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.backgroundPresence()
    }

    func lookupUser(handle: String) async throws -> TurboUserLookupResponse {
        try await client.lookupUser(handle: handle)
    }

    func resolveIdentity(reference: String) async throws -> TurboUserLookupResponse {
        try await client.resolveIdentity(reference: reference)
    }

    func rememberContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboRememberContactResponse {
        try await client.rememberContact(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func forgetContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboForgetContactResponse {
        try await client.forgetContact(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func lookupPresence(handle: String) async throws -> TurboUserPresenceResponse {
        try await client.lookupPresence(handle: handle)
    }

    func contactSummaries() async throws -> [TurboContactSummaryResponse] {
        try await client.contactSummaries()
    }

    func directChannel(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboDirectChannelResponse {
        try await client.directChannel(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func joinChannel(
        channelId: String,
        operationId: String? = nil,
        deviceSessionProof: BackendJoinDeviceSessionProof? = nil
    ) async throws -> TurboJoinResponse {
        try await client.joinChannel(
            channelId: channelId,
            operationId: operationId,
            deviceSessionProof: deviceSessionProof
        )
    }

    func leaveChannel(channelId: String, operationId: String? = nil) async throws -> TurboLeaveResponse {
        try await client.leaveChannel(channelId: channelId, operationId: operationId)
    }

    func channelState(channelId: String) async throws -> TurboChannelStateResponse {
        try await client.channelState(channelId: channelId)
    }

    func channelReadiness(channelId: String) async throws -> TurboChannelReadinessResponse {
        try await client.channelReadiness(channelId: channelId)
    }

    func publishReceiverAudioReadiness(
        channelId: String,
        type: TurboSignalKind,
        payload: String
    ) async throws -> TurboReceiverAudioReadinessResponse {
        try await client.publishReceiverAudioReadiness(
            channelId: channelId,
            type: type,
            payload: payload
        )
    }

    func createBeep(
        friendHandle: String? = nil,
        friendUserId: String? = nil,
        operationId: String? = nil,
        subject: String? = nil
    ) async throws -> TurboBeepResponse {
        try await client.createBeep(
            friendHandle: friendHandle,
            friendUserId: friendUserId,
            operationId: operationId,
            subject: subject
        )
    }

    func incomingBeeps() async throws -> [TurboBeepResponse] {
        try await client.incomingBeeps()
    }

    func outgoingBeeps() async throws -> [TurboBeepResponse] {
        try await client.outgoingBeeps()
    }

    func acceptBeep(beepId: String) async throws -> TurboBeepResponse {
        try await client.acceptBeep(beepId: beepId)
    }

    func declineBeep(beepId: String) async throws -> TurboBeepResponse {
        try await client.declineBeep(beepId: beepId)
    }

    func cancelBeep(beepId: String) async throws -> TurboBeepResponse {
        try await client.cancelBeep(beepId: beepId)
    }

    func uploadEphemeralToken(
        channelId: String,
        token: String,
        apnsEnvironment: TurboAPNSEnvironment
    ) async throws -> TurboTokenResponse {
        try await client.uploadEphemeralToken(
            channelId: channelId,
            token: token,
            apnsEnvironment: apnsEnvironment
        )
    }

    func revokeEphemeralToken(channelId: String) async throws -> TurboRevokeTokenResponse {
        try await client.revokeEphemeralToken(channelId: channelId)
    }

    func beginTransmit(
        channelId: String,
        request leaseRequest: TurboBeginTransmitLeaseRequest
    ) async throws -> TurboBeginTransmitResponse {
        try await criticalHTTPClient.beginTransmit(channelId: channelId, request: leaseRequest)
    }

    func endTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboEndTransmitResponse {
        try await client.endTransmit(channelId: channelId, transmitId: transmitId)
    }

    func renewTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboRenewTransmitResponse {
        try await client.renewTransmit(channelId: channelId, transmitId: transmitId)
    }

    func connectWebSocket() {
        client.connectWebSocket()
    }

    func disconnectWebSocket() {
        client.disconnectWebSocket()
    }

    func suspendWebSocket() {
        client.suspendWebSocket()
    }

    func resumeWebSocket() {
        client.resumeWebSocket()
    }

    func forceReconnectWebSocket() {
        client.forceReconnectWebSocket()
    }

    func ensureWebSocketConnected() {
        client.ensureWebSocketConnected()
    }

    func waitForWebSocketConnection() async throws {
        try await client.waitForWebSocketConnection()
    }

    func sendSignal(_ envelope: TurboSignalEnvelope) async throws {
        try await client.sendSignal(envelope)
    }
}

@MainActor
struct MediaServices {
    let session: () -> MediaSession?
    let contactID: () -> UUID?
    let hasSession: () -> Bool
    let sendAudioChunk: () -> (@Sendable (String) async throws -> Void)?
    let attach: (MediaSession, UUID) -> Void
    let updateConnectionState: (MediaConnectionState) -> Void
    let isStartupInFlight: (MediaSessionStartupContext) -> Bool
    let shouldDelayRetry: (MediaSessionStartupContext, TimeInterval) -> Bool
    let markStartupInFlight: (MediaSessionStartupContext) -> Void
    let markStartupSucceeded: () -> Void
    let markStartupFailed: (MediaSessionStartupContext, String) -> Void
    let replaceSendAudioChunk: ((@Sendable (String) async throws -> Void)?) -> Void
    let reset: (Bool, Bool, Bool) -> Void
}
