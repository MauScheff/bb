import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
import UserNotifications
import Intents
import CryptoKit
import TurboEngine

@testable import BeepBeep

struct PropertyRunConfig {
    let seed: UInt64
    let iterations: Int
}

struct PropertyFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

@MainActor
func runProperty(
    _ config: PropertyRunConfig,
    name: String,
    body: (inout SeededRNG, Int, UInt64) throws -> Void
) throws {
    for iteration in 0..<config.iterations {
        let iterationSeed = config.seed &+ UInt64(iteration) &* 0x9E37_79B9_7F4A_7C15
        var rng = SeededRNG(seed: iterationSeed)
        do {
            try body(&rng, iteration, iterationSeed)
        } catch let failure as PropertyFailure {
            throw PropertyFailure(message: "\(name) failed\n\(failure.message)")
        }
    }
}

@MainActor
func requireProperty(
    _ condition: Bool,
    seed: UInt64,
    iteration: Int,
    inputSummary: String,
    expectedInvariant: String,
    observed: String
) throws {
    guard condition else {
        throw PropertyFailure(
            message: """
            seed=\(seed)
            iteration=\(iteration)
            input=\(inputSummary)
            expected=\(expectedInvariant)
            observed=\(observed)
            """
        )
    }
}

struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xA076_1D64_78BD_642F : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextBool() -> Bool {
        (next() & 1) == 0
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func pick<Element>(_ values: [Element]) -> Element {
        values[nextInt(in: 0...(values.count - 1))]
    }

    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((a >> UInt64(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((b >> UInt64(shift)) & 0xff))
        }
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

struct ConversationProjectionPropertySample {
    let context: ConversationDerivationContext
    let relationship: BeepThreadProjection
    let summary: String

    @MainActor
    static func generate(rng: inout SeededRNG) -> ConversationProjectionPropertySample {
        let contactID = rng.uuid()
        let selectedContactID = rng.nextBool() ? contactID : (rng.nextBool() ? rng.uuid() : nil)
        let isSelected = selectedContactID == contactID
        let channelUUID = rng.uuid()
        let localSessionKind = rng.nextInt(in: 0...3)
        let isJoined = localSessionKind == 2 || localSessionKind == 3
        let activeChannelID = (localSessionKind == 1 || localSessionKind == 3) ? contactID : nil
        let systemMatches = localSessionKind == 3
        let systemSessionState: SystemPTTSessionState = {
            switch rng.nextInt(in: 0...4) {
            case 0:
                return .none
            case 1:
                return .active(contactID: contactID, channelUUID: channelUUID)
            case 2:
                return .active(contactID: rng.uuid(), channelUUID: rng.uuid())
            case 3:
                return .mismatched(channelUUID: rng.uuid())
            default:
                return systemMatches ? .active(contactID: contactID, channelUUID: channelUUID) : .none
            }
        }()
        let localTransmit = randomLocalTransmit(rng: &rng)
        let channel = randomChannel(rng: &rng)
        let relationship = ConversationStateMachine.beepThreadProjection(
            hasIncomingBeep: rng.nextBool(),
            hasOutgoingBeep: rng.nextBool(),
            requestCount: rng.nextInt(in: 0...5)
        )
        let pendingAction = randomPendingAction(rng: &rng, contactID: contactID)
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: selectedContactID,
            baseState: randomBaseState(rng: &rng),
            relationship: relationship,
            contactName: "Blake",
            contactIsOnline: rng.nextBool(),
            isJoined: isJoined,
            localTransmit: localTransmit,
            remoteParticipantSignalIsTransmitting: rng.nextBool(),
            activeChannelID: activeChannelID,
            systemSessionMatchesContact: systemMatches,
            systemSessionState: systemSessionState,
            pendingAction: pendingAction,
            pendingConnectAcceptedIncomingBeep: rng.nextBool(),
            localJoinFailure: nil,
            mediaState: rng.pick([.idle, .preparing, .connected, .closed, .failed("property")]),
            localMediaWarmupState: rng.pick([.cold, .prewarming, .ready, .failed]),
            localRelayTransportReady: rng.nextBool(),
            directMediaPathActive: rng.nextBool(),
            firstTalkStartupProfile: rng.pick([.directQuicWarm, .directQuicWarming, .relayWarm, .relayWarming, .unavailable]),
            incomingWakeActivationState: nil,
            hadConnectedDevicePTTContinuity: rng.nextBool(),
            channel: channel
        )
        return ConversationProjectionPropertySample(
            context: context,
            relationship: relationship,
            summary: [
                "selected=\(isSelected)",
                "base=\(context.baseState.rawValue)",
                "relationship=\(relationship)",
                "joined=\(isJoined)",
                "activeChannel=\(activeChannelID != nil)",
                "system=\(systemSessionState)",
                "pending=\(pendingAction)",
                "localTransmit=\(localTransmit)",
                "channel=\(String(describing: channel?.readinessStatus?.kind))",
            ].joined(separator: " ")
        )
    }

    @MainActor
    static func generatePendingBeepDominanceFault(rng: inout SeededRNG) -> ConversationProjectionPropertySample {
        let contactID = rng.uuid()
        let requestCount = rng.nextInt(in: 1...4)
        let relationship = rng.pick([
            BeepThreadProjection.outgoingBeep(requestCount: requestCount),
            .incomingBeep(requestCount: requestCount),
            .mutualBeep(requestCount: requestCount),
        ])
        let selfJoined = rng.nextBool()
        let peerJoined = rng.nextBool()
        let peerDeviceConnected = false
        let readinessStatus = rng.pick([
            TurboChannelReadinessStatus.inactive,
            .waitingForSelf,
            .waitingForPeer,
        ])
        let conversationStatus = rng.pick([
            ConversationState.waitingForPeer,
            .ready,
            relationship.fallbackConversationState,
        ])
        let channel = ChannelReadinessSnapshot(
            channelState: makeChannelState(
                status: conversationStatus,
                canTransmit: false,
                selfJoined: selfJoined,
                peerJoined: peerJoined,
                peerDeviceConnected: peerDeviceConnected,
                hasIncomingBeep: relationship.hasIncomingBeep,
                hasOutgoingBeep: relationship.hasOutgoingBeep
            ),
            readiness: makeChannelReadiness(
                status: readinessStatus,
                selfHasActiveDevice: selfJoined,
                peerHasActiveDevice: peerDeviceConnected,
                remoteAudioReadiness: rng.pick([.unknown, .waiting, .wakeCapable]),
                remoteWakeCapability: rng.nextBool()
                    ? .wakeCapable(targetDeviceId: "peer-device")
                    : .unavailable
            )
        )
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: rng.pick([.idle, .waitingForPeer, .ready, relationship.fallbackConversationState]),
            relationship: relationship,
            contactName: "Blake",
            contactIsOnline: rng.nextBool(),
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            pendingConnectAcceptedIncomingBeep: false,
            localJoinFailure: nil,
            mediaState: rng.pick([.idle, .preparing, .connected]),
            localMediaWarmupState: rng.pick([.cold, .prewarming, .ready]),
            localRelayTransportReady: rng.nextBool(),
            directMediaPathActive: rng.nextBool(),
            firstTalkStartupProfile: rng.pick([.directQuicWarming, .relayWarm, .relayWarming]),
            incomingWakeActivationState: nil,
            hadConnectedDevicePTTContinuity: rng.nextBool(),
            channel: channel
        )
        return ConversationProjectionPropertySample(
            context: context,
            relationship: relationship,
            summary: [
                "fault=pending-beep-dominance",
                "relationship=\(relationship)",
                "base=\(context.baseState.rawValue)",
                "selfJoined=\(selfJoined)",
                "peerJoined=\(peerJoined)",
                "readiness=\(readinessStatus.kind)",
                "conversationStatus=\(conversationStatus.rawValue)",
            ].joined(separator: " ")
        )
    }

    @MainActor
    private static func randomBaseState(rng: inout SeededRNG) -> ConversationState {
        rng.pick([.idle, .outgoingBeep, .incomingBeep, .waitingForPeer, .ready, .transmitting, .receiving])
    }

    @MainActor
    private static func randomPendingAction(rng: inout SeededRNG, contactID: UUID) -> PendingConversationAction {
        switch rng.nextInt(in: 0...6) {
        case 0:
            return .connect(.requestingBackend(contactID: contactID))
        case 1:
            return .connect(.joiningLocal(contactID: contactID))
        case 2:
            return .leave(.explicit(contactID: contactID))
        case 3:
            return .leave(.explicit(contactID: nil))
        case 4:
            return .leave(.reconciledTeardown(contactID: contactID))
        default:
            return .none
        }
    }

    @MainActor
    private static func randomLocalTransmit(rng: inout SeededRNG) -> LocalTransmitProjection {
        switch rng.nextInt(in: 0...8) {
        case 0:
            return .stopping
        case 1:
            return .releaseRequired
        case 2:
            return .starting(.requestingLease)
        case 3:
            return .starting(.awaitingSystemTransmit)
        case 4:
            return .starting(.awaitingAudioSession)
        case 5:
            return .starting(.awaitingAudioConnection(mediaState: rng.pick([.idle, .preparing, .connected, .failed("property")])))
        case 6:
            return .transmitting
        default:
            return .idle
        }
    }

    @MainActor
    private static func randomChannel(rng: inout SeededRNG) -> ChannelReadinessSnapshot? {
        guard rng.nextBool() else { return nil }
        let membership = rng.nextInt(in: 0...3)
        let selfJoined = membership == 1 || membership == 3
        let peerJoined = membership == 2 || membership == 3
        let peerDeviceConnected = peerJoined && rng.nextBool()
        let status = rng.pick([
            TurboChannelReadinessStatus.inactive,
            .waitingForSelf,
            .waitingForPeer,
            .ready,
            .selfTransmitting(activeTransmitterUserId: "self"),
            .peerTransmitting(activeTransmitterUserId: "peer"),
        ])
        let channelState = makeChannelState(
            status: status.conversationState ?? .idle,
            canTransmit: status == .ready && peerDeviceConnected,
            selfJoined: selfJoined,
            peerJoined: peerJoined,
            peerDeviceConnected: peerDeviceConnected,
            hasIncomingBeep: rng.nextBool(),
            hasOutgoingBeep: rng.nextBool()
        )
        return ChannelReadinessSnapshot(
            channelState: channelState,
            readiness: makeChannelReadiness(
                status: status,
                selfHasActiveDevice: selfJoined,
                peerHasActiveDevice: peerDeviceConnected,
                remoteAudioReadiness: rng.pick([.unknown, .waiting, .wakeCapable, .ready]),
                remoteWakeCapability: rng.nextBool()
                    ? .wakeCapable(targetDeviceId: "peer-device")
                    : .unavailable
            )
        )
    }
}

