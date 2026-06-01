import Foundation

enum DirectQuicNominatedPathSource: String, Equatable {
    case outboundProbe
    case inboundConnection
}

struct DirectQuicNominatedPath: Equatable {
    let attemptId: String
    let source: DirectQuicNominatedPathSource
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: Int
    let remoteCandidateKind: TurboDirectQuicCandidateKind?
}

enum DirectQuicFailureCategory: String, Equatable {
    case connectivity
    case security
    case peerRejected
    case signaling
    case localEnvironment
    case unknown
}

struct DirectQuicRetryBackoffRequest: Equatable {
    let milliseconds: Int
    let reason: String
    let category: DirectQuicFailureCategory
    let attemptId: String?
}

struct DirectQuicRetryBackoffState: Equatable {
    let notBefore: Date
    let milliseconds: Int
    let reason: String
    let category: DirectQuicFailureCategory
    let attemptId: String?
}

enum DirectQuicRetryBackoffPolicy {
    private static let maxConnectivityBackoffMilliseconds = 300_000
    private static let maxExtendedBackoffMilliseconds = 120_000
    private static let maxElevatedBackoffMilliseconds = 60_000

    static func category(for reason: String) -> DirectQuicFailureCategory {
        let normalizedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedReason.isEmpty else {
            return .unknown
        }

        if normalizedReason.contains("certificate")
            || normalizedReason.contains("fingerprint") {
            return .security
        }
        if normalizedReason.contains("rejected")
            || normalizedReason == "identity-missing" {
            return .peerRejected
        }
        if normalizedReason.contains("timeout")
            || normalizedReason.contains("path-lost")
            || normalizedReason.contains("network-path")
            || normalizedReason.contains("probe-connect")
            || normalizedReason.contains("no-viable-candidate") {
            return .connectivity
        }
        if normalizedReason.contains("send-failed")
            || normalizedReason.contains("websocket") {
            return .signaling
        }
        if normalizedReason.contains("offer-failed")
            || normalizedReason.contains("activation-failed")
            || normalizedReason.contains("missing-probe-controller")
            || normalizedReason.contains("local probe context")
            || normalizedReason.contains("identity label")
            || normalizedReason.contains("identity ")
            || normalizedReason.contains("listener failed") {
            return .localEnvironment
        }
        return .unknown
    }

    static func milliseconds(
        baseMilliseconds: Int,
        category: DirectQuicFailureCategory,
        priorFailureCount: Int = 0
    ) -> Int {
        guard baseMilliseconds > 0 else { return 0 }

        let base: Int
        let maximum: Int
        switch category {
        case .connectivity, .unknown:
            base = baseMilliseconds
            maximum = maxConnectivityBackoffMilliseconds
        case .signaling, .localEnvironment:
            base = baseMilliseconds * 2
            maximum = maxElevatedBackoffMilliseconds
        case .security, .peerRejected:
            base = baseMilliseconds * 4
            maximum = maxExtendedBackoffMilliseconds
        }
        let exponent = min(max(priorFailureCount, 0), 6)
        let multiplier = 1 << exponent
        return min(base * multiplier, maximum)
    }
}

struct DirectQuicUpgradeAttempt: Equatable {
    let contactID: UUID
    let channelID: String
    var attemptId: String
    var peerDeviceID: String?
    var startedAt: Date
    var lastUpdatedAt: Date
    var isDirectActive: Bool
    var remoteOffer: TurboDirectQuicOfferPayload?
    var localOffer: TurboDirectQuicOfferPayload?
    var remoteAnswer: TurboDirectQuicAnswerPayload?
    var remoteCandidates: [TurboDirectQuicCandidate]
    var remoteCandidateCount: Int
    var remoteEndOfCandidates: Bool
    var nominatedPath: DirectQuicNominatedPath?
    var lastHangupReason: String?
    var networkPathGeneration: UInt64
}

enum DirectQuicUpgradeTransition: Equatable {
    case enteredPromoting(DirectQuicUpgradeAttempt)
    case updatedPromoting(DirectQuicUpgradeAttempt)
    case directActivated(DirectQuicUpgradeAttempt)
    case recovering(previousAttemptId: String, reason: String)
    case fellBackToRelay(previousAttemptId: String?, reason: String)

