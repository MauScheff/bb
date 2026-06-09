import Foundation

public struct ContactID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineUserID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineDeviceID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineChannelID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineTransmitID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineAudioChunkID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineAudioSequence: Hashable, Codable, Comparable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: EngineAudioSequence, rhs: EngineAudioSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct EnginePayloadDigest: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct EngineAttemptID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum EngineApplicationState: Equatable, Codable, Sendable {
    case active
    case inactive
    case background
    case locked

    public var needsSystemPTTActivationForPlayback: Bool {
        switch self {
        case .active, .inactive:
            return false
        case .background, .locked:
            return true
        }
    }
}

public enum EngineTransportPath: String, Codable, Equatable, Sendable {
    case relayWebSocket
    case fastRelay
    case directQuic
}

public enum TransportLane: String, Codable, Equatable, Sendable, CaseIterable {
    case directQuic
    case fastRelayQuic
    case fastRelayTcp
    case webSocketTcp

    public var priority: Int {
        switch self {
        case .directQuic:
            return 4
        case .fastRelayQuic:
            return 3
        case .fastRelayTcp:
            return 2
        case .webSocketTcp:
            return 0
        }
    }

    public var legacyPath: EngineTransportPath {
        switch self {
        case .directQuic:
            return .directQuic
        case .fastRelayQuic, .fastRelayTcp:
            return .fastRelay
        case .webSocketTcp:
            return .relayWebSocket
        }
    }

    public var diagnosticsValue: String {
        switch self {
        case .directQuic:
            return "direct-quic"
        case .fastRelayQuic:
            return "fast-relay-quic"
        case .fastRelayTcp:
            return "fast-relay-tcp"
        case .webSocketTcp:
            return "websocket-tcp"
        }
    }

    public static var priorityOrder: [TransportLane] {
        [.directQuic, .fastRelayQuic, .fastRelayTcp]
    }
}

public struct TransportCapabilityEvidence: Equatable, Codable, Sendable {
    public let lane: TransportLane
    public let reason: TransportCapabilityReason

    public init(lane: TransportLane, reason: TransportCapabilityReason) {
        self.lane = lane
        self.reason = reason
    }
}

public enum TransportCapabilityReason: Equatable, Codable, Sendable {
    case directQuicDatagram
    case fastRelayQuicDatagram
    case fastRelayTcpFallback
    case webSocketFallback
    case backendControlPlane
}

public enum TransportCapability: Equatable, Codable, Sendable {
    case unorderedPacketMedia(TransportCapabilityEvidence)
    case orderedReliableMedia(TransportCapabilityEvidence)
    case controlOnly(TransportCapabilityEvidence)
    case unavailable(TransportUnavailableReason)

    public static func defaultCapability(for lane: TransportLane) -> TransportCapability {
        switch lane {
        case .directQuic:
            return .unorderedPacketMedia(
                TransportCapabilityEvidence(lane: lane, reason: .directQuicDatagram)
            )
        case .fastRelayQuic:
            return .unorderedPacketMedia(
                TransportCapabilityEvidence(lane: lane, reason: .fastRelayQuicDatagram)
            )
        case .fastRelayTcp:
            return .orderedReliableMedia(
                TransportCapabilityEvidence(lane: lane, reason: .fastRelayTcpFallback)
            )
        case .webSocketTcp:
            return .controlOnly(
                TransportCapabilityEvidence(lane: lane, reason: .webSocketFallback)
            )
        }
    }

    public var isMediaViable: Bool {
        switch self {
        case .unorderedPacketMedia, .orderedReliableMedia:
            return true
        case .controlOnly, .unavailable:
            return false
        }
    }

    public var mediaCapability: EngineMediaTransportCapability {
        switch self {
        case .unorderedPacketMedia(let evidence):
            switch evidence.lane {
            case .directQuic:
                return .unorderedPacketMedia(
                    UnorderedPacketMediaEvidence(path: .directQuic, reason: .directQuicDatagram)
                )
            case .fastRelayQuic:
                return .unorderedPacketMedia(
                    UnorderedPacketMediaEvidence(path: .fastRelay, reason: .fastRelayPacketRelay)
                )
            case .fastRelayTcp:
                return .orderedReliableMedia(
                    OrderedReliableMediaEvidence(path: .fastRelay, reason: .fastRelayTcpFallback)
                )
            case .webSocketTcp:
                return .controlReliable(
                    ControlReliableEvidence(path: .relayWebSocket, reason: .backendControlPlane)
                )
            }
        case .orderedReliableMedia(let evidence):
            switch evidence.lane {
            case .directQuic:
                return .unorderedPacketMedia(
                    UnorderedPacketMediaEvidence(path: .directQuic, reason: .directQuicDatagram)
                )
            case .fastRelayQuic:
                return .unorderedPacketMedia(
                    UnorderedPacketMediaEvidence(path: .fastRelay, reason: .fastRelayPacketRelay)
                )
            case .fastRelayTcp:
                return .orderedReliableMedia(
                    OrderedReliableMediaEvidence(path: .fastRelay, reason: .fastRelayTcpFallback)
                )
            case .webSocketTcp:
                return .controlReliable(
                    ControlReliableEvidence(path: .relayWebSocket, reason: .backendControlPlane)
                )
            }
        case .controlOnly:
            return .controlReliable(
                ControlReliableEvidence(path: .relayWebSocket, reason: .backendControlPlane)
            )
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}

public struct TransportLaneStatus: Equatable, Codable, Sendable {
    public let lane: TransportLane
    public var capability: TransportCapability

    public init(lane: TransportLane, capability: TransportCapability) {
        self.lane = lane
        self.capability = capability
    }
}

public struct TransportLaneAvailability: Equatable, Codable, Sendable {
    public let lane: TransportLane
    public let capability: TransportCapability
    public let networkPathGeneration: UInt64

    public init(
        lane: TransportLane,
        capability: TransportCapability? = nil,
        networkPathGeneration: UInt64
    ) {
        self.lane = lane
        self.capability = capability ?? TransportCapability.defaultCapability(for: lane)
        self.networkPathGeneration = networkPathGeneration
    }
}

public struct TransportLaneFailure: Equatable, Codable, Sendable {
    public let lane: TransportLane
    public let reason: TransportUnavailableReason
    public let networkPathGeneration: UInt64

    public init(
        lane: TransportLane,
        reason: TransportUnavailableReason,
        networkPathGeneration: UInt64
    ) {
        self.lane = lane
        self.reason = reason
        self.networkPathGeneration = networkPathGeneration
    }
}

public struct MediaEpochID: Equatable, Hashable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let senderDeviceID: EngineDeviceID
    public let receiverDeviceID: EngineDeviceID
    public let transmitID: EngineTransmitID

    public init(
        channelID: EngineChannelID,
        senderDeviceID: EngineDeviceID,
        receiverDeviceID: EngineDeviceID,
        transmitID: EngineTransmitID
    ) {
        self.channelID = channelID
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
        self.transmitID = transmitID
    }
}

public enum MediaLaneState: Equatable, Codable, Sendable {
    case unavailable(reason: TransportUnavailableReason, generation: UInt64)
    case warming(attemptID: EngineAttemptID, generation: UInt64)
    case available(proof: TransportCapability, generation: UInt64)
    case failed(reason: TransportUnavailableReason, generation: UInt64)

    public var generation: UInt64 {
        switch self {
        case .unavailable(_, let generation),
             .warming(_, let generation),
             .available(_, let generation),
             .failed(_, let generation):
            return generation
        }
    }

    public var isMediaViable: Bool {
        switch self {
        case .available(let proof, _):
            return proof.isMediaViable
        case .unavailable, .warming, .failed:
            return false
        }
    }
}

public struct MediaLaneAvailabilityMap: Equatable, Codable, Sendable {
    public private(set) var states: [TransportLane: MediaLaneState]

    public init(states: [TransportLane: MediaLaneState] = [:]) {
        self.states = states
    }

    @discardableResult
    public mutating func join(_ state: MediaLaneState, for lane: TransportLane) -> Bool {
        if let current = states[lane], current.generation > state.generation {
            return false
        }
        states[lane] = state
        return true
    }

    public func state(for lane: TransportLane) -> MediaLaneState? {
        states[lane]
    }

    public var viableLanes: [TransportLane] {
        TransportLane.priorityOrder.filter { states[$0]?.isMediaViable == true }
    }
}

public enum MediaDeliveryProof: Equatable, Codable, Sendable {
    case firstAudioQueued(frameIndex: UInt64?)
    case playbackAck(frameIndex: UInt64?, transport: TransportLane)
    case receiveAccepted(frameIndex: UInt64?, transport: TransportLane)
}

public struct ProvenMediaLane: Equatable, Codable, Sendable {
    public let lane: TransportLane
    public let proof: MediaDeliveryProof

    public init(lane: TransportLane, proof: MediaDeliveryProof) {
        self.lane = lane
        self.proof = proof
    }
}

public enum MediaEpochRescueState: Equatable, Codable, Sendable {
    case none(primary: TransportLane)
    case available(primary: TransportLane, rescue: TransportLane)
    case attempting(primary: TransportLane, rescue: TransportLane, reason: TransportUnavailableReason)
    case rescued(primary: TransportLane, rescue: TransportLane)
    case broken(reason: TransportUnavailableReason)

    public var primaryLane: TransportLane? {
        switch self {
        case .none(let primary),
             .available(let primary, _),
             .attempting(let primary, _, _),
             .rescued(let primary, _):
            return primary
        case .broken:
            return nil
        }
    }

    public var rescueLane: TransportLane? {
        switch self {
        case .available(_, let rescue),
             .attempting(_, let rescue, _),
             .rescued(_, let rescue):
            return rescue
        case .none, .broken:
            return nil
        }
    }

    public var plannedLanes: [TransportLane] {
        switch self {
        case .none(let primary):
            return [primary]
        case .available(let primary, let rescue),
             .attempting(let primary, let rescue, _),
             .rescued(let primary, let rescue):
            return [primary, rescue]
        case .broken:
            return []
        }
    }

    public var activeAttemptLanes: [TransportLane] {
        switch self {
        case .none(let primary), .available(let primary, _):
            return [primary]
        case .attempting(_, let rescue, _), .rescued(_, let rescue):
            return [rescue]
        case .broken:
            return []
        }
    }
}

public enum FrameAdmission: Equatable, Codable, Sendable {
    case accepted
    case duplicate
    case late
}

public struct FrameDedupeWindow: Equatable, Codable, Sendable {
    public let capacity: UInt64
    public private(set) var baseFrame: UInt64
    public private(set) var seenOffsets: Set<UInt64>
    public private(set) var maxSeenFrame: UInt64?

    public init(
        capacity: UInt64 = 512,
        baseFrame: UInt64 = 0,
        seenOffsets: Set<UInt64> = [],
        maxSeenFrame: UInt64? = nil
    ) {
        self.capacity = max(1, capacity)
        self.baseFrame = baseFrame
        self.seenOffsets = seenOffsets
        self.maxSeenFrame = maxSeenFrame
    }

    @discardableResult
    public mutating func admit(frameIndex: UInt64) -> FrameAdmission {
        if frameIndex < baseFrame {
            return .late
        }
        if frameIndex >= baseFrame + capacity {
            let newBase = frameIndex - capacity + 1
            seenOffsets = Set(seenOffsets.compactMap { offset in
                let absolute = baseFrame + offset
                return absolute >= newBase ? absolute - newBase : nil
            })
            baseFrame = newBase
        }
        let offset = frameIndex - baseFrame
        guard seenOffsets.insert(offset).inserted else {
            return .duplicate
        }
        maxSeenFrame = max(maxSeenFrame ?? frameIndex, frameIndex)
        return .accepted
    }
}

public struct MediaEpochDeliveryState: Equatable, Codable, Sendable {
    public let epochID: MediaEpochID
    public var activeLane: ProvenMediaLane?
    public var preferredLane: TransportLane?
    public var availableLanes: MediaLaneAvailabilityMap
    public var rescueState: MediaEpochRescueState
    public var receiveWindow: FrameDedupeWindow

    public init(
        epochID: MediaEpochID,
        activeLane: ProvenMediaLane? = nil,
        preferredLane: TransportLane? = nil,
        availableLanes: MediaLaneAvailabilityMap = MediaLaneAvailabilityMap(),
        rescueState: MediaEpochRescueState = .broken(reason: .noRoute),
        receiveWindow: FrameDedupeWindow = FrameDedupeWindow()
    ) {
        self.epochID = epochID
        self.activeLane = activeLane
        self.preferredLane = preferredLane
        self.availableLanes = availableLanes
        self.rescueState = rescueState
        self.receiveWindow = receiveWindow
    }

    public mutating func markAvailable(_ availability: TransportLaneAvailability) -> Bool {
        availableLanes.join(
            .available(proof: availability.capability, generation: availability.networkPathGeneration),
            for: availability.lane
        )
    }

    public mutating func markFailed(_ failure: TransportLaneFailure) -> Bool {
        availableLanes.join(
            .failed(reason: failure.reason, generation: failure.networkPathGeneration),
            for: failure.lane
        )
    }

    public mutating func proveActiveLane(_ lane: TransportLane, proof: MediaDeliveryProof) {
        activeLane = ProvenMediaLane(lane: lane, proof: proof)
    }
}

public struct TransportSelection: Equatable, Codable, Sendable {
    public var currentLane: TransportLane?
    public var bestViableLane: TransportLane?
    public var fallbackLane: TransportLane?
    public var upgradeTarget: TransportLane?
    public var networkPathGeneration: UInt64
    public var laneCapabilities: [TransportLaneStatus]

    public init(
        currentLane: TransportLane? = nil,
        bestViableLane: TransportLane? = nil,
        fallbackLane: TransportLane? = nil,
        upgradeTarget: TransportLane? = nil,
        networkPathGeneration: UInt64 = 0,
        laneCapabilities: [TransportLaneStatus] = [
            TransportLaneStatus(
                lane: .webSocketTcp,
                capability: TransportCapability.defaultCapability(for: .webSocketTcp)
            ),
        ]
    ) {
        self.currentLane = currentLane
        self.bestViableLane = bestViableLane
        self.fallbackLane = fallbackLane
        self.upgradeTarget = upgradeTarget
        self.networkPathGeneration = networkPathGeneration
        self.laneCapabilities = laneCapabilities
        reconcile(activeMedia: false)
    }

    public init(legacyPhase: EngineTransportPhase, networkPathGeneration: UInt64 = 0) {
        let lane = legacyPhase.currentLane
        var statuses: [TransportLaneStatus] = [
            TransportLaneStatus(
                lane: .webSocketTcp,
                capability: TransportCapability.defaultCapability(for: .webSocketTcp)
            ),
        ]
        if let lane, lane != .webSocketTcp {
            statuses.append(
                TransportLaneStatus(
                    lane: lane,
                    capability: TransportCapability.defaultCapability(for: lane)
                )
            )
        }
        self.init(
            currentLane: lane,
            bestViableLane: lane,
            fallbackLane: TransportSelection.fallbackLane(below: lane, statuses: statuses),
            upgradeTarget: nil,
            networkPathGeneration: networkPathGeneration,
            laneCapabilities: statuses
        )
    }

