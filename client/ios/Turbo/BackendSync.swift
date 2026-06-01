import Foundation

enum BackendConnectionPhase: Equatable {
    case starting
    case connected(mode: String, handle: String)
    case unavailable(message: String)

    var hasEstablishedConnection: Bool {
        switch self {
        case .connected:
            return true
        case .starting, .unavailable:
            return false
        }
    }

    var statusMessage: String {
        switch self {
        case .starting:
            return "Starting backend..."
        case .connected(let mode, let handle):
            return "Backend connected (\(mode)) as \(handle)"
        case .unavailable(let message):
            return "Backend unavailable: \(message)"
        }
    }
}

struct BackendSyncState: Equatable {
    var connectionPhase: BackendConnectionPhase = .starting
    var statusMessage: String = BackendConnectionPhase.starting.statusMessage
    var contactSummaries: [UUID: TurboContactSummaryResponse] = [:]
    var channelStates: [UUID: TurboChannelStateResponse] = [:]
    var channelReadiness: [UUID: TurboChannelReadinessResponse] = [:]
    var incomingBeeps: [UUID: TurboBeepResponse] = [:]
    var outgoingBeeps: [UUID: TurboBeepResponse] = [:]
    var handledIncomingBeepSourceKeys: [UUID: Set<String>] = [:]
    var handledIncomingBeepCounts: [UUID: Int] = [:]
    var beepCooldownDeadlines: [UUID: Date] = [:]
    var beepCooldownSourceKeys: [UUID: String] = [:]

    var hasEstablishedConnection: Bool {
        connectionPhase.hasEstablishedConnection
    }

    mutating func markBootstrapConnected(mode: String, handle: String) {
        connectionPhase = .connected(mode: mode, handle: handle)
        statusMessage = connectionPhase.statusMessage
    }

    mutating func markBootstrapUnavailable(message: String) {
        connectionPhase = .unavailable(message: message)
        statusMessage = connectionPhase.statusMessage
    }

    nonisolated static func beepSourceKey(for beep: TurboBeepResponse) -> String {
        "\(beep.beepId)|\(beep.requestCount)|\(beep.updatedAt ?? beep.createdAt)"
    }

    nonisolated static func beepCooldownSourceKey(for beep: TurboBeepResponse) -> String {
        "\(beep.beepId)|\(beep.requestCount)"
    }

