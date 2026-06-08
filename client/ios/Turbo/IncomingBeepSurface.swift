import Foundation

nonisolated struct BeepSurfaceKey: Hashable {
    let contactID: UUID
    let requestCount: Int

    init(contactID: UUID, requestCount: Int) {
        self.contactID = contactID
        self.requestCount = max(requestCount, 1)
    }

    var stableID: String {
        "\(contactID.uuidString):\(requestCount)"
    }
}

nonisolated enum BeepSurfaceSource: String, Hashable {
    case backendBeep
    case relationshipProjection
    case foregroundNotification

    init(surfaceSource: String) {
        switch surfaceSource {
        case "relationship":
            self = .relationshipProjection
        case "notification", "foreground-notification":
            self = .foregroundNotification
        default:
            self = .backendBeep
        }
    }
}

nonisolated struct CanonicalIncomingBeep: Equatable, Identifiable {
    let key: BeepSurfaceKey
    let contactName: String
    let contactHandle: String
    let contactIsOnline: Bool
    let beepID: String
    let channelID: String?
    let subject: String?
    let sentAt: String?
    let sources: Set<BeepSurfaceSource>
    let recencyKey: String

    var id: String { key.stableID }

    var surface: IncomingBeepSurface {
        IncomingBeepSurface(
            contactID: key.contactID,
            beepID: beepID,
            contactName: contactName,
            contactHandle: contactHandle,
            contactIsOnline: contactIsOnline,
            requestCount: key.requestCount,
            recencyKey: recencyKey,
            channelID: channelID,
            subject: subject,
            sentAt: sentAt
        )
    }

    func merging(_ other: CanonicalIncomingBeep) -> CanonicalIncomingBeep {
        guard key == other.key else { return self }

        let preferred = presentationPriority >= other.presentationPriority ? self : other
        let fallback = preferred == self ? other : self
        return CanonicalIncomingBeep(
            key: key,
            contactName: preferred.contactName,
            contactHandle: preferred.contactHandle,
            contactIsOnline: preferred.contactIsOnline,
            beepID: preferred.beepID,
            channelID: preferred.channelID ?? fallback.channelID,
            subject: preferred.subject ?? fallback.subject,
            sentAt: preferred.sentAt ?? fallback.sentAt,
            sources: sources.union(other.sources),
            recencyKey: max(recencyKey, other.recencyKey)
        )
    }

    private var presentationPriority: Int {
        if sources.contains(.backendBeep) { return 3 }
        if sources.contains(.foregroundNotification) { return 2 }
        return 1
    }

    var isEligibleForSurfaceByPresence: Bool {
        contactIsOnline || sources.contains(.foregroundNotification)
    }

    func wasSentBeforeForegroundBannerEpoch(_ epochStartedAt: Date?) -> Bool {
        guard let epochStartedAt,
              let sentAt,
              let sentDate = Self.parseBackendInstant(sentAt) else {
            return false
        }
        return sentDate < epochStartedAt
    }

    private static func parseBackendInstant(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let withoutZone = String(text.dropLast())
        let parts = withoutZone.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let baseText = String(parts[0]) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let baseDate = formatter.date(from: baseText) else { return nil }
        guard parts.count == 2 else { return baseDate }

        let fractionalDigits = parts[1].prefix { $0 >= "0" && $0 <= "9" }
        guard !fractionalDigits.isEmpty else { return baseDate }
        let scale = pow(10.0, Double(fractionalDigits.count))
        let fractionalSeconds = (Double(fractionalDigits) ?? 0) / scale
        return baseDate.addingTimeInterval(fractionalSeconds)
    }
}