    var pathState: MediaTransportPathState {
        switch self {
        case .enteredPromoting, .updatedPromoting:
            return .promoting
        case .directActivated:
            return .direct
        case .recovering:
            return .recovering
        case .fellBackToRelay:
            return .relay
        }
    }

    var attemptId: String? {
        switch self {
        case .enteredPromoting(let attempt),
             .updatedPromoting(let attempt),
             .directActivated(let attempt):
            return attempt.attemptId
        case .recovering(let previousAttemptId, _):
            return previousAttemptId
        case .fellBackToRelay(let previousAttemptId, _):
            return previousAttemptId
        }
    }

    var reason: String? {
        switch self {
        case .recovering(_, let reason), .fellBackToRelay(_, let reason):
            return reason
        case .enteredPromoting, .updatedPromoting, .directActivated:
            return nil
        }
    }
}

final class DirectQuicUpgradeRuntimeState {
    private(set) var attemptByContactID: [UUID: DirectQuicUpgradeAttempt] = [:]
    private var retryBackoffStateByContactID: [UUID: DirectQuicRetryBackoffState] = [:]
    private var retryFailureStateByContactID: [UUID: (category: DirectQuicFailureCategory, count: Int)] = [:]
    private var fastConnectivityRetryCountByContactID: [UUID: Int] = [:]

    func reset() {
        attemptByContactID = [:]
        retryBackoffStateByContactID = [:]
        retryFailureStateByContactID = [:]
        fastConnectivityRetryCountByContactID = [:]
    }

    func attempt(for contactID: UUID) -> DirectQuicUpgradeAttempt? {
        attemptByContactID[contactID]
    }

    func retryBackoffRemaining(
        for contactID: UUID,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let backoffState = retryBackoffState(for: contactID, now: now) else {
            return nil
        }
        return backoffState.notBefore.timeIntervalSince(now)
    }

    func retryBackoffState(
        for contactID: UUID,
        now: Date = Date()
    ) -> DirectQuicRetryBackoffState? {
        guard let backoffState = retryBackoffStateByContactID[contactID] else {
            return nil
        }
        let remaining = backoffState.notBefore.timeIntervalSince(now)
        guard remaining > 0 else {
            retryBackoffStateByContactID.removeValue(forKey: contactID)
            return nil
        }
        return backoffState
    }

    func canBeginLocalAttempt(
        for contactID: UUID,
        now: Date = Date()
    ) -> Bool {
        retryBackoffRemaining(for: contactID, now: now) == nil
    }

    func applyRetryBackoff(
        for contactID: UUID,
        request: DirectQuicRetryBackoffRequest?,
        now: Date = Date()
    ) {
        guard let request, request.milliseconds > 0 else { return }
        let previousFailure = retryFailureStateByContactID[contactID]
        let nextFailureCount = previousFailure?.category == request.category
            ? (previousFailure?.count ?? 0) + 1
            : 1
        retryFailureStateByContactID[contactID] = (
            category: request.category,
            count: nextFailureCount
        )
        retryBackoffStateByContactID[contactID] = DirectQuicRetryBackoffState(
            notBefore: now.addingTimeInterval(TimeInterval(request.milliseconds) / 1_000),
            milliseconds: request.milliseconds,
            reason: request.reason,
            category: request.category,
            attemptId: request.attemptId
        )
    }

    func consumeFastConnectivityRetry(
        for contactID: UUID,
        maxAttempts: Int
    ) -> Int? {
        guard maxAttempts > 0 else { return nil }
        let consumed = fastConnectivityRetryCountByContactID[contactID] ?? 0
        guard consumed < maxAttempts else { return nil }
        let next = consumed + 1
        fastConnectivityRetryCountByContactID[contactID] = next
        return next
    }

    func fastConnectivityRetryCount(for contactID: UUID) -> Int {
        fastConnectivityRetryCountByContactID[contactID] ?? 0
    }

    func retryFailureCount(
        for contactID: UUID,
        category: DirectQuicFailureCategory
    ) -> Int {
        guard let failureState = retryFailureStateByContactID[contactID],
              failureState.category == category else {
            return 0
        }
        return failureState.count
    }

    func clearRetryBackoff(for contactID: UUID) {
        retryBackoffStateByContactID.removeValue(forKey: contactID)
        retryFailureStateByContactID.removeValue(forKey: contactID)
    }