struct ConversationProjectionObserved {
    let summary: String

    @MainActor
    init(projection: SelectedConversationProjection) {
        summary = [
            "durable=\(projection.devicePTTContinuity)",
            "execution=\(String(describing: projection.connectedExecution))",
            "control=\(projection.connectedControlPlane)",
            "phase=\(projection.selectedConversationState.phase)",
            "detail=\(projection.selectedConversationState.detail)",
            "canTransmitNow=\(projection.selectedConversationState.canTransmitNow)",
            "reconcile=\(projection.reconciliationAction)",
        ].joined(separator: " ")
    }
}

@MainActor
struct PTTReadinessAdapterPropertySample {
    enum LocalSessionMode: String {
        case none
        case localOnly
        case systemOnly
        case aligned
        case wrongSystem
        case mismatchedSystem
    }

    @MainActor
    enum BackendMode: Equatable {
        case absent
        case inactive
        case selfOnly
        case peerOnly(peerDeviceConnected: Bool)
        case bothWaitingForPeer(peerDeviceConnected: Bool)
        case bothReady(peerDeviceConnected: Bool, canTransmit: Bool)
        case bothInactiveStale
        case peerTransmitting
        case selfTransmitting

        var summary: String {
            switch self {
            case .absent:
                return "absent"
            case .inactive:
                return "inactive"
            case .selfOnly:
                return "selfOnly"
            case .peerOnly(let peerDeviceConnected):
                return "peerOnly(peerDevice=\(peerDeviceConnected))"
            case .bothWaitingForPeer(let peerDeviceConnected):
                return "bothWaiting(peerDevice=\(peerDeviceConnected))"
            case .bothReady(let peerDeviceConnected, let canTransmit):
                return "bothReady(peerDevice=\(peerDeviceConnected),canTransmit=\(canTransmit))"
            case .bothInactiveStale:
                return "bothInactiveStale"
            case .peerTransmitting:
                return "peerTransmitting"
            case .selfTransmitting:
                return "selfTransmitting"
            }
        }

