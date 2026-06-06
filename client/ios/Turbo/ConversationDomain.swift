import Foundation
import CryptoKit

nonisolated enum ConversationState: String {
    case idle
    case outgoingBeep = "outgoing-beep"
    case incomingBeep = "incoming-beep"
    case waitingForPeer = "waiting-for-peer"
    case ready
    case transmitting = "self-transmitting"
    case receiving = "peer-transmitting"
}

nonisolated struct Contact: Identifiable, Hashable {
    let id: UUID
    var profileName: String
    var localName: String?
    var handle: String
    var isOnline: Bool
    var channelId: UUID
    var backendChannelId: String?
    var remoteUserId: String?

    init(
        id: UUID,
        name: String,
        handle: String,
        isOnline: Bool,
        channelId: UUID,
        backendChannelId: String? = nil,
        remoteUserId: String? = nil,
        localName: String? = nil
    ) {
        self.init(
            id: id,
            profileName: name,
            localName: localName,
            handle: handle,
            isOnline: isOnline,
            channelId: channelId,
            backendChannelId: backendChannelId,
            remoteUserId: remoteUserId
        )
    }

    init(
        id: UUID,
        profileName: String,
        localName: String? = nil,
        handle: String,
        isOnline: Bool,
        channelId: UUID,
        backendChannelId: String? = nil,
        remoteUserId: String? = nil
    ) {
        self.id = id
        self.profileName = Self.normalizedProfileName(profileName, fallbackHandle: handle)
        self.localName = Self.normalizedLocalName(localName)
        self.handle = handle
        self.isOnline = isOnline
        self.channelId = channelId
        self.backendChannelId = backendChannelId
        self.remoteUserId = remoteUserId
    }

    var name: String {
        get {
            Self.presentedName(
                localName: localName,
                profileName: profileName,
                handle: handle
            )
        }
        set {
            profileName = Self.normalizedProfileName(newValue, fallbackHandle: handle)
        }
    }

    var hasLocalNameOverride: Bool {
        guard let localName else { return false }
        let normalizedLocal = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocal.isEmpty else { return false }
        return normalizedLocal.localizedCaseInsensitiveCompare(profileName) != .orderedSame
    }

    static func stableID(remoteUserId: String?, fallbackHandle: String) -> UUID {
        let identitySeed: String
        if let remoteUserId, !remoteUserId.isEmpty {
            identitySeed = remoteUserId
        } else {
            identitySeed = normalizedHandle(fallbackHandle)
        }
        let digest = SHA256.hash(data: Data("contact:\(identitySeed)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func stableID(for handle: String) -> UUID {
        stableID(remoteUserId: nil, fallbackHandle: handle)
    }

    static func displayName(for handle: String) -> String {
        let raw = TurboHandle.body(from: handle)
        guard !raw.isEmpty else { return normalizedHandle(handle) }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func normalizedHandle(_ handle: String) -> String {
        TurboHandle.normalizedStoredHandle(handle)
    }

    static func normalizedProfileName(_ profileName: String, fallbackHandle: String) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return displayName(for: fallbackHandle) }
        return trimmed
    }

    static func normalizedLocalName(_ localName: String?) -> String? {
        guard let localName else { return nil }
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func presentedName(localName: String?, profileName: String, handle: String) -> String {
        normalizedLocalName(localName) ?? normalizedProfileName(profileName, fallbackHandle: handle)
    }
}

enum SystemPTTSessionState: Equatable {
    case none
    case active(contactID: UUID, channelUUID: UUID)
    case mismatched(channelUUID: UUID)
}

enum PendingConnectAction: Equatable {
    case requestingBackend(contactID: UUID)
    case joiningLocal(contactID: UUID)

    var contactID: UUID {
        switch self {
        case .requestingBackend(let contactID), .joiningLocal(let contactID):
            return contactID
        }
    }
}

enum PendingConnectOrigin: Equatable {
    case neutral
    case acceptingIncomingBeep
}

enum PendingLeaveAction: Equatable {
    case explicit(contactID: UUID?)
    case reconciledTeardown(contactID: UUID)
}

enum PendingConversationAction: Equatable {
    case none
    case connect(PendingConnectAction)
    case leave(PendingLeaveAction)

    var pendingConnectContactID: UUID? {
        switch self {
        case .connect(let action):
            return action.contactID
        case .none, .leave:
            return nil
        }
    }

    var pendingJoinContactID: UUID? {
        switch self {
        case .connect(.joiningLocal(let contactID)):
            return contactID
        case .none, .connect(.requestingBackend), .leave:
            return nil
        }
    }

    var pendingTeardownContactID: UUID? {
        guard case .leave(.reconciledTeardown(let contactID)) = self else { return nil }
        return contactID
    }

    var hasAnyLeaveInFlight: Bool {
        switch self {
        case .leave:
            return true
        case .none, .connect:
            return false
        }
    }

    var blocksAutoRejoin: Bool {
        switch self {
        case .leave:
            return true
        case .none, .connect:
            return false
        }
    }

    func isLeaveInFlight(for contactID: UUID) -> Bool {
        switch self {
        case .leave(.explicit(let pendingContactID)):
            return pendingContactID == nil || pendingContactID == contactID
        case .leave(.reconciledTeardown(let pendingContactID)):
            return pendingContactID == contactID
        case .none, .connect:
            return false
        }
    }

    func isExplicitLeaveInFlight(for contactID: UUID) -> Bool {
        guard case .leave(.explicit(let pendingContactID)) = self else { return false }
        return pendingContactID == nil || pendingContactID == contactID
    }
}

struct LocalJoinAttempt: Equatable {
    let contactID: UUID
    let channelUUID: UUID
    var issuedCount: Int
    var firstIssuedAt: Date
    var lastIssuedAt: Date
}

struct ConversationActionCoordinatorState: Equatable {
    private(set) var pendingAction: PendingConversationAction = .none
    private(set) var pendingConnectOrigin: PendingConnectOrigin?
    private(set) var localJoinAttempt: LocalJoinAttempt?

    var pendingJoinContactID: UUID? {
        pendingAction.pendingJoinContactID
    }

    mutating func queueConnect(contactID: UUID, origin: PendingConnectOrigin = .neutral) {
        pendingAction = .connect(.requestingBackend(contactID: contactID))
        pendingConnectOrigin = origin
        localJoinAttempt = nil
    }

    mutating func queueJoin(
        contactID: UUID,
        channelUUID: UUID? = nil,
        now: Date = Date()
    ) {
        if case .leave(.explicit(let pendingContactID)) = pendingAction,
           pendingContactID == nil || pendingContactID == contactID {
            return
        }
        pendingAction = .connect(.joiningLocal(contactID: contactID))
        pendingConnectOrigin = nil
        guard let channelUUID else { return }
        if var attempt = localJoinAttempt,
           attempt.contactID == contactID,
           attempt.channelUUID == channelUUID {
            attempt.issuedCount += 1
            attempt.lastIssuedAt = now
            localJoinAttempt = attempt
        } else {
            localJoinAttempt = LocalJoinAttempt(
                contactID: contactID,
                channelUUID: channelUUID,
                issuedCount: 1,
                firstIssuedAt: now,
                lastIssuedAt: now
            )
        }
    }

    mutating func markExplicitLeave(contactID: UUID?) {
        pendingAction = .leave(.explicit(contactID: contactID))
        pendingConnectOrigin = nil
        if contactID == nil || localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func markReconciledTeardown(contactID: UUID) {
        pendingAction = .leave(.reconciledTeardown(contactID: contactID))
        pendingConnectOrigin = nil
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearAfterSuccessfulJoin(for contactID: UUID) {
        if pendingAction.pendingConnectContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearPendingJoin(for contactID: UUID) {
        if pendingJoinContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearPendingConnect(for contactID: UUID) {
        if pendingAction.pendingConnectContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
    }

    mutating func clearExplicitLeave(for contactID: UUID?) {
        guard case .leave(.explicit(let pendingContactID)) = pendingAction else { return }
        if pendingContactID == nil || pendingContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
    }

    mutating func clearLeaveAction(for contactID: UUID?) {
        switch pendingAction {
        case .leave(.explicit(let pendingContactID)):
            if pendingContactID == nil || pendingContactID == contactID {
                pendingAction = .none
                pendingConnectOrigin = nil
            }
        case .leave(.reconciledTeardown(let pendingContactID)):
            if pendingContactID == contactID {
                pendingAction = .none
                pendingConnectOrigin = nil
            }
        case .none, .connect:
            break
        }
    }

    var pendingConnectAcceptedIncomingBeepContactID: UUID? {
        guard pendingConnectOrigin == .acceptingIncomingBeep else { return nil }
        guard case .connect(.requestingBackend(let contactID)) = pendingAction else { return nil }
        return contactID
    }

    mutating func reconcileAfterChannelRefresh(
        for contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localDevicePTTEvidenceEstablished: Bool,
        localDevicePTTEvidenceCleared: Bool
    ) {
        if effectiveChannelState.membership.hasLocalMembership, localDevicePTTEvidenceEstablished {
            clearAfterSuccessfulJoin(for: contactID)
        } else if !effectiveChannelState.membership.hasLocalMembership, localDevicePTTEvidenceCleared {
            clearPendingJoin(for: contactID)
            clearLeaveAction(for: contactID)
        }
    }

    mutating func select(contactID: UUID) {
        switch pendingAction {
        case .connect(.joiningLocal(let pendingContactID)) where pendingContactID != contactID:
            pendingAction = .none
            pendingConnectOrigin = nil
            if localJoinAttempt?.contactID == pendingContactID {
                localJoinAttempt = nil
            }
        case .leave(.explicit(let pendingContactID)) where pendingContactID != nil && pendingContactID != contactID:
            pendingAction = .none
            pendingConnectOrigin = nil
        default:
            break
        }
    }

    mutating func reset() {
        pendingAction = .none
        pendingConnectOrigin = nil
        localJoinAttempt = nil
    }

    func autoRejoinContactID(afterLeaving _: UUID?) -> UUID? {
        guard !pendingAction.blocksAutoRejoin else { return nil }
        return pendingAction.pendingConnectContactID
    }
}

enum ConversationPrimaryActionKind: Equatable {
    case connect
    case holdToTalk
}

enum ConversationPrimaryActionStyle: Equatable {
    case accent
    case active
    case muted
}

struct ConversationPrimaryAction: Equatable {
    let kind: ConversationPrimaryActionKind
    let label: String
    let isEnabled: Bool
    let style: ConversationPrimaryActionStyle
}

enum BeepThreadProjection: Equatable {
    case none
    case outgoingBeep(requestCount: Int)
    case incomingBeep(requestCount: Int)
    case mutualBeep(requestCount: Int)

    var requestCount: Int? {
        switch self {
        case .none:
            return nil
        case .outgoingBeep(let requestCount), .incomingBeep(let requestCount), .mutualBeep(let requestCount):
            return requestCount
        }
    }

    var hasIncomingBeep: Bool {
        switch self {
        case .incomingBeep, .mutualBeep:
            return true
        case .none, .outgoingBeep:
            return false
        }
    }

    var hasOutgoingBeep: Bool {
        switch self {
        case .outgoingBeep, .mutualBeep:
            return true
        case .none, .incomingBeep:
            return false
        }
    }

    var hasPendingBeep: Bool {
        hasIncomingBeep || hasOutgoingBeep
    }

    var fallbackConversationState: ConversationState {
        switch self {
        case .none:
            return .idle
        case .outgoingBeep:
            return .outgoingBeep
        case .incomingBeep, .mutualBeep:
            return .incomingBeep
        }
    }
}

enum ConversationBeepDirection: Equatable {
    case outgoing
    case incoming
}

enum ConversationDisplayStatus: Equatable {
    case offline
    case online
    case beep(direction: ConversationBeepDirection, requestCount: Int)
    case ready
    case live

    var requestCount: Int? {
        switch self {
        case .beep(_, let requestCount):
            return requestCount
        case .offline, .online, .ready, .live:
            return nil
        }
    }

    var pillText: String {
        switch self {
        case .offline:
            return "Offline"
        case .online:
            return "Online"
        case .beep(let direction, let requestCount):
            let base = switch direction {
            case .outgoing:
                "Sent"
            case .incoming:
                "Incoming"
            }
            guard requestCount > 1 else { return base }
            return "\(base) \(requestCount)"
        case .ready:
            return "Ready"
        case .live:
            return "Live"
        }
    }
}

enum ConversationListSection: String, Equatable {
    case wantsToTalk = "wants-to-talk"
    case readyToTalk = "ready-to-talk"
    case outgoingBeep
    case contacts

    var title: String {
        switch self {
        case .wantsToTalk:
            return "Beeps"
        case .readyToTalk:
            return "Ready to Talk"
        case .outgoingBeep:
            return "Sent Beeps"
        case .contacts:
            return "Contacts"
        }
    }
}

enum ConversationAvailabilityPill: String, Equatable {
    case online
    case offline
    case busy

    var pillText: String {
        switch self {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .busy:
            return "Busy"
        }
    }
}

struct ContactListPresentation: Equatable {
    let displayStatus: ConversationDisplayStatus
    let section: ConversationListSection
    let availabilityPill: ConversationAvailabilityPill
    let requestCount: Int?

    func statusPillText(isActiveConversation: Bool = false) -> String {
        if isActiveConversation, availabilityPill == .online {
            return "Connected"
        }

        if section == .wantsToTalk, availabilityPill == .online {
            return "Ready"
        }

        return availabilityPill.pillText
    }
}

enum SelectedConversationPhase: Equatable {
    case idle
    case outgoingBeep
    case incomingBeep
    case friendReady
    case wakeReady
    case waitingForPeer
    case localJoinFailed
    case ready
    case startingTransmit
    case transmitting
    case receiving
    case blockedByOtherSession
    case systemMismatch

    var showsTransportPathBadge: Bool {
        switch self {
        case .ready, .startingTransmit, .transmitting, .receiving:
            return true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .wakeReady, .waitingForPeer,
             .localJoinFailed, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }
}

enum SelectedConversationWaitingReason: Equatable {
    case pendingJoin
    case disconnecting
    case devicePTTTransition
    case releaseRequiredAfterInterruptedTransmit
    case localAudioPrewarm
    case systemWakeActivation
    case wakePlaybackDeferredUntilForeground
    case localTransportWarmup
    case remoteAudioPrewarm
    case remoteWakeUnavailable
    case backendConversationTransition
    case friendReadyToConnect
}

enum StartingTransmitStage: Equatable {
    case requestingLease
    case awaitingSystemTransmit
    case awaitingAudioSession
    case awaitingAudioConnection(mediaState: MediaConnectionState)
}

enum LocalTransmitProjection: Equatable {
    case idle
    case stopping
    case releaseRequired
    case starting(StartingTransmitStage)
    case transmitting

    var hasTransmitIntent: Bool {
        switch self {
        case .starting, .transmitting:
            return true
        case .idle, .stopping, .releaseRequired:
            return false
        }
    }

    var preservesConnectedDevicePTTContinuity: Bool {
        switch self {
        case .stopping, .starting, .transmitting:
            return true
        case .idle, .releaseRequired:
            return false
        }
    }

    var startingTransmitStage: StartingTransmitStage? {
        guard case .starting(let stage) = self else { return nil }
        return stage
    }

    static func fromRuntimeState(
        isTransmitting: Bool,
        isStopping: Bool,
        requiresFreshPress: Bool,
        backendLeaseActive: Bool = true,
        transmitPhase: TransmitDomainPhase,
        systemIsTransmitting: Bool,
        pttAudioSessionActive: Bool,
        mediaState: MediaConnectionState
    ) -> LocalTransmitProjection {
        if isStopping {
            return .stopping
        }

        if requiresFreshPress {
            return .releaseRequired
        }

        guard isTransmitting else {
            return .idle
        }

        guard backendLeaseActive else {
            return .starting(.requestingLease)
        }

        if !systemIsTransmitting {
            switch transmitPhase {
            case .requesting:
                return .starting(.requestingLease)
            case .idle, .active, .stopping:
                return .starting(.awaitingSystemTransmit)
            }
        }

        guard pttAudioSessionActive else {
            return .starting(.awaitingAudioSession)
        }

        switch mediaState {
        case .connected:
            return .transmitting
        case .preparing, .idle, .closed, .failed:
            return .starting(.awaitingAudioConnection(mediaState: mediaState))
        }
    }
}

enum LocalMediaWarmupState: Equatable {
    case cold
    case prewarming
    case ready
    case failed
}

enum FirstTalkStartupProfile: Equatable {
    case directQuicWarm
    case directQuicWarming
    case relayWarm
    case relayWarming
    case unavailable

    var diagnosticsValue: String {
        switch self {
        case .directQuicWarm:
            return "direct-quic-warm"
        case .directQuicWarming:
            return "direct-quic-warming"
        case .relayWarm:
            return "relay-warm"
        case .relayWarming:
            return "relay-warming"
        case .unavailable:
            return "unavailable"
        }
    }

    var blocksFirstTalkTransmit: Bool {
        switch self {
        case .directQuicWarming, .relayWarming, .unavailable:
            return true
        case .directQuicWarm, .relayWarm:
            return false
        }
    }
}

enum RemoteAudioReadinessState: Equatable {
    case unknown
    case waiting
    case wakeCapable
    case ready
}

enum RemoteWakeCapabilityState: Equatable {
    case unavailable
    case wakeCapable(targetDeviceId: String)
}

enum SelectedConversationDetail: Equatable {
    case idle(isOnline: Bool)
    case outgoingBeep(requestCount: Int)
    case incomingBeep(requestCount: Int)
    case friendReady
    case wakeReady
    case waitingForPeer(reason: SelectedConversationWaitingReason)
    case localJoinFailed(recoveryMessage: String)
    case ready
    case readyHoldToTalkDisabled
    case startingTransmit(stage: StartingTransmitStage)
    case transmitting
    case receiving
    case blockedByOtherSession
    case systemMismatch

    var phase: SelectedConversationPhase {
        switch self {
        case .idle:
            return .idle
        case .outgoingBeep:
            return .outgoingBeep
        case .incomingBeep:
            return .incomingBeep
        case .friendReady:
            return .friendReady
        case .wakeReady:
            return .wakeReady
        case .waitingForPeer:
            return .waitingForPeer
        case .localJoinFailed:
            return .localJoinFailed
        case .ready, .readyHoldToTalkDisabled:
            return .ready
        case .startingTransmit:
            return .startingTransmit
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession:
            return .blockedByOtherSession
        case .systemMismatch:
            return .systemMismatch
        }
    }
}

struct SelectedConversationState: Equatable {
    let contactID: UUID?
    let contactName: String?
    let contactPresence: ContactPresencePresentation?
    let relationship: BeepThreadProjection
    let detail: SelectedConversationDetail
    let statusMessage: String
    let canTransmitNow: Bool

    init(
        contactID: UUID? = nil,
        contactName: String? = nil,
        contactPresence: ContactPresencePresentation? = nil,
        relationship: BeepThreadProjection,
        detail: SelectedConversationDetail,
        statusMessage: String,
        canTransmitNow: Bool
    ) {
        self.contactID = contactID
        self.contactName = contactName
        self.contactPresence = contactPresence
        self.relationship = relationship
        self.detail = detail
        self.statusMessage = statusMessage
        self.canTransmitNow = canTransmitNow
    }

    init(
        contactID: UUID? = nil,
        contactName: String? = nil,
        contactPresence: ContactPresencePresentation? = nil,
        relationship: BeepThreadProjection,
        phase: SelectedConversationPhase,
        statusMessage: String,
        canTransmitNow: Bool
    ) {
        self.init(
            contactID: contactID,
            contactName: contactName,
            contactPresence: contactPresence,
            relationship: relationship,
            detail: SelectedConversationState.defaultDetail(for: phase, relationship: relationship, statusMessage: statusMessage),
            statusMessage: statusMessage,
            canTransmitNow: canTransmitNow
        )
    }

    var phase: SelectedConversationPhase {
        detail.phase
    }

    var allowsHoldToTalk: Bool {
        if case .readyHoldToTalkDisabled = detail {
            return false
        }
        if canTransmitNow {
            return true
        }
        switch phase {
        case .wakeReady, .transmitting, .startingTransmit:
            return true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .waitingForPeer,
             .localJoinFailed, .ready, .receiving, .blockedByOtherSession,
             .systemMismatch:
            return false
        }
    }

    var conversationState: ConversationState {
        switch phase {
        case .idle:
            return relationship.fallbackConversationState
        case .outgoingBeep, .friendReady:
            return .outgoingBeep
        case .incomingBeep:
            return .incomingBeep
        case .wakeReady:
            return .ready
        case .waitingForPeer, .localJoinFailed:
            return .waitingForPeer
        case .ready:
            return .ready
        case .startingTransmit:
            return .transmitting
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession, .systemMismatch:
            return relationship.fallbackConversationState
        }
    }

    var displayStatus: ConversationDisplayStatus {
        switch detail {
        case .idle(let isOnline):
            return isOnline ? .online : .offline
        case .outgoingBeep(let requestCount):
            return .beep(direction: .outgoing, requestCount: requestCount)
        case .incomingBeep(let requestCount):
            return .beep(direction: .incoming, requestCount: requestCount)
        case .friendReady:
            return .ready
        case .wakeReady, .ready, .readyHoldToTalkDisabled, .startingTransmit, .transmitting, .receiving:
            return .live
        case .waitingForPeer(reason: .friendReadyToConnect):
            return .ready
        case .waitingForPeer, .localJoinFailed, .blockedByOtherSession, .systemMismatch:
            return .offline
        }
    }

    private static func defaultDetail(
        for phase: SelectedConversationPhase,
        relationship: BeepThreadProjection,
        statusMessage: String
    ) -> SelectedConversationDetail {
        switch phase {
        case .idle:
            return .idle(isOnline: false)
        case .outgoingBeep:
            return .outgoingBeep(requestCount: relationship.requestCount ?? 1)
        case .incomingBeep:
            return .incomingBeep(requestCount: relationship.requestCount ?? 1)
        case .friendReady:
            return .friendReady
        case .wakeReady:
            return .wakeReady
        case .waitingForPeer:
            return .waitingForPeer(reason: .backendConversationTransition)
        case .localJoinFailed:
            return .localJoinFailed(recoveryMessage: statusMessage)
        case .ready:
            return .ready
        case .startingTransmit:
            return .startingTransmit(stage: .awaitingAudioConnection(mediaState: .preparing))
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession:
            return .blockedByOtherSession
        case .systemMismatch:
            return .systemMismatch
        }
    }
}

enum SelectedConversationReconciliationAction: Equatable {
    case none
    case restoreDevicePTTSession(contactID: UUID)
    case teardownDevicePTTSession(contactID: UUID)
    case clearStaleBackendMembership(contactID: UUID)
}

struct ChannelReadinessSnapshot: Equatable {
    let membership: TurboChannelMembership
    let beepThreadProjection: BackendBeepThreadProjection
    let canTransmit: Bool
    let status: ConversationState?
    let readinessStatus: TurboChannelReadinessStatus?
    let activeTransmitterUserId: String?
    let activeTransmitId: String?
    let activeTransmitExpiresAt: String?
    let serverTimestamp: String?
    let localHasActiveDevice: Bool
    let localAudioReadiness: RemoteAudioReadinessState
    let remoteAudioReadiness: RemoteAudioReadinessState
    let remoteWakeCapability: RemoteWakeCapabilityState

    init(
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse? = nil
    ) {
        membership = channelState.membership
        beepThreadProjection = channelState.beepThreadProjection
        activeTransmitId = readiness?.activeTransmitId ?? channelState.activeTransmitId
        activeTransmitExpiresAt = readiness?.activeTransmitExpiresAt ?? channelState.transmitLeaseExpiresAt
        serverTimestamp = readiness?.serverTimestamp ?? channelState.serverTimestamp
        localHasActiveDevice = readiness?.selfHasActiveDevice ?? false
        localAudioReadiness = readiness?.localAudioReadiness ?? .unknown
        self.remoteAudioReadiness = readiness?.remoteAudioReadiness ?? .unknown
        self.remoteWakeCapability = readiness?.remoteWakeCapability ?? .unavailable
        if let readiness {
            canTransmit = readiness.canTransmit
            status = readiness.statusView.conversationState
            readinessStatus = readiness.statusView
            activeTransmitterUserId = readiness.statusView.activeTransmitterUserId
        } else {
            canTransmit = channelState.canTransmit
            status = channelState.conversationStatus
            readinessStatus = TurboChannelReadinessStatus(
                conversationStatus: channelState.statusView,
                canTransmit: channelState.canTransmit
            )
            activeTransmitterUserId = channelState.statusView.activeTransmitterUserId
        }
    }

    init(
        membership: TurboChannelMembership,
        beepThreadProjection: BackendBeepThreadProjection,
        canTransmit: Bool,
        status: ConversationState?,
        readinessStatus: TurboChannelReadinessStatus?,
        activeTransmitterUserId: String?,
        activeTransmitId: String?,
        activeTransmitExpiresAt: String?,
        serverTimestamp: String?,
        localHasActiveDevice: Bool,
        localAudioReadiness: RemoteAudioReadinessState,
        remoteAudioReadiness: RemoteAudioReadinessState,
        remoteWakeCapability: RemoteWakeCapabilityState
    ) {
        self.membership = membership
        self.beepThreadProjection = beepThreadProjection
        self.canTransmit = canTransmit
        self.status = status
        self.readinessStatus = readinessStatus
        self.activeTransmitterUserId = activeTransmitterUserId
        self.activeTransmitId = activeTransmitId
        self.activeTransmitExpiresAt = activeTransmitExpiresAt
        self.serverTimestamp = serverTimestamp
        self.localHasActiveDevice = localHasActiveDevice
        self.localAudioReadiness = localAudioReadiness
        self.remoteAudioReadiness = remoteAudioReadiness
        self.remoteWakeCapability = remoteWakeCapability
    }

    func replacingBeepThreadProjection(
        _ beepThreadProjection: BackendBeepThreadProjection,
        status: ConversationState?
    ) -> ChannelReadinessSnapshot {
        ChannelReadinessSnapshot(
            membership: membership,
            beepThreadProjection: beepThreadProjection,
            canTransmit: canTransmit,
            status: status,
            readinessStatus: readinessStatus,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitId: activeTransmitId,
            activeTransmitExpiresAt: activeTransmitExpiresAt,
            serverTimestamp: serverTimestamp,
            localHasActiveDevice: localHasActiveDevice,
            localAudioReadiness: localAudioReadiness,
            remoteAudioReadiness: remoteAudioReadiness,
            remoteWakeCapability: remoteWakeCapability
        )
    }

    var remoteAudioReadyForLiveTransmit: Bool {
        switch remoteAudioReadiness {
        case .ready:
            return true
        case .waiting, .wakeCapable:
            return false
        case .unknown:
            break
        }

        return membership.peerDeviceConnected && readinessStatus == .ready
    }
}

enum DevicePTTReadiness: Equatable {
    case none
    case partial
    case aligned
}

enum DevicePTTDevicePTTEvidence: Equatable {
    case joinedWithoutChannel
    case channelOnly(UUID)
    case joinedChannel(UUID)

    var isJoined: Bool {
        switch self {
        case .joinedWithoutChannel, .joinedChannel:
            return true
        case .channelOnly:
            return false
        }
    }

    var activeChannelID: UUID? {
        switch self {
        case .joinedWithoutChannel:
            return nil
        case .channelOnly(let channelID), .joinedChannel(let channelID):
            return channelID
        }
    }
}

enum DevicePTTLocalSession: Equatable {
    case absent
    case selected(DevicePTTDevicePTTEvidence)
    case other(DevicePTTDevicePTTEvidence)

    init(
        selectedContactID: UUID,
        isJoined: Bool,
        activeChannelID: UUID?
    ) {
        guard isJoined || activeChannelID != nil else {
            self = .absent
            return
        }

        if let activeChannelID {
            let evidence: DevicePTTDevicePTTEvidence =
                isJoined ? .joinedChannel(activeChannelID) : .channelOnly(activeChannelID)
            self = activeChannelID == selectedContactID ? .selected(evidence) : .other(evidence)
            return
        }

        self = .selected(.joinedWithoutChannel)
    }

    var isJoined: Bool {
        switch self {
        case .absent:
            return false
        case .selected(let evidence), .other(let evidence):
            return evidence.isJoined
        }
    }

    var activeChannelID: UUID? {
        switch self {
        case .absent:
            return nil
        case .selected(let evidence), .other(let evidence):
            return evidence.activeChannelID
        }
    }

    var selectedEvidence: DevicePTTDevicePTTEvidence? {
        guard case .selected(let evidence) = self else { return nil }
        return evidence
    }

    var isOtherSessionActive: Bool {
        guard case .other = self else { return false }
        return true
    }
}

enum RemotePlaybackContinuityState: Equatable {
    case idle
    case drainingBeforeStop
    case drainingAfterStop(projectionGraceActive: Bool)
    case stopped(projectionGraceActive: Bool)

    init(
        drainBlocksTransmit: Bool,
        stopObserved: Bool,
        stopProjectionGraceActive: Bool
    ) {
        switch (drainBlocksTransmit, stopObserved) {
        case (false, false):
            self = .idle
        case (true, false):
            self = .drainingBeforeStop
        case (true, true):
            self = .drainingAfterStop(projectionGraceActive: stopProjectionGraceActive)
        case (false, true):
            self = .stopped(projectionGraceActive: stopProjectionGraceActive)
        }
    }

    var drainBlocksTransmit: Bool {
        switch self {
        case .drainingBeforeStop, .drainingAfterStop:
            return true
        case .idle, .stopped:
            return false
        }
    }

    var stopObserved: Bool {
        switch self {
        case .drainingAfterStop, .stopped:
            return true
        case .idle, .drainingBeforeStop:
            return false
        }
    }

    var stopProjectionGraceActive: Bool {
        switch self {
        case .drainingAfterStop(let projectionGraceActive),
             .stopped(let projectionGraceActive):
            return projectionGraceActive
        case .idle, .drainingBeforeStop:
            return false
        }
    }
}

enum BackendJoinPhase: Equatable {
    case stable
    case settling
    case signalingRecovery

    var isSettling: Bool {
        switch self {
        case .settling:
            return true
        case .stable, .signalingRecovery:
            return false
        }
    }

    var isSignalingRecoveryActive: Bool {
        switch self {
        case .signalingRecovery:
            return true
        case .stable, .settling:
            return false
        }
    }
}

enum ControlPlaneContinuityPhase: Equatable {
    case normal
    case reconnectGrace

    var reconnectGraceActive: Bool {
        switch self {
        case .reconnectGrace:
            return true
        case .normal:
            return false
        }
    }
}

struct BackendConversationConvergenceState: Equatable {
    var joinPhase: BackendJoinPhase
    var controlPlaneContinuity: ControlPlaneContinuityPhase

    static let stable = BackendConversationConvergenceState(
        joinPhase: .stable,
        controlPlaneContinuity: .normal
    )

    init(
        joinPhase: BackendJoinPhase = .stable,
        controlPlaneContinuity: ControlPlaneContinuityPhase = .normal
    ) {
        self.joinPhase = joinPhase
        self.controlPlaneContinuity = controlPlaneContinuity
    }

    init(
        joinSettling: Bool,
        signalingJoinRecoveryActive: Bool,
        controlPlaneReconnectGraceActive: Bool
    ) {
        let joinPhase: BackendJoinPhase
        if signalingJoinRecoveryActive {
            joinPhase = .signalingRecovery
        } else if joinSettling {
            joinPhase = .settling
        } else {
            joinPhase = .stable
        }
        self.init(
            joinPhase: joinPhase,
            controlPlaneContinuity: controlPlaneReconnectGraceActive ? .reconnectGrace : .normal
        )
    }

    var backendJoinSettling: Bool {
        joinPhase.isSettling
    }

    var backendSignalingJoinRecoveryActive: Bool {
        joinPhase.isSignalingRecoveryActive
    }

    var controlPlaneReconnectGraceActive: Bool {
        controlPlaneContinuity.reconnectGraceActive
    }
}

enum BackendChannelReadiness: Equatable {
    case absent
    case peerOnly(peerDeviceConnected: Bool, canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)
    case selfOnly(canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)
    case both(peerDeviceConnected: Bool, canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)

    var status: ConversationState? {
        switch self {
        case .absent:
            return nil
        case .peerOnly(_, _, let readinessStatus), .selfOnly(_, let readinessStatus), .both(_, _, let readinessStatus):
            return readinessStatus?.conversationState
        }
    }

    var readinessStatus: TurboChannelReadinessStatus? {
        switch self {
        case .absent:
            return nil
        case .peerOnly(_, _, let readinessStatus), .selfOnly(_, let readinessStatus), .both(_, _, let readinessStatus):
            return readinessStatus
        }
    }

    var hasLocalMembership: Bool {
        switch self {
        case .selfOnly, .both:
            return true
        case .absent, .peerOnly:
            return false
        }
    }

    var hasPeerMembership: Bool {
        switch self {
        case .peerOnly, .both:
            return true
        case .absent, .selfOnly:
            return false
        }
    }

    var peerDeviceConnected: Bool {
        switch self {
        case .peerOnly(let peerDeviceConnected, _, _), .both(let peerDeviceConnected, _, _):
            return peerDeviceConnected
        case .absent, .selfOnly:
            return false
        }
    }

    var canTransmit: Bool {
        switch self {
        case .absent:
            return false
        case .peerOnly(_, let canTransmit, _), .selfOnly(let canTransmit, _), .both(_, let canTransmit, _):
            return canTransmit
        }
    }
}

struct ConversationDerivationContext: Equatable {
    let contactID: UUID
    let selectedContactID: UUID?
    let baseState: ConversationState
    let relationship: BeepThreadProjection
    let contactName: String
    let contactIsOnline: Bool
    let contactPresence: ContactPresencePresentation
    let localSession: DevicePTTLocalSession
    let localTransmit: LocalTransmitProjection
    let remoteParticipantSignalIsTransmitting: Bool
    let remotePlaybackContinuity: RemotePlaybackContinuityState
    let systemSessionMatchesContact: Bool
    let systemSessionState: SystemPTTSessionState
    let pendingAction: PendingConversationAction
    let pendingConnectAcceptedIncomingBeep: Bool
    let localJoinFailure: PTTJoinFailure?
    let mediaState: MediaConnectionState
    let localMediaWarmupState: LocalMediaWarmupState
    let mediaTransport: SelectedMediaTransportState
    let firstTalkStartupProfile: FirstTalkStartupProfile
    let firstTalkReadiness: FirstTalkReadinessProjection?
    let incomingWakeActivationState: IncomingWakeActivationState?
    let backendConvergence: BackendConversationConvergenceState
    let devicePTTRestoreBarrier: DevicePTTRestoreBarrier
    let hadConnectedDevicePTTContinuity: Bool
    let channel: ChannelReadinessSnapshot?

    init(
        contactID: UUID,
        selectedContactID: UUID?,
        baseState: ConversationState,
        relationship: BeepThreadProjection = .none,
        contactName: String,
        contactIsOnline: Bool,
        contactPresence: ContactPresencePresentation? = nil,
        localSession: DevicePTTLocalSession? = nil,
        isJoined: Bool,
        localTransmit: LocalTransmitProjection? = nil,
        localIsTransmitting: Bool = false,
        localIsStopping: Bool = false,
        localRequiresFreshPress: Bool = false,
        localTransmitPhase: TransmitDomainPhase = .idle,
        localSystemIsTransmitting: Bool = false,
        localPTTAudioSessionActive: Bool = false,
        remoteParticipantSignalIsTransmitting: Bool = false,
        remotePlaybackContinuity: RemotePlaybackContinuityState? = nil,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool,
        systemSessionState: SystemPTTSessionState,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool = false,
        localJoinFailure: PTTJoinFailure?,
        mediaState: MediaConnectionState = .idle,
        localMediaWarmupState: LocalMediaWarmupState = .cold,
        localRelayTransportReady: Bool = true,
        directMediaPathActive: Bool = false,
        mediaTransport: SelectedMediaTransportState? = nil,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        firstTalkReadiness: FirstTalkReadinessProjection? = nil,
        incomingWakeActivationState: IncomingWakeActivationState? = nil,
        backendConvergence: BackendConversationConvergenceState? = nil,
        devicePTTRestoreBarrier: DevicePTTRestoreBarrier,
        hadConnectedDevicePTTContinuity: Bool = false,
        channel: ChannelReadinessSnapshot?
    ) {
        self.contactID = contactID
        self.selectedContactID = selectedContactID
        self.baseState = baseState
        self.relationship = relationship
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.contactPresence = contactPresence ?? (contactIsOnline ? .connected : .offline)
        self.localSession = localSession ?? DevicePTTLocalSession(
            selectedContactID: contactID,
            isJoined: isJoined,
            activeChannelID: activeChannelID
        )
        self.localTransmit = localTransmit ?? LocalTransmitProjection.fromRuntimeState(
            isTransmitting: localIsTransmitting,
            isStopping: localIsStopping,
            requiresFreshPress: localRequiresFreshPress,
            transmitPhase: localTransmitPhase,
            systemIsTransmitting: localSystemIsTransmitting,
            pttAudioSessionActive: localPTTAudioSessionActive,
            mediaState: mediaState
        )
        self.remoteParticipantSignalIsTransmitting = remoteParticipantSignalIsTransmitting
        self.remotePlaybackContinuity = remotePlaybackContinuity ?? .idle
        self.systemSessionMatchesContact = systemSessionMatchesContact
        self.systemSessionState = systemSessionState
        self.pendingAction = pendingAction
        self.pendingConnectAcceptedIncomingBeep = pendingConnectAcceptedIncomingBeep
        self.localJoinFailure = localJoinFailure
        self.mediaState = mediaState
        self.localMediaWarmupState = localMediaWarmupState
        self.mediaTransport = mediaTransport
            ?? SelectedMediaTransportState(
                localRelayTransportReady: localRelayTransportReady,
                directMediaPathActive: directMediaPathActive
            )
        self.firstTalkStartupProfile = firstTalkStartupProfile
        self.firstTalkReadiness = firstTalkReadiness
        self.incomingWakeActivationState = incomingWakeActivationState
        self.backendConvergence = backendConvergence ?? .stable
        self.devicePTTRestoreBarrier = devicePTTRestoreBarrier
        self.hadConnectedDevicePTTContinuity = hadConnectedDevicePTTContinuity
        self.channel = channel
    }

    init(
        contactID: UUID,
        selectedContactID: UUID?,
        baseState: ConversationState,
        relationship: BeepThreadProjection = .none,
        contactName: String,
        contactIsOnline: Bool,
        contactPresence: ContactPresencePresentation? = nil,
        localSession: DevicePTTLocalSession? = nil,
        isJoined: Bool,
        localTransmit: LocalTransmitProjection? = nil,
        localIsTransmitting: Bool = false,
        localIsStopping: Bool = false,
        localRequiresFreshPress: Bool = false,
        localTransmitPhase: TransmitDomainPhase = .idle,
        localSystemIsTransmitting: Bool = false,
        localPTTAudioSessionActive: Bool = false,
        remoteParticipantSignalIsTransmitting: Bool = false,
        remotePlaybackContinuity: RemotePlaybackContinuityState? = nil,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool,
        systemSessionState: SystemPTTSessionState,
        pendingAction: PendingConversationAction,
        pendingConnectAcceptedIncomingBeep: Bool = false,
        localJoinFailure: PTTJoinFailure?,
        mediaState: MediaConnectionState = .idle,
        localMediaWarmupState: LocalMediaWarmupState = .cold,
        localRelayTransportReady: Bool = true,
        directMediaPathActive: Bool = false,
        mediaTransport: SelectedMediaTransportState? = nil,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        firstTalkReadiness: FirstTalkReadinessProjection? = nil,
        incomingWakeActivationState: IncomingWakeActivationState? = nil,
        backendConvergence: BackendConversationConvergenceState? = nil,
        hadConnectedDevicePTTContinuity: Bool = false,
        channel: ChannelReadinessSnapshot?
    ) {
        self.init(
            contactID: contactID,
            selectedContactID: selectedContactID,
            baseState: baseState,
            relationship: relationship,
            contactName: contactName,
            contactIsOnline: contactIsOnline,
            contactPresence: contactPresence,
            localSession: localSession,
            isJoined: isJoined,
            localTransmit: localTransmit,
            localIsTransmitting: localIsTransmitting,
            localIsStopping: localIsStopping,
            localRequiresFreshPress: localRequiresFreshPress,
            localTransmitPhase: localTransmitPhase,
            localSystemIsTransmitting: localSystemIsTransmitting,
            localPTTAudioSessionActive: localPTTAudioSessionActive,
            remoteParticipantSignalIsTransmitting: remoteParticipantSignalIsTransmitting,
            remotePlaybackContinuity: remotePlaybackContinuity,
            activeChannelID: activeChannelID,
            systemSessionMatchesContact: systemSessionMatchesContact,
            systemSessionState: systemSessionState,
            pendingAction: pendingAction,
            pendingConnectAcceptedIncomingBeep: pendingConnectAcceptedIncomingBeep,
            localJoinFailure: localJoinFailure,
            mediaState: mediaState,
            localMediaWarmupState: localMediaWarmupState,
            localRelayTransportReady: localRelayTransportReady,
            directMediaPathActive: directMediaPathActive,
            mediaTransport: mediaTransport,
            firstTalkStartupProfile: firstTalkStartupProfile,
            firstTalkReadiness: firstTalkReadiness,
            incomingWakeActivationState: incomingWakeActivationState,
            backendConvergence: backendConvergence,
            devicePTTRestoreBarrier: .none,
            hadConnectedDevicePTTContinuity: hadConnectedDevicePTTContinuity,
            channel: channel
        )
    }

    var remotePlaybackDrainBlocksTransmit: Bool {
        remotePlaybackContinuity.drainBlocksTransmit
    }

    var remoteTransmitStopObserved: Bool {
        remotePlaybackContinuity.stopObserved
    }

    var remoteTransmitStopProjectionGraceActive: Bool {
        remotePlaybackContinuity.stopProjectionGraceActive
    }

    var backendJoinSettling: Bool {
        backendConvergence.backendJoinSettling
    }

    var backendSignalingJoinRecoveryActive: Bool {
        backendConvergence.backendSignalingJoinRecoveryActive
    }

    var controlPlaneReconnectGraceActive: Bool {
        backendConvergence.controlPlaneReconnectGraceActive
    }

    var directMediaPathActive: Bool {
        mediaTransport.directMediaPathActive
    }

    var localRelayTransportReady: Bool {
        mediaTransport.fallbackReady
    }

    var localTransportReadyForTransmit: Bool {
        mediaTransport.isReadyForTransmit
    }

    var idleAvailabilityStatusMessage: String {
        switch contactPresence {
        case .connected, .reachable:
            return "\(contactName) is online"
        case .offline:
            return "Ready to connect"
        }
    }

    var connectionAttemptStatusMessage: String {
        switch contactPresence {
        case .offline:
            return "Waiting for \(contactName) to reconnect"
        case .connected, .reachable:
            return "Connecting..."
        }
    }

    var remoteAudioReadinessState: RemoteAudioReadinessState {
        channel?.remoteAudioReadiness ?? .unknown
    }

    var remoteWakeCapabilityState: RemoteWakeCapabilityState {
        channel?.remoteWakeCapability ?? .unavailable
    }

    var remoteAudioReadinessAllowsWakeProjection: Bool {
        switch remoteAudioReadinessState {
        case .wakeCapable, .unknown:
            return true
        case .waiting, .ready:
            return false
        }
    }

    var localIsTransmitting: Bool {
        localTransmit.hasTransmitIntent
    }

    var localIsStopping: Bool {
        localTransmit == .stopping
    }

    var localRequiresFreshPress: Bool {
        localTransmit == .releaseRequired
    }

    var isJoined: Bool {
        localSession.isJoined
    }

    var activeChannelID: UUID? {
        localSession.activeChannelID
    }

    var rawLocalDevicePTTEvidencePresent: Bool {
        isJoined
            || activeChannelID != nil
            || systemSessionState != .none
            || localTransmit.hasTransmitIntent
            || localTransmit.preservesConnectedDevicePTTContinuity
    }

    var explicitLeaveRequested: Bool {
        switch pendingAction {
        case .leave(.explicit(let contactID)):
            return contactID == nil || contactID == self.contactID
        case .none, .connect, .leave(.reconciledTeardown):
            return false
        }
    }

    var backendShowsConnectableConversationRecovery: Bool {
        guard !backendMembershipIsStaleWithoutDevicePTTEvidence else { return false }
        guard let channel else { return false }
        if channel.membership.hasPeerMembership {
            return true
        }
        return channel.canTransmit
    }

    var backendShowsEstablishedReadyConversation: Bool {
        backendChannelReadiness.hasLocalMembership
            && backendChannelReadiness.hasPeerMembership
            && backendChannelReadiness.peerDeviceConnected
            && backendChannelReadiness.canTransmit
    }

    var backendShowsWakeCapableReceiverRecovery: Bool {
        guard let channel else { return false }
        guard !backendJoinSettling else { return false }
        guard !channel.canTransmit else { return false }
        guard channel.membership.hasLocalMembership else { return false }
        guard channel.localHasActiveDevice else { return false }
        guard case .wakeCapable = channel.remoteWakeCapability else { return false }
        guard remoteAudioReadinessAllowsWakeProjection else { return false }
        guard !remoteParticipantSignalIsTransmitting else { return false }
        if channel.readinessStatus?.isTransmitActive == true {
            return false
        }

        switch channel.membership {
        case .both(let peerDeviceConnected):
            return !peerDeviceConnected
        case .selfOnly:
            return devicePTTReadiness == .none
                && systemSessionState == .none
                && activeChannelID == nil
        case .peerOnly, .absent:
            return false
        }
    }

    var backendShowsWakeReadyAffordance: Bool {
        devicePTTReadiness == .aligned && backendShowsWakeCapableReceiverRecovery
    }

    var backendExplicitlyInactiveWithoutMembership: Bool {
        guard !backendJoinSettling else { return false }
        guard let channel else { return false }
        guard channel.membership == .absent else { return false }
        return channel.readinessStatus == .inactive
    }

    var backendInactiveReadinessInvalidatesLocalDevicePTT: Bool {
        guard !backendJoinSettling else { return false }
        guard rawLocalDevicePTTEvidencePresent else { return false }
        guard let channel else { return false }
        guard channel.readinessStatus == .inactive else { return false }
        guard !channel.canTransmit else { return false }
        guard !wakeRecoveryInFlight else { return false }
        guard !channelHasBeepThreadProjection else { return false }
        guard !remoteParticipantSignalIsTransmitting else { return false }
        return true
    }

    var channelHasBeepThreadProjection: Bool {
        guard relationship == .none else { return true }
        guard let relationship = channel?.beepThreadProjection else { return false }
        return relationship != .none
    }

    var pendingJoinHasTerminalBackendMembershipLoss: Bool {
        guard !backendJoinSettling else { return false }
        guard pendingAction.pendingJoinContactID == contactID else { return false }
        guard devicePTTReadiness != .none else { return false }
        guard let channel else { return false }
        guard channel.membership == .absent else { return false }
        guard channel.beepThreadProjection == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard !remoteParticipantSignalIsTransmitting else { return false }
        if channel.readinessStatus == .inactive {
            return true
        }
        if channel.status == .idle {
            return true
        }
        return !channel.canTransmit
    }

    var remoteAudioRecoveryAvailable: Bool {
        switch remoteAudioReadinessState {
        case .wakeCapable, .ready:
            return true
        case .unknown, .waiting:
            return false
        }
    }

    var wakeRecoveryInFlight: Bool {
        switch incomingWakeActivationState {
        case .signalBuffered, .awaitingSystemActivation, .appManagedFallback, .systemActivated:
            return systemSessionMatchesContact
        case .systemActivationTimedOutWaitingForForeground, .systemActivationInterruptedByTransmitEnd, .none:
            return false
        }
    }

    var shouldTreatSystemMismatchAsRecoverable: Bool {
        guard case .mismatched = systemSessionState else { return false }
        guard !explicitLeaveRequested else { return false }
        if systemMismatchChannelMatchesContact {
            return true
        }
        if unattributedJoinedSystemMismatch,
           !backendExplicitlyInactiveWithoutMembership {
            return true
        }
        if hadConnectedDevicePTTContinuity {
            return true
        }
        if pendingAction.pendingJoinContactID == contactID {
            return true
        }
        if devicePTTReadiness != .none {
            if channelHasBeepThreadProjection {
                return true
            }
            switch backendChannelReadiness {
            case .selfOnly, .both:
                return true
            case .absent, .peerOnly:
                break
            }
        }
        return false
    }

    var systemMismatchChannelMatchesContact: Bool {
        guard case .mismatched = systemSessionState else { return false }
        return systemSessionMatchesContact
    }

    var unattributedJoinedSystemMismatch: Bool {
        guard case .mismatched = systemSessionState else { return false }
        return isJoined && activeChannelID == nil
    }

    var pendingJoinIsStaleWithoutDevicePTTEvidence: Bool {
        guard pendingAction.pendingJoinContactID == contactID else { return false }
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .ready else {
            return false
        }
        return true
    }

    var pendingBackendConnectIsReadyForDevicePTTRestore: Bool {
        guard pendingAction.pendingConnectContactID == contactID else { return false }
        guard pendingAction.pendingJoinContactID == nil else { return false }
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected else {
            return false
        }
        return readinessStatus == .waitingForSelf || readinessStatus == .ready
    }

    var backendMembershipIsStaleWithoutDevicePTTEvidence: Bool {
        if backendMembershipIsStaleAfterRecentSystemLeaveWithoutPeer {
            return true
        }
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard pendingAction == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard channel?.beepThreadProjection == BackendBeepThreadProjection.none else { return false }
        guard remoteAudioReadinessState != .waiting else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness else {
            return false
        }
        guard !peerDeviceConnected else { return false }
        return readinessStatus == .inactive
    }

    var backendMembershipIsStaleAfterRecentSystemLeaveWithoutPeer: Bool {
        guard devicePTTRestoreBarrier.blocksAutomaticRestore else { return false }
        guard pendingAction == .none else { return false }
        guard relationship == .none else { return false }
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard channel?.beepThreadProjection == BackendBeepThreadProjection.none else { return false }
        guard case .selfOnly = backendChannelReadiness else { return false }
        return true
    }

    var backendMembershipCanRestoreMissingDevicePTTEvidence: Bool {
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard pendingAction == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard channel?.beepThreadProjection == BackendBeepThreadProjection.none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .waitingForSelf else {
            return false
        }
        return true
    }

    var backendWakeCapableSelfMembershipCanRestoreMissingDevicePTTEvidence: Bool {
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard pendingAction == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard channel?.beepThreadProjection == BackendBeepThreadProjection.none else { return false }
        guard backendShowsWakeCapableReceiverRecovery else { return false }
        guard case .selfOnly(_, let readinessStatus) = backendChannelReadiness else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer:
            return true
        case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var backendReadyAutoRestoreAllowed: Bool {
        if pendingBackendConnectIsReadyForDevicePTTRestore {
            return true
        }
        if pendingAction.pendingJoinContactID == contactID {
            return true
        }
        guard !devicePTTRestoreBarrier.blocksAutomaticRestore else {
            return false
        }
        if backendMembershipCanRestoreMissingDevicePTTEvidence {
            return true
        }
        if backendWakeCapableSelfMembershipCanRestoreMissingDevicePTTEvidence {
            return true
        }
        if backendReadyMembershipHasCurrentDeviceEvidence {
            return true
        }
        return hadConnectedDevicePTTContinuity
    }

    var blockedAutomaticRestoreIsAwaitingBackendConvergence: Bool {
        guard devicePTTRestoreBarrier.blocksAutomaticRestore else { return false }
        guard pendingAction == .none else { return false }
        guard relationship == .none else { return false }
        guard devicePTTReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard channel?.beepThreadProjection == BackendBeepThreadProjection.none else { return false }
        return backendChannelReadiness.hasLocalMembership
    }

    var establishedConnectedSessionLostTransmitAuthorityWaitingForPeer: Bool {
        guard selectedContactID == contactID else { return false }
        guard !devicePTTRestoreBarrier.blocksAutomaticRestore else { return false }
        guard hadConnectedDevicePTTContinuity else { return false }
        guard devicePTTReadiness == .aligned else { return false }
        guard !backendJoinSettling else { return false }
        guard !remoteParticipantSignalIsTransmitting else { return false }
        guard remoteAudioReadinessState != .ready else { return false }
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              !canTransmit,
              readinessStatus == .waitingForPeer else {
            return false
        }
        return true
    }

    var backendReadyMembershipHasCurrentDeviceEvidence: Bool {
        guard let channel else { return false }
        guard channel.localHasActiveDevice else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .ready else {
            return false
        }
        return true
    }
}

enum DevicePTTContinuityProjection: Equatable {
    case inactive
    case transitioning
    case connected
    case blockedByOtherSession
    case systemMismatch
    case localJoinFailed(recoveryMessage: String)
    case pendingJoin
    case disconnecting

    var localDevicePTTEvidencePresent: Bool {
        switch self {
        case .transitioning, .connected, .disconnecting:
            return true
        case .inactive, .blockedByOtherSession, .systemMismatch, .localJoinFailed, .pendingJoin:
            return false
        }
    }
}

enum ConnectedExecutionProjection: Equatable {
    case wakeActivating
    case wakeDeferredUntilForeground(message: String)
    case stopping
    case releaseRequired
    case startingTransmit(StartingTransmitStage)
    case transmitting
}

enum ConnectedControlPlaneProjection: Equatable {
    case unavailable
    case wakeReady
    case waiting(reason: SelectedConversationWaitingReason, statusMessage: String)
    case ready
    case readyHoldToTalkDisabled
    case transmitting
    case receiving
}

enum DevicePTTRestoreState: Equatable {
    case absent
    case partialMissingSystemSession(DevicePTTDevicePTTEvidence)
    case restoring
    case pendingJoin
}

enum DevicePTTRestoreBarrier: Equatable {
    case none
    case recentSystemLeave(contactID: UUID, channelUUID: UUID, reason: String)

    var blocksAutomaticRestore: Bool {
        switch self {
        case .none:
            return false
        case .recentSystemLeave:
            return true
        }
    }
}

struct SelectedConversationProjection: Equatable {
    let devicePTTContinuity: DevicePTTContinuityProjection
    let connectedExecution: ConnectedExecutionProjection?
    let connectedControlPlane: ConnectedControlPlaneProjection
    let selectedConversationState: SelectedConversationState
    let reconciliationAction: SelectedConversationReconciliationAction
}

enum ConversationStateMachine {
    static func beepThreadProjection(
        hasIncomingBeep: Bool,
        hasOutgoingBeep: Bool,
        requestCount: Int
    ) -> BeepThreadProjection {
        let normalizedCount = max(requestCount, 1)
        if hasIncomingBeep && hasOutgoingBeep {
            return .mutualBeep(requestCount: normalizedCount)
        }
        if hasIncomingBeep {
            return .incomingBeep(requestCount: normalizedCount)
        }
        if hasOutgoingBeep {
            return .outgoingBeep(requestCount: normalizedCount)
        }
        return .none
    }

    static func effectiveState(for context: ConversationDerivationContext) -> ConversationState {
        guard context.selectedContactID == context.contactID else {
            return context.baseState
        }

        switch context.baseState {
        case .ready, .transmitting, .receiving:
            guard context.devicePTTReadiness == .aligned else {
                return .waitingForPeer
            }
            guard case .both(let peerDeviceConnected, let canTransmit, _) = context.backendChannelReadiness,
                  peerDeviceConnected else {
                return .waitingForPeer
            }
            if !canTransmit && context.baseState != .receiving {
                return .waitingForPeer
            }
            return context.baseState
        case .idle, .outgoingBeep, .incomingBeep, .waitingForPeer:
            return context.baseState
        }
    }

    static func selectedConversationState(
        for context: ConversationDerivationContext,
        relationship: BeepThreadProjection
    ) -> SelectedConversationState {
        projection(for: context, relationship: relationship).selectedConversationState
    }

    static func projection(
        for context: ConversationDerivationContext,
        relationship: BeepThreadProjection
    ) -> SelectedConversationProjection {
        let canTransmitNow = context.canTransmitNow
        let makeState: (SelectedConversationDetail, String, Bool) -> SelectedConversationState = { detail, statusMessage, canTransmitNow in
            SelectedConversationState(
                contactID: context.contactID,
                contactName: context.contactName,
                contactPresence: context.contactPresence,
                relationship: relationship,
                detail: detail,
                statusMessage: statusMessage,
                canTransmitNow: canTransmitNow
            )
        }

        let devicePTTContinuity = context.devicePTTContinuityProjection
        let connectedExecution = context.connectedExecutionProjection
        let connectedControlPlane = context.connectedControlPlaneProjection
        let pendingBeepState: () -> SelectedConversationState? = {
            guard context.pendingAction.pendingJoinContactID != context.contactID else {
                return nil
            }
            guard (!context.rawLocalDevicePTTEvidencePresent || !context.backendShowsEstablishedReadyConversation),
                  !context.backendJoinSettling else {
                return nil
            }
            switch relationship {
            case .incomingBeep, .mutualBeep:
                return makeState(
                    .incomingBeep(requestCount: relationship.requestCount ?? 1),
                    "\(context.contactName) wants to talk",
                    false
                )
            case .outgoingBeep:
                return makeState(
                    .outgoingBeep(requestCount: relationship.requestCount ?? 1),
                    "Beep sent to \(context.contactName)",
                    false
                )
            case .none:
                return nil
            }
        }
        let fallbackState: () -> SelectedConversationState = {
            let localDevicePTTEvidencePresent = devicePTTContinuity.localDevicePTTEvidencePresent
            let idleIsOnline = context.contactPresence != .offline

            if let pendingBeepState = pendingBeepState() {
                return pendingBeepState
            }

            if context.backendMembershipIsStaleWithoutDevicePTTEvidence {
                return makeState(
                    .idle(isOnline: idleIsOnline),
                    context.idleAvailabilityStatusMessage,
                    false
                )
            }

            if !localDevicePTTEvidencePresent, context.pendingConnectAcceptedIncomingBeep {
                return makeState(
                    .waitingForPeer(reason: .pendingJoin),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            if !localDevicePTTEvidencePresent, context.backendJoinSettling {
                return makeState(
                    .waitingForPeer(reason: .backendConversationTransition),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            switch context.backendChannelReadiness {
            case .peerOnly:
                if !localDevicePTTEvidencePresent {
                    return makeState(.friendReady, "\(context.contactName) is ready to connect", false)
                }
            case .selfOnly:
                if localDevicePTTEvidencePresent
                    || (
                        context.backendChannelReadiness.hasLocalMembership
                            && context.backendReadyAutoRestoreAllowed
                    ) {
                    return makeState(
                        .waitingForPeer(reason: .backendConversationTransition),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                }
            case .both:
                if localDevicePTTEvidencePresent
                    || (
                        context.backendChannelReadiness.hasLocalMembership
                            && context.backendReadyAutoRestoreAllowed
                    ) {
                    let reason: SelectedConversationWaitingReason =
                        context.backendChannelReadiness.hasLocalMembership
                        ? .friendReadyToConnect
                        : .backendConversationTransition
                    return makeState(
                        .waitingForPeer(reason: reason),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                }
            case .absent:
                break
            }

            // After backend resets or lagging summary refreshes, the backend can
            // still report a durable channel status before membership fields are
            // repopulated. Treat that as a connectable recovery state instead of
            // falling all the way back to idle/outgoingBeep.
            if !localDevicePTTEvidencePresent,
               !context.backendChannelReadiness.hasLocalMembership,
               context.channel?.readinessStatus == .waitingForSelf {
                return makeState(.friendReady, "\(context.contactName) is ready to connect", false)
            }

            if !localDevicePTTEvidencePresent,
               context.backendChannelReadiness.hasLocalMembership,
               context.backendChannelReadiness.hasPeerMembership,
               context.channel?.readinessStatus == .inactive {
                return makeState(.friendReady, "\(context.contactName) is ready to connect", false)
            }

            if let channelStatus = context.channel?.status,
               context.backendShowsConnectableConversationRecovery
                || (!localDevicePTTEvidencePresent && context.backendShowsWakeCapableReceiverRecovery) {
                switch channelStatus {
                case .waitingForPeer, .ready, .transmitting, .receiving:
                    if !localDevicePTTEvidencePresent {
                        return makeState(.friendReady, "\(context.contactName) is ready to connect", false)
                    }
                    return makeState(
                        .waitingForPeer(reason: .backendConversationTransition),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                case .idle, .outgoingBeep, .incomingBeep:
                    break
                }
            }

            if localDevicePTTEvidencePresent, context.backendShowsWakeReadyAffordance {
                return makeState(
                    .wakeReady,
                    "Hold to talk to wake \(context.contactName)",
                    false
                )
            }

            if localDevicePTTEvidencePresent {
                return makeState(
                    .waitingForPeer(reason: .devicePTTTransition),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            switch relationship {
            case .incomingBeep, .mutualBeep:
                return makeState(
                    .incomingBeep(requestCount: relationship.requestCount ?? 1),
                    "\(context.contactName) wants to talk",
                    false
                )
            case .outgoingBeep:
                return makeState(
                    .outgoingBeep(requestCount: relationship.requestCount ?? 1),
                    "Beep sent to \(context.contactName)",
                    false
                )
            case .none:
                return makeState(
                    .idle(isOnline: idleIsOnline),
                    context.idleAvailabilityStatusMessage,
                    false
                )
            }
        }

        let selectedConversationState: SelectedConversationState = {
            if let pendingBeepState = pendingBeepState() {
                switch devicePTTContinuity {
                case .blockedByOtherSession, .systemMismatch, .localJoinFailed:
                    break
                case .inactive, .transitioning, .connected, .pendingJoin, .disconnecting:
                    return pendingBeepState
                }
            }

            switch devicePTTContinuity {
            case .blockedByOtherSession:
                return makeState(.blockedByOtherSession, "Another session is active", false)
            case .systemMismatch:
                return makeState(.systemMismatch, "System session mismatch", false)
            case .localJoinFailed(let recoveryMessage):
                return makeState(
                    .localJoinFailed(recoveryMessage: recoveryMessage),
                    recoveryMessage,
                    false
                )
            case .pendingJoin:
                return makeState(
                    .waitingForPeer(reason: .pendingJoin),
                    context.connectionAttemptStatusMessage,
                    false
                )
            case .disconnecting:
                return makeState(.waitingForPeer(reason: .disconnecting), "Disconnecting...", false)
            case .connected:
                if let connectedConversationState = connectedSelectedConversationState(
                    contactName: context.contactName,
                    connectedExecution: connectedExecution,
                    connectedControlPlane: connectedControlPlane,
                    devicePTTContinuity: devicePTTContinuity
                ) {
                    return makeState(
                        connectedConversationState.detail,
                        connectedConversationState.statusMessage,
                        canTransmitNow
                    )
                }
                return fallbackState()
            case .inactive, .transitioning:
                return fallbackState()
            }
        }()

        return SelectedConversationProjection(
            devicePTTContinuity: devicePTTContinuity,
            connectedExecution: connectedExecution,
            connectedControlPlane: connectedControlPlane,
            selectedConversationState: selectedConversationState,
            reconciliationAction: reconcileAction(for: context, relationship: relationship)
        )
    }

    static func listConversationState(for summary: TurboContactSummaryResponse) -> ConversationState {
        switch summary.beepThreadProjection {
        case .incoming, .outgoing, .mutual:
            let relationship = beepThreadProjection(
                hasIncomingBeep: summary.beepThreadProjection.hasIncomingBeep,
                hasOutgoingBeep: summary.beepThreadProjection.hasOutgoingBeep,
                requestCount: summary.beepThreadProjection.requestCount ?? 0
            )
            return relationship.fallbackConversationState
        case .none:
            break
        }

        return summary.badge.conversationState
    }

    static func displayStatus(
        for conversationState: ConversationState,
        requestCount: Int?,
        presence: ContactPresencePresentation
    ) -> ConversationDisplayStatus {
        switch conversationState {
        case .outgoingBeep:
            return .beep(direction: .outgoing, requestCount: max(requestCount ?? 1, 1))
        case .incomingBeep:
            return .beep(direction: .incoming, requestCount: max(requestCount ?? 1, 1))
        case .waitingForPeer:
            return .ready
        case .ready, .transmitting, .receiving:
            return .live
        case .idle:
            return presence == .offline ? .offline : .online
        }
    }

    static func contactListSection(for displayStatus: ConversationDisplayStatus) -> ConversationListSection {
        switch displayStatus {
        case .beep(let direction, _):
            switch direction {
            case .incoming:
                return .wantsToTalk
            case .outgoing:
                return .outgoingBeep
            }
        case .ready, .live:
            return .readyToTalk
        case .offline, .online:
            return .contacts
        }
    }

    static func availabilityPill(
        for presence: ContactPresencePresentation,
        isBusy: Bool = false
    ) -> ConversationAvailabilityPill {
        if isBusy {
            return .busy
        }

        switch presence {
        case .connected, .reachable:
            return .online
        case .offline:
            return .offline
        }
    }

    static func contactListPresentation(
        for conversationState: ConversationState,
        requestCount: Int?,
        presence: ContactPresencePresentation,
        isBusy: Bool = false
    ) -> ContactListPresentation {
        let displayStatus = displayStatus(
            for: conversationState,
            requestCount: requestCount,
            presence: presence
        )
        return ContactListPresentation(
            displayStatus: displayStatus,
            section: contactListSection(for: displayStatus),
            availabilityPill: availabilityPill(for: presence, isBusy: isBusy),
            requestCount: displayStatus.requestCount
        )
    }

    static func statusMessage(for context: ConversationDerivationContext) -> String {
        let effectiveState = effectiveState(for: context)

        guard context.selectedContactID == context.contactID else {
            switch context.systemSessionState {
            case .none:
                return "Ready to connect"
            case .active:
                return "System session active"
            case .mismatched:
                return "System session mismatch"
            }
        }

        switch context.systemSessionState {
        case .active(let activeContactID, _) where activeContactID != context.contactID:
            return "Another session is active"
        case .mismatched:
            return "System session mismatch"
        default:
            break
        }

        if context.pendingAction.pendingJoinContactID == context.contactID {
            return "Connecting..."
        }

        switch effectiveState {
        case .idle:
            return context.idleAvailabilityStatusMessage
        case .outgoingBeep:
            return "Beep sent to \(context.contactName)"
        case .incomingBeep:
            return "\(context.contactName) wants to talk"
        case .waitingForPeer:
            if context.channel?.membership.hasLocalMembership == true {
                return "Connecting..."
            }
            return "Waiting for \(context.contactName)"
        case .ready:
            return context.canTransmitNow ? "Connected" : "Connecting..."
        case .transmitting:
            return "Talking to \(context.contactName)"
        case .receiving:
            return "\(context.contactName) is talking"
        }
    }

    static func talkButtonLabel(
        conversationState: ConversationState?,
        isSelectedChannelJoined: Bool,
        beepCooldownRemaining: Int?
    ) -> String {
        switch conversationState {
        case .incomingBeep:
            return "Accept"
        case .outgoingBeep:
            if let beepCooldownRemaining {
                return "Beep again in \(beepCooldownRemaining)s"
            }
            return "Beep Again"
        case .waitingForPeer:
            return "Waiting for Peer"
        case .transmitting:
            return "Talking"
        case .receiving:
            return "Receiving"
        case .ready:
            return "Hold To Talk"
        case .idle, .none:
            return isSelectedChannelJoined ? "Waiting for Peer" : "Send Beep"
        }
    }

    static func primaryAction(
        conversationState: ConversationState?,
        isSelectedChannelJoined: Bool,
        canTransmitNow: Bool,
        isTransmitting: Bool,
        beepCooldownRemaining: Int?
    ) -> ConversationPrimaryAction {
        let label = talkButtonLabel(
            conversationState: conversationState,
            isSelectedChannelJoined: isSelectedChannelJoined,
            beepCooldownRemaining: beepCooldownRemaining
        )

        if canTransmitNow || conversationState == .transmitting {
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: label,
                isEnabled: true,
                style: isTransmitting ? .active : .accent
            )
        }

        switch conversationState {
        case .incomingBeep:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: true, style: .accent)
        case .outgoingBeep:
            return ConversationPrimaryAction(
                kind: .connect,
                label: label,
                isEnabled: beepCooldownRemaining == nil,
                style: beepCooldownRemaining == nil ? .accent : .muted
            )
        case .waitingForPeer, .receiving:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: false, style: .muted)
        case .idle, .ready, .none:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: true, style: .accent)
        case .transmitting:
            return ConversationPrimaryAction(kind: .holdToTalk, label: label, isEnabled: true, style: .active)
        }
    }

    static func primaryAction(
        selectedConversationState: SelectedConversationState,
        isSelectedChannelJoined: Bool,
        isTransmitting: Bool,
        beepCooldownRemaining: Int?
    ) -> ConversationPrimaryAction {
        switch selectedConversationState.phase {
        case .blockedByOtherSession, .systemMismatch:
            if selectedConversationState.conversationState == .outgoingBeep {
                return ConversationPrimaryAction(
                    kind: .connect,
                    label: talkButtonLabel(
                        conversationState: .outgoingBeep,
                        isSelectedChannelJoined: isSelectedChannelJoined,
                        beepCooldownRemaining: beepCooldownRemaining
                    ),
                    isEnabled: beepCooldownRemaining == nil,
                    style: .muted
                )
            }
            return ConversationPrimaryAction(
                kind: .connect,
                label: talkButtonLabel(
                    conversationState: selectedConversationState.conversationState,
                    isSelectedChannelJoined: isSelectedChannelJoined,
                    beepCooldownRemaining: beepCooldownRemaining
                ),
                isEnabled: false,
                style: .muted
            )
        case .friendReady:
            return ConversationPrimaryAction(
                kind: .connect,
                label: "Connect",
                isEnabled: true,
                style: .accent
            )
        case .wakeReady:
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: selectedConversationState.contactName.map { "Hold to wake \($0)" } ?? "Hold to wake",
                isEnabled: selectedConversationState.allowsHoldToTalk,
                style: .accent
            )
        case .localJoinFailed:
            return ConversationPrimaryAction(
                kind: .connect,
                label: "Try Again",
                isEnabled: true,
                style: .accent
            )
        case .waitingForPeer:
            if case .waitingForPeer(reason: .pendingJoin) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .backendConversationTransition) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .devicePTTTransition) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .friendReadyToConnect) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .localAudioPrewarm) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Hold To Talk",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .localTransportWarmup) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Hold To Talk",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .releaseRequiredAfterInterruptedTransmit) = selectedConversationState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Release To Retry",
                    isEnabled: false,
                    style: .muted
                )
            }
            return primaryAction(
                conversationState: selectedConversationState.conversationState,
                isSelectedChannelJoined: isSelectedChannelJoined,
                canTransmitNow: selectedConversationState.canTransmitNow,
                isTransmitting: isTransmitting,
                beepCooldownRemaining: beepCooldownRemaining
            )
        case .ready:
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: "Hold To Talk",
                isEnabled: selectedConversationState.allowsHoldToTalk,
                style: .accent
            )
        case .outgoingBeep:
            return ConversationPrimaryAction(
                kind: .connect,
                label: talkButtonLabel(
                    conversationState: .outgoingBeep,
                    isSelectedChannelJoined: isSelectedChannelJoined,
                    beepCooldownRemaining: beepCooldownRemaining
                ),
                isEnabled: beepCooldownRemaining == nil,
                style: beepCooldownRemaining == nil ? .accent : .muted
            )
        case .idle, .incomingBeep, .startingTransmit, .transmitting, .receiving:
            if selectedConversationState.phase == .incomingBeep,
               selectedConversationState.contactPresence == .offline {
                return ConversationPrimaryAction(
                    kind: .connect,
                    label: "Beep Back",
                    isEnabled: beepCooldownRemaining == nil,
                    style: beepCooldownRemaining == nil ? .accent : .muted
                )
            }
            return primaryAction(
                conversationState: selectedConversationState.conversationState,
                isSelectedChannelJoined: isSelectedChannelJoined,
                canTransmitNow: selectedConversationState.canTransmitNow,
                isTransmitting: isTransmitting,
                beepCooldownRemaining: beepCooldownRemaining
            )
        }
    }

    static func shouldShowCallScreen(
        selectedConversationState: SelectedConversationState,
        requestedExpanded: Bool
    ) -> Bool {
        if selectedConversationState.detail == .waitingForPeer(reason: .disconnecting) {
            return false
        }

        switch selectedConversationState.phase {
        case .waitingForPeer, .localJoinFailed, .ready, .wakeReady,
             .startingTransmit, .transmitting, .receiving,
             .blockedByOtherSession, .systemMismatch:
            return true
        case .friendReady:
            return requestedExpanded
        case .incomingBeep:
            return false
        case .outgoingBeep:
            return false
        case .idle:
            return false
        }
    }

    static func hasEstablishedCallScreenSessionClaim(
        contactID: UUID,
        selectedConversationState: SelectedConversationState,
        isJoined: Bool,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool
    ) -> Bool {
        guard !selectedConversationState.relationship.hasPendingBeep else {
            return false
        }
        if isJoined, activeChannelID == contactID {
            return true
        }
        if systemSessionMatchesContact {
            return true
        }
        return false
    }

    static func reconciliationAction(for context: ConversationDerivationContext) -> SelectedConversationReconciliationAction {
        reconcileAction(for: context, relationship: context.relationship)
    }

    private static func reconcileAction(
        for context: ConversationDerivationContext,
        relationship: BeepThreadProjection
    ) -> SelectedConversationReconciliationAction {
        guard context.selectedContactID == context.contactID else {
            return .none
        }

        if context.pendingAction.pendingJoinContactID == context.contactID,
           !context.pendingJoinHasTerminalBackendMembershipLoss,
           !context.pendingJoinIsStaleWithoutDevicePTTEvidence {
            return .none
        }

        if context.pendingAction.pendingTeardownContactID == context.contactID {
            return .none
        }

        if let localJoinFailure = context.localJoinFailure,
           localJoinFailure.contactID == context.contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return .none
        }

        if context.shouldTreatSystemMismatchAsRecoverable {
            return .none
        }

        let explicitLeaveRequested = context.explicitLeaveRequested

        switch context.devicePTTContinuityProjection {
        case .systemMismatch:
            return .teardownDevicePTTSession(contactID: context.contactID)
        case .inactive, .transitioning, .connected, .blockedByOtherSession, .localJoinFailed, .pendingJoin, .disconnecting:
            break
        }

        let localDevicePTTEvidencePresent = context.devicePTTContinuityProjection.localDevicePTTEvidencePresent

        if relationship != .none,
           !context.pendingConnectAcceptedIncomingBeep,
           !context.backendJoinSettling,
           context.pendingAction.pendingJoinContactID != context.contactID,
           context.rawLocalDevicePTTEvidencePresent,
           !context.backendShowsEstablishedReadyConversation,
           !explicitLeaveRequested {
            return .teardownDevicePTTSession(contactID: context.contactID)
        }

        if context.localTransmit.preservesConnectedDevicePTTContinuity && localDevicePTTEvidencePresent {
            return .none
        }

        if explicitLeaveRequested,
           context.systemSessionState == .none,
           localDevicePTTEvidencePresent {
            return .teardownDevicePTTSession(contactID: context.contactID)
        }

        if context.wakeRecoveryInFlight && localDevicePTTEvidencePresent {
            return .none
        }

        if context.backendSignalingJoinRecoveryActive && localDevicePTTEvidencePresent && !explicitLeaveRequested {
            return .none
        }

        if context.backendMembershipIsStaleWithoutDevicePTTEvidence {
            return .clearStaleBackendMembership(contactID: context.contactID)
        }

        if context.backendInactiveReadinessInvalidatesLocalDevicePTT {
            return .teardownDevicePTTSession(contactID: context.contactID)
        }

        if context.establishedConnectedSessionLostTransmitAuthorityWaitingForPeer {
            return .teardownDevicePTTSession(contactID: context.contactID)
        }

        switch context.backendChannelReadiness {
        case .absent:
            if localDevicePTTEvidencePresent,
               !context.backendJoinSettling,
               !context.controlPlaneReconnectGraceActive,
               !context.wakeRecoveryInFlight,
               !context.backendShowsWakeCapableReceiverRecovery,
               !context.systemMismatchChannelMatchesContact,
               !context.unattributedJoinedSystemMismatch,
               !context.channelHasBeepThreadProjection,
               !context.remoteParticipantSignalIsTransmitting,
               !explicitLeaveRequested,
               (
                   context.channel != nil
                       || (
                           context.hadConnectedDevicePTTContinuity
                               && !context.controlPlaneReconnectGraceActive
                       )
               ) {
                return .teardownDevicePTTSession(contactID: context.contactID)
            }
            return .none
        case .peerOnly:
            if localDevicePTTEvidencePresent,
               context.channel != nil,
               !context.backendJoinSettling,
               !context.controlPlaneReconnectGraceActive,
               !context.wakeRecoveryInFlight,
               !context.backendShowsWakeCapableReceiverRecovery,
               !context.systemMismatchChannelMatchesContact,
               !context.unattributedJoinedSystemMismatch,
               !context.channelHasBeepThreadProjection,
               !context.remoteParticipantSignalIsTransmitting,
               !explicitLeaveRequested {
                return .teardownDevicePTTSession(contactID: context.contactID)
            }
            return .none
        case .selfOnly, .both:
            break
        }

        if case .both(let peerDeviceConnected, _, _) = context.backendChannelReadiness,
           peerDeviceConnected,
           context.devicePTTReadiness != .aligned,
           context.backendReadyAutoRestoreAllowed,
           !context.pendingAction.isLeaveInFlight(for: context.contactID),
           !explicitLeaveRequested {
            switch context.devicePTTRestoreState {
            case .absent, .partialMissingSystemSession:
                return .restoreDevicePTTSession(contactID: context.contactID)
            case .restoring, .pendingJoin:
                return .none
            }
        }

        if context.backendWakeCapableSelfMembershipCanRestoreMissingDevicePTTEvidence,
           context.devicePTTReadiness != .aligned,
           context.backendReadyAutoRestoreAllowed,
           !context.pendingAction.isLeaveInFlight(for: context.contactID),
           !explicitLeaveRequested {
            switch context.devicePTTRestoreState {
            case .absent, .partialMissingSystemSession:
                return .restoreDevicePTTSession(contactID: context.contactID)
            case .restoring, .pendingJoin:
                return .none
            }
        }

        return .none
    }
}

private extension ConversationStateMachine {
    static func connectedSelectedConversationState(
        contactName: String,
        connectedExecution: ConnectedExecutionProjection?,
        connectedControlPlane: ConnectedControlPlaneProjection,
        devicePTTContinuity: DevicePTTContinuityProjection
    ) -> (detail: SelectedConversationDetail, statusMessage: String)? {
        guard devicePTTContinuity == .connected else {
            return nil
        }

        if let executionProjection = connectedExecution {
            switch executionProjection {
            case .wakeActivating:
                return (
                    .waitingForPeer(reason: .systemWakeActivation),
                    "Waiting for system audio activation..."
                )
            case .wakeDeferredUntilForeground(let message):
                return (
                    .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground),
                    message
                )
            case .stopping:
                return (
                    .readyHoldToTalkDisabled,
                    "Connected"
                )
            case .releaseRequired:
                return (
                    .waitingForPeer(reason: .releaseRequiredAfterInterruptedTransmit),
                    "Release and press again."
                )
            case .startingTransmit(let stage):
                switch stage {
                case .requestingLease, .awaitingSystemTransmit, .awaitingAudioSession:
                    return (.startingTransmit(stage: stage), "Connecting...")
                case .awaitingAudioConnection(let mediaState):
                    switch mediaState {
                    case .failed:
                        return (.startingTransmit(stage: stage), "Audio unavailable")
                    case .preparing, .idle, .closed:
                        return (.startingTransmit(stage: stage), "Connecting...")
                    case .connected:
                        return (.transmitting, "Talking to \(contactName)")
                    }
                }
            case .transmitting:
                return (.transmitting, "Talking to \(contactName)")
            }
        }

        switch connectedControlPlane {
        case .unavailable:
            return nil
        case .wakeReady:
            return (.wakeReady, "Hold to talk to wake \(contactName)")
        case .waiting(let reason, let statusMessage):
            return (.waitingForPeer(reason: reason), statusMessage)
        case .ready:
            return (.ready, "Connected")
        case .readyHoldToTalkDisabled:
            return (.readyHoldToTalkDisabled, "Connected")
        case .transmitting:
            return (.transmitting, "Talking to \(contactName)")
        case .receiving:
            return (.receiving, "\(contactName) is talking")
        }
    }
}

private extension ConversationDerivationContext {
    var devicePTTContinuityProjection: DevicePTTContinuityProjection {
        switch systemSessionState {
        case .active(let activeContactID, _) where activeContactID != contactID:
            return .blockedByOtherSession
        case .mismatched:
            if shouldTreatSystemMismatchAsRecoverable {
                return .transitioning
            }
            return .systemMismatch
        case .none, .active:
            break
        }

        if localSession.isOtherSessionActive {
            return .blockedByOtherSession
        }

        if let localJoinFailure,
           localJoinFailure.contactID == contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return .localJoinFailed(recoveryMessage: localJoinFailure.reason.recoveryMessage)
        }

        if devicePTTRestoreBarrier.blocksAutomaticRestore {
            return .disconnecting
        }

        if pendingAction.isLeaveInFlight(for: contactID) {
            return .disconnecting
        }

        if pendingJoinHasTerminalBackendMembershipLoss {
            return .disconnecting
        }

        if backendInactiveReadinessInvalidatesLocalDevicePTT {
            return .disconnecting
        }

        if blockedAutomaticRestoreIsAwaitingBackendConvergence {
            return .disconnecting
        }

        if establishedConnectedSessionLostTransmitAuthorityWaitingForPeer {
            return .disconnecting
        }

        if pendingAction.pendingJoinContactID == contactID {
            return .pendingJoin
        }

        if backendExplicitlyInactiveWithoutMembership,
           !controlPlaneReconnectGraceActive,
           !wakeRecoveryInFlight,
           !backendShowsWakeCapableReceiverRecovery,
           devicePTTReadiness != .none {
            return .disconnecting
        }

        switch devicePTTReadiness {
        case .none:
            return .inactive
        case .partial:
            return .transitioning
        case .aligned:
            return .connected
        }
    }

    var connectedExecutionProjection: ConnectedExecutionProjection? {
        guard devicePTTContinuityProjection == .connected else { return nil }

        if let incomingWakeActivationState {
            switch incomingWakeActivationState {
            case .signalBuffered, .awaitingSystemActivation:
                return .wakeActivating
            case .systemActivationTimedOutWaitingForForeground:
                return .wakeDeferredUntilForeground(
                    message: "Wake received, but system audio never activated. Unlock to resume audio."
                )
            case .systemActivationInterruptedByTransmitEnd:
                return .wakeDeferredUntilForeground(
                    message: "Wake ended before system audio activated."
                )
            case .appManagedFallback, .systemActivated:
                break
            }
        }

        if localIsStopping {
            return .stopping
        }

        if localRequiresFreshPress {
            return .releaseRequired
        }

        switch localTransmit {
        case .starting(let stage):
            return .startingTransmit(stage)
        case .transmitting:
            return .transmitting
        case .idle, .stopping, .releaseRequired:
            break
        }

        return nil
    }

    var connectedControlPlaneProjection: ConnectedControlPlaneProjection {
        guard devicePTTContinuityProjection == .connected else {
            return .unavailable
        }

        if shouldPreserveReadyAfterObservedRemoteTransmitStop {
            return .ready
        }
        if shouldPreserveReadyDisabledAfterObservedRemoteTransmitStop {
            return .readyHoldToTalkDisabled
        }

        if backendShowsWakeCapableReceiverRecovery {
            guard localTransportReadyForTransmit else {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }
            return .wakeReady
        }

        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              let readinessStatus else {
            return .unavailable
        }

        let shouldPreferWakeReadyDespiteStalePeerConnectivity: Bool = {
            guard case .wakeCapable = remoteWakeCapabilityState,
                  !backendJoinSettling,
                  hadConnectedDevicePTTContinuity,
                  !peerDeviceConnected,
                  !canTransmit else {
                return false
            }

            switch readinessStatus {
            case .waitingForSelf, .waitingForPeer:
                switch remoteAudioReadinessState {
                case .wakeCapable, .unknown:
                    return true
                case .ready, .waiting:
                    return false
                }
            case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let effectivePeerDeviceConnected =
            peerDeviceConnected
            || directMediaPathActive
            || remoteAudioReadinessState == .ready
            || remoteParticipantSignalIsTransmitting
            || readinessStatus.isTransmitActive
            || readinessStatus == .ready

        let connectionTransmitReady = effectivePeerDeviceConnected
        if connectionTransmitReady && remoteParticipantSignalIsTransmitting && !remoteTransmitStopObserved {
            return .receiving
        }
        if remotePlaybackDrainBlocksTransmit {
            return .readyHoldToTalkDisabled
        }
        if shouldPreferWakeReadyDespiteStalePeerConnectivity {
            guard localTransportReadyForTransmit else {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }
            return .wakeReady
        }
        if shouldExposeWakeReadyWithoutTransmitAuthority {
            return .wakeReady
        }

        let authoritativeBackendReady = backendReadyAuthoritativelySatisfiesRemoteAudio
        let authoritativeRecoveryReady =
            authoritativeBackendReady
            || backendReadyAuthoritativelySatisfiesWakeCapability

        if friendReadyHintOptimisticallySatisfiesConnectedUI {
            return .ready
        }

        if backendSignalingJoinRecoveryActive,
           !shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           !authoritativeRecoveryReady {
            return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
        }

        if shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           controlPlaneReconnectGraceActive,
           canTransmit {
            return .ready
        }

        if shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           !canTransmit {
            if remoteAudioReadinessAllowsWakeProjection,
               case .wakeCapable = remoteWakeCapabilityState {
                return .wakeReady
            }
            return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
        }

        if connectionTransmitReady && canTransmit {
            if shouldKeepReadyProjectionDuringLocalWarmup {
                return .ready
            }
            if shouldProjectReadyForWarmRelayWhileLocalMediaStarts {
                return .ready
            }

            guard localTransportReadyForTransmit else {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }

            if hadConnectedDevicePTTContinuity && authoritativeBackendReady {
                return .ready
            }

            if directMediaPathActive {
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState,
                   !authoritativeBackendReady {
                    return .wakeReady
                }
                return .ready
            }

            if firstTalkStartupProfile == .directQuicWarming {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }

            switch localMediaWarmupState {
            case .cold:
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState {
                    return .wakeReady
                }
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Connecting...")
            case .prewarming:
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState {
                    return .wakeReady
                }
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Connecting...")
            case .failed:
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Audio unavailable")
            case .ready:
                break
            }

            if remoteAudioReadinessState == .wakeCapable,
               case .wakeCapable = remoteWakeCapabilityState {
                return .wakeReady
            }

            if authoritativeBackendReady {
                return .ready
            }

            switch remoteAudioReadinessState {
            case .ready:
                break
            case .wakeCapable:
                return .waiting(
                    reason: .remoteAudioPrewarm,
                    statusMessage: "Waiting for \(contactName)'s audio..."
                )
            case .waiting, .unknown:
                return .waiting(
                    reason: .remoteAudioPrewarm,
                    statusMessage: "Waiting for \(contactName)'s audio..."
                )
            }
        }

        if !effectivePeerDeviceConnected {
            switch remoteWakeCapabilityState {
            case .wakeCapable:
                if !backendJoinSettling,
                   hadConnectedDevicePTTContinuity,
                   remoteAudioReadinessAllowsWakeProjection {
                    return .wakeReady
                }
                return .waiting(
                    reason: .backendConversationTransition,
                    statusMessage: "Connecting..."
                )
            case .unavailable:
                return .waiting(
                    reason: .remoteWakeUnavailable,
                    statusMessage: "Waiting for \(contactName) to reconnect"
                )
            }
        }

        switch readinessStatus {
        case .peerTransmitting:
            guard connectionTransmitReady else {
                return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
            }
            guard !remoteTransmitStopObserved else {
                if canTransmit {
                    return .ready
                }
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState {
                    return .wakeReady
                }
                return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
            }
            return .receiving
        case .selfTransmitting:
            guard connectionTransmitReady else {
                return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
            }
            guard localTransmit.hasTransmitIntent else {
                return .ready
            }
            return .transmitting
        case .ready where canTransmit:
            return .ready
        case .waitingForSelf, .waitingForPeer, .ready:
            return .waiting(reason: .backendConversationTransition, statusMessage: "Connecting...")
        case .inactive, .unknown:
            return .unavailable
        }
    }

    var shouldPreserveConnectedReadinessDuringControlPlaneTransition: Bool {
        guard hadConnectedDevicePTTContinuity,
              devicePTTReadiness == .aligned,
              (localTransportReadyForTransmit),
              case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer:
            return true
        case .ready:
            return backendSignalingJoinRecoveryActive || controlPlaneReconnectGraceActive
        case .inactive, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var shouldExposeWakeReadyWithoutTransmitAuthority: Bool {
        guard hadConnectedDevicePTTContinuity,
              !backendJoinSettling,
              devicePTTReadiness == .aligned,
              localTransportReadyForTransmit,
              !remoteParticipantSignalIsTransmitting,
              !remotePlaybackDrainBlocksTransmit,
              remoteAudioReadinessState == .ready,
              case .wakeCapable = remoteWakeCapabilityState,
              case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              !peerDeviceConnected,
              !canTransmit else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer:
            return true
        case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var effectivePeerDeviceConnectedForTransmit: Bool {
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness else {
            return false
        }

        return peerDeviceConnected
            || directMediaPathActive
            || remoteAudioReadinessState == .ready
            || remoteParticipantSignalIsTransmitting
            || readinessStatus?.isTransmitActive == true
            || readinessStatus == .ready
    }

    var devicePTTReadiness: DevicePTTReadiness {
        let hasAnyLocalSessionSignal =
            systemSessionMatchesContact
            || localSession.selectedEvidence != nil
        guard hasAnyLocalSessionSignal else {
            return .none
        }

        let isAligned: Bool = {
            guard systemSessionMatchesContact,
                  let selectedEvidence = localSession.selectedEvidence else {
                return false
            }
            return selectedEvidence.isJoined
                && selectedEvidence.activeChannelID == contactID
        }()
        return isAligned ? .aligned : .partial
    }

    var devicePTTRestoreState: DevicePTTRestoreState {
        if pendingAction.pendingJoinContactID == contactID,
           !pendingJoinIsStaleWithoutDevicePTTEvidence {
            return .pendingJoin
        }

        switch devicePTTReadiness {
        case .none:
            return .absent
        case .aligned:
            return .restoring
        case .partial:
            guard systemSessionState == .none,
                  let selectedEvidence = localSession.selectedEvidence else {
                return .restoring
            }
            return .partialMissingSystemSession(selectedEvidence)
        }
    }

    var backendChannelReadiness: BackendChannelReadiness {
        guard let channel else { return .absent }

        switch channel.membership {
        case .absent:
            return .absent
        case .peerOnly(let peerDeviceConnected):
            return .peerOnly(
                peerDeviceConnected: peerDeviceConnected,
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        case .selfOnly:
            return .selfOnly(
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        case .both(let peerDeviceConnected):
            return .both(
                peerDeviceConnected: peerDeviceConnected,
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        }
    }

    var canTransmitNow: Bool {
        guard selectedContactID == contactID,
              devicePTTReadiness == .aligned,
              localTransmit == .idle,
              !remoteParticipantSignalIsTransmitting,
              !remotePlaybackDrainBlocksTransmit,
              !controlPlaneReconnectGraceActive,
              (!backendSignalingJoinRecoveryActive || backendReadyAuthoritativelySatisfiesRemoteAudio),
              case .both(_, let canTransmit, _) = backendChannelReadiness,
              effectivePeerDeviceConnectedForTransmit else {
            return false
        }
        guard !firstTalkStartupProfile.blocksFirstTalkTransmit else {
            return false
        }
        let localMediaReadyForTransmit = localMediaWarmupState == .ready || directMediaPathActive
        return canTransmit
            && localMediaReadyForTransmit
            && localTransportReadyForTransmit
            && remoteAudioReadyForTransmit
    }

    var remoteAudioReadyForTransmit: Bool {
        if directMediaPathActive {
            if remoteAudioReadinessState == .wakeCapable,
               case .wakeCapable = remoteWakeCapabilityState {
                return backendReadyAuthoritativelySatisfiesRemoteAudio
            }
            return true
        }

        guard effectivePeerDeviceConnectedForTransmit else {
            return false
        }

        switch remoteAudioReadinessState {
        case .ready:
            return true
        case .wakeCapable, .waiting, .unknown:
            return backendReadyAuthoritativelySatisfiesRemoteAudio
        }
    }

    var backendReadyAuthoritativelySatisfiesRemoteAudio: Bool {
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              readinessStatus == .ready,
              peerDeviceConnected,
              canTransmit else {
            return false
        }

        switch remoteWakeCapabilityState {
        case .wakeCapable:
            return remoteAudioReadinessState == .ready
        case .unavailable:
            return remoteAudioReadinessState == .ready
        }
    }

    var backendReadyAuthoritativelySatisfiesWakeCapability: Bool {
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              readinessStatus == .ready,
              peerDeviceConnected,
              canTransmit,
              remoteAudioReadinessState == .wakeCapable,
              case .wakeCapable = remoteWakeCapabilityState else {
            return false
        }

        return true
    }

    var shouldPreserveReadyAfterObservedRemoteTransmitStop: Bool {
        guard remoteTransmitStopObserved,
              remoteTransmitStopProjectionGraceActive,
              hadConnectedDevicePTTContinuity,
              devicePTTReadiness == .aligned,
              !localTransmit.hasTransmitIntent,
              !remoteParticipantSignalIsTransmitting,
              !remotePlaybackDrainBlocksTransmit,
              localTransportReadyForTransmit,
              case .both(_, let canTransmit, let readinessStatus) = backendChannelReadiness,
              canTransmit,
              let readinessStatus else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer, .ready, .peerTransmitting:
            return true
        case .inactive, .selfTransmitting, .unknown:
            return false
        }
    }

    var shouldPreserveReadyDisabledAfterObservedRemoteTransmitStop: Bool {
        guard remoteTransmitStopObserved,
              remoteTransmitStopProjectionGraceActive,
              hadConnectedDevicePTTContinuity,
              devicePTTReadiness == .aligned,
              !localTransmit.hasTransmitIntent,
              !remoteParticipantSignalIsTransmitting,
              localTransportReadyForTransmit,
              case .both(_, let canTransmit, let readinessStatus) = backendChannelReadiness,
              !canTransmit,
              let readinessStatus else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer, .ready, .peerTransmitting:
            return true
        case .inactive, .selfTransmitting, .unknown:
            return false
        }
    }

    var shouldKeepReadyProjectionDuringLocalWarmup: Bool {
        guard hadConnectedDevicePTTContinuity,
              devicePTTReadiness == .aligned,
              !backendSignalingJoinRecoveryActive,
              !controlPlaneReconnectGraceActive,
              localTransmit == .idle,
              !remoteParticipantSignalIsTransmitting,
              !remotePlaybackDrainBlocksTransmit,
              remoteAudioReadinessState == .ready,
              case .both(_, let canTransmit, let readinessStatus) = backendChannelReadiness,
              canTransmit,
              readinessStatus == .ready else {
            return false
        }

        return true
    }

    var shouldProjectReadyForWarmRelayWhileLocalMediaStarts: Bool {
        guard firstTalkStartupProfile == .relayWarm,
              localMediaWarmupCanUseWarmRelayStartupEvidence,
              devicePTTReadiness == .aligned,
              !backendSignalingJoinRecoveryActive,
              !controlPlaneReconnectGraceActive,
              localTransmit == .idle,
              !remoteParticipantSignalIsTransmitting,
              !remotePlaybackDrainBlocksTransmit,
              localTransportReadyForTransmit,
              remoteAudioReadinessState == .ready,
              backendReadyAuthoritativelySatisfiesRemoteAudio else {
            return false
        }

        switch localMediaWarmupState {
        case .cold, .prewarming:
            return true
        case .ready, .failed:
            return false
        }
    }

    var localMediaWarmupCanUseWarmRelayStartupEvidence: Bool {
        if hadConnectedDevicePTTContinuity {
            return true
        }
        guard let firstTalkReadiness,
              !firstTalkReadiness.localMediaWarm,
              firstTalkReadiness.receiverWarm,
              firstTalkReadiness.transportWarm else {
            return false
        }
        return true
    }

    var friendReadyHintOptimisticallySatisfiesConnectedUI: Bool {
        guard devicePTTReadiness == .aligned else { return false }
        guard localMediaWarmupState == .ready || directMediaPathActive else { return false }
        guard localTransportReadyForTransmit else { return false }
        guard remoteAudioReadinessState == .ready,
              case .wakeCapable = remoteWakeCapabilityState else {
            return false
        }
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              canTransmit,
              peerDeviceConnected || directMediaPathActive else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer, .ready:
            return true
        case .inactive, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var startingTransmitStage: StartingTransmitStage? {
        localTransmit.startingTransmitStage
    }
}

private extension TurboChannelReadinessStatus {
    var isTransmitActive: Bool {
        switch self {
        case .selfTransmitting, .peerTransmitting:
            return true
        case .inactive, .waitingForSelf, .waitingForPeer, .ready, .unknown:
            return false
        }
    }
}

enum ContactDirectory {
    static let suggestedDevHandles: [String] = [
        "@turbo-ios",
        "@alice",
        "@bob",
        "@avery",
        "@blake",
        "@casey",
        "@devin",
        "@elliot",
        "@finley",
        "@gray",
        "@harper",
        "@indigo",
        "@jules",
        "@kai",
        "@logan",
        "@maya",
        "@noel",
        "@orion",
        "@parker",
        "@quinn",
        "@riley",
        "@sasha",
        "@tatum",
    ]

    static func ensureContact(
        handle: String,
        remoteUserId: String,
        channelId: String,
        displayName: String? = nil,
        localName: String? = nil,
        existingContacts: [Contact]
    ) -> (contacts: [Contact], contactID: UUID) {
        let normalizedHandle = Contact.normalizedHandle(handle)
        let stableID = Contact.stableID(remoteUserId: remoteUserId, fallbackHandle: normalizedHandle)
        let stableChannelID = channelId.isEmpty ? nil : stableChannelUUID(for: channelId)
        let normalizedLocalName = Contact.normalizedLocalName(localName)

        var contacts = existingContacts
        if let index = contacts.firstIndex(where: {
            ($0.remoteUserId != nil && $0.remoteUserId == remoteUserId)
                || Contact.normalizedHandle($0.handle) == normalizedHandle
        }) {
            if let displayName {
                contacts[index].profileName = Contact.normalizedProfileName(
                    displayName,
                    fallbackHandle: normalizedHandle
                )
            }
            contacts[index].localName = normalizedLocalName
            contacts[index].handle = normalizedHandle
            contacts[index].remoteUserId = remoteUserId
            if let stableChannelID {
                contacts[index].backendChannelId = channelId
                contacts[index].channelId = stableChannelID
            } else if contacts[index].backendChannelId != nil {
                contacts[index].backendChannelId = nil
                contacts[index].channelId = UUID()
            }
            return (contacts, contacts[index].id)
        }

        let normalizedProfileName =
            Contact.normalizedProfileName(displayName ?? "", fallbackHandle: normalizedHandle)

        contacts.append(
            Contact(
                id: stableID,
                profileName: normalizedProfileName,
                localName: normalizedLocalName,
                handle: normalizedHandle,
                isOnline: false,
                channelId: stableChannelID ?? UUID(),
                backendChannelId: channelId.isEmpty ? nil : channelId,
                remoteUserId: remoteUserId
            )
        )
        contacts.sort { $0.handle < $1.handle }
        return (contacts, stableID)
    }

    static func retainedContacts(
        existingContacts: [Contact],
        authoritativeContactIDs: Set<UUID>
    ) -> [Contact] {
        existingContacts
            .filter { authoritativeContactIDs.contains($0.id) }
            .sorted { $0.handle < $1.handle }
    }

    static func authoritativeContactIDs(
        trackedContactIDs: Set<UUID>,
        summaryContactIDs: Set<UUID>,
        selectedContactID: UUID?,
        activeChannelID: UUID?,
        mediaSessionContactID: UUID?,
        pendingJoinContactID: UUID?,
        beepContactIDs: Set<UUID>
    ) -> Set<UUID> {
        var ids = trackedContactIDs
            .union(summaryContactIDs)
            .union(beepContactIDs)
        if let selectedContactID {
            ids.insert(selectedContactID)
        }
        if let activeChannelID {
            ids.insert(activeChannelID)
        }
        if let mediaSessionContactID {
            ids.insert(mediaSessionContactID)
        }
        if let pendingJoinContactID {
            ids.insert(pendingJoinContactID)
        }
        return ids
    }

    static func stableChannelUUID(for backendChannelID: String) -> UUID {
        let digest = SHA256.hash(data: Data("channel:\(backendChannelID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