    public func capability(for lane: TransportLane) -> TransportCapability {
        laneCapabilities.first(where: { $0.lane == lane })?.capability ?? .unavailable(.noRoute)
    }

    public mutating func markAvailable(_ availability: TransportLaneAvailability, activeMedia: Bool) -> Bool {
        guard availability.networkPathGeneration == networkPathGeneration else {
            return false
        }
        setCapability(availability.capability, for: availability.lane)
        reconcile(activeMedia: activeMedia)
        return true
    }

    public mutating func markFailed(_ failure: TransportLaneFailure, activeMedia: Bool) -> Bool {
        guard failure.networkPathGeneration == networkPathGeneration else {
            return false
        }
        setCapability(.unavailable(failure.reason), for: failure.lane)
        if currentLane == failure.lane {
            currentLane = bestViableLane(excluding: failure.lane)
        }
        reconcile(activeMedia: activeMedia)
        return true
    }

    public mutating func networkChanged(_ network: EngineNetworkInterface, activeMedia: Bool) {
        networkPathGeneration &+= 1
        guard network != .offline else {
            for lane in TransportLane.allCases {
                setCapability(.unavailable(.networkChanged(network)), for: lane)
            }
            currentLane = nil
            bestViableLane = nil
            fallbackLane = nil
            upgradeTarget = nil
            return
        }

        let directNeedsReprobe = currentLane == .directQuic
        if directNeedsReprobe && !activeMedia {
            setCapability(.unavailable(.networkChanged(network)), for: .directQuic)
            currentLane = TransportSelection.fallbackLane(below: .directQuic, statuses: laneCapabilities)
            upgradeTarget = .directQuic
        }

        reconcile(activeMedia: activeMedia)
        if directNeedsReprobe && !activeMedia {
            upgradeTarget = .directQuic
        } else if currentLane != .directQuic,
                  capability(for: .directQuic).isMediaViable {
            upgradeTarget = .directQuic
        }
    }

    private mutating func setCapability(_ capability: TransportCapability, for lane: TransportLane) {
        if let index = laneCapabilities.firstIndex(where: { $0.lane == lane }) {
            laneCapabilities[index].capability = capability
        } else {
            laneCapabilities.append(TransportLaneStatus(lane: lane, capability: capability))
        }
    }

    private mutating func reconcile(activeMedia: Bool) {
        bestViableLane = selectBestViableLane()
        if let currentLane, !capability(for: currentLane).isMediaViable {
            self.currentLane = bestViableLane
        }
        if currentLane == nil {
            currentLane = bestViableLane
        }
        fallbackLane = TransportSelection.fallbackLane(below: currentLane, statuses: laneCapabilities)
        guard !activeMedia else {
            if let currentLane,
               let bestViableLane,
               bestViableLane.priority > currentLane.priority {
                upgradeTarget = bestViableLane
            } else {
                upgradeTarget = nil
            }
            return
        }
        if let currentLane,
           let bestViableLane,
           bestViableLane.priority > currentLane.priority {
            self.currentLane = bestViableLane
            upgradeTarget = nil
        } else if let currentLane,
                  let bestViableLane,
                  bestViableLane.priority < currentLane.priority {
            upgradeTarget = nil
        } else {
            upgradeTarget = nil
        }
    }

    private func selectBestViableLane() -> TransportLane? {
        TransportLane.priorityOrder.first { capability(for: $0).isMediaViable }
    }

    private func bestViableLane(excluding excluded: TransportLane) -> TransportLane? {
        TransportLane.priorityOrder.first { lane in
            lane != excluded && capability(for: lane).isMediaViable
        }
    }

    private static func fallbackLane(
        below lane: TransportLane?,
        statuses: [TransportLaneStatus]
    ) -> TransportLane? {
        guard let lane else {
            return TransportLane.priorityOrder.first { candidate in
                statuses.first(where: { $0.lane == candidate })?.capability.isMediaViable == true
            }
        }
        return TransportLane.priorityOrder.first { candidate in
            candidate.priority < lane.priority
                && statuses.first(where: { $0.lane == candidate })?.capability.isMediaViable == true
        }
    }
}

public enum EngineMediaTransportCapability: Equatable, Codable, Sendable {
    case unorderedPacketMedia(UnorderedPacketMediaEvidence)
    case orderedReliableMedia(OrderedReliableMediaEvidence)
    case controlReliable(ControlReliableEvidence)
    case unavailable(TransportUnavailableReason)
    case degraded(MediaTransportDegradation)

    public static func defaultMediaCapability(for path: EngineTransportPath) -> EngineMediaTransportCapability {
        switch path {
        case .directQuic:
            return .unorderedPacketMedia(
                UnorderedPacketMediaEvidence(path: path, reason: .directQuicDatagram)
            )
        case .fastRelay:
            return .unorderedPacketMedia(
                UnorderedPacketMediaEvidence(path: path, reason: .fastRelayPacketRelay)
            )
        case .relayWebSocket:
            return .controlReliable(
                ControlReliableEvidence(path: path, reason: .backendControlPlane)
            )
        }
    }
}

public struct UnorderedPacketMediaEvidence: Equatable, Codable, Sendable {
    public let path: EngineTransportPath
    public let reason: UnorderedPacketMediaReason
    public init(path: EngineTransportPath, reason: UnorderedPacketMediaReason) {
        self.path = path
        self.reason = reason
    }
}

public enum UnorderedPacketMediaReason: Equatable, Codable, Sendable {
    case directQuicDatagram
    case fastRelayPacketRelay
}

public struct OrderedReliableMediaEvidence: Equatable, Codable, Sendable {
    public let path: EngineTransportPath
    public let reason: OrderedReliableMediaReason
    public init(path: EngineTransportPath, reason: OrderedReliableMediaReason) {
        self.path = path
        self.reason = reason
    }
}

public enum OrderedReliableMediaReason: Equatable, Codable, Sendable {
    case fastRelayTcpFallback
    case webSocketFallback
}

public struct ControlReliableEvidence: Equatable, Codable, Sendable {
    public let path: EngineTransportPath
    public let reason: ControlReliableReason
    public init(path: EngineTransportPath, reason: ControlReliableReason) {
        self.path = path
        self.reason = reason
    }
}

public enum ControlReliableReason: Equatable, Codable, Sendable {
    case backendControlPlane
    case directQuicControl
}

public struct MediaTransportDegradation: Equatable, Codable, Sendable {
    public let path: EngineTransportPath
    public let reason: MediaTransportDegradationReason
    public init(path: EngineTransportPath, reason: MediaTransportDegradationReason) {
        self.path = path
        self.reason = reason
    }
}

public enum MediaTransportDegradationReason: Equatable, Codable, Sendable {
    case mediaStall
    case orderedBacklog
    case datagramUnavailable
    case packetLossExceeded
    case networkMigration(EngineNetworkInterface)
    case sendFailure(TransportUnavailableReason)
}

public enum EngineAudioOutputPreference: Equatable, Codable, Sendable {
    case speaker
    case phone
}

public enum ReadinessMissingReason: Equatable, Codable, Sendable {
    case noPeerSelected
    case noBackendConversation
    case noWakeTarget
    case transportUnavailable(TransportUnavailableReason)
}

public enum ReadinessPendingReason: Equatable, Codable, Sendable {
    case joining
    case waitingForPeerDevice
    case waitingForPTTActivation
    case waitingForAudio
    case waitingForTransportRecovery(TransportRecoveryReason)
}

public enum EngineReadiness<T: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case unavailable(ReadinessMissingReason)
    case pending(ReadinessPendingReason)
    case ready(T)
}

public enum CapabilityUnsupportedReason: Equatable, Codable, Sendable {
    case backendDoesNotAdvertise
    case platformUnavailable
}

public enum CapabilityBlockedReason: Equatable, Codable, Sendable {
    case receiverNotReady
    case receiverNotAddressable(ReceiverAddressabilityUnavailableReason)
    case localNotJoined
    case transportUnavailable(TransportUnavailableReason)
    case pttActivationRequired
}

public enum EngineCapability<T: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case unsupported(CapabilityUnsupportedReason)
    case blocked(CapabilityBlockedReason)
    case available(T)
}

public struct SelectedFriendEvidence: Equatable, Codable, Sendable {
    public let contactID: ContactID
    public let handle: String
    public init(contactID: ContactID, handle: String) {
        self.contactID = contactID
        self.handle = handle
    }
}

public struct ConnectionRequestEvidence: Equatable, Codable, Sendable {
    public let friend: SelectedFriendEvidence
    public let attemptID: EngineAttemptID
    public init(friend: SelectedFriendEvidence, attemptID: EngineAttemptID) {
        self.friend = friend
        self.attemptID = attemptID
    }
}

public struct IncomingBeepEvidence: Equatable, Codable, Sendable {
    public let friend: SelectedFriendEvidence
    public let beepID: String
    public init(friend: SelectedFriendEvidence, beepID: String) {
        self.friend = friend
        self.beepID = beepID
    }
}

public struct JoinAttemptEvidence: Equatable, Codable, Sendable {
    public let friend: SelectedFriendEvidence
    public let channelID: EngineChannelID
    public let attemptID: EngineAttemptID
    public init(friend: SelectedFriendEvidence, channelID: EngineChannelID, attemptID: EngineAttemptID) {
        self.friend = friend
        self.channelID = channelID
        self.attemptID = attemptID
    }
}

public struct JoinedConversationEvidence: Equatable, Codable, Sendable {
    public let friend: SelectedFriendEvidence
    public let channelID: EngineChannelID
    public let localDeviceID: EngineDeviceID
    public let peerDevice: EngineReadiness<PeerDeviceEvidence>
    public let receiverAddressability: ReceiverAddressability
    public let readiness: EngineReadiness<JoinedReadinessEvidence>
    public init(
        friend: SelectedFriendEvidence,
        channelID: EngineChannelID,
        localDeviceID: EngineDeviceID,
        peerDevice: EngineReadiness<PeerDeviceEvidence>,
        receiverAddressability: ReceiverAddressability? = nil,
        readiness: EngineReadiness<JoinedReadinessEvidence>
    ) {
        self.friend = friend
        self.channelID = channelID
        self.localDeviceID = localDeviceID
        self.peerDevice = peerDevice
        self.receiverAddressability = receiverAddressability ?? JoinedConversationEvidence.defaultAddressability(peerDevice)
        self.readiness = readiness
    }

    public var peerDeviceID: EngineDeviceID? {
        guard case .ready(let evidence) = peerDevice else { return nil }
        return evidence.deviceID
    }

    public func withReceiverAddressability(_ addressability: ReceiverAddressability) -> JoinedConversationEvidence {
        JoinedConversationEvidence(
            friend: friend,
            channelID: channelID,
            localDeviceID: localDeviceID,
            peerDevice: peerDevice,
            receiverAddressability: addressability,
            readiness: readiness
        )
    }

    private static func defaultAddressability(
        _ peerDevice: EngineReadiness<PeerDeviceEvidence>
    ) -> ReceiverAddressability {
        switch peerDevice {
        case .ready(let evidence):
            return .foreground(evidence)
        case .pending:
            return .unavailable(.peerDeviceUnavailable)
        case .unavailable:
            return .unavailable(.membershipLost)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case friend
        case channelID
        case localDeviceID
        case peerDevice
        case receiverAddressability
        case readiness
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case peer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.friend = try container.decodeIfPresent(SelectedFriendEvidence.self, forKey: .friend)
            ?? legacyContainer.decode(SelectedFriendEvidence.self, forKey: .peer)
        self.channelID = try container.decode(EngineChannelID.self, forKey: .channelID)
        self.localDeviceID = try container.decode(EngineDeviceID.self, forKey: .localDeviceID)
        self.peerDevice = try container.decode(EngineReadiness<PeerDeviceEvidence>.self, forKey: .peerDevice)
        self.receiverAddressability = try container.decodeIfPresent(
            ReceiverAddressability.self,
            forKey: .receiverAddressability
        ) ?? JoinedConversationEvidence.defaultAddressability(peerDevice)
        self.readiness = try container.decode(EngineReadiness<JoinedReadinessEvidence>.self, forKey: .readiness)
    }
}

public struct PeerDeviceEvidence: Equatable, Codable, Sendable {
    public let deviceID: EngineDeviceID
    public init(deviceID: EngineDeviceID) {
        self.deviceID = deviceID
    }
}

public enum ReceiverAddressability: Equatable, Codable, Sendable {
    case foreground(PeerDeviceEvidence)
    case wakeCapable(WakeTargetEvidence)
    case unavailable(ReceiverAddressabilityUnavailableReason)

    public var isAddressable: Bool {
        switch self {
        case .foreground, .wakeCapable:
            return true
        case .unavailable:
            return false
        }
    }

    public var unavailableReason: ReceiverAddressabilityUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public struct WakeTargetEvidence: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let deviceID: EngineDeviceID
    public let tokenObservedAtTick: UInt64
    public init(channelID: EngineChannelID, deviceID: EngineDeviceID, tokenObservedAtTick: UInt64) {
        self.channelID = channelID
        self.deviceID = deviceID
        self.tokenObservedAtTick = tokenObservedAtTick
    }
}

public enum ReceiverAddressabilityUnavailableReason: Equatable, Codable, Sendable {
    case peerDeviceUnavailable
    case wakeTokenRevoked
    case membershipLost
    case backendClearedActiveTransmit
}

public struct JoinedReadinessEvidence: Equatable, Codable, Sendable {
    public let backendMembershipObserved: BackendMembershipEvidence
    public let transport: EngineTransportPath
    public init(backendMembershipObserved: BackendMembershipEvidence, transport: EngineTransportPath) {
        self.backendMembershipObserved = backendMembershipObserved
        self.transport = transport
    }
}

public struct BackendMembershipEvidence: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let localDeviceID: EngineDeviceID
    public let peerDeviceID: EngineDeviceID
    public let observedAtTick: UInt64
    public init(
        channelID: EngineChannelID,
        localDeviceID: EngineDeviceID,
        peerDeviceID: EngineDeviceID,
        observedAtTick: UInt64
    ) {
        self.channelID = channelID
        self.localDeviceID = localDeviceID
        self.peerDeviceID = peerDeviceID
        self.observedAtTick = observedAtTick
    }
}

public struct DisconnectAttemptEvidence: Equatable, Codable, Sendable {
    public let conversation: JoinedConversationEvidence
    public let attemptID: EngineAttemptID
    public init(conversation: JoinedConversationEvidence, attemptID: EngineAttemptID) {
        self.conversation = conversation
        self.attemptID = attemptID
    }
}

public struct ConversationRecoveryEvidence: Equatable, Codable, Sendable {
    public let previous: JoinedConversationEvidence
    public let reason: ConversationRecoveryReason
    public init(previous: JoinedConversationEvidence, reason: ConversationRecoveryReason) {
        self.previous = previous
        self.reason = reason
    }
}