        func channel(
            remoteAudioReadiness: RemoteAudioReadinessState,
            remoteWakeCapability: RemoteWakeCapabilityState
        ) -> ChannelReadinessSnapshot? {
            guard self != .absent else { return nil }

            let selfJoined: Bool
            let peerJoined: Bool
            let peerDeviceConnected: Bool
            let readinessStatus: TurboChannelReadinessStatus
            let canTransmit: Bool
            let activeTransmitId: String?
            let conversationStatus: ConversationState

            switch self {
            case .absent:
                return nil
            case .inactive:
                selfJoined = false
                peerJoined = false
                peerDeviceConnected = false
                readinessStatus = .inactive
                canTransmit = false
                activeTransmitId = nil
                conversationStatus = .idle
            case .selfOnly:
                selfJoined = true
                peerJoined = false
                peerDeviceConnected = false
                readinessStatus = .waitingForPeer
                canTransmit = false
                activeTransmitId = nil
                conversationStatus = .waitingForPeer
            case .peerOnly(let connected):
                selfJoined = false
                peerJoined = true
                peerDeviceConnected = connected
                readinessStatus = .waitingForSelf
                canTransmit = false
                activeTransmitId = nil
                conversationStatus = .waitingForPeer
            case .bothWaitingForPeer(let connected):
                selfJoined = true
                peerJoined = true
                peerDeviceConnected = connected
                readinessStatus = .waitingForPeer
                canTransmit = false
                activeTransmitId = nil
                conversationStatus = .waitingForPeer
            case .bothReady(let connected, let allowed):
                selfJoined = true
                peerJoined = true
                peerDeviceConnected = connected
                readinessStatus = .ready
                canTransmit = allowed
                activeTransmitId = nil
                conversationStatus = .ready
            case .bothInactiveStale:
                selfJoined = true
                peerJoined = true
                peerDeviceConnected = false
                readinessStatus = .inactive
                canTransmit = false
                activeTransmitId = nil
                conversationStatus = .idle
            case .peerTransmitting:
                selfJoined = true
                peerJoined = true
                peerDeviceConnected = true
                readinessStatus = .peerTransmitting(activeTransmitterUserId: "peer-user")
                canTransmit = false
                activeTransmitId = "tx-peer-active"
                conversationStatus = .receiving
            case .selfTransmitting:
                selfJoined = true
                peerJoined = true
                peerDeviceConnected = true
                readinessStatus = .selfTransmitting(activeTransmitterUserId: "self")
                canTransmit = false
                activeTransmitId = "tx-self-active"
                conversationStatus = .transmitting
            }

            let channelState = makeChannelState(
                status: conversationStatus,
                canTransmit: canTransmit,
                selfJoined: selfJoined,
                peerJoined: peerJoined,
                peerDeviceConnected: peerDeviceConnected,
                activeTransmitId: activeTransmitId
            )
            let readiness = makeChannelReadiness(
                status: readinessStatus,
                selfHasActiveDevice: selfJoined,
                peerHasActiveDevice: peerDeviceConnected,
                remoteAudioReadiness: remoteAudioReadiness,
                remoteWakeCapability: remoteWakeCapability,
                peerTargetDeviceId: peerDeviceConnected ? "peer-device" : nil,
                activeTransmitId: activeTransmitId
            )
            return ChannelReadinessSnapshot(channelState: channelState, readiness: readiness)
        }
    }

    @MainActor
    private enum Action: String, CaseIterable {
        case selectFriend
        case appleNone
        case appleLocalOnly
        case appleAligned
        case appleWrongContact
        case backendAbsent
        case backendInactive
        case backendSelfOnly
        case backendPeerOnly
        case backendWaitingForPeer
        case backendReady
        case backendReadyWithoutTransmit
        case backendBothInactiveStale
        case remoteReady
        case remoteWaiting
        case remoteWakeCapable
        case remoteWakeUnavailable
        case mediaCold
        case mediaReady
        case directPathActive
        case directPathInactive
        case enterReconnectGrace
        case exitReconnectGrace
        case localPressStarts
        case backendLeaseObserved
        case appleBeginObserved
        case localTransmitEnds
        case pendingNone
        case pendingBackendConnect
        case pendingLocalJoin
        case pendingExplicitLeave
        case pendingReconciledTeardown
        case recentLeaveBarrier
        case clearRestoreBarrier
        case remoteStart
        case remoteStop
        case playbackDrainStart
        case playbackDrainEnd