    nonisolated static func normalizedBeepCooldownSourceKey(_ sourceKey: String) -> String {
        let parts = sourceKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return sourceKey }
        return "\(parts[0])|\(parts[1])"
    }

    private func beepCooldownSourceKey(for beep: TurboBeepResponse) -> String {
        Self.beepCooldownSourceKey(for: beep)
    }

    private func handledIncomingBeepCount(for contactID: UUID) -> Int {
        handledIncomingBeepCounts[contactID] ?? 0
    }

    func incomingBeepIsHandled(_ beep: TurboBeepResponse, for contactID: UUID) -> Bool {
        let sourceKey = Self.beepSourceKey(for: beep)
        if handledIncomingBeepSourceKeys[contactID]?.contains(sourceKey) == true {
            return true
        }
        if handledIncomingBeepSourceKeys[contactID]?.isEmpty == false {
            return false
        }
        return beep.requestCount <= handledIncomingBeepCount(for: contactID)
    }

    private func visibleIncomingBeeps(
        from incoming: [UUID: TurboBeepResponse]
    ) -> [UUID: TurboBeepResponse] {
        incoming.filter { contactID, beep in
            !incomingBeepIsHandled(beep, for: contactID)
        }
    }

    func visibleIncomingBeep(for contactID: UUID) -> TurboBeepResponse? {
        guard let beep = incomingBeeps[contactID],
              !incomingBeepIsHandled(beep, for: contactID) else {
            return nil
        }
        return beep
    }

    func visibleIncomingBeepsByContactID() -> [UUID: TurboBeepResponse] {
        visibleIncomingBeeps(from: incomingBeeps)
    }

    func summaryIncomingBeepIsHandled(for contactID: UUID) -> Bool {
        guard let requestCount = contactSummaries[contactID]?.beepThreadProjection.requestCount else {
            return false
        }
        return requestCount <= handledIncomingBeepCount(for: contactID)
    }

    mutating func markIncomingBeepHandled(
        contactID: UUID,
        beep: TurboBeepResponse?,
        requestCount: Int
    ) {
        let normalizedRequestCount = max(requestCount, beep?.requestCount ?? 0)
        if normalizedRequestCount > 0 {
            handledIncomingBeepCounts[contactID] = max(
                handledIncomingBeepCount(for: contactID),
                normalizedRequestCount
            )
        }

        if let beep {
            handledIncomingBeepSourceKeys[contactID, default: []].insert(Self.beepSourceKey(for: beep))
        }

        if let currentBeep = incomingBeeps[contactID],
           incomingBeepIsHandled(currentBeep, for: contactID) {
            incomingBeeps[contactID] = nil
        }
    }

    private func shouldApplyProjectionEpoch(incoming: String?, existing: String?) -> Bool {
        guard let incoming else { return true }
        guard let existing else { return true }
        return incoming >= existing
    }

    func shouldAcceptChannelReadiness(_ readiness: TurboChannelReadinessResponse, for contactID: UUID) -> Bool {
        if let channelState = channelStates[contactID],
           channelState.membership == .absent,
           !shouldApplyProjectionEpoch(incoming: readiness.stateEpoch, existing: channelState.stateEpoch) {
            return false
        }
        return shouldApplyProjectionEpoch(
            incoming: readiness.stateEpoch,
            existing: channelReadiness[contactID]?.stateEpoch
        )
    }

    mutating func applyContactSummaries(_ summaries: [UUID: TurboContactSummaryResponse]) {
        contactSummaries = summaries
        let contactsWithConversationChannels: Set<UUID> = Set(
            summaries.compactMap { contactID, summary in
                guard let channelID = summary.channelId, !channelID.isEmpty else { return nil }
                return contactID
            }
        )
        channelStates = channelStates.filter { contactsWithConversationChannels.contains($0.key) }
        channelReadiness = channelReadiness.filter { contactsWithConversationChannels.contains($0.key) }

        for (contactID, summary) in summaries {
            if !summary.beepThreadProjection.hasIncomingBeep {
                handledIncomingBeepSourceKeys[contactID] = nil
                handledIncomingBeepCounts[contactID] = nil
            }

            guard summary.membership == .absent,
                  let summaryChannelID = summary.channelId,
                  let existingChannelState = channelStates[contactID],
                  existingChannelState.channelId == summaryChannelID else {
                continue
            }

            let existingChannelStateLooksActive =
                existingChannelState.membership.hasLocalMembership
                || existingChannelState.membership.hasPeerMembership
                || existingChannelState.membership.peerDeviceConnected
                || {
                    switch existingChannelState.conversationStatus {
                    case .waitingForPeer, .ready, .transmitting, .receiving:
                        return true
                    case .idle, .outgoingBeep, .incomingBeep, nil:
                        return false
                    }
                }()

            guard !existingChannelStateLooksActive else {
                continue
            }

            channelStates[contactID] = existingChannelState.settingMembership(.absent)
            channelReadiness[contactID] = nil
        }
    }

    mutating func clearContactSummaries() {
        contactSummaries = [:]
    }

    mutating func applyChannelState(_ channelState: TurboChannelStateResponse, for contactID: UUID) {
        guard shouldApplyProjectionEpoch(
            incoming: channelState.stateEpoch,
            existing: channelStates[contactID]?.stateEpoch
        ) else {
            return
        }
        channelStates[contactID] = channelState
        if channelState.membership == .absent {
            channelReadiness[contactID] = nil
        }
        if !channelState.beepThreadProjection.hasIncomingBeep {
            incomingBeeps[contactID] = nil
        }
        if !channelState.beepThreadProjection.hasOutgoingBeep {
            outgoingBeeps[contactID] = nil
            beepCooldownDeadlines[contactID] = nil
            beepCooldownSourceKeys[contactID] = nil
        }
    }

    mutating func applyChannelReadiness(_ readiness: TurboChannelReadinessResponse, for contactID: UUID) {
        if channelStates[contactID]?.membership == .absent,
           readiness.peerTargetDeviceId == nil {
            channelReadiness[contactID] = nil
            return
        }
        guard shouldAcceptChannelReadiness(readiness, for: contactID) else {
            return
        }
        channelReadiness[contactID] = readiness
    }

    mutating func invalidateRemoteReceiverReadinessAfterWebSocketIdle() {
        channelReadiness = channelReadiness.mapValues { readiness in
            guard readiness.remoteAudioReadiness == .ready else { return readiness }

            let downgradedReadiness: RemoteAudioReadinessState
            switch readiness.remoteWakeCapability {
            case .wakeCapable:
                downgradedReadiness = .waiting
            case .unavailable:
                downgradedReadiness = .unknown
            }

            return readiness.settingRemoteAudioReadiness(downgradedReadiness)
        }
    }

    mutating func clearChannelState(for contactID: UUID) {
        channelStates[contactID] = nil
        channelReadiness[contactID] = nil
    }

    mutating func applyBeeps(
        incoming: [UUID: TurboBeepResponse],
        outgoing: [UUID: TurboBeepResponse],
        now: Date = .now
    ) {
        incomingBeeps = visibleIncomingBeeps(from: incoming)
        outgoingBeeps = outgoing
        reconcileOutgoingBeepCooldowns(now: now)
    }

    mutating func applyPartialBeeps(
        incoming: [UUID: TurboBeepResponse]?,
        outgoing: [UUID: TurboBeepResponse]?,
        now: Date = .now
    ) {
        if let incoming {
            incomingBeeps = visibleIncomingBeeps(from: incoming)
        }
        if let outgoing {
            outgoingBeeps = outgoing
        }
        reconcileOutgoingBeepCooldowns(now: now)
    }

    private mutating func reconcileOutgoingBeepCooldowns(now: Date) {
        beepCooldownDeadlines = beepCooldownDeadlines.filter { outgoingBeeps.keys.contains($0.key) && $0.value > now }
        beepCooldownSourceKeys = beepCooldownSourceKeys.filter { outgoingBeeps.keys.contains($0.key) }

        for (contactID, beep) in outgoingBeeps {
            let sourceKey = beepCooldownSourceKey(for: beep)
            let existingSourceKey = beepCooldownSourceKeys[contactID]
                .map(Self.normalizedBeepCooldownSourceKey)
            if existingSourceKey != sourceKey {
                beepCooldownDeadlines[contactID] = now.addingTimeInterval(30)
            }
            beepCooldownSourceKeys[contactID] = sourceKey
        }
    }

    mutating func clearBeeps() {
        incomingBeeps = [:]
        outgoingBeeps = [:]
        handledIncomingBeepSourceKeys = [:]
        handledIncomingBeepCounts = [:]
        beepCooldownDeadlines = [:]
        beepCooldownSourceKeys = [:]
    }

    mutating func reset(statusMessage: String) {
        connectionPhase = .starting
        self.statusMessage = statusMessage
        contactSummaries = [:]
        channelStates = [:]
        channelReadiness = [:]
        incomingBeeps = [:]
        outgoingBeeps = [:]
        handledIncomingBeepSourceKeys = [:]
        handledIncomingBeepCounts = [:]
        beepCooldownDeadlines = [:]
        beepCooldownSourceKeys = [:]
    }

    mutating func applyRecoverableSyncFailureStatus(_ message: String) {
        guard connectionPhase.hasEstablishedConnection else {
            statusMessage = message
            return
        }

        guard !isReconnectStatusMessage else { return }
        statusMessage = "Connected (retrying sync)"
    }

    var isReconnectStatusMessage: Bool {
        statusMessage == "Connecting WebSocket..." || statusMessage == "Reconnecting WebSocket..."
    }

    var requestContactIDs: Set<UUID> {
        let summaryIncoming = contactSummaries.compactMap { contactID, summary in
            summary.beepThreadProjection.hasIncomingBeep
                && !summaryIncomingBeepIsHandled(for: contactID)
                ? contactID
                : nil
        }
        let summaryOutgoing = contactSummaries.compactMap { contactID, summary in
            summary.beepThreadProjection.hasOutgoingBeep ? contactID : nil
        }
        return Set(summaryIncoming)
            .union(summaryOutgoing)
            .union(incomingBeeps.keys)
            .union(outgoingBeeps.keys)
    }
}