public enum ConversationRecoveryReason: Equatable, Codable, Sendable {
    case backendReconnect
    case transportRecovered(EngineTransportPath)
    case appForegrounded
}

public enum EngineConversationPhase: Equatable, Codable, Sendable {
    case none
    case selected(SelectedFriendEvidence)
    case requesting(ConnectionRequestEvidence)
    case incomingBeep(IncomingBeepEvidence)
    case joining(JoinAttemptEvidence)
    case joined(JoinedConversationEvidence)
    case disconnecting(DisconnectAttemptEvidence)
    case recovering(ConversationRecoveryEvidence)

    public var joinedEvidence: JoinedConversationEvidence? {
        if case .joined(let evidence) = self { return evidence }
        return nil
    }
}

public struct TransmitBeginAttempt: Equatable, Codable, Sendable {
    public let conversation: JoinedConversationEvidence
    public let attemptID: EngineAttemptID
    public let backendTransmitID: EngineTransmitID?
    public let backendAcceptedAtTick: UInt64?
    public let systemTransmitID: EngineTransmitID?
    public let systemStartedAtTick: UInt64?
    public init(
        conversation: JoinedConversationEvidence,
        attemptID: EngineAttemptID,
        backendTransmitID: EngineTransmitID? = nil,
        backendAcceptedAtTick: UInt64? = nil,
        systemTransmitID: EngineTransmitID? = nil,
        systemStartedAtTick: UInt64? = nil
    ) {
        self.conversation = conversation
        self.attemptID = attemptID
        self.backendTransmitID = backendTransmitID
        self.backendAcceptedAtTick = backendAcceptedAtTick
        self.systemTransmitID = systemTransmitID
        self.systemStartedAtTick = systemStartedAtTick
    }

    public func recordingBackendTransmitAccepted(
        _ transmitID: EngineTransmitID,
        atTick tick: UInt64
    ) -> TransmitBeginAttempt {
        TransmitBeginAttempt(
            conversation: conversation,
            attemptID: attemptID,
            backendTransmitID: transmitID,
            backendAcceptedAtTick: tick,
            systemTransmitID: systemTransmitID,
            systemStartedAtTick: systemStartedAtTick
        )
    }

    public func recordingSystemTransmitBegan(
        _ transmitID: EngineTransmitID,
        atTick tick: UInt64
    ) -> TransmitBeginAttempt {
        TransmitBeginAttempt(
            conversation: conversation,
            attemptID: attemptID,
            backendTransmitID: backendTransmitID,
            backendAcceptedAtTick: backendAcceptedAtTick,
            systemTransmitID: transmitID,
            systemStartedAtTick: tick
        )
    }
}

public struct TransmitEpoch: Equatable, Codable, Sendable {
    public let conversation: JoinedConversationEvidence
    public let transmitID: EngineTransmitID
    public let startedAtTick: UInt64
    public init(conversation: JoinedConversationEvidence, transmitID: EngineTransmitID, startedAtTick: UInt64) {
        self.conversation = conversation
        self.transmitID = transmitID
        self.startedAtTick = startedAtTick
    }
}

public struct TransmitStopAttempt: Equatable, Codable, Sendable {
    public let epoch: TransmitEpoch
    public let reason: TransmitStopReason
    public init(epoch: TransmitEpoch, reason: TransmitStopReason) {
        self.epoch = epoch
        self.reason = reason
    }
}

public enum TransmitStopReason: Equatable, Codable, Sendable {
    case userReleased
    case systemEnded
    case transportFailed(TransportUnavailableReason)
    case receiverUnaddressable(ReceiverAddressabilityUnavailableReason)
}

public struct TransmitFailure: Equatable, Codable, Sendable {
    public let conversation: JoinedConversationEvidence?
    public let reason: TransmitFailureReason
    public init(conversation: JoinedConversationEvidence?, reason: TransmitFailureReason) {
        self.conversation = conversation
        self.reason = reason
    }
}

public enum TransmitFailureReason: Equatable, Codable, Sendable {
    case noJoinedConversation
    case receiverNotReady(ReadinessPendingReason)
    case receiverNotAddressable(ReceiverAddressabilityUnavailableReason)
    case systemRejected(String)
    case transportUnavailable(TransportUnavailableReason)
}

public enum ActiveTransmitClearReason: Equatable, Codable, Sendable {
    case receiverBecameUnaddressable(ReceiverAddressabilityUnavailableReason)
    case senderMembershipLost
    case backendLeaseExpired
}

public enum EngineTransmitPhase: Equatable, Codable, Sendable {
    case idle
    case beginning(TransmitBeginAttempt)
    case active(TransmitEpoch)
    case stopping(TransmitStopAttempt)
    case failed(TransmitFailure)

    public var activeEpoch: TransmitEpoch? {
        if case .active(let epoch) = self { return epoch }
        return nil
    }
}

public struct RemoteTransmitPrepareEvidence: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let transmitID: EngineTransmitID
    public let senderDeviceID: EngineDeviceID
    public init(channelID: EngineChannelID, transmitID: EngineTransmitID, senderDeviceID: EngineDeviceID) {
        self.channelID = channelID
        self.transmitID = transmitID
        self.senderDeviceID = senderDeviceID
    }
}

public struct WakeBufferedReceive: Equatable, Codable, Sendable {
    public let prepare: RemoteTransmitPrepareEvidence
    public let reason: WakeBufferReason
    public var chunks: [EngineAudioChunk]
    public init(prepare: RemoteTransmitPrepareEvidence, reason: WakeBufferReason, chunks: [EngineAudioChunk]) {
        self.prepare = prepare
        self.reason = reason
        self.chunks = chunks
    }
}

public enum WakeBufferReason: Equatable, Codable, Sendable {
    case appBackgrounded
    case appLocked
    case waitingForPTTActivation
}

public struct ReceiveEpoch: Equatable, Codable, Sendable {
    public let prepare: RemoteTransmitPrepareEvidence
    public var playout: EngineMediaPlayoutState

    public var acceptedChunkIDs: Set<EngineAudioChunkID> {
        playout.acceptedChunkIDs
    }

    private enum CodingKeys: String, CodingKey {
        case prepare
        case acceptedChunkIDs
        case playout
    }

    public init(
        prepare: RemoteTransmitPrepareEvidence,
        acceptedChunkIDs: Set<EngineAudioChunkID> = [],
        playout: EngineMediaPlayoutState = EngineMediaPlayoutState()
    ) {
        self.prepare = prepare
        var playout = playout
        playout.acceptedChunkIDs.formUnion(acceptedChunkIDs)
        self.playout = playout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prepare = try container.decode(RemoteTransmitPrepareEvidence.self, forKey: .prepare)
        let acceptedChunkIDs = try container.decodeIfPresent(Set<EngineAudioChunkID>.self, forKey: .acceptedChunkIDs) ?? []
        var playout = try container.decodeIfPresent(EngineMediaPlayoutState.self, forKey: .playout) ?? EngineMediaPlayoutState()
        playout.acceptedChunkIDs.formUnion(acceptedChunkIDs)
        self.playout = playout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prepare, forKey: .prepare)
        try container.encode(acceptedChunkIDs, forKey: .acceptedChunkIDs)
        try container.encode(playout, forKey: .playout)
    }
}

public struct PlaybackDrain: Equatable, Codable, Sendable {
    public let epoch: ReceiveEpoch
    public let stoppedAtTick: UInt64
    public init(epoch: ReceiveEpoch, stoppedAtTick: UInt64) {
        self.epoch = epoch
        self.stoppedAtTick = stoppedAtTick
    }
}

public struct ReceiveFailure: Equatable, Codable, Sendable {
    public let reason: ReceiveFailureReason
    public init(reason: ReceiveFailureReason) {
        self.reason = reason
    }
}

public enum ReceiveFailureReason: Equatable, Codable, Sendable {
    case staleAudioChunk(EngineTransmitID)
    case playbackFailed(String)
}

public enum EngineReceivePhase: Equatable, Codable, Sendable {
    case idle
    case prepared(RemoteTransmitPrepareEvidence)
    case awaitingPTTActivation(WakeBufferedReceive)
    case receiving(ReceiveEpoch)
    case draining(PlaybackDrain)
    case failed(ReceiveFailure)
}

public struct RelayWebSocketEvidence: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID?
    public init(channelID: EngineChannelID? = nil) {
        self.channelID = channelID
    }
}

public struct FastRelayEvidence: Equatable, Codable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct DirectQuicEvidence: Equatable, Codable, Sendable {
    public let peerDeviceID: EngineDeviceID
    public init(peerDeviceID: EngineDeviceID) {
        self.peerDeviceID = peerDeviceID
    }
}

public struct MultipathEvidence: Equatable, Codable, Sendable {
    public let primary: EngineTransportPath
    public let fallback: EngineTransportPath
    public init(primary: EngineTransportPath, fallback: EngineTransportPath) {
        self.primary = primary
        self.fallback = fallback
    }
}

public struct TransportRecoveryEvidence: Equatable, Codable, Sendable {
    public let previous: EngineTransportPath
    public let fallback: EngineTransportPath
    public let reason: TransportRecoveryReason
    public init(previous: EngineTransportPath, fallback: EngineTransportPath, reason: TransportRecoveryReason) {
        self.previous = previous
        self.fallback = fallback
        self.reason = reason
    }
}

public enum TransportRecoveryReason: Equatable, Codable, Sendable {
    case networkChanged(EngineNetworkInterface)
    case pathFailed(TransportUnavailableReason)
    case peerUnavailable
}

public enum TransportUnavailableReason: Equatable, Codable, Sendable {
    case quicBlocked
    case relayUnavailable
    case websocketDisconnected
    case peerUnavailable
    case noRoute
    case networkChanged(EngineNetworkInterface)
}

public enum EngineTransportPhase: Equatable, Codable, Sendable {
    case relayWebSocket(RelayWebSocketEvidence)
    case fastRelay(FastRelayEvidence)
    case directQuic(DirectQuicEvidence)
    case multipath(MultipathEvidence)
    case recovering(TransportRecoveryEvidence)
    case unavailable(TransportUnavailableReason)

    public var currentPath: EngineTransportPath? {
        switch self {
        case .relayWebSocket:
            return .relayWebSocket
        case .fastRelay:
            return .fastRelay
        case .directQuic:
            return .directQuic
        case .multipath(let evidence):
            return evidence.primary
        case .recovering(let evidence):
            return evidence.fallback
        case .unavailable:
            return nil
        }
    }

    public var currentLane: TransportLane? {
        switch self {
        case .relayWebSocket:
            return .webSocketTcp
        case .fastRelay:
            return .fastRelayQuic
        case .directQuic:
            return .directQuic
        case .multipath(let evidence):
            return evidence.primary.defaultLane
        case .recovering(let evidence):
            return evidence.fallback.defaultLane
        case .unavailable:
            return nil
        }
    }
}

public extension EngineTransportPath {
    var defaultLane: TransportLane {
        switch self {
        case .relayWebSocket:
            return .webSocketTcp
        case .fastRelay:
            return .fastRelayQuic
        case .directQuic:
            return .directQuic
        }
    }
}

public enum EngineNetworkInterface: Equatable, Codable, Sendable {
    case wifi
    case cellular
    case offline
}

public enum EnginePTTAudioActivationState: Equatable, Codable, Sendable {
    case inactive
    case activating(PTTActivationAttempt)
    case active(PTTActivationEvidence)
    case failed(PTTActivationFailure)
}

public struct PTTActivationAttempt: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let reason: PTTActivationReason
    public init(channelID: EngineChannelID, reason: PTTActivationReason) {
        self.channelID = channelID
        self.reason = reason
    }
}

public struct PTTActivationEvidence: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let activatedAtTick: UInt64
    public init(channelID: EngineChannelID, activatedAtTick: UInt64) {
        self.channelID = channelID
        self.activatedAtTick = activatedAtTick
    }
}

public struct PTTActivationFailure: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID?
    public let reason: PTTActivationFailureReason
    public init(channelID: EngineChannelID?, reason: PTTActivationFailureReason) {
        self.channelID = channelID
        self.reason = reason
    }
}

public enum PTTActivationReason: Equatable, Codable, Sendable {
    case localTransmit
    case incomingPush
    case playbackWake
}

public enum PTTActivationFailureReason: Equatable, Codable, Sendable {
    case systemRejected(String)
    case timedOut
}

public struct EngineAudioChunk: Equatable, Codable, Sendable {
    public let id: EngineAudioChunkID
    public let transmitID: EngineTransmitID
    public let sequence: EngineAudioSequence
    public let fromDeviceID: EngineDeviceID
    public let toDeviceID: EngineDeviceID
    public let transport: EngineTransportPath
    public let payloadDigest: EnginePayloadDigest
    public let mediaCapability: EngineMediaTransportCapability?
    public let capturedAtTick: UInt64?
    public let receivedAtTick: UInt64?
    public let durationTicks: UInt64?

    public init(
        id: EngineAudioChunkID,
        transmitID: EngineTransmitID,
        sequence: EngineAudioSequence,
        fromDeviceID: EngineDeviceID,
        toDeviceID: EngineDeviceID,
        transport: EngineTransportPath,
        payloadDigest: EnginePayloadDigest,
        mediaCapability: EngineMediaTransportCapability? = nil,
        capturedAtTick: UInt64? = nil,
        receivedAtTick: UInt64? = nil,
        durationTicks: UInt64? = nil
    ) {
        self.id = id
        self.transmitID = transmitID
        self.sequence = sequence
        self.fromDeviceID = fromDeviceID
        self.toDeviceID = toDeviceID
        self.transport = transport
        self.payloadDigest = payloadDigest
        self.mediaCapability = mediaCapability
        self.capturedAtTick = capturedAtTick
        self.receivedAtTick = receivedAtTick
        self.durationTicks = durationTicks
    }

    public var effectiveMediaCapability: EngineMediaTransportCapability {
        mediaCapability ?? EngineMediaTransportCapability.defaultMediaCapability(for: transport)
    }
}

public struct EngineMediaPlayoutPolicy: Equatable, Codable, Sendable {
    public let frameDurationTicks: UInt64
    public let targetJitterTicks: UInt64
    public let maximumHoldTicks: UInt64
    public let maximumQueuedFrames: Int
    public let orderedBacklogGraceFrames: Int

    public init(
        frameDurationTicks: UInt64,
        targetJitterTicks: UInt64,
        maximumHoldTicks: UInt64,
        maximumQueuedFrames: Int,
        orderedBacklogGraceFrames: Int
    ) {
        self.frameDurationTicks = frameDurationTicks
        self.targetJitterTicks = targetJitterTicks
        self.maximumHoldTicks = maximumHoldTicks
        self.maximumQueuedFrames = maximumQueuedFrames
        self.orderedBacklogGraceFrames = orderedBacklogGraceFrames
    }