        func apply(to model: inout Model) {
            switch self {
            case .selectFriend:
                model.selected = true
            case .appleNone:
                model.localSessionMode = .none
            case .appleLocalOnly:
                model.localSessionMode = .localOnly
            case .appleAligned:
                model.localSessionMode = .aligned
            case .appleWrongContact:
                model.localSessionMode = .wrongSystem
            case .backendAbsent:
                model.backendMode = .absent
            case .backendInactive:
                model.backendMode = .inactive
            case .backendSelfOnly:
                model.backendMode = .selfOnly
            case .backendPeerOnly:
                model.backendMode = .peerOnly(peerDeviceConnected: model.rngToggle)
            case .backendWaitingForPeer:
                model.backendMode = .bothWaitingForPeer(peerDeviceConnected: false)
            case .backendReady:
                model.backendMode = .bothReady(peerDeviceConnected: true, canTransmit: true)
            case .backendReadyWithoutTransmit:
                model.backendMode = .bothReady(peerDeviceConnected: true, canTransmit: false)
            case .backendBothInactiveStale:
                model.backendMode = .bothInactiveStale
            case .remoteReady:
                model.remoteAudioReadiness = .ready
            case .remoteWaiting:
                model.remoteAudioReadiness = .waiting
            case .remoteWakeCapable:
                model.remoteAudioReadiness = .wakeCapable
                model.remoteWakeCapability = .wakeCapable(targetDeviceId: "peer-device")
            case .remoteWakeUnavailable:
                model.remoteWakeCapability = .unavailable
                if model.remoteAudioReadiness == .wakeCapable {
                    model.remoteAudioReadiness = .waiting
                }
            case .mediaCold:
                model.localMediaWarmupState = .cold
                model.directMediaPathActive = false
            case .mediaReady:
                model.localMediaWarmupState = .ready
                model.localRelayTransportReady = true
                if case .starting(.awaitingAudioConnection(_)) = model.localTransmit {
                    model.localTransmit = .transmitting
                }
            case .directPathActive:
                model.directMediaPathActive = true
            case .directPathInactive:
                model.directMediaPathActive = false
            case .enterReconnectGrace:
                model.backendConvergence = BackendConversationConvergenceState(
                    joinPhase: .stable,
                    controlPlaneContinuity: .reconnectGrace
                )
            case .exitReconnectGrace:
                model.backendConvergence = .stable
            case .localPressStarts:
                model.localTransmit = .starting(.requestingLease)
            case .backendLeaseObserved:
                model.localTransmit = .starting(.awaitingSystemTransmit)
            case .appleBeginObserved:
                model.localTransmit = .starting(.awaitingAudioSession)
            case .localTransmitEnds:
                model.localTransmit = .stopping
            case .pendingNone:
                model.pendingAction = .none
            case .pendingBackendConnect:
                model.pendingAction = .connect(.requestingBackend(contactID: model.contactID))
            case .pendingLocalJoin:
                model.pendingAction = .connect(.joiningLocal(contactID: model.contactID))
            case .pendingExplicitLeave:
                model.pendingAction = .leave(.explicit(contactID: model.contactID))
            case .pendingReconciledTeardown:
                model.pendingAction = .leave(.reconciledTeardown(contactID: model.contactID))
            case .recentLeaveBarrier:
                model.devicePTTRestoreBarrier = .recentSystemLeave(
                    contactID: model.contactID,
                    channelUUID: model.channelUUID,
                    reason: "property-fuzz"
                )
            case .clearRestoreBarrier:
                model.devicePTTRestoreBarrier = .none
            case .remoteStart:
                model.backendMode = .peerTransmitting
                model.remoteParticipantSignalIsTransmitting = true
                model.remotePlaybackContinuity = .idle
            case .remoteStop:
                model.remoteParticipantSignalIsTransmitting = true
                model.remotePlaybackContinuity = .stopped(projectionGraceActive: true)
            case .playbackDrainStart:
                model.remotePlaybackContinuity = .drainingAfterStop(projectionGraceActive: true)
            case .playbackDrainEnd:
                model.remotePlaybackContinuity = .stopped(projectionGraceActive: false)
            }
        }
    }

    @MainActor
    private struct Model {
        let contactID: UUID
        let channelUUID: UUID
        let otherContactID: UUID
        var selected: Bool
        var localSessionMode: LocalSessionMode
        var backendMode: BackendMode
        var remoteAudioReadiness: RemoteAudioReadinessState
        var remoteWakeCapability: RemoteWakeCapabilityState
        var remoteParticipantSignalIsTransmitting: Bool
        var remotePlaybackContinuity: RemotePlaybackContinuityState
        var localTransmit: LocalTransmitProjection
        var localMediaWarmupState: LocalMediaWarmupState
        var localRelayTransportReady: Bool
        var directMediaPathActive: Bool
        var backendConvergence: BackendConversationConvergenceState
        var pendingAction: PendingConversationAction
        var devicePTTRestoreBarrier: DevicePTTRestoreBarrier
        var hadConnectedDevicePTTContinuity: Bool
        var firstTalkStartupProfile: FirstTalkStartupProfile
        var rngToggle = false

        var selectedContactID: UUID? {
            selected ? contactID : nil
        }

        var localSession: DevicePTTLocalSession {
            switch localSessionMode {
            case .none, .systemOnly, .mismatchedSystem:
                return .absent
            case .localOnly, .aligned:
                return DevicePTTLocalSession(
                    selectedContactID: contactID,
                    isJoined: true,
                    activeChannelID: contactID
                )
            case .wrongSystem:
                return DevicePTTLocalSession(
                    selectedContactID: contactID,
                    isJoined: true,
                    activeChannelID: otherContactID
                )
            }
        }

        var systemSessionState: SystemPTTSessionState {
            switch localSessionMode {
            case .none, .localOnly:
                return .none
            case .systemOnly, .aligned:
                return .active(contactID: contactID, channelUUID: channelUUID)
            case .wrongSystem:
                return .active(contactID: otherContactID, channelUUID: channelUUID)
            case .mismatchedSystem:
                return .mismatched(channelUUID: channelUUID)
            }
        }

        var systemSessionMatchesContact: Bool {
            switch systemSessionState {
            case .active(let activeContactID, _) where activeContactID == contactID:
                return true
            case .none, .active, .mismatched:
                return false
            }
        }

        var diagnosticsIsJoined: Bool {
            localSessionMode == .aligned
        }

        var systemActiveContactID: UUID? {
            if case .active(let contactID, _) = systemSessionState {
                return contactID
            }
            return nil
        }