    func beginLocalAttempt(
        contactID: UUID,
        channelID: String,
        attemptID: String,
        peerDeviceID: String?,
        networkPathGeneration: UInt64 = 0,
        now: Date = Date()
    ) -> DirectQuicUpgradeTransition {
        retryBackoffStateByContactID.removeValue(forKey: contactID)
        let existingAttempt = attemptByContactID[contactID]
        var attempt = currentAttempt(
            for: contactID,
            channelID: channelID,
            attemptID: attemptID,
            peerDeviceID: peerDeviceID,
            networkPathGeneration: networkPathGeneration,
            now: now
        )
        attempt.peerDeviceID = peerDeviceID
        attempt.networkPathGeneration = networkPathGeneration
        attempt.lastUpdatedAt = now
        attemptByContactID[contactID] = attempt
        if existingAttempt?.attemptId == attemptID {
            return .updatedPromoting(attempt)
        }
        return .enteredPromoting(attempt)
    }

    func observeIncomingSignal(
        contactID: UUID,
        channelID: String,
        signal: TurboDirectQuicSignalPayload,
        now: Date = Date()
    ) -> DirectQuicUpgradeTransition {
        switch signal {
        case .offer(let payload):
            var attempt = currentAttempt(
                for: contactID,
                channelID: channelID,
                attemptID: payload.attemptId,
                peerDeviceID: payload.fromDeviceId,
                networkPathGeneration: 0,
                now: now
            )
            let isNewAttempt = attempt.remoteOffer == nil
            attempt.peerDeviceID = payload.fromDeviceId
            attempt.remoteOffer = payload
            attempt.remoteCandidates = mergedRemoteCandidates(
                existing: attempt.remoteCandidates,
                new: payload.candidates
            )
            attempt.remoteCandidateCount = attempt.remoteCandidates.count
            attempt.lastUpdatedAt = now
            attemptByContactID[contactID] = attempt
            return updatedTransition(for: attempt, isNewAttempt: isNewAttempt)

        case .answer(let payload):
            if !payload.accepted {
                let existingAttempt = attemptByContactID.removeValue(forKey: contactID)
                return .fellBackToRelay(
                    previousAttemptId: existingAttempt?.attemptId ?? payload.attemptId,
                    reason: payload.rejectionReason ?? "answer-rejected"
                )
            }
            var attempt = currentAttempt(
                for: contactID,
                channelID: channelID,
                attemptID: payload.attemptId,
                peerDeviceID: attemptByContactID[contactID]?.peerDeviceID,
                networkPathGeneration: attemptByContactID[contactID]?.networkPathGeneration ?? 0,
                now: now
            )
            let isNewAttempt = attempt.remoteAnswer == nil
            attempt.remoteAnswer = payload
            attempt.remoteCandidates = mergedRemoteCandidates(
                existing: attempt.remoteCandidates,
                new: payload.candidates
            )
            attempt.remoteCandidateCount = attempt.remoteCandidates.count
            attempt.lastUpdatedAt = now
            attemptByContactID[contactID] = attempt
            return updatedTransition(for: attempt, isNewAttempt: isNewAttempt)

        case .candidate(let payload):
            var attempt = currentAttempt(
                for: contactID,
                channelID: channelID,
                attemptID: payload.attemptId,
                peerDeviceID: attemptByContactID[contactID]?.peerDeviceID,
                networkPathGeneration: attemptByContactID[contactID]?.networkPathGeneration ?? 0,
                now: now
            )
            if let candidate = payload.candidate {
                attempt.remoteCandidates = mergedRemoteCandidates(
                    existing: attempt.remoteCandidates,
                    new: [candidate]
                )
            }
            attempt.remoteCandidateCount = attempt.remoteCandidates.count
            attempt.remoteEndOfCandidates = attempt.remoteEndOfCandidates || payload.endOfCandidates
            attempt.lastUpdatedAt = now
            attemptByContactID[contactID] = attempt
            return updatedTransition(for: attempt, isNewAttempt: false)

        case .hangup(let payload):
            let existingAttempt = attemptByContactID.removeValue(forKey: contactID)
            let reason = payload.reason
            if existingAttempt?.isDirectActive == true {
                return .recovering(previousAttemptId: payload.attemptId, reason: reason)
            }
            return .fellBackToRelay(previousAttemptId: existingAttempt?.attemptId ?? payload.attemptId, reason: reason)
        }
    }