    public static let live = EngineMediaPlayoutPolicy(
        frameDurationTicks: 20,
        targetJitterTicks: 80,
        maximumHoldTicks: 160,
        maximumQueuedFrames: 64,
        orderedBacklogGraceFrames: 4
    )

    public static let webSocketFallback = EngineMediaPlayoutPolicy(
        frameDurationTicks: 20,
        targetJitterTicks: 120,
        maximumHoldTicks: 160,
        maximumQueuedFrames: 64,
        orderedBacklogGraceFrames: 6
    )
}

public enum EngineMediaPlayoutAction: Equatable, Codable, Sendable {
    case schedule([EngineAudioChunk])
    case buffer(EngineAudioChunk)
    case drop(EngineAudioChunk, MediaDropReason)
    case skipMissing(EngineTransmitID, EngineAudioSequence)
}

public struct EngineMediaPlayoutState: Equatable, Codable, Sendable {
    public var policy: EngineMediaPlayoutPolicy
    public var nextExpectedSequence: EngineAudioSequence
    public var acceptedChunkIDs: Set<EngineAudioChunkID>
    public var queuedChunks: [EngineAudioSequence: EngineAudioChunk]
    public var lastScheduledSequence: EngineAudioSequence?
    public var lastScheduledReceivedAtTick: UInt64?

    public init(
        policy: EngineMediaPlayoutPolicy = .live,
        nextExpectedSequence: EngineAudioSequence = EngineAudioSequence(0),
        acceptedChunkIDs: Set<EngineAudioChunkID> = [],
        queuedChunks: [EngineAudioSequence: EngineAudioChunk] = [:],
        lastScheduledSequence: EngineAudioSequence? = nil,
        lastScheduledReceivedAtTick: UInt64? = nil
    ) {
        self.policy = policy
        self.nextExpectedSequence = nextExpectedSequence
        self.acceptedChunkIDs = acceptedChunkIDs
        self.queuedChunks = queuedChunks
        self.lastScheduledSequence = lastScheduledSequence
        self.lastScheduledReceivedAtTick = lastScheduledReceivedAtTick
    }

    public static func liveDefault(
        for capability: EngineMediaTransportCapability
    ) -> EngineMediaPlayoutState {
        let policy: EngineMediaPlayoutPolicy
        switch capability {
        case .orderedReliableMedia(let evidence) where evidence.path == .relayWebSocket:
            policy = .webSocketFallback
        default:
            policy = .live
        }
        return EngineMediaPlayoutState(policy: policy)
    }

    public mutating func receive(_ chunk: EngineAudioChunk) -> [EngineMediaPlayoutAction] {
        guard acceptedChunkIDs.insert(chunk.id).inserted else {
            return [.drop(chunk, .duplicate)]
        }

        switch chunk.effectiveMediaCapability {
        case .unorderedPacketMedia:
            return receiveUnorderedPacket(chunk)
        case .orderedReliableMedia:
            return receiveOrderedReliable(chunk)
        case .controlReliable, .unavailable, .degraded:
            return [.drop(chunk, .transportUnavailable)]
        }
    }

    public mutating func deadlineElapsed(
        transmitID: EngineTransmitID,
        sequence: EngineAudioSequence
    ) -> [EngineMediaPlayoutAction] {
        guard sequence == nextExpectedSequence else { return [] }
        nextExpectedSequence = EngineAudioSequence(nextExpectedSequence.rawValue + 1)
        return [.skipMissing(transmitID, sequence)] + drainContiguousQueued()
    }

    private mutating func receiveUnorderedPacket(_ chunk: EngineAudioChunk) -> [EngineMediaPlayoutAction] {
        if chunk.sequence < nextExpectedSequence {
            return [.drop(chunk, .late)]
        }
        if chunk.sequence > nextExpectedSequence {
            queuedChunks[chunk.sequence] = chunk
            if queuedChunks.count > policy.maximumQueuedFrames {
                return [.buffer(chunk)] + skipMissingUntilQueueIsBounded(transmitID: chunk.transmitID)
            }
            return [.buffer(chunk)]
        }
        return release(chunk) + drainContiguousQueued()
    }

    private mutating func skipMissingUntilQueueIsBounded(
        transmitID: EngineTransmitID
    ) -> [EngineMediaPlayoutAction] {
        var actions: [EngineMediaPlayoutAction] = []
        while queuedChunks.count > policy.maximumQueuedFrames {
            actions.append(.skipMissing(transmitID, nextExpectedSequence))
            if let nextQueuedSequence = queuedChunks.keys.sorted().first,
               nextQueuedSequence > nextExpectedSequence {
                nextExpectedSequence = nextQueuedSequence
            } else {
                nextExpectedSequence = EngineAudioSequence(nextExpectedSequence.rawValue + 1)
            }
            actions.append(contentsOf: drainContiguousQueued())
        }
        return actions
    }

    private mutating func receiveOrderedReliable(_ chunk: EngineAudioChunk) -> [EngineMediaPlayoutAction] {
        if shouldDropOrderedBacklog(chunk) {
            return [.drop(chunk, .orderedBacklog)]
        }
        return release(chunk)
    }

    private func shouldDropOrderedBacklog(_ chunk: EngineAudioChunk) -> Bool {
        guard let lastSequence = lastScheduledSequence,
              let lastReceivedAtTick = lastScheduledReceivedAtTick,
              let receivedAtTick = chunk.receivedAtTick,
              receivedAtTick > lastReceivedAtTick,
              receivedAtTick - lastReceivedAtTick > policy.maximumHoldTicks else {
            return false
        }
        let elapsedTicks = receivedAtTick - lastReceivedAtTick
        let frameDuration = max(1, chunk.durationTicks ?? policy.frameDurationTicks)
        let expectedAdvance = Int(elapsedTicks / frameDuration)
        let catchUpFloor = lastSequence.rawValue + max(0, expectedAdvance - policy.orderedBacklogGraceFrames)
        return chunk.sequence.rawValue <= catchUpFloor
    }

    private mutating func drainContiguousQueued() -> [EngineMediaPlayoutAction] {
        var actions: [EngineMediaPlayoutAction] = []
        while let next = queuedChunks.removeValue(forKey: nextExpectedSequence) {
            actions.append(contentsOf: release(next))
        }
        return actions
    }

    private mutating func release(_ chunk: EngineAudioChunk) -> [EngineMediaPlayoutAction] {
        lastScheduledSequence = chunk.sequence
        lastScheduledReceivedAtTick = chunk.receivedAtTick
        if chunk.sequence.rawValue >= nextExpectedSequence.rawValue {
            nextExpectedSequence = EngineAudioSequence(chunk.sequence.rawValue + 1)
        }
        return [.schedule([chunk])]
    }
}

public struct EngineDiagnostic: Equatable, Codable, Sendable {
    public let subsystem: String
    public let message: String
    public let metadata: [String: String]
    public init(subsystem: String, message: String, metadata: [String: String] = [:]) {
        self.subsystem = subsystem
        self.message = message
        self.metadata = metadata
    }
}

public enum EngineContractKind: String, Equatable, Codable, Sendable {
    case precondition
    case postcondition
    case invariant
    case liveness
}

public struct EngineInvariantViolation: Equatable, Codable, Sendable {
    public let invariantID: String
    public let kind: EngineContractKind
    public let message: String
    public let metadata: [String: String]
    public init(
        invariantID: String,
        kind: EngineContractKind,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.invariantID = invariantID
        self.kind = kind
        self.message = message
        self.metadata = metadata
    }
}

public struct TurboEngineState: Equatable, Codable, Sendable {
    public internal(set) var localDeviceID: EngineDeviceID
    public internal(set) var conversation: EngineConversationPhase
    public internal(set) var transmit: EngineTransmitPhase
    public internal(set) var receive: EngineReceivePhase
    public internal(set) var transport: EngineTransportPhase
    public internal(set) var transportSelection: TransportSelection
    public internal(set) var mediaEpochDelivery: MediaEpochDeliveryState?
    public internal(set) var lifecycle: EngineApplicationState
    public internal(set) var pttAudio: EnginePTTAudioActivationState
    public internal(set) var audioOutputPreference: EngineAudioOutputPreference
    public internal(set) var scheduledPlayback: [EngineAudioChunk]
    public internal(set) var tick: UInt64

    init(
        localDeviceID: EngineDeviceID,
        conversation: EngineConversationPhase = .none,
        transmit: EngineTransmitPhase = .idle,
        receive: EngineReceivePhase = .idle,
        transport: EngineTransportPhase = .relayWebSocket(RelayWebSocketEvidence()),
        transportSelection: TransportSelection? = nil,
        mediaEpochDelivery: MediaEpochDeliveryState? = nil,
        lifecycle: EngineApplicationState = .active,
        pttAudio: EnginePTTAudioActivationState = .inactive,
        audioOutputPreference: EngineAudioOutputPreference = .speaker,
        scheduledPlayback: [EngineAudioChunk] = [],
        tick: UInt64 = 0
    ) {
        self.localDeviceID = localDeviceID
        self.conversation = conversation
        self.transmit = transmit
        self.receive = receive
        self.transport = transport
        self.transportSelection = transportSelection ?? TransportSelection(legacyPhase: transport)
        self.mediaEpochDelivery = mediaEpochDelivery
        self.lifecycle = lifecycle
        self.pttAudio = pttAudio
        self.audioOutputPreference = audioOutputPreference
        self.scheduledPlayback = scheduledPlayback
        self.tick = tick
    }

    enum CodingKeys: String, CodingKey {
        case localDeviceID
        case conversation
        case transmit
        case receive
        case transport
        case transportSelection
        case mediaEpochDelivery
        case lifecycle
        case pttAudio
        case audioOutputPreference
        case scheduledPlayback
        case tick
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let localDeviceID = try container.decode(EngineDeviceID.self, forKey: .localDeviceID)
        let conversation = try container.decodeIfPresent(EngineConversationPhase.self, forKey: .conversation) ?? .none
        let transmit = try container.decodeIfPresent(EngineTransmitPhase.self, forKey: .transmit) ?? .idle
        let receive = try container.decodeIfPresent(EngineReceivePhase.self, forKey: .receive) ?? .idle
        let transport = try container.decodeIfPresent(EngineTransportPhase.self, forKey: .transport)
            ?? .relayWebSocket(RelayWebSocketEvidence())
        let transportSelection = try container.decodeIfPresent(
            TransportSelection.self,
            forKey: .transportSelection
        ) ?? TransportSelection(legacyPhase: transport)
        let mediaEpochDelivery = try container.decodeIfPresent(
            MediaEpochDeliveryState.self,
            forKey: .mediaEpochDelivery
        )
        let lifecycle = try container.decodeIfPresent(EngineApplicationState.self, forKey: .lifecycle) ?? .active
        let pttAudio = try container.decodeIfPresent(EnginePTTAudioActivationState.self, forKey: .pttAudio)
            ?? .inactive
        let audioOutputPreference = try container.decodeIfPresent(
            EngineAudioOutputPreference.self,
            forKey: .audioOutputPreference
        ) ?? .speaker
        let scheduledPlayback = try container.decodeIfPresent(
            [EngineAudioChunk].self,
            forKey: .scheduledPlayback
        ) ?? []
        let tick = try container.decodeIfPresent(UInt64.self, forKey: .tick) ?? 0
        self.init(
            localDeviceID: localDeviceID,
            conversation: conversation,
            transmit: transmit,
            receive: receive,
            transport: transport,
            transportSelection: transportSelection,
            mediaEpochDelivery: mediaEpochDelivery,
            lifecycle: lifecycle,
            pttAudio: pttAudio,
            audioOutputPreference: audioOutputPreference,
            scheduledPlayback: scheduledPlayback,
            tick: tick
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localDeviceID, forKey: .localDeviceID)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(transmit, forKey: .transmit)
        try container.encode(receive, forKey: .receive)
        try container.encode(transport, forKey: .transport)
        try container.encode(transportSelection, forKey: .transportSelection)
        try container.encodeIfPresent(mediaEpochDelivery, forKey: .mediaEpochDelivery)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(pttAudio, forKey: .pttAudio)
        try container.encode(audioOutputPreference, forKey: .audioOutputPreference)
        try container.encode(scheduledPlayback, forKey: .scheduledPlayback)
        try container.encode(tick, forKey: .tick)
    }
}

public struct TurboEngineSnapshot: Equatable, Codable, Sendable {
    public let conversation: EngineConversationPhase
    public let transmit: EngineTransmitPhase
    public let receive: EngineReceivePhase
    public let transport: EngineTransportPhase
    public let transportSelection: TransportSelection
    public let mediaEpochDelivery: MediaEpochDeliveryState?
    public let lifecycle: EngineApplicationState
    public let pttAudio: EnginePTTAudioActivationState
    public let localTalkCapability: EngineCapability<TransmitCapabilityEvidence>
    public let receiverReadiness: EngineReadiness<ReceiveReadinessEvidence>
    public let scheduledPlaybackCount: Int
}

public struct TransmitCapabilityEvidence: Equatable, Codable, Sendable {
    public let conversation: JoinedConversationEvidence
    public let transport: EngineTransportPath
    public init(conversation: JoinedConversationEvidence, transport: EngineTransportPath) {
        self.conversation = conversation
        self.transport = transport
    }
}

public struct ReceiveReadinessEvidence: Equatable, Codable, Sendable {
    public let activation: EnginePTTAudioActivationState
    public let transport: EngineTransportPath
    public init(activation: EnginePTTAudioActivationState, transport: EngineTransportPath) {
        self.activation = activation
        self.transport = transport
    }
}

public enum TurboEngineIntent: Equatable, Codable, Sendable {
    case selectFriend(SelectedFriendEvidence?)
    case requestConnection(ContactID)
    case acceptConnection(ContactID)
    case disconnect(ContactID)
    case beginTalk
    case endTalk
    case setAudioOutputPreference(EngineAudioOutputPreference)
}

public enum TurboEngineEvent: Equatable, Codable, Sendable {
    case backend(BackendEngineEvent)
    case ptt(PTTEngineEvent)
    case media(MediaEngineEvent)
    case transport(TransportEngineEvent)
    case lifecycle(AppLifecycleEngineEvent)
    case clock(ClockEngineEvent)
}

public enum BackendEngineEvent: Equatable, Codable, Sendable {
    case joined(JoinedConversationEvidence)
    case joinFailed(ConversationRecoveryReason)
    case receiverAddressabilityChanged(ReceiverAddressability)
    case activeTransmitCleared(EngineTransmitID, ActiveTransmitClearReason)
    case beginTransmitAccepted(EngineTransmitID)
    case localTransmitObserved(EngineTransmitID)
    case stopTransmitAccepted(EngineTransmitID)
    case remoteTransmitStarted(RemoteTransmitPrepareEvidence)
    case remoteTransmitStopped(EngineTransmitID)
}