        var systemChannelUUID: UUID? {
            if case .active(_, let channelUUID) = systemSessionState {
                return channelUUID
            }
            return nil
        }
    }

    private static let relevantContractIDs: Set<String> = [
        "selected.hold_to_talk_requires_transmit_capability",
        "selected.wake_ready_requires_aligned_apple_session",
        "selected.control_plane_reconnect_grace_disables_hold_to_talk",
        "selected.receiving_after_remote_transmit_stop",
        "engine.transmit_capture_requires_backend_lease_and_system_begin",
        "engine.no_playback_after_transmit_stop",
        "transmit.live_projection_after_lease_expiry",
    ]

    private static let staleBackendContractIDs: Set<String> = [
        "selected.backend_absent_with_local_device_ptt_evidence",
        "selected.backend_absent_pending_local_action_without_device_ptt_evidence",
        "selected.backend_idle_without_local_evidence_still_connecting",
        "selected.backend_inactive_ui_still_joined",
        "selected.backend_membership_absent_ui_still_joined",
        "selected.backend_ready_missing_local_device_ptt_evidence",
        "selected.backend_ready_stale_backend_connect",
        "selected.live_projection_after_membership_exit",
        "selected.ready_while_backend_cannot_transmit",
        "selected.stale_backend_membership_without_local_device_ptt_evidence",
        "selected.stale_membership_friend_ready_without_local_device_ptt_evidence",
    ]

    let actions: [String]
    let context: ConversationDerivationContext
    let selectedConversationState: SelectedConversationState
    let devicePTTProjection: DevicePTTDiagnosticsProjection
    let controlPlaneReconnectGraceActive: Bool
    let pendingLeaveInFlight: Bool
    let restoreBarrierActive: Bool
    let backendMembershipStaleWithoutLocalEvidence: Bool
    let reconciliationAction: SelectedConversationReconciliationAction
    let remoteTransmitStopObserved: Bool
    let remoteTransmitStopProjectionGraceActive: Bool
    let summary: String

    var relevantInvariantIDs: [String] {
        devicePTTProjection.derivedInvariantCandidates
            .map(\.invariantID)
            .filter(Self.relevantContractIDs.contains)
            .sorted()
    }

    var staleBackendInvariantIDs: [String] {
        devicePTTProjection.derivedInvariantCandidates
            .map(\.invariantID)
            .filter(Self.staleBackendContractIDs.contains)
            .sorted()
    }

    func observedSummary(violations: [String]) -> String {
        [
            "phase=\(selectedConversationState.phase)",
            "detail=\(selectedConversationState.detail)",
            "canTransmit=\(selectedConversationState.canTransmitNow)",
            "allowsHold=\(selectedConversationState.allowsHoldToTalk)",
            "violations=\(violations)",
            "system=\(devicePTTProjection.systemSession)",
            "backendReadiness=\(devicePTTProjection.backendReadiness ?? "none")",
            "remoteAudio=\(devicePTTProjection.remoteAudioReadiness ?? "none")",
            "remoteWake=\(devicePTTProjection.remoteWakeCapabilityKind ?? "none")",
            "pendingLeave=\(pendingLeaveInFlight)",
            "restoreBarrier=\(restoreBarrierActive)",
            "reconciliation=\(reconciliationAction)",
            "remoteStop=\(remoteTransmitStopObserved)",
            "stopGrace=\(remoteTransmitStopProjectionGraceActive)",
        ].joined(separator: " ")
    }

    static func generate(rng: inout SeededRNG) -> PTTReadinessAdapterPropertySample {
        let contactID = rng.uuid()
        let channelUUID = rng.uuid()
        var model = Model(
            contactID: contactID,
            channelUUID: channelUUID,
            otherContactID: rng.uuid(),
            selected: true,
            localSessionMode: rng.pick(LocalSessionMode.allCasesForFuzz),
            backendMode: randomBackendMode(rng: &rng),
            remoteAudioReadiness: rng.pick([.unknown, .waiting, .wakeCapable, .ready]),
            remoteWakeCapability: rng.nextBool()
                ? .wakeCapable(targetDeviceId: "peer-device")
                : .unavailable,
            remoteParticipantSignalIsTransmitting: rng.nextBool(),
            remotePlaybackContinuity: randomRemotePlaybackContinuity(rng: &rng),
            localTransmit: randomLocalTransmit(rng: &rng),
            localMediaWarmupState: rng.pick([.cold, .prewarming, .ready, .failed]),
            localRelayTransportReady: rng.nextBool(),
            directMediaPathActive: rng.nextBool(),
            backendConvergence: randomBackendConvergence(rng: &rng),
            pendingAction: randomPendingAction(rng: &rng, contactID: contactID),
            devicePTTRestoreBarrier: rng.nextBool()
                ? .recentSystemLeave(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: "property-fuzz"
                )
                : .none,
            hadConnectedDevicePTTContinuity: rng.nextBool(),
            firstTalkStartupProfile: rng.pick([.directQuicWarm, .directQuicWarming, .relayWarm, .relayWarming])
        )
        var actions: [String] = []
        for _ in 0..<rng.nextInt(in: 1...24) {
            let action = rng.pick(Action.allCases)
            model.rngToggle = rng.nextBool()
            action.apply(to: &model)
            actions.append(action.rawValue)
        }
        return make(actions: actions, model: model)
    }