    func markDirectPathActivated(
        for contactID: UUID,
        attemptID: String,
        nominatedPath: DirectQuicNominatedPath,
        now: Date = Date()
    ) -> DirectQuicUpgradeTransition? {
        guard var attempt = attemptByContactID[contactID], attempt.attemptId == attemptID else {
            return nil
        }
        attempt.isDirectActive = true
        attempt.nominatedPath = nominatedPath
        attempt.lastUpdatedAt = now
        attemptByContactID[contactID] = attempt
        retryFailureStateByContactID.removeValue(forKey: contactID)
        fastConnectivityRetryCountByContactID.removeValue(forKey: contactID)
        return .directActivated(attempt)
    }

    func markDirectPathLost(
        for contactID: UUID,
        reason: String,
        now: Date = Date()
    ) -> DirectQuicUpgradeTransition? {
        guard var attempt = attemptByContactID.removeValue(forKey: contactID), attempt.isDirectActive else {
            return nil
        }
        attempt.lastHangupReason = reason
        attempt.lastUpdatedAt = now
        return .recovering(previousAttemptId: attempt.attemptId, reason: reason)
    }

    func clearAttempt(
        for contactID: UUID,
        fallbackReason: String,
        retryBackoff: DirectQuicRetryBackoffRequest? = nil,
        now: Date = Date()
    ) -> DirectQuicUpgradeTransition {
        let removedAttempt = attemptByContactID.removeValue(forKey: contactID)
        applyRetryBackoff(for: contactID, request: retryBackoff, now: now)
        return .fellBackToRelay(previousAttemptId: removedAttempt?.attemptId, reason: fallbackReason)
    }

    private func currentAttempt(
        for contactID: UUID,
        channelID: String,
        attemptID: String,
        peerDeviceID: String?,
        networkPathGeneration: UInt64,
        now: Date
    ) -> DirectQuicUpgradeAttempt {
        if var existing = attemptByContactID[contactID], existing.attemptId == attemptID {
            existing.lastUpdatedAt = now
            existing.networkPathGeneration = networkPathGeneration
            if let peerDeviceID {
                existing.peerDeviceID = peerDeviceID
            }
            return existing
        }

        return DirectQuicUpgradeAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptId: attemptID,
            peerDeviceID: peerDeviceID,
            startedAt: now,
            lastUpdatedAt: now,
            isDirectActive: false,
            remoteOffer: nil,
            localOffer: nil,
            remoteAnswer: nil,
            remoteCandidates: [],
            remoteCandidateCount: 0,
            remoteEndOfCandidates: false,
            nominatedPath: nil,
            lastHangupReason: nil,
            networkPathGeneration: networkPathGeneration
        )
    }

    func markLocalOffer(
        _ offer: TurboDirectQuicOfferPayload,
        for contactID: UUID,
        now: Date = Date()
    ) {
        guard var attempt = attemptByContactID[contactID],
              attempt.attemptId == offer.attemptId else {
            return
        }
        attempt.localOffer = offer
        attempt.lastUpdatedAt = now
        attemptByContactID[contactID] = attempt
    }

    private func updatedTransition(
        for attempt: DirectQuicUpgradeAttempt,
        isNewAttempt: Bool
    ) -> DirectQuicUpgradeTransition {
        if attempt.isDirectActive {
            return .directActivated(attempt)
        }
        return isNewAttempt ? .enteredPromoting(attempt) : .updatedPromoting(attempt)
    }

    private func mergedRemoteCandidates(
        existing: [TurboDirectQuicCandidate],
        new: [TurboDirectQuicCandidate]
    ) -> [TurboDirectQuicCandidate] {
        var merged = existing
        var seen = Set(existing.map(Self.remoteCandidateKey))
        for candidate in new {
            let key = Self.remoteCandidateKey(candidate)
            guard seen.insert(key).inserted else { continue }
            merged.append(candidate)
        }
        return merged
    }

    nonisolated private static func remoteCandidateKey(_ candidate: TurboDirectQuicCandidate) -> String {
        [
            candidate.kind.rawValue,
            candidate.transport.lowercased(),
            candidate.address.lowercased(),
            String(candidate.port),
            candidate.relatedAddress?.lowercased() ?? "",
            candidate.relatedPort.map(String.init) ?? "",
            candidate.foundation,
        ].joined(separator: "|")
    }
}