public enum PTTEngineEvent: Equatable, Codable, Sendable {
    case incomingPush(RemoteTransmitPrepareEvidence)
    case audioActivationStarted(PTTActivationAttempt)
    case audioActivated(PTTActivationEvidence)
    case audioActivationFailed(PTTActivationFailure)
    case systemTransmitBegan(EngineTransmitID)
    case systemTransmitEnded(EngineTransmitID)
    case systemTransmitBeginFailed(PTTActivationFailureReason)
}

public enum MediaEngineEvent: Equatable, Codable, Sendable {
    case localAudioCaptured(EngineAudioChunk)
    case remoteAudioReceived(EngineAudioChunk)
    case playoutDeadlineElapsed(EngineTransmitID, EngineAudioSequence)
    case playbackScheduled(EngineAudioChunk)
    case playbackDrained(EngineTransmitID)
    case playbackFailed(EngineAudioChunk, String)
}

public enum TransportEngineEvent: Equatable, Codable, Sendable {
    case networkChanged(EngineNetworkInterface)
    case pathAvailable(EngineTransportPhase)
    case pathFailed(EngineTransportPath, TransportUnavailableReason)
    case fallbackSelected(EngineTransportPath)
    case laneAvailable(TransportLaneAvailability)
    case laneFailed(TransportLaneFailure)
}

public enum AppLifecycleEngineEvent: Equatable, Codable, Sendable {
    case moved(EngineApplicationState)
}

public enum ClockEngineEvent: Equatable, Codable, Sendable {
    case tick(UInt64)
    case deadlineElapsed(EngineDeadline)
}

public enum EngineDeadline: Equatable, Codable, Sendable {
    case pttActivation(EngineChannelID)
    case firstAudio(EngineTransmitID)
    case playbackDrain(EngineTransmitID)
}

public enum TurboEngineEffect: Equatable, Codable, Sendable {
    case backend(BackendEngineEffect)
    case ptt(PTTEngineEffect)
    case media(MediaEngineEffect)
    case transport(TransportEngineEffect)
    case diagnostics(DiagnosticsEngineEffect)
}

public enum BackendEngineEffect: Equatable, Codable, Sendable {
    case connectWebSocket
    case beginTransmit(EngineChannelID)
    case endTransmit(EngineChannelID, EngineTransmitID)
    case fetchChannelState(EngineChannelID)
}

public enum PTTEngineEffect: Equatable, Codable, Sendable {
    case requestBeginTransmit(EngineChannelID)
    case requestStopTransmit(EngineChannelID)
    case activateReceiveAudio(EngineChannelID)
}

public enum MediaEngineEffect: Equatable, Codable, Sendable {
    case startCapture(TransmitEpoch)
    case stopCapture(TransmitEpoch)
    case sendLiveAudio(EngineAudioChunk)
    case schedulePlayback(EngineAudioChunk)
    case dropChunk(EngineAudioChunk, MediaDropReason)
}

public enum MediaDropReason: Equatable, Codable, Sendable {
    case duplicate
    case staleTransmit
    case noActiveReceiveEpoch
    case late
    case orderedBacklog
    case jitterQueueOverflow
    case transportUnavailable
}

public enum TransportEngineEffect: Equatable, Codable, Sendable {
    case prewarm(EngineTransportPath)
    case fallBack(to: EngineTransportPath, reason: TransportRecoveryReason)
}

public enum DiagnosticsEngineEffect: Equatable, Codable, Sendable {
    case record(EngineDiagnostic)
    case invariant(EngineInvariantViolation)
}

public enum EngineControlCommandKind: String, Codable, Sendable {
    case beginTransmit = "begin-transmit"
    case endTransmit = "end-transmit"
}

public struct EngineControlCommand: Equatable, Codable, Sendable {
    public let kind: EngineControlCommandKind
    public let channelID: EngineChannelID?
    public let deviceID: EngineDeviceID?
    public init(kind: EngineControlCommandKind, channelID: EngineChannelID? = nil, deviceID: EngineDeviceID? = nil) {
        self.kind = kind
        self.channelID = channelID
        self.deviceID = deviceID
    }
}

public enum EngineControlRejectionReason: Equatable, Codable, Sendable {
    case backendUnavailable
    case notReady
    case unsupported
    case unknown(String)
}

public enum EngineControlResponseStatus: Equatable, Codable, Sendable {
    case accepted
    case rejected(EngineControlRejectionReason)
}

public struct EngineControlResponse: Equatable, Codable, Sendable {
    public let status: EngineControlResponseStatus
    public let channelID: EngineChannelID?
    public let transmitID: EngineTransmitID?
    public init(
        status: EngineControlResponseStatus,
        channelID: EngineChannelID? = nil,
        transmitID: EngineTransmitID? = nil
    ) {
        self.status = status
        self.channelID = channelID
        self.transmitID = transmitID
    }
}

public enum EngineChannelStatus: Equatable, Codable, Sendable {
    case idle
    case waitingForPeer
    case ready
    case transmitting
    case receiving
    case unknown(String)
}

public struct EngineChannelState: Equatable, Codable, Sendable {
    public let channelID: EngineChannelID
    public let status: EngineChannelStatus
    public init(channelID: EngineChannelID, status: EngineChannelStatus) {
        self.channelID = channelID
        self.status = status
    }
}

public protocol EngineBackendPort {
    func seed(handle: String) async throws
    func reset(handle: String) async throws
    func connectWebSocket() async throws
    func sendControlCommand(_ command: EngineControlCommand) async throws -> EngineControlResponse
    func fetchChannelState(_ channelID: EngineChannelID) async throws -> EngineChannelState
}

public struct TurboEngineTransition: Equatable, Sendable {
    public let state: TurboEngineState
    public let snapshot: TurboEngineSnapshot
    public let effects: [TurboEngineEffect]
    public let diagnostics: [EngineDiagnostic]
    public let invariantViolations: [EngineInvariantViolation]
}

public enum EngineTraceInput: Equatable, Codable, Sendable {
    case intent(TurboEngineIntent)
    case event(TurboEngineEvent)

    public init(_ intent: TurboEngineIntent) {
        self = .intent(intent)
    }

    public init(_ event: TurboEngineEvent) {
        self = .event(event)
    }
}

public struct EngineTraceStep: Equatable, Codable, Sendable {
    public let index: Int
    public let source: String
    public let input: EngineTraceInput
    public let resultingState: TurboEngineState
    public let effects: [TurboEngineEffect]
    public let diagnostics: [EngineDiagnostic]
    public let invariantIDs: [String]

    public init(
        index: Int,
        source: String,
        input: EngineTraceInput,
        resultingState: TurboEngineState,
        effects: [TurboEngineEffect],
        diagnostics: [EngineDiagnostic],
        invariantIDs: [String]
    ) {
        self.index = index
        self.source = source
        self.input = input
        self.resultingState = resultingState
        self.effects = effects
        self.diagnostics = diagnostics
        self.invariantIDs = invariantIDs
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case source
        case input
        case resultingState
        case effects
        case diagnostics
        case invariantIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try container.decode(Int.self, forKey: .index)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "legacy-trace"
        self.input = try container.decode(EngineTraceInput.self, forKey: .input)
        self.resultingState = try container.decode(TurboEngineState.self, forKey: .resultingState)
        self.effects = try container.decode([TurboEngineEffect].self, forKey: .effects)
        self.diagnostics = try container.decode([EngineDiagnostic].self, forKey: .diagnostics)
        self.invariantIDs = try container.decode([String].self, forKey: .invariantIDs)
    }
}

public struct EngineTrace: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let localDeviceID: EngineDeviceID
    public var initialState: TurboEngineState
    public var steps: [EngineTraceStep]

    public init(
        schemaVersion: Int = 1,
        localDeviceID: EngineDeviceID,
        initialState: TurboEngineState? = nil,
        steps: [EngineTraceStep] = []
    ) {
        self.schemaVersion = schemaVersion
        self.localDeviceID = localDeviceID
        self.initialState = initialState ?? TurboEngineState(localDeviceID: localDeviceID)
        self.steps = steps
    }
}

public struct EngineTraceReplayReport: Equatable, Codable, Sendable {
    public let passed: Bool
    public let stepCount: Int
    public let invariantIDs: [String]
    public let mismatches: [String]
    public let finalSnapshot: TurboEngineSnapshot
}

public struct TurboEngineTraceRecorder: Equatable, Sendable {
    public private(set) var trace: EngineTrace
    public let maxSteps: Int

    public init(localDeviceID: EngineDeviceID, maxSteps: Int = 2_000) {
        self.trace = EngineTrace(localDeviceID: localDeviceID)
        self.maxSteps = maxSteps
    }

    public mutating func reset(localDeviceID: EngineDeviceID) {
        trace = EngineTrace(localDeviceID: localDeviceID)
    }

    public mutating func record(
        input: EngineTraceInput,
        source: String,
        previousState: TurboEngineState,
        transition: TurboEngineTransition
    ) {
        if trace.steps.isEmpty {
            trace.initialState = previousState
        }
        trace.steps.append(
            EngineTraceStep(
                index: (trace.steps.last?.index ?? -1) + 1,
                source: source,
                input: input,
                resultingState: transition.state,
                effects: transition.effects,
                diagnostics: transition.diagnostics,
                invariantIDs: transition.invariantViolations.map(\.invariantID)
            )
        )
        if trace.steps.count > maxSteps {
            let overflowCount = trace.steps.count - maxSteps
            let removed = trace.steps.prefix(overflowCount)
            trace.steps.removeFirst(overflowCount)
            if let lastRemoved = removed.last {
                trace.initialState = lastRemoved.resultingState
            }
        }
    }
}

public enum EngineTraceReplayer {
    public static func replay(_ trace: EngineTrace) -> EngineTraceReplayReport {
        var engine = TurboEngine(state: trace.initialState)
        var mismatches: [String] = []
        var invariantIDs: [String] = []

        for step in trace.steps {
            let transition = engine.replay(step.input)
            let observedInvariantIDs = transition.invariantViolations.map(\.invariantID)
            invariantIDs.append(contentsOf: observedInvariantIDs)

            if transition.state != step.resultingState {
                mismatches.append("step \(step.index) resulting state mismatch source=\(step.source)")
            }
            if transition.effects != step.effects {
                mismatches.append("step \(step.index) effects mismatch source=\(step.source)")
            }
            if transition.diagnostics != step.diagnostics {
                mismatches.append("step \(step.index) diagnostics mismatch source=\(step.source)")
            }
            if observedInvariantIDs != step.invariantIDs {
                mismatches.append("step \(step.index) invariant ids mismatch source=\(step.source)")
            }
        }

        return EngineTraceReplayReport(
            passed: mismatches.isEmpty,
            stepCount: trace.steps.count,
            invariantIDs: invariantIDs,
            mismatches: mismatches,
            finalSnapshot: engine.snapshot
        )
    }

    public static func normalizedTrace(_ trace: EngineTrace) -> EngineTrace {
        var engine = TurboEngine(state: trace.initialState)
        var normalized = EngineTrace(
            schemaVersion: trace.schemaVersion,
            localDeviceID: trace.localDeviceID,
            initialState: trace.initialState
        )

        for step in trace.steps {
            let transition = engine.replay(step.input)
            normalized.steps.append(
                EngineTraceStep(
                    index: step.index,
                    source: step.source,
                    input: step.input,
                    resultingState: transition.state,
                    effects: transition.effects,
                    diagnostics: transition.diagnostics,
                    invariantIDs: transition.invariantViolations.map(\.invariantID)
                )
            )
        }

        return normalized
    }
}

public struct TurboEngine: Sendable {
    public private(set) var state: TurboEngineState

    public init(localDeviceID: EngineDeviceID) {
        state = TurboEngineState(localDeviceID: localDeviceID)
    }

    public init(state: TurboEngineState) {
        self.state = state
    }

    public var snapshot: TurboEngineSnapshot {
        TurboEngineSnapshot(
            conversation: state.conversation,
            transmit: state.transmit,
            receive: state.receive,
            transport: state.transport,
            transportSelection: state.transportSelection,
            mediaEpochDelivery: state.mediaEpochDelivery,
            lifecycle: state.lifecycle,
            pttAudio: state.pttAudio,
            localTalkCapability: localTalkCapability(for: state),
            receiverReadiness: receiverReadiness(for: state),
            scheduledPlaybackCount: state.scheduledPlayback.count
        )
    }

    public mutating func send(_ intent: TurboEngineIntent) -> TurboEngineTransition {
        apply(.intent(intent))
    }

    public mutating func receive(_ event: TurboEngineEvent) -> TurboEngineTransition {
        apply(.event(event))
    }

    public mutating func replay(_ input: EngineTraceInput) -> TurboEngineTransition {
        switch input {
        case .intent(let intent):
            return send(intent)
        case .event(let event):
            return receive(event)
        }
    }

    private mutating func apply(_ input: EngineInput) -> TurboEngineTransition {
        let reduced = EngineReducer.reduce(state: state, input: input)
        state = reduced.state
        let postconditions = EngineReducer.postconditionViolations(state)
        let allViolations = reduced.invariantViolations + postconditions
        let allEffects = reduced.effects + allViolations.map { .diagnostics(.invariant($0)) }
        let allDiagnostics = reduced.diagnostics + allViolations.map {
            EngineDiagnostic(
                subsystem: "engine",
                message: $0.message,
                metadata: $0.metadata.merging(["invariantID": $0.invariantID]) { current, _ in current }
            )
        }
        return TurboEngineTransition(
            state: state,
            snapshot: snapshot,
            effects: allEffects,
            diagnostics: allDiagnostics,
            invariantViolations: allViolations
        )
    }
}

private enum EngineInput: Equatable {
    case intent(TurboEngineIntent)
    case event(TurboEngineEvent)
}

private struct EngineReduction {
    var state: TurboEngineState
    var effects: [TurboEngineEffect] = []
    var diagnostics: [EngineDiagnostic] = []
    var invariantViolations: [EngineInvariantViolation] = []
}