nonisolated struct IncomingBeepSurface: Equatable, Identifiable {
    let contactID: UUID
    let beepID: String
    let contactName: String
    let contactHandle: String
    let contactIsOnline: Bool
    let requestCount: Int
    let recencyKey: String
    let channelID: String?
    let subject: String?
    let sentAt: String?

    init(
        contactID: UUID,
        beepID: String,
        contactName: String,
        contactHandle: String,
        contactIsOnline: Bool,
        requestCount: Int,
        recencyKey: String,
        channelID: String? = nil,
        subject: String? = nil,
        sentAt: String? = nil
    ) {
        self.contactID = contactID
        self.beepID = beepID
        self.contactName = contactName
        self.contactHandle = contactHandle
        self.contactIsOnline = contactIsOnline
        self.requestCount = max(requestCount, 1)
        self.recencyKey = recencyKey
        self.channelID = channelID
        self.subject = subject
        self.sentAt = sentAt
    }

    var id: String { beepID }

    var content: BeepContent {
        BeepContent(subject: subject)
    }

    var surfaceKey: BeepSurfaceKey {
        BeepSurfaceKey(contactID: contactID, requestCount: requestCount)
    }

    func matchesPresentation(of other: IncomingBeepSurface) -> Bool {
        surfaceKey == other.surfaceKey
    }
}

nonisolated struct IncomingBeepCandidate: Equatable {
    let beep: CanonicalIncomingBeep

    var surface: IncomingBeepSurface {
        beep.surface
    }

    nonisolated init(beep: CanonicalIncomingBeep) {
        self.beep = beep
    }

    nonisolated init(surface: IncomingBeepSurface, source: BeepSurfaceSource = .foregroundNotification) {
        self.beep = CanonicalIncomingBeep(
            key: surface.surfaceKey,
            contactName: surface.contactName,
            contactHandle: surface.contactHandle,
            contactIsOnline: surface.contactIsOnline,
            beepID: surface.beepID,
            channelID: surface.channelID,
            subject: surface.subject,
            sentAt: surface.sentAt,
            sources: [source],
            recencyKey: surface.recencyKey
        )
    }

    nonisolated init(contact: Contact, beep: TurboBeepResponse) {
        let requestCount = max(beep.requestCount, 1)
        self.beep = CanonicalIncomingBeep(
            key: BeepSurfaceKey(contactID: contact.id, requestCount: requestCount),
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            beepID: beep.beepId,
            channelID: beep.channelId,
            subject: beep.subject,
            sentAt: beep.createdAt,
            sources: [.backendBeep],
            recencyKey: beep.updatedAt ?? beep.createdAt
        )
    }

    nonisolated init(contact: Contact, requestCount: Int, source: String) {
        let normalizedRequestCount = max(requestCount, 1)
        let requestSource = BeepSurfaceSource(surfaceSource: source)
        self.beep = CanonicalIncomingBeep(
            key: BeepSurfaceKey(contactID: contact.id, requestCount: normalizedRequestCount),
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            beepID: "\(source):\(contact.id.uuidString):\(normalizedRequestCount)",
            channelID: contact.backendChannelId,
            subject: nil,
            sentAt: nil,
            sources: [requestSource],
            recencyKey: "\(source):\(normalizedRequestCount):\(contact.id.uuidString)"
        )
    }
}

nonisolated struct IncomingBeepSurfaceState: Equatable {
    var activeIncomingBeep: IncomingBeepSurface?
    var surfacedBeepIDs: Set<String> = []
    var surfacedBeepKeys: Set<BeepSurfaceKey> = []
    var foregroundBannerEpochStartedAt: Date?
    var pendingForegroundBeep: IncomingBeepSurface?
    var pendingForegroundBeepReceivedAt: Date?
    var pendingAcceptBeep: IncomingBeepSurface?

    func isAccepting(_ surface: IncomingBeepSurface) -> Bool {
        pendingAcceptBeep?.surfaceKey == surface.surfaceKey
    }
}

nonisolated enum IncomingBeepSurfaceEvent: Equatable {
    case beepsUpdated(
        candidates: [IncomingBeepCandidate],
        selectedContactID: UUID?,
        applicationIsActive: Bool,
        presentationPolicy: IncomingBeepSurfacePresentationPolicy = .surfaceEligible,
        allowsSelectedContact: Bool = false,
        allowsAlreadySurfacedBeep: Bool = false
    )
    case incomingBeepDismissed
    case contactOpened(contactID: UUID, beepID: String?, requestCount: Int? = nil)
    case pendingForegroundBeepQueued(surface: IncomingBeepSurface, receivedAt: Date)
    case pendingForegroundBeepCleared(contactID: UUID?, beepID: String?)
    case pendingForegroundBeepExpired(now: Date, lifetime: TimeInterval)
    case beepSeenWithoutBanner(contactID: UUID, beepID: String?, requestCount: Int?)
    case foregroundBannerEpochStarted(Date)
    case incomingBeepAcceptStarted(IncomingBeepSurface)
    case incomingBeepAcceptFinished(IncomingBeepSurface)
}