    static func make(
        actions: [String],
        contactID: UUID = UUID(),
        channelUUID: UUID = UUID(),
        localSessionMode: LocalSessionMode,
        backendMode: BackendMode,
        remoteAudioReadiness: RemoteAudioReadinessState,
        remoteWakeCapability: RemoteWakeCapabilityState,
        remoteParticipantSignalIsTransmitting: Bool = false,
        remotePlaybackContinuity: RemotePlaybackContinuityState = .idle,
        localTransmit: LocalTransmitProjection = .idle,
        pendingAction: PendingConversationAction = .none,
        devicePTTRestoreBarrier: DevicePTTRestoreBarrier = .none,
        localMediaWarmupState: LocalMediaWarmupState,
        localRelayTransportReady: Bool,
        directMediaPathActive: Bool = false,
        backendConvergence: BackendConversationConvergenceState? = nil,
        hadConnectedDevicePTTContinuity: Bool = false,
        firstTalkStartupProfile: FirstTalkStartupProfile
    ) -> PTTReadinessAdapterPropertySample {
        let model = Model(
            contactID: contactID,
            channelUUID: channelUUID,
            otherContactID: UUID(),
            selected: true,
            localSessionMode: localSessionMode,
            backendMode: backendMode,
            remoteAudioReadiness: remoteAudioReadiness,
            remoteWakeCapability: remoteWakeCapability,
            remoteParticipantSignalIsTransmitting: remoteParticipantSignalIsTransmitting,
            remotePlaybackContinuity: remotePlaybackContinuity,
            localTransmit: localTransmit,
            localMediaWarmupState: localMediaWarmupState,
            localRelayTransportReady: localRelayTransportReady,
            directMediaPathActive: directMediaPathActive,
            backendConvergence: backendConvergence ?? .stable,
            pendingAction: pendingAction,
            devicePTTRestoreBarrier: devicePTTRestoreBarrier,
            hadConnectedDevicePTTContinuity: hadConnectedDevicePTTContinuity,
            firstTalkStartupProfile: firstTalkStartupProfile
        )
        return make(actions: actions, model: model)
    }

    static func generateStaleBackendFault(rng: inout SeededRNG) -> PTTReadinessAdapterPropertySample {
        let contactID = rng.uuid()
        let channelUUID = rng.uuid()
        let fault = rng.nextInt(in: 0...4)
        switch fault {
        case 0:
            return make(
                actions: ["pendingExplicitLeave", "staleBackendReady"],
                contactID: contactID,
                channelUUID: channelUUID,
                localSessionMode: .aligned,
                backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
                remoteAudioReadiness: .ready,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                pendingAction: .leave(.explicit(contactID: contactID)),
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                firstTalkStartupProfile: .relayWarm
            )
        case 1:
            return make(
                actions: ["recentLeaveBarrier", "staleBackendReady"],
                contactID: contactID,
                channelUUID: channelUUID,
                localSessionMode: .none,
                backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
                remoteAudioReadiness: .ready,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device"),
                devicePTTRestoreBarrier: .recentSystemLeave(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: "property-fuzz"
                ),
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                firstTalkStartupProfile: .relayWarm
            )
        case 2:
            return make(
                actions: ["backendBothInactiveStale"],
                contactID: contactID,
                channelUUID: channelUUID,
                localSessionMode: .none,
                backendMode: .bothInactiveStale,
                remoteAudioReadiness: rng.pick([.ready, .wakeCapable]),
                remoteWakeCapability: rng.nextBool()
                    ? .wakeCapable(targetDeviceId: "peer-device")
                    : .unavailable,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                firstTalkStartupProfile: .relayWarm
            )
        case 3:
            return make(
                actions: ["pendingBackendConnect", "backendReady"],
                contactID: contactID,
                channelUUID: channelUUID,
                localSessionMode: .none,
                backendMode: .bothReady(peerDeviceConnected: true, canTransmit: true),
                remoteAudioReadiness: .ready,
                remoteWakeCapability: .unavailable,
                pendingAction: .connect(.requestingBackend(contactID: contactID)),
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                firstTalkStartupProfile: .relayWarm
            )
        default:
            return make(
                actions: ["backendReadyMissingPeerDevice"],
                contactID: contactID,
                channelUUID: channelUUID,
                localSessionMode: .aligned,
                backendMode: .bothReady(peerDeviceConnected: false, canTransmit: true),
                remoteAudioReadiness: .unknown,
                remoteWakeCapability: .unavailable,
                localMediaWarmupState: .ready,
                localRelayTransportReady: true,
                firstTalkStartupProfile: .relayWarm
            )
        }
    }