private enum EngineReducer {
    static func reduce(state: TurboEngineState, input: EngineInput) -> EngineReduction {
        var next = state
        next.tick += 1
        var effects: [TurboEngineEffect] = []
        var diagnostics: [EngineDiagnostic] = []
        var violations: [EngineInvariantViolation] = []

        func record(_ message: String, _ metadata: [String: String] = [:]) {
            diagnostics.append(EngineDiagnostic(subsystem: "engine", message: message, metadata: metadata))
        }

        func invariant(
            _ id: String,
            _ kind: EngineContractKind,
            _ message: String,
            _ metadata: [String: String] = [:]
        ) {
            violations.append(
                EngineInvariantViolation(
                    invariantID: id,
                    kind: kind,
                    message: message,
                    metadata: metadata
                )
            )
        }

        func mediaLaneAvailabilityMap(
            from selection: TransportSelection
        ) -> MediaLaneAvailabilityMap {
            var map = MediaLaneAvailabilityMap()
            for status in selection.laneCapabilities {
                let state: MediaLaneState = status.capability.isMediaViable
                    ? .available(proof: status.capability, generation: selection.networkPathGeneration)
                    : .unavailable(reason: .noRoute, generation: selection.networkPathGeneration)
                _ = map.join(state, for: status.lane)
            }
            return map
        }

        func rescueState(
            for selection: TransportSelection
        ) -> MediaEpochRescueState {
            guard let primary = selection.currentLane ?? selection.bestViableLane else {
                return .broken(reason: .noRoute)
            }
            guard let fallback = selection.fallbackLane,
                  fallback != primary else {
                return .none(primary: primary)
            }
            return .available(
                primary: primary,
                rescue: fallback
            )
        }

        func makeMediaEpochDelivery(
            epoch: TransmitEpoch,
            localDeviceID: EngineDeviceID,
            transportSelection: TransportSelection
        ) -> MediaEpochDeliveryState {
            MediaEpochDeliveryState(
                epochID: MediaEpochID(
                    channelID: epoch.conversation.channelID,
                    senderDeviceID: localDeviceID,
                    receiverDeviceID: epoch.conversation.peerDeviceID ?? EngineDeviceID("unknown-peer-device"),
                    transmitID: epoch.transmitID
                ),
                preferredLane: transportSelection.bestViableLane,
                availableLanes: mediaLaneAvailabilityMap(from: transportSelection),
                rescueState: rescueState(for: transportSelection)
            )
        }

        func makeMediaEpochDelivery(
            prepare: RemoteTransmitPrepareEvidence,
            localDeviceID: EngineDeviceID,
            transportSelection: TransportSelection
        ) -> MediaEpochDeliveryState {
            MediaEpochDeliveryState(
                epochID: MediaEpochID(
                    channelID: prepare.channelID,
                    senderDeviceID: prepare.senderDeviceID,
                    receiverDeviceID: localDeviceID,
                    transmitID: prepare.transmitID
                ),
                preferredLane: transportSelection.bestViableLane,
                availableLanes: mediaLaneAvailabilityMap(from: transportSelection),
                rescueState: rescueState(for: transportSelection)
            )
        }

        switch input {
        case .intent(.selectFriend(let friend)):
            switch friend {
            case .some(let friend):
                next.conversation = .selected(friend)
                record("Selected friend", ["contactID": friend.contactID.rawValue])
            case .none:
                next.conversation = .none
                next.transmit = .idle
                next.receive = .idle
                record("Cleared selected friend")
            }

        case .intent(.requestConnection(let contactID)):
            guard case .selected(let friend) = next.conversation, friend.contactID == contactID else {
                invariant(
                    "engine.connection_request_requires_selected_friend",
                    .precondition,
                    "connection request requires the selected friend",
                    ["contactID": contactID.rawValue]
                )
                break
            }
            let evidence = ConnectionRequestEvidence(
                friend: friend,
                attemptID: EngineAttemptID("connect-\(next.tick)")
            )
            next.conversation = .requesting(evidence)
            effects.append(.backend(.connectWebSocket))

        case .intent(.acceptConnection(let contactID)):
            guard case .incomingBeep(let beep) = next.conversation, beep.friend.contactID == contactID else {
                invariant(
                    "engine.accept_requires_beep",
                    .precondition,
                    "accept requires an incoming Beep for the selected Friend",
                    ["contactID": contactID.rawValue]
                )
                break
            }
            next.conversation = .joining(
                JoinAttemptEvidence(
                    friend: beep.friend,
                    channelID: EngineChannelID("channel-\(contactID.rawValue)"),
                    attemptID: EngineAttemptID("join-\(next.tick)")
                )
            )

        case .intent(.disconnect(let contactID)):
            guard case .joined(let joined) = next.conversation, joined.friend.contactID == contactID else {
                invariant(
                    "engine.disconnect_requires_joined_conversation",
                    .precondition,
                    "disconnect requires a joined conversation for the friend",
                    ["contactID": contactID.rawValue]
                )
                break
            }
            next.conversation = .disconnecting(
                DisconnectAttemptEvidence(conversation: joined, attemptID: EngineAttemptID("disconnect-\(next.tick)"))
            )

        case .intent(.beginTalk):
            guard case .joined(let joined) = next.conversation else {
                next.transmit = .failed(TransmitFailure(conversation: nil, reason: .noJoinedConversation))
                invariant(
                    "engine.transmit_requires_joined_conversation",
                    .precondition,
                    "begin talk requires a joined conversation",
                    [:]
                )
                break
            }
            guard joined.receiverAddressability.isAddressable else {
                let reason = joined.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable
                next.transmit = .failed(TransmitFailure(conversation: joined, reason: .receiverNotAddressable(reason)))
                invariant(
                    "engine.transmit_requires_addressable_receiver",
                    .precondition,
                    "begin talk requires foreground or wake-capable receiver addressability",
                    ["reason": String(describing: reason)]
                )
                break
            }
            switch joined.readiness {
            case .ready:
                let attempt = TransmitBeginAttempt(conversation: joined, attemptID: EngineAttemptID("begin-\(next.tick)"))
                next.transmit = .beginning(attempt)
                effects.append(.ptt(.requestBeginTransmit(joined.channelID)))
                effects.append(.backend(.beginTransmit(joined.channelID)))
            case .pending(let reason):
                next.transmit = .failed(TransmitFailure(conversation: joined, reason: .receiverNotReady(reason)))
                invariant(
                    "engine.transmit_requires_receiver_readiness",
                    .precondition,
                    "begin talk requires receiver readiness evidence",
                    ["reason": String(describing: reason)]
                )
            case .unavailable(let reason):
                next.transmit = .failed(TransmitFailure(conversation: joined, reason: .transportUnavailable(.noRoute)))
                invariant(
                    "engine.transmit_requires_receiver_readiness",
                    .precondition,
                    "begin talk requires available receiver readiness evidence",
                    ["reason": String(describing: reason)]
                )
            }

        case .intent(.endTalk):
            switch next.transmit {
            case .active(let epoch):
                next.transmit = .stopping(TransmitStopAttempt(epoch: epoch, reason: .userReleased))
                next.mediaEpochDelivery = nil
                effects.append(.media(.stopCapture(epoch)))
                effects.append(.backend(.endTransmit(epoch.conversation.channelID, epoch.transmitID)))
                effects.append(.ptt(.requestStopTransmit(epoch.conversation.channelID)))
            case .beginning(let attempt):
                if let backendTransmitID = attempt.backendTransmitID {
                    let epoch = TransmitEpoch(
                        conversation: attempt.conversation,
                        transmitID: backendTransmitID,
                        startedAtTick: attempt.systemStartedAtTick ?? next.tick
                    )
                    next.transmit = .stopping(TransmitStopAttempt(epoch: epoch, reason: .userReleased))
                    next.mediaEpochDelivery = nil
                    effects.append(.backend(.endTransmit(epoch.conversation.channelID, epoch.transmitID)))
                    effects.append(.ptt(.requestStopTransmit(epoch.conversation.channelID)))
                } else {
                    next.transmit = .idle
                    next.mediaEpochDelivery = nil
                    next.pttAudio = .inactive
                    effects.append(.ptt(.requestStopTransmit(attempt.conversation.channelID)))
                }
            case .idle, .failed, .stopping:
                break
            }

        case .intent(.setAudioOutputPreference(let preference)):
            next.audioOutputPreference = preference

        case .event(.backend(.joined(let joined))):
            next.conversation = .joined(joined)
            next.transport = transportPhase(for: joined.readiness)
            next.transportSelection = TransportSelection(
                legacyPhase: next.transport,
                networkPathGeneration: next.transportSelection.networkPathGeneration
            )
            applyReceiverAddressability(
                joined.receiverAddressability,
                state: &next,
                effects: &effects,
                invariant: invariant
            )

        case .event(.backend(.joinFailed(let reason))):
            if case .joined(let joined) = next.conversation {
                next.conversation = .recovering(ConversationRecoveryEvidence(previous: joined, reason: reason))
            }

        case .event(.backend(.receiverAddressabilityChanged(let addressability))):
            applyReceiverAddressability(
                addressability,
                state: &next,
                effects: &effects,
                invariant: invariant
            )

        case .event(.backend(.activeTransmitCleared(let transmitID, let reason))):
            applyActiveTransmitCleared(
                transmitID: transmitID,
                reason: reason,
                state: &next,
                effects: &effects,
                invariant: invariant,
                record: record
            )

        case .event(.backend(.beginTransmitAccepted(let transmitID))):
            guard case .beginning(let attempt) = next.transmit else {
                if case .active(let epoch) = next.transmit,
                   epoch.transmitID == transmitID {
                    next.pttAudio = .active(
                        PTTActivationEvidence(channelID: epoch.conversation.channelID, activatedAtTick: next.tick)
                    )
                    record(
                        "Ignored duplicate transmit begin acknowledgement",
                        ["transmitID": transmitID.rawValue]
                    )
                    break
                }
                invariant(
                    "engine.transmit_begin_ack_requires_beginning_phase",
                    .precondition,
                    "transmit begin ack arrived without a beginning phase",
                    ["transmitID": transmitID.rawValue]
                )
                break
            }
            guard attempt.conversation.receiverAddressability.isAddressable else {
                let reason = attempt.conversation.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable
                next.transmit = .failed(
                    TransmitFailure(conversation: attempt.conversation, reason: .receiverNotAddressable(reason))
                )
                invariant(
                    "engine.transmit_requires_addressable_receiver",
                    .precondition,
                    "transmit begin ack requires foreground or wake-capable receiver addressability",
                    ["reason": String(describing: reason), "transmitID": transmitID.rawValue]
                )
                break
            }
            let updatedAttempt = attempt.recordingBackendTransmitAccepted(transmitID, atTick: next.tick)
            guard updatedAttempt.systemStartedAtTick != nil else {
                next.transmit = .beginning(updatedAttempt)
                record(
                    "Recorded backend transmit lease while waiting for system transmit begin",
                    ["transmitID": transmitID.rawValue]
                )
                break
            }
            let epoch = TransmitEpoch(
                conversation: updatedAttempt.conversation,
                transmitID: transmitID,
                startedAtTick: updatedAttempt.systemStartedAtTick ?? next.tick
            )
            next.transmit = .active(epoch)
            next.mediaEpochDelivery = makeMediaEpochDelivery(
                epoch: epoch,
                localDeviceID: next.localDeviceID,
                transportSelection: next.transportSelection
            )
            next.pttAudio = .active(
                PTTActivationEvidence(channelID: updatedAttempt.conversation.channelID, activatedAtTick: next.tick)
            )
            effects.append(.media(.startCapture(epoch)))

        case .event(.ptt(.systemTransmitBegan(let transmitID))):
            switch next.transmit {
            case .beginning(let attempt):
                let updatedAttempt = attempt.recordingSystemTransmitBegan(transmitID, atTick: next.tick)
                next.pttAudio = .active(
                    PTTActivationEvidence(channelID: attempt.conversation.channelID, activatedAtTick: next.tick)
                )
                guard let backendTransmitID = updatedAttempt.backendTransmitID else {
                    next.transmit = .beginning(updatedAttempt)
                    record(
                        "Recorded system transmit begin while waiting for backend lease",
                        ["transmitID": transmitID.rawValue]
                    )
                    break
                }
                let epoch = TransmitEpoch(
                    conversation: updatedAttempt.conversation,
                    transmitID: backendTransmitID,
                    startedAtTick: updatedAttempt.systemStartedAtTick ?? next.tick
                )
                next.transmit = .active(epoch)
                next.mediaEpochDelivery = makeMediaEpochDelivery(
                    epoch: epoch,
                    localDeviceID: next.localDeviceID,
                    transportSelection: next.transportSelection
                )
                record(
                    "Activated transmit after backend lease and system transmit begin",
                    ["transmitID": transmitID.rawValue]
                )
                effects.append(.media(.startCapture(epoch)))

            case .active(let epoch) where epoch.transmitID == transmitID:
                next.pttAudio = .active(
                    PTTActivationEvidence(channelID: epoch.conversation.channelID, activatedAtTick: next.tick)
                )
                record(
                    "Ignored duplicate transmit begin acknowledgement",
                    ["transmitID": transmitID.rawValue]
                )

            case .idle, .failed:
                guard case .joined(let joined) = next.conversation else {
                    invariant(
                        "engine.system_transmit_begin_requires_joined_conversation",
                        .precondition,
                        "system transmit begin arrived without a joined conversation",
                        ["transmitID": transmitID.rawValue]
                    )
                    break
                }
                guard joined.receiverAddressability.isAddressable else {
                    let reason = joined.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable
                    next.transmit = .failed(TransmitFailure(conversation: joined, reason: .receiverNotAddressable(reason)))
                    invariant(
                        "engine.transmit_requires_addressable_receiver",
                        .precondition,
                        "system transmit begin requires foreground or wake-capable receiver addressability",
                        ["reason": String(describing: reason), "transmitID": transmitID.rawValue]
                    )
                    break
                }
                let attempt = TransmitBeginAttempt(
                    conversation: joined,
                    attemptID: EngineAttemptID("system-begin-\(next.tick)")
                ).recordingSystemTransmitBegan(transmitID, atTick: next.tick)
                next.transmit = .beginning(attempt)
                next.pttAudio = .active(
                    PTTActivationEvidence(channelID: joined.channelID, activatedAtTick: next.tick)
                )
                record(
                    "Recorded system transmit begin while requesting backend lease",
                    ["transmitID": transmitID.rawValue]
                )
                effects.append(.backend(.beginTransmit(joined.channelID)))

            case .active, .stopping:
                invariant(
                    "engine.system_transmit_begin_conflicts_with_active_epoch",
                    .precondition,
                    "system transmit begin conflicted with an active transmit epoch",
                    ["transmitID": transmitID.rawValue]
                )
            }

        case .event(.backend(.localTransmitObserved(let transmitID))):
            guard case .joined(let joined) = next.conversation else {
                invariant(
                    "engine.local_transmit_observation_requires_joined_conversation",
                    .precondition,
                    "backend observed local transmit without a joined conversation",
                    ["transmitID": transmitID.rawValue]
                )
                break
            }
            guard joined.receiverAddressability.isAddressable else {
                let reason = joined.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable
                next.transmit = .failed(TransmitFailure(conversation: joined, reason: .receiverNotAddressable(reason)))
                invariant(
                    "engine.transmit_requires_addressable_receiver",
                    .precondition,
                    "backend local transmit observation requires foreground or wake-capable receiver addressability",
                    ["reason": String(describing: reason), "transmitID": transmitID.rawValue]
                )
                break
            }

            switch next.transmit {
            case .active(let epoch) where epoch.transmitID == transmitID:
                break

            case .beginning(let attempt):
                let updatedAttempt = attempt.recordingBackendTransmitAccepted(transmitID, atTick: next.tick)
                guard updatedAttempt.systemStartedAtTick != nil else {
                    next.transmit = .beginning(updatedAttempt)
                    record(
                        "Recorded backend local transmit while waiting for system transmit begin",
                        ["transmitID": transmitID.rawValue]
                    )
                    break
                }
                let epoch = TransmitEpoch(
                    conversation: updatedAttempt.conversation,
                    transmitID: transmitID,
                    startedAtTick: updatedAttempt.systemStartedAtTick ?? next.tick
                )
                next.transmit = .active(epoch)
                next.pttAudio = .active(
                    PTTActivationEvidence(channelID: updatedAttempt.conversation.channelID, activatedAtTick: next.tick)
                )
                record(
                    "Recovered local transmit after backend lease and system transmit begin",
                    ["transmitID": transmitID.rawValue]
                )
                effects.append(.media(.startCapture(epoch)))

            case .idle, .failed:
                let attempt = TransmitBeginAttempt(
                    conversation: joined,
                    attemptID: EngineAttemptID("backend-observed-\(next.tick)")
                ).recordingBackendTransmitAccepted(transmitID, atTick: next.tick)
                next.transmit = .beginning(attempt)
                record(
                    "Recorded backend local transmit while waiting for system transmit begin",
                    ["transmitID": transmitID.rawValue]
                )

            case .active, .stopping:
                record(
                    "Ignored backend local transmit observation during another transmit phase",
                    [
                        "transmitID": transmitID.rawValue,
                        "phase": String(describing: next.transmit),
                    ]
                )
            }

        case .event(.backend(.stopTransmitAccepted(let transmitID))),
             .event(.ptt(.systemTransmitEnded(let transmitID))):
            guard case .stopping(let stop) = next.transmit else {
                if case .idle = next.transmit {
                    record(
                        "Ignored duplicate transmit stop acknowledgement",
                        ["transmitID": transmitID.rawValue]
                    )
                    break
                }
                invariant(
                    "engine.transmit_stop_ack_requires_stopping_phase",
                    .precondition,
                    "transmit stop ack arrived without a stopping phase",
                    ["transmitID": transmitID.rawValue]
                )
                break
            }
            guard stop.epoch.transmitID == transmitID else {
                invariant(
                    "transmit.stale_end_overrides_newer_epoch",
                    .precondition,
                    "stale transmit stop was rejected",
                    [
                        "expectedTransmitID": stop.epoch.transmitID.rawValue,
                        "observedTransmitID": transmitID.rawValue,
                    ]
                )
                break
            }
            next.transmit = .idle
            next.mediaEpochDelivery = nil
            next.pttAudio = .inactive

        case .event(.backend(.remoteTransmitStarted(let prepare))):
            next.receive = .prepared(prepare)
            next.mediaEpochDelivery = makeMediaEpochDelivery(
                prepare: prepare,
                localDeviceID: next.localDeviceID,
                transportSelection: next.transportSelection
            )

        case .event(.backend(.remoteTransmitStopped(let transmitID))):
            switch next.receive {
            case .receiving(let epoch) where epoch.prepare.transmitID == transmitID:
                next.receive = .draining(PlaybackDrain(epoch: epoch, stoppedAtTick: next.tick))
            case .prepared(let prepare) where prepare.transmitID == transmitID:
                next.receive = .idle
                next.mediaEpochDelivery = nil
            case .awaitingPTTActivation(let buffered) where buffered.prepare.transmitID == transmitID:
                next.receive = .draining(
                    PlaybackDrain(
                        epoch: ReceiveEpoch(
                            prepare: buffered.prepare,
                            acceptedChunkIDs: Set(buffered.chunks.map(\.id))
                        ),
                        stoppedAtTick: next.tick
                    )
                )
            case .draining(let drain) where drain.epoch.prepare.transmitID == transmitID:
                record(
                    "Ignored duplicate remote transmit stop",
                    ["transmitID": transmitID.rawValue]
                )
            default:
                invariant(
                    "engine.remote_stop_requires_matching_receive_epoch",
                    .precondition,
                    "remote stop did not match the active receive epoch",
                    ["transmitID": transmitID.rawValue]
                )
            }

        case .event(.ptt(.incomingPush(let prepare))):
            next.mediaEpochDelivery = makeMediaEpochDelivery(
                prepare: prepare,
                localDeviceID: next.localDeviceID,
                transportSelection: next.transportSelection
            )
            next.receive = .awaitingPTTActivation(
                WakeBufferedReceive(
                    prepare: prepare,
                    reason: next.lifecycle == .locked ? .appLocked : .waitingForPTTActivation,
                    chunks: []
                )
            )
            next.pttAudio = .activating(
                PTTActivationAttempt(channelID: prepare.channelID, reason: .incomingPush)
            )
            effects.append(.ptt(.activateReceiveAudio(prepare.channelID)))

        case .event(.ptt(.audioActivationStarted(let attempt))):
            next.pttAudio = .activating(attempt)

        case .event(.ptt(.audioActivated(let evidence))):
            next.pttAudio = .active(evidence)
            if case .awaitingPTTActivation(var buffered) = next.receive {
                let capability = buffered.chunks.first?.effectiveMediaCapability
                    ?? EngineMediaTransportCapability.defaultMediaCapability(for: .relayWebSocket)
                var epoch = ReceiveEpoch(
                    prepare: buffered.prepare,
                    playout: .liveDefault(for: capability)
                )
                for chunk in buffered.chunks.sorted(by: { $0.sequence < $1.sequence }) {
                    let actions = epoch.playout.receive(chunk)
                    appendPlayoutActions(
                        actions,
                        state: &next,
                        effects: &effects,
                        record: record
                    )
                }
                buffered.chunks.removeAll()
                next.receive = .receiving(epoch)
            }

        case .event(.ptt(.audioActivationFailed(let failure))):
            next.pttAudio = .failed(failure)
            invariant(
                "engine.ptt_activation_failed",
                .liveness,
                "PTT audio activation failed",
                ["reason": String(describing: failure.reason)]
            )

        case .event(.ptt(.systemTransmitBeginFailed(let reason))):
            let joined = next.conversation.joinedEvidence
            next.transmit = .failed(TransmitFailure(conversation: joined, reason: .systemRejected(String(describing: reason))))
            invariant(
                "engine.system_transmit_begin_failed",
                .liveness,
                "system transmit begin failed",
                ["reason": String(describing: reason)]
            )

        case .event(.media(.localAudioCaptured(let chunk))):
            guard case .active(let epoch) = next.transmit, epoch.transmitID == chunk.transmitID else {
                invariant(
                    "engine.local_audio_requires_active_transmit_epoch",
                    .precondition,
                    "local audio was captured without a matching active transmit epoch",
                    ["chunkTransmitID": chunk.transmitID.rawValue]
                )
                break
            }
            let capturedLane = chunk.transport.defaultLane
            next.mediaEpochDelivery?.proveActiveLane(
                capturedLane,
                proof: .firstAudioQueued(frameIndex: UInt64(chunk.sequence.rawValue))
            )
            effects.append(.media(.sendLiveAudio(chunk)))

        case .event(.media(.remoteAudioReceived(let chunk))):
            var shouldReceiveChunk = true
            if next.mediaEpochDelivery?.epochID.transmitID == chunk.transmitID {
                let frameIndex = UInt64(chunk.sequence.rawValue)
                switch next.mediaEpochDelivery?.receiveWindow.admit(frameIndex: frameIndex) {
                case .accepted:
                    next.mediaEpochDelivery?.proveActiveLane(
                        chunk.transport.defaultLane,
                        proof: .receiveAccepted(frameIndex: frameIndex, transport: chunk.transport.defaultLane)
                    )
                case .duplicate:
                    shouldReceiveChunk = false
                    record(
                        "Deduplicated media epoch frame before playback",
                        [
                            "transmitID": chunk.transmitID.rawValue,
                            "sequence": String(chunk.sequence.rawValue),
                            "transport": chunk.transport.rawValue,
                        ]
                    )
                    effects.append(.media(.dropChunk(chunk, .duplicate)))
                case .late:
                    shouldReceiveChunk = false
                    record(
                        "Dropped late media epoch frame before receive admission",
                        [
                            "transmitID": chunk.transmitID.rawValue,
                            "sequence": String(chunk.sequence.rawValue),
                            "transport": chunk.transport.rawValue,
                        ]
                    )
                    effects.append(.media(.dropChunk(chunk, .orderedBacklog)))
                case .none:
                    break
                }
            }
            if shouldReceiveChunk {
                receiveRemoteAudioChunk(
                    chunk,
                    state: &next,
                    effects: &effects,
                    record: record,
                    invariant: invariant
                )
            }

        case .event(.media(.playoutDeadlineElapsed(let transmitID, let sequence))):
            if case .receiving(var epoch) = next.receive,
               epoch.prepare.transmitID == transmitID {
                let actions = epoch.playout.deadlineElapsed(transmitID: transmitID, sequence: sequence)
                next.receive = .receiving(epoch)
                appendPlayoutActions(
                    actions,
                    state: &next,
                    effects: &effects,
                    record: record
                )
            }

        case .event(.media(.playbackScheduled(let chunk))):
            next.scheduledPlayback.append(chunk)

        case .event(.media(.playbackDrained(let transmitID))):
            if case .draining(let drain) = next.receive, drain.epoch.prepare.transmitID == transmitID {
                next.receive = .idle
                next.mediaEpochDelivery = nil
            }

        case .event(.media(.playbackFailed(let chunk, let message))):
            next.receive = .failed(ReceiveFailure(reason: .playbackFailed(message)))
            invariant(
                "engine.playback_failed",
                .liveness,
                "playback failed after receiving audio",
                ["chunkID": chunk.id.rawValue, "message": message]
            )

        case .event(.transport(.networkChanged(let network))):
            let previousLane = next.transportSelection.currentLane
            next.transportSelection.networkChanged(network, activeMedia: activeMediaIsLive(next))
            if let current = next.transportSelection.currentLane {
                next.transport = legacyTransportPhase(for: current, state: next)
            } else {
                next.transport = .unavailable(.networkChanged(network))
            }
            switch previousLane {
            case .directQuic:
                effects.append(.transport(.prewarm(.fastRelay)))
            case .fastRelayQuic:
                break
            case .fastRelayTcp, .webSocketTcp:
                effects.append(.transport(.prewarm(.fastRelay)))
            case nil:
                break
            }
            next.lifecycle = network == .offline ? .inactive : next.lifecycle

        case .event(.transport(.pathAvailable(let phase))):
            if let lane = phase.currentLane {
                _ = next.transportSelection.markAvailable(
                    TransportLaneAvailability(
                        lane: lane,
                        networkPathGeneration: next.transportSelection.networkPathGeneration
                    ),
                    activeMedia: activeMediaIsLive(next)
                )
            }
            next.transport = legacyTransportPhase(for: next.transportSelection.currentLane, state: next)

        case .event(.transport(.pathFailed(let path, let reason))):
            _ = next.transportSelection.markFailed(
                TransportLaneFailure(
                    lane: path.defaultLane,
                    reason: reason,
                    networkPathGeneration: next.transportSelection.networkPathGeneration
                ),
                activeMedia: activeMediaIsLive(next)
            )
            if let fallback = next.transportSelection.currentLane?.legacyPath {
                next.transport = .recovering(
                    TransportRecoveryEvidence(previous: path, fallback: fallback, reason: .pathFailed(reason))
                )
                effects.append(.transport(.fallBack(to: fallback, reason: .pathFailed(reason))))
            } else {
                next.transport = .unavailable(.noRoute)
            }

        case .event(.transport(.fallbackSelected(let fallback))):
            switch fallback {
            case .relayWebSocket:
                next.transport = .relayWebSocket(RelayWebSocketEvidence())
            case .fastRelay:
                next.transport = .fastRelay(FastRelayEvidence(host: "relay.beepbeep.to", port: 443))
            case .directQuic:
                if let peerDeviceID = next.conversation.joinedEvidence?.peerDeviceID {
                    next.transport = .directQuic(DirectQuicEvidence(peerDeviceID: peerDeviceID))
                } else {
                    next.transport = .unavailable(.noRoute)
                }
            }
            next.transportSelection = TransportSelection(
                legacyPhase: next.transport,
                networkPathGeneration: next.transportSelection.networkPathGeneration
            )

        case .event(.transport(.laneAvailable(let availability))):
            let accepted = next.transportSelection.markAvailable(
                availability,
                activeMedia: activeMediaIsLive(next)
            )
            if activeMediaIsLive(next) {
                _ = next.mediaEpochDelivery?.markAvailable(availability)
            }
            if accepted {
                next.transport = legacyTransportPhase(for: next.transportSelection.currentLane, state: next)
            } else {
                record(
                    "Ignored stale transport lane availability",
                    [
                        "lane": availability.lane.diagnosticsValue,
                        "eventGeneration": "\(availability.networkPathGeneration)",
                        "currentGeneration": "\(next.transportSelection.networkPathGeneration)",
                    ]
                )
            }

        case .event(.transport(.laneFailed(let failure))):
            let accepted = next.transportSelection.markFailed(
                failure,
                activeMedia: activeMediaIsLive(next)
            )
            if activeMediaIsLive(next) {
                _ = next.mediaEpochDelivery?.markFailed(failure)
            }
            if accepted {
                if let fallback = next.transportSelection.currentLane?.legacyPath {
                    next.transport = .recovering(
                        TransportRecoveryEvidence(
                            previous: failure.lane.legacyPath,
                            fallback: fallback,
                            reason: .pathFailed(failure.reason)
                        )
                    )
                    effects.append(.transport(.fallBack(to: fallback, reason: .pathFailed(failure.reason))))
                } else {
                    next.transport = .unavailable(.noRoute)
                }
            } else {
                record(
                    "Ignored stale transport lane failure",
                    [
                        "lane": failure.lane.diagnosticsValue,
                        "eventGeneration": "\(failure.networkPathGeneration)",
                        "currentGeneration": "\(next.transportSelection.networkPathGeneration)",
                    ]
                )
            }

        case .event(.lifecycle(.moved(let appState))):
            next.lifecycle = appState
            if appState.needsSystemPTTActivationForPlayback,
               case .receiving(let epoch) = next.receive {
                next.receive = .awaitingPTTActivation(
                    WakeBufferedReceive(
                        prepare: epoch.prepare,
                        reason: appState == .locked ? .appLocked : .appBackgrounded,
                        chunks: []
                    )
                )
            }

        case .event(.clock(.tick(let tick))):
            next.tick = max(next.tick, tick)

        case .event(.clock(.deadlineElapsed(let deadline))):
            switch deadline {
            case .pttActivation(let channelID):
                if case .activating(let attempt) = next.pttAudio, attempt.channelID == channelID {
                    next.pttAudio = .failed(
                        PTTActivationFailure(channelID: channelID, reason: .timedOut)
                    )
                    invariant(
                        "engine.ptt_activation_deadline_elapsed",
                        .liveness,
                        "PTT audio activation deadline elapsed",
                        ["channelID": channelID.rawValue]
                    )
                }
            case .firstAudio(let transmitID):
                invariant(
                    "engine.first_audio_deadline_elapsed",
                    .liveness,
                    "first audio deadline elapsed",
                    ["transmitID": transmitID.rawValue]
                )
            case .playbackDrain(let transmitID):
                if case .draining(let drain) = next.receive, drain.epoch.prepare.transmitID == transmitID {
                    next.receive = .idle
                }
            }
        }

        return EngineReduction(
            state: next,
            effects: effects,
            diagnostics: diagnostics,
            invariantViolations: violations
        )
    }