nonisolated enum IncomingBeepSurfacePresentationPolicy: Equatable {
    case surfaceEligible
    case markSeenWithoutBanner
}

nonisolated enum IncomingBeepSurfaceReducer {
    static func reduce(
        state: IncomingBeepSurfaceState,
        event: IncomingBeepSurfaceEvent
    ) -> IncomingBeepSurfaceState {
        var nextState = state

        switch event {
        case .beepsUpdated(
            let candidates,
            let selectedContactID,
            let applicationIsActive,
            let presentationPolicy,
            let allowsSelectedContact,
            let allowsAlreadySurfacedBeep
        ):
            let canonicalCandidates = canonicalize(candidates)
            let sortedCandidates = canonicalCandidates.sorted { lhs, rhs in
                lhs.beep.recencyKey > rhs.beep.recencyKey
            }
            let activeBeepIDs = Set(canonicalCandidates.map(\.surface.beepID))
            let activeBeepKeys = Set(canonicalCandidates.map(\.beep.key))
            let preEpochCandidates = canonicalCandidates.filter {
                $0.beep.wasSentBeforeForegroundBannerEpoch(nextState.foregroundBannerEpochStartedAt)
            }
            let preEpochBeepIDs = Set(preEpochCandidates.map(\.surface.beepID))
            let preEpochBeepKeys = Set(preEpochCandidates.map(\.beep.key))
            nextState.surfacedBeepIDs.formIntersection(activeBeepIDs)
            nextState.surfacedBeepKeys.formIntersection(activeBeepKeys)
            nextState.surfacedBeepIDs.formUnion(preEpochBeepIDs)
            nextState.surfacedBeepKeys.formUnion(preEpochBeepKeys)

            if let activeIncomingBeep = nextState.activeIncomingBeep,
               let activeCandidate = canonicalCandidates.first(where: { $0.beep.key == activeIncomingBeep.surfaceKey }),
               (!activeCandidate.beep.isEligibleForSurfaceByPresence
                || activeCandidate.beep.wasSentBeforeForegroundBannerEpoch(nextState.foregroundBannerEpochStartedAt)) {
                nextState.activeIncomingBeep = nil
            } else if let activeIncomingBeep = nextState.activeIncomingBeep,
                      !activeBeepKeys.contains(activeIncomingBeep.surfaceKey) {
                nextState.activeIncomingBeep = nil
            }

            if let activeIncomingBeep = nextState.activeIncomingBeep,
               activeBeepKeys.contains(activeIncomingBeep.surfaceKey) {
                nextState.surfacedBeepIDs.insert(activeIncomingBeep.beepID)
                nextState.surfacedBeepKeys.insert(activeIncomingBeep.surfaceKey)
            }

            if presentationPolicy == .markSeenWithoutBanner {
                nextState.surfacedBeepIDs.formUnion(activeBeepIDs)
                nextState.surfacedBeepKeys.formUnion(activeBeepKeys)
                if let pendingForegroundBeep = nextState.pendingForegroundBeep,
                   activeBeepKeys.contains(pendingForegroundBeep.surfaceKey) {
                    nextState.pendingForegroundBeep = nil
                    nextState.pendingForegroundBeepReceivedAt = nil
                }
                return nextState
            }

            guard applicationIsActive else {
                return nextState
            }

            guard nextState.activeIncomingBeep == nil else {
                return nextState
            }

            let candidate = sortedCandidates.first { candidate in
                candidate.beep.isEligibleForSurfaceByPresence
                    && !candidate.beep.wasSentBeforeForegroundBannerEpoch(nextState.foregroundBannerEpochStartedAt)
                    && (allowsSelectedContact || candidate.surface.contactID != selectedContactID)
                    && (
                        allowsAlreadySurfacedBeep
                            || !nextState.surfacedBeepKeys.contains(candidate.beep.key)
                    )
            }

            if let candidate {
                nextState.activeIncomingBeep = candidate.surface
                nextState.surfacedBeepIDs.insert(candidate.surface.beepID)
                nextState.surfacedBeepKeys.insert(candidate.beep.key)
            }

        case .incomingBeepDismissed:
            nextState.activeIncomingBeep = nil

        case .contactOpened(let contactID, let beepID, let requestCount):
            if let activeIncomingBeep = nextState.activeIncomingBeep,
               activeIncomingBeep.contactID == contactID {
                nextState.surfacedBeepKeys.insert(activeIncomingBeep.surfaceKey)
                nextState.activeIncomingBeep = nil
            }
            if let beepID {
                nextState.surfacedBeepIDs.insert(beepID)
            }
            if let requestCount {
                nextState.surfacedBeepKeys.insert(
                    BeepSurfaceKey(contactID: contactID, requestCount: requestCount)
                )
            }
            if nextState.pendingForegroundBeep?.contactID == contactID,
               beepID == nil || nextState.pendingForegroundBeep?.beepID == beepID {
                nextState.pendingForegroundBeep = nil
                nextState.pendingForegroundBeepReceivedAt = nil
            }

        case .pendingForegroundBeepQueued(let surface, let receivedAt):
            nextState.pendingForegroundBeep = surface
            nextState.pendingForegroundBeepReceivedAt = receivedAt

        case .pendingForegroundBeepCleared(let contactID, let beepID):
            guard let pendingSurface = nextState.pendingForegroundBeep else {
                return nextState
            }
            if let contactID, pendingSurface.contactID != contactID {
                return nextState
            }
            if let beepID, pendingSurface.beepID != beepID {
                return nextState
            }
            nextState.pendingForegroundBeep = nil
            nextState.pendingForegroundBeepReceivedAt = nil

        case .pendingForegroundBeepExpired(let now, let lifetime):
            guard let receivedAt = nextState.pendingForegroundBeepReceivedAt,
                  now.timeIntervalSince(receivedAt) >= lifetime else {
                return nextState
            }
            nextState.pendingForegroundBeep = nil
            nextState.pendingForegroundBeepReceivedAt = nil

        case .beepSeenWithoutBanner(let contactID, let beepID, let requestCount):
            if let activeIncomingBeep = nextState.activeIncomingBeep,
               activeIncomingBeep.contactID == contactID,
               beepID == nil || activeIncomingBeep.beepID == beepID {
                nextState.activeIncomingBeep = nil
            }
            if let beepID {
                nextState.surfacedBeepIDs.insert(beepID)
            }
            if let requestCount {
                nextState.surfacedBeepKeys.insert(
                    BeepSurfaceKey(contactID: contactID, requestCount: requestCount)
                )
            }
            if nextState.pendingForegroundBeep?.contactID == contactID,
               beepID == nil || nextState.pendingForegroundBeep?.beepID == beepID {
                nextState.pendingForegroundBeep = nil
                nextState.pendingForegroundBeepReceivedAt = nil
            }

        case .foregroundBannerEpochStarted(let startedAt):
            nextState.foregroundBannerEpochStartedAt = startedAt
            nextState.activeIncomingBeep = nil
            nextState.pendingForegroundBeep = nil
            nextState.pendingForegroundBeepReceivedAt = nil

        case .incomingBeepAcceptStarted(let surface):
            guard !nextState.isAccepting(surface) else {
                return nextState
            }
            nextState.pendingAcceptBeep = surface

        case .incomingBeepAcceptFinished(let surface):
            guard nextState.pendingAcceptBeep?.surfaceKey == surface.surfaceKey else {
                return nextState
            }
            nextState.pendingAcceptBeep = nil
        }

        return nextState
    }

    private static func canonicalize(
        _ candidates: [IncomingBeepCandidate]
    ) -> [IncomingBeepCandidate] {
        let merged = candidates.reduce(into: [BeepSurfaceKey: CanonicalIncomingBeep]()) { result, candidate in
            if let existing = result[candidate.beep.key] {
                result[candidate.beep.key] = existing.merging(candidate.beep)
            } else {
                result[candidate.beep.key] = candidate.beep
            }
        }
        return merged.values.map(IncomingBeepCandidate.init(beep:))
    }
}