    private static func make(
        actions: [String],
        model: Model
    ) -> PTTReadinessAdapterPropertySample {
        let channel = model.backendMode.channel(
            remoteAudioReadiness: model.remoteAudioReadiness,
            remoteWakeCapability: model.remoteWakeCapability
        )
        let context = ConversationDerivationContext(
            contactID: model.contactID,
            selectedContactID: model.selectedContactID,
            baseState: .waitingForPeer,
            relationship: .none,
            contactName: "Blake",
            contactIsOnline: true,
            localSession: model.localSession,
            isJoined: model.localSession.isJoined,
            localTransmit: model.localTransmit,
            remoteParticipantSignalIsTransmitting: model.remoteParticipantSignalIsTransmitting,
            remotePlaybackContinuity: model.remotePlaybackContinuity,
            activeChannelID: model.localSession.activeChannelID,
            systemSessionMatchesContact: model.systemSessionMatchesContact,
            systemSessionState: model.systemSessionState,
            pendingAction: model.pendingAction,
            localJoinFailure: nil,
            mediaState: model.localMediaWarmupState == .ready ? .connected : .preparing,
            localMediaWarmupState: model.localMediaWarmupState,
            localRelayTransportReady: model.localRelayTransportReady,
            directMediaPathActive: model.directMediaPathActive,
            firstTalkStartupProfile: model.firstTalkStartupProfile,
            backendConvergence: model.backendConvergence,
            devicePTTRestoreBarrier: model.devicePTTRestoreBarrier,
            hadConnectedDevicePTTContinuity: model.hadConnectedDevicePTTContinuity,
            channel: channel
        )
        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: .none
        )
        let selectedConversationState = projection.selectedConversationState
        let devicePTTProjection = DevicePTTDiagnosticsProjection(
            selectedContactID: model.selectedContactID?.uuidString,
            selectedHandle: "@blake",
            selectedConversationPhase: String(describing: selectedConversationState.phase),
            selectedConversationPhaseDetail: String(describing: selectedConversationState.detail),
            selectedConversationRelationship: String(describing: selectedConversationState.relationship),
            selectedConversationCanTransmit: selectedConversationState.canTransmitNow,
            selectedConversationAllowsHoldToTalk: selectedConversationState.allowsHoldToTalk,
            selectedConversationAutoJoinArmed: false,
            isJoined: model.diagnosticsIsJoined,
            isTransmitting: selectedConversationState.phase == .transmitting,
            activeChannelID: model.diagnosticsIsJoined ? model.contactID.uuidString : nil,
            systemSession: String(describing: model.systemSessionState),
            systemActiveContactID: model.systemActiveContactID?.uuidString,
            systemChannelUUID: model.systemChannelUUID?.uuidString,
            mediaState: String(describing: context.mediaState),
            transmitPhase: transmitPhaseDiagnosticsValue(model.localTransmit),
            transmitActiveContactID: model.localTransmit.hasTransmitIntent ? model.contactID.uuidString : nil,
            transmitPressActive: model.localTransmit.hasTransmitIntent,
            transmitExplicitStopRequested: model.localTransmit == .stopping,
            transmitSystemTransmitting: transmitSystemTransmitting(model.localTransmit),
            incomingWakeActivationState: nil,
            incomingWakeBufferedChunkCount: 0,
            remoteReceiveActive: model.remoteParticipantSignalIsTransmitting && !model.remotePlaybackContinuity.stopObserved,
            remoteTransmitStopObserved: model.remotePlaybackContinuity.stopObserved,
            remoteTransmitStopProjectionGraceActive: model.remotePlaybackContinuity.stopProjectionGraceActive,
            remoteReceiveActivityState: model.remoteParticipantSignalIsTransmitting ? "stale-remote-participant-signal" : nil,
            receiverAudioReadinessState: nil,
            pendingAction: String(describing: model.pendingAction),
            pendingConnectAcceptedIncomingBeep: false,
            localJoinAttempt: nil,
            localJoinAttemptIssuedCount: 0,
            reconciliationAction: String(describing: projection.reconciliationAction),
            hadConnectedDevicePTTContinuity: model.hadConnectedDevicePTTContinuity,
            controlPlaneReconnectGraceActive: model.backendConvergence.controlPlaneReconnectGraceActive,
            backendSignalingJoinRecoveryActive: model.backendConvergence.backendSignalingJoinRecoveryActive,
            backendJoinSettling: model.backendConvergence.backendJoinSettling,
            backendChannelStatus: channel?.status?.rawValue,
            backendReadiness: channel?.readinessStatus?.kind,
            backendSelfJoined: channel?.membership.hasLocalMembership,
            backendPeerJoined: channel?.membership.hasPeerMembership,
            backendPeerDeviceConnected: channel?.membership.peerDeviceConnected,
            backendActiveTransmitterUserId: channel?.activeTransmitterUserId,
            backendActiveTransmitId: channel?.activeTransmitId,
            backendActiveTransmitExpiresAt: nil,
            backendServerTimestamp: nil,
            backendCanTransmit: channel?.canTransmit,
            remoteAudioReadiness: channel.map { String(describing: $0.remoteAudioReadiness) },
            remoteWakeCapabilityKind: channel.map { remoteWakeCapabilityKind($0.remoteWakeCapability) }
        )
        let summary = [
            "actions=\(actions.joined(separator: ","))",
            "localSession=\(model.localSessionMode.rawValue)",
            "backend=\(model.backendMode.summary)",
            "remoteAudio=\(model.remoteAudioReadiness)",
            "remoteWake=\(remoteWakeCapabilityKind(model.remoteWakeCapability))",
            "localTransmit=\(model.localTransmit)",
            "mediaWarmup=\(model.localMediaWarmupState)",
            "relayReady=\(model.localRelayTransportReady)",
            "direct=\(model.directMediaPathActive)",
            "pending=\(model.pendingAction)",
            "restoreBarrier=\(model.devicePTTRestoreBarrier)",
            "remoteParticipantSignal=\(model.remoteParticipantSignalIsTransmitting)",
            "remotePlayback=\(model.remotePlaybackContinuity)",
            "reconnectGrace=\(model.backendConvergence.controlPlaneReconnectGraceActive)",
            "continuity=\(model.hadConnectedDevicePTTContinuity)",
        ].joined(separator: " ")