    static func postconditionViolations(_ state: TurboEngineState) -> [EngineInvariantViolation] {
        var violations: [EngineInvariantViolation] = []
        if case .active(let epoch) = state.transmit,
           epoch.conversation.channelID.rawValue.isEmpty {
            violations.append(
                EngineInvariantViolation(
                    invariantID: "engine.active_transmit_requires_channel",
                    kind: .postcondition,
                    message: "active transmit epoch must carry a channel id"
                )
            )
        }
        if case .active(let epoch) = state.transmit,
           !epoch.conversation.receiverAddressability.isAddressable {
            violations.append(
                EngineInvariantViolation(
                    invariantID: "engine.active_transmit_requires_addressable_receiver",
                    kind: .postcondition,
                    message: "active transmit epoch must have foreground or wake-capable receiver addressability",
                    metadata: [
                        "reason": String(
                            describing: epoch.conversation.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable
                        ),
                    ]
                )
            )
        }
        if case .receiving(let epoch) = state.receive {
            let scheduledForEpoch = state.scheduledPlayback.filter { $0.transmitID == epoch.prepare.transmitID }
            let duplicates = Dictionary(grouping: scheduledForEpoch, by: \.id).filter { $0.value.count > 1 }
            if !duplicates.isEmpty {
                violations.append(
                    EngineInvariantViolation(
                        invariantID: "engine.playback_schedule_has_no_duplicate_chunks",
                        kind: .postcondition,
                        message: "playback schedule contains duplicate chunk ids",
                        metadata: ["duplicateCount": String(duplicates.count)]
                    )
                )
            }
        }
        return violations
    }