        return PTTReadinessAdapterPropertySample(
            actions: actions,
            context: context,
            selectedConversationState: selectedConversationState,
            devicePTTProjection: devicePTTProjection,
            controlPlaneReconnectGraceActive: model.backendConvergence.controlPlaneReconnectGraceActive,
            pendingLeaveInFlight: model.pendingAction.isLeaveInFlight(for: model.contactID),
            restoreBarrierActive: model.devicePTTRestoreBarrier.blocksAutomaticRestore,
            backendMembershipStaleWithoutLocalEvidence: context.backendMembershipIsStaleWithoutDevicePTTEvidence,
            reconciliationAction: projection.reconciliationAction,
            remoteTransmitStopObserved: model.remotePlaybackContinuity.stopObserved,
            remoteTransmitStopProjectionGraceActive: model.remotePlaybackContinuity.stopProjectionGraceActive,
            summary: summary
        )
    }

    private static func randomBackendMode(rng: inout SeededRNG) -> BackendMode {
        switch rng.nextInt(in: 0...8) {
        case 0:
            return .absent
        case 1:
            return .inactive
        case 2:
            return .selfOnly
        case 3:
            return .peerOnly(peerDeviceConnected: rng.nextBool())
        case 4:
            return .bothWaitingForPeer(peerDeviceConnected: rng.nextBool())
        case 5:
            return .bothReady(peerDeviceConnected: rng.nextBool(), canTransmit: rng.nextBool())
        case 6:
            return .peerTransmitting
        case 7:
            return .selfTransmitting
        default:
            return .bothInactiveStale
        }
    }

    private static func randomPendingAction(
        rng: inout SeededRNG,
        contactID: UUID
    ) -> PendingConversationAction {
        switch rng.nextInt(in: 0...7) {
        case 0:
            return .connect(.requestingBackend(contactID: contactID))
        case 1:
            return .connect(.joiningLocal(contactID: contactID))
        case 2:
            return .leave(.explicit(contactID: contactID))
        case 3:
            return .leave(.explicit(contactID: nil))
        case 4:
            return .leave(.reconciledTeardown(contactID: contactID))
        default:
            return .none
        }
    }

    private static func randomRemotePlaybackContinuity(
        rng: inout SeededRNG
    ) -> RemotePlaybackContinuityState {
        switch rng.nextInt(in: 0...3) {
        case 0:
            return .idle
        case 1:
            return .drainingBeforeStop
        case 2:
            return .drainingAfterStop(projectionGraceActive: rng.nextBool())
        default:
            return .stopped(projectionGraceActive: rng.nextBool())
        }
    }

    private static func randomLocalTransmit(rng: inout SeededRNG) -> LocalTransmitProjection {
        switch rng.nextInt(in: 0...6) {
        case 0:
            return .idle
        case 1:
            return .stopping
        case 2:
            return .releaseRequired
        case 3:
            return .starting(.requestingLease)
        case 4:
            return .starting(.awaitingSystemTransmit)
        case 5:
            return .starting(.awaitingAudioSession)
        default:
            return .transmitting
        }
    }

    private static func randomBackendConvergence(
        rng: inout SeededRNG
    ) -> BackendConversationConvergenceState {
        switch rng.nextInt(in: 0...4) {
        case 0:
            return BackendConversationConvergenceState(joinPhase: .settling, controlPlaneContinuity: .normal)
        case 1:
            return BackendConversationConvergenceState(joinPhase: .signalingRecovery, controlPlaneContinuity: .normal)
        case 2:
            return BackendConversationConvergenceState(joinPhase: .stable, controlPlaneContinuity: .reconnectGrace)
        default:
            return .stable
        }
    }

    private static func remoteWakeCapabilityKind(_ value: RemoteWakeCapabilityState) -> String {
        switch value {
        case .unavailable:
            return "unavailable"
        case .wakeCapable:
            return "wake-capable"
        }
    }

    private static func transmitPhaseDiagnosticsValue(_ value: LocalTransmitProjection) -> String {
        switch value {
        case .idle, .releaseRequired:
            return "idle"
        case .stopping:
            return "stopping"
        case .starting(.requestingLease):
            return "requesting"
        case .starting(.awaitingSystemTransmit), .starting(.awaitingAudioSession),
             .starting(.awaitingAudioConnection(_)), .transmitting:
            return "active"
        }
    }

    private static func transmitSystemTransmitting(_ value: LocalTransmitProjection) -> Bool {
        switch value {
        case .starting(.awaitingAudioSession), .starting(.awaitingAudioConnection), .transmitting:
            return true
        case .idle, .stopping, .releaseRequired, .starting:
            return false
        }
    }
}

extension PTTReadinessAdapterPropertySample.LocalSessionMode {
    static let allCasesForFuzz: [PTTReadinessAdapterPropertySample.LocalSessionMode] = [
        .none,
        .localOnly,
        .systemOnly,
        .aligned,
        .wrongSystem,
        .mismatchedSystem,
    ]
}

enum SimulatorScenarioActionPropertySample {
    static let signalKinds: [TurboSignalKind] = [
        .transmitStart,
        .transmitStop,
        .receiverReady,
        .receiverNotReady,
        .directQuicUpgradeRequest,
        .selectedFriendPrewarm,
    ]

    static func generateActions(rng: inout SeededRNG) -> [SimulatorScenarioAction] {
        (0..<rng.nextInt(in: 1...12)).map { _ in
            let type = rng.pick([
                "openFriend",
                "connect",
                "refreshContactSummaries",
                "refreshBeeps",
                "refreshChannelState",
                "refreshChannelStateAsync",
                "captureDiagnostics",
                "injectStaleTransmitStopCompletion",
                "setHTTPDelay",
                "setWebSocketSignalDelay",
                "dropNextWebSocketSignals",
                "duplicateNextWebSocketSignals",
                "reorderNextWebSocketSignals",
                "wait",
            ])
            let count: Int? = {
                if type == "reorderNextWebSocketSignals" {
                    return rng.nextInt(in: 2...4)
                }
                if type.contains("WebSocket") || type == "setHTTPDelay" {
                    return rng.nextInt(in: 1...3)
                }
                return nil
            }()
            let milliseconds: Int? = {
                if type == "setHTTPDelay" || type == "setWebSocketSignalDelay" || type == "wait" {
                    return rng.nextInt(in: 0...1_000)
                }
                return nil
            }()
            return SimulatorScenarioAction(
                actor: rng.pick(["a", "b"]),
                type: type,
                friend: type == "openFriend" ? rng.pick(["a", "b"]) : nil,
                route: type == "setHTTPDelay" ? rng.pick(TransportFaultHTTPRoute.allCases).rawValue : nil,
                signalKind: type.contains("WebSocket") ? rng.pick(signalKinds).rawValue : nil,
                milliseconds: milliseconds,
                count: count,
                delayMilliseconds: rng.nextBool() ? rng.nextInt(in: 0...1_000) : nil,
                repeatCount: rng.nextBool() ? rng.nextInt(in: 1...3) : nil,
                repeatIntervalMilliseconds: rng.nextBool() ? rng.nextInt(in: 0...250) : nil,
                reorderIndex: rng.nextBool() ? rng.nextInt(in: 0...12) : nil,
                drop: rng.nextInt(in: 0...7) == 0
            )
        }
    }

    static func summary(_ actions: [SimulatorScenarioAction]) -> String {
        actions.enumerated().map { index, action in
            "\(index):\(action.actor):\(action.type):delay=\(action.delayMilliseconds ?? 0):repeat=\(action.repeatCount ?? 1):drop=\(action.drop ?? false)"
        }.joined(separator: " ")
    }
}