    private static func applyReceiverAddressability(
        _ addressability: ReceiverAddressability,
        state: inout TurboEngineState,
        effects: inout [TurboEngineEffect],
        invariant: (String, EngineContractKind, String, [String: String]) -> Void
    ) {
        guard case .joined(let joined) = state.conversation else {
            invariant(
                "engine.receiver_addressability_requires_joined_conversation",
                .precondition,
                "receiver addressability update arrived without joined conversation",
                [:]
            )
            return
        }

        let updatedJoined = joined.withReceiverAddressability(addressability)
        state.conversation = .joined(updatedJoined)
        updateTransmitConversation(updatedJoined, state: &state)

        guard case .unavailable(let reason) = addressability else { return }
        if case .beginning = state.transmit {
            state.transmit = .failed(
                TransmitFailure(conversation: updatedJoined, reason: .receiverNotAddressable(reason))
            )
            effects.append(.ptt(.requestStopTransmit(updatedJoined.channelID)))
            return
        }
        if case .active(let epoch) = state.transmit {
            let updatedEpoch = TransmitEpoch(
                conversation: updatedJoined,
                transmitID: epoch.transmitID,
                startedAtTick: epoch.startedAtTick
            )
            state.transmit = .stopping(
                TransmitStopAttempt(epoch: updatedEpoch, reason: .receiverUnaddressable(reason))
            )
            effects.append(.media(.stopCapture(updatedEpoch)))
            effects.append(.backend(.endTransmit(updatedJoined.channelID, updatedEpoch.transmitID)))
            effects.append(.ptt(.requestStopTransmit(updatedJoined.channelID)))
        }
    }

    private static func applyActiveTransmitCleared(
        transmitID: EngineTransmitID,
        reason: ActiveTransmitClearReason,
        state: inout TurboEngineState,
        effects: inout [TurboEngineEffect],
        invariant: (String, EngineContractKind, String, [String: String]) -> Void,
        record: (String, [String: String]) -> Void
    ) {
        if case .receiverBecameUnaddressable(let unavailableReason) = reason,
           case .joined(let joined) = state.conversation {
            let updatedJoined = joined.withReceiverAddressability(.unavailable(unavailableReason))
            state.conversation = .joined(updatedJoined)
            updateTransmitConversation(updatedJoined, state: &state)
        }

        switch state.transmit {
        case .active(let epoch) where epoch.transmitID == transmitID:
            effects.append(.media(.stopCapture(epoch)))
            state.transmit = .idle
            state.pttAudio = .inactive
            record(
                "Backend cleared active transmit",
                ["transmitID": transmitID.rawValue, "reason": String(describing: reason)]
            )

        case .stopping(let stop) where stop.epoch.transmitID == transmitID:
            state.transmit = .idle
            state.pttAudio = .inactive
            record(
                "Backend confirmed active transmit clear while stopping",
                ["transmitID": transmitID.rawValue, "reason": String(describing: reason)]
            )

        case .idle:
            record(
                "Ignored duplicate active transmit clear",
                ["transmitID": transmitID.rawValue, "reason": String(describing: reason)]
            )

        default:
            invariant(
                "engine.active_transmit_clear_requires_matching_epoch",
                .precondition,
                "backend active transmit clear did not match local transmit epoch",
                ["transmitID": transmitID.rawValue, "reason": String(describing: reason)]
            )
        }
    }

    private static func updateTransmitConversation(_ joined: JoinedConversationEvidence, state: inout TurboEngineState) {
        switch state.transmit {
        case .beginning(let attempt):
            state.transmit = .beginning(
                TransmitBeginAttempt(
                    conversation: joined,
                    attemptID: attempt.attemptID,
                    backendTransmitID: attempt.backendTransmitID,
                    backendAcceptedAtTick: attempt.backendAcceptedAtTick,
                    systemTransmitID: attempt.systemTransmitID,
                    systemStartedAtTick: attempt.systemStartedAtTick
                )
            )
        case .active(let epoch):
            state.transmit = .active(
                TransmitEpoch(conversation: joined, transmitID: epoch.transmitID, startedAtTick: epoch.startedAtTick)
            )
        case .stopping(let stop):
            let epoch = TransmitEpoch(
                conversation: joined,
                transmitID: stop.epoch.transmitID,
                startedAtTick: stop.epoch.startedAtTick
            )
            state.transmit = .stopping(TransmitStopAttempt(epoch: epoch, reason: stop.reason))
        case .idle, .failed:
            break
        }
    }

    private static func receiveRemoteAudioChunk(
        _ chunk: EngineAudioChunk,
        state: inout TurboEngineState,
        effects: inout [TurboEngineEffect],
        record: (String, [String: String]) -> Void,
        invariant: (String, EngineContractKind, String, [String: String]) -> Void
    ) {
        switch state.receive {
        case .idle:
            invariant(
                "engine.remote_audio_requires_receive_epoch",
                .precondition,
                "remote audio arrived before a receive epoch",
                ["chunkID": chunk.id.rawValue, "transmitID": chunk.transmitID.rawValue]
            )
            effects.append(.media(.dropChunk(chunk, .noActiveReceiveEpoch)))

        case .prepared(let prepare):
            guard prepare.transmitID == chunk.transmitID else {
                invariant(
                    "engine.remote_audio_rejects_stale_epoch",
                    .precondition,
                    "remote audio transmit id did not match prepared epoch",
                    ["expected": prepare.transmitID.rawValue, "observed": chunk.transmitID.rawValue]
                )
                effects.append(.media(.dropChunk(chunk, .staleTransmit)))
                return
            }
            if state.lifecycle.needsSystemPTTActivationForPlayback,
               !isPTTAudioActive(state.pttAudio, channelID: prepare.channelID) {
                state.receive = .awaitingPTTActivation(
                    WakeBufferedReceive(
                        prepare: prepare,
                        reason: state.lifecycle == .locked ? .appLocked : .appBackgrounded,
                        chunks: [chunk]
                    )
                )
                effects.append(.ptt(.activateReceiveAudio(prepare.channelID)))
                return
            }
            var epoch = ReceiveEpoch(
                prepare: prepare,
                playout: .liveDefault(for: chunk.effectiveMediaCapability)
            )
            let actions = epoch.playout.receive(chunk)
            state.receive = .receiving(epoch)
            appendPlayoutActions(
                actions,
                state: &state,
                effects: &effects,
                record: record
            )

        case .awaitingPTTActivation(var buffered):
            guard buffered.prepare.transmitID == chunk.transmitID else {
                invariant(
                    "engine.remote_audio_rejects_stale_epoch",
                    .precondition,
                    "buffered remote audio transmit id did not match wake epoch",
                    ["expected": buffered.prepare.transmitID.rawValue, "observed": chunk.transmitID.rawValue]
                )
                effects.append(.media(.dropChunk(chunk, .staleTransmit)))
                return
            }
            guard !buffered.chunks.contains(where: { $0.id == chunk.id }) else {
                effects.append(.media(.dropChunk(chunk, .duplicate)))
                return
            }
            buffered.chunks.append(chunk)
            state.receive = .awaitingPTTActivation(buffered)

        case .receiving(var epoch):
            guard epoch.prepare.transmitID == chunk.transmitID else {
                invariant(
                    "engine.remote_audio_rejects_stale_epoch",
                    .precondition,
                    "remote audio transmit id did not match active receive epoch",
                    ["expected": epoch.prepare.transmitID.rawValue, "observed": chunk.transmitID.rawValue]
                )
                effects.append(.media(.dropChunk(chunk, .staleTransmit)))
                return
            }
            let actions = epoch.playout.receive(chunk)
            state.receive = .receiving(epoch)
            appendPlayoutActions(
                actions,
                state: &state,
                effects: &effects,
                record: record
            )

        case .draining(let drain):
            invariant(
                "engine.no_playback_after_transmit_stop",
                .precondition,
                "remote audio arrived after transmit stop was accepted",
                [
                    "chunkID": chunk.id.rawValue,
                    "stoppedTransmitID": drain.epoch.prepare.transmitID.rawValue,
                    "observedTransmitID": chunk.transmitID.rawValue,
                ]
            )
            effects.append(.media(.dropChunk(chunk, .staleTransmit)))

        case .failed:
            effects.append(.media(.dropChunk(chunk, .noActiveReceiveEpoch)))
        }
    }

    private static func appendPlayoutActions(
        _ actions: [EngineMediaPlayoutAction],
        state: inout TurboEngineState,
        effects: inout [TurboEngineEffect],
        record: (String, [String: String]) -> Void
    ) {
        for action in actions {
            switch action {
            case .schedule(let chunks):
                for chunk in chunks {
                    effects.append(.media(.schedulePlayback(chunk)))
                    state.scheduledPlayback.append(chunk)
                }
            case .buffer(let chunk):
                record(
                    "Buffered media frame in jitter buffer",
                    [
                        "chunkID": chunk.id.rawValue,
                        "sequence": String(chunk.sequence.rawValue),
                        "transport": chunk.transport.rawValue,
                    ]
                )
            case .drop(let chunk, let reason):
                effects.append(.media(.dropChunk(chunk, reason)))
                record(
                    "Dropped media frame before playback",
                    [
                        "chunkID": chunk.id.rawValue,
                        "sequence": String(chunk.sequence.rawValue),
                        "transport": chunk.transport.rawValue,
                        "reason": String(describing: reason),
                    ]
                )
            case .skipMissing(let transmitID, let sequence):
                record(
                    "Skipped missing media frame after jitter deadline",
                    [
                        "transmitID": transmitID.rawValue,
                        "sequence": String(sequence.rawValue),
                    ]
                )
            }
        }
    }

    private static func isPTTAudioActive(
        _ activation: EnginePTTAudioActivationState,
        channelID: EngineChannelID
    ) -> Bool {
        guard case .active(let evidence) = activation else { return false }
        return evidence.channelID == channelID
    }

    private static func transportPhase(for readiness: EngineReadiness<JoinedReadinessEvidence>) -> EngineTransportPhase {
        guard case .ready(let evidence) = readiness else {
            return .unavailable(.noRoute)
        }
        switch evidence.transport {
        case .relayWebSocket:
            return .relayWebSocket(RelayWebSocketEvidence(channelID: evidence.backendMembershipObserved.channelID))
        case .fastRelay:
            return .fastRelay(FastRelayEvidence(host: "relay.beepbeep.to", port: 443))
        case .directQuic:
            return .directQuic(DirectQuicEvidence(peerDeviceID: evidence.backendMembershipObserved.peerDeviceID))
        }
    }
}

private func activeMediaIsLive(_ state: TurboEngineState) -> Bool {
    switch state.transmit {
    case .active:
        return true
    case .idle, .beginning, .stopping, .failed:
        break
    }
    switch state.receive {
    case .receiving, .awaitingPTTActivation:
        return true
    case .idle, .prepared, .draining, .failed:
        return false
    }
}

private func legacyTransportPhase(
    for lane: TransportLane?,
    state: TurboEngineState
) -> EngineTransportPhase {
    guard let lane else {
        return .unavailable(.noRoute)
    }
    switch lane {
    case .directQuic:
        return .directQuic(
            DirectQuicEvidence(
                peerDeviceID: state.conversation.joinedEvidence?.peerDeviceID ?? "unknown-peer-device"
            )
        )
    case .fastRelayQuic, .fastRelayTcp:
        return .fastRelay(FastRelayEvidence(host: "relay.beepbeep.to", port: 443))
    case .webSocketTcp:
        return .relayWebSocket(
            RelayWebSocketEvidence(channelID: state.conversation.joinedEvidence?.channelID)
        )
    }
}

private func localTalkCapability(for state: TurboEngineState) -> EngineCapability<TransmitCapabilityEvidence> {
    guard case .joined(let joined) = state.conversation else {
        return .blocked(.localNotJoined)
    }
    guard joined.receiverAddressability.isAddressable else {
        return .blocked(.receiverNotAddressable(joined.receiverAddressability.unavailableReason ?? .peerDeviceUnavailable))
    }
    guard case .ready = joined.readiness else {
        return .blocked(.receiverNotReady)
    }
    guard let path = state.transport.currentPath else {
        return .blocked(.transportUnavailable(.noRoute))
    }
    return .available(TransmitCapabilityEvidence(conversation: joined, transport: path))
}

private func receiverReadiness(for state: TurboEngineState) -> EngineReadiness<ReceiveReadinessEvidence> {
    guard let path = state.transport.currentPath else {
        return .unavailable(.transportUnavailable(.noRoute))
    }
    switch state.pttAudio {
    case .active:
        return .ready(ReceiveReadinessEvidence(activation: state.pttAudio, transport: path))
    case .activating:
        return .pending(.waitingForPTTActivation)
    case .inactive:
        return state.lifecycle.needsSystemPTTActivationForPlayback
            ? .pending(.waitingForPTTActivation)
            : .ready(ReceiveReadinessEvidence(activation: state.pttAudio, transport: path))
    case .failed:
        return .unavailable(.noWakeTarget)
    }
}
