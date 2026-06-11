import Foundation

enum ReceiverAudioReadinessReason: Equatable, Codable, CustomStringConvertible {
    case appBackgroundMediaClosed
    case audioRouteChange
    case audioRoutePreference(String)
    case backendReconnect
    case backendSignalingRecovery
    case channelRefresh
    case directQuicReceiverPrewarm
    case directQuicTransmitPrepare
    case foregroundTalkPrewarm(String)
    case incomingPushForeground
    case mediaState(MediaConnectionState)
    case networkChange
    case pttSync
    case pttWakePostActivationRefresh
    case receiverPrewarmRequest
    case remoteAudioEndedKeepalive
    case telemetryRefresh
    case websocketConnected
    case legacy(String)

    init(wireValue: String) {
        switch wireValue {
        case "app-background-media-closed":
            self = .appBackgroundMediaClosed
        case "audio-route-change":
            self = .audioRouteChange
        case "backend-reconnect":
            self = .backendReconnect
        case "backend-signaling-recovery":
            self = .backendSignalingRecovery
        case "channel-refresh":
            self = .channelRefresh
        case "direct-quic-receiver-prewarm":
            self = .directQuicReceiverPrewarm
        case "direct-quic-transmit-prepare":
            self = .directQuicTransmitPrepare
        case "incoming-push-foreground":
            self = .incomingPushForeground
        case "media-idle":
            self = .mediaState(.idle)
        case "media-preparing":
            self = .mediaState(.preparing)
        case "media-connected":
            self = .mediaState(.connected)
        case "media-closed":
            self = .mediaState(.closed)
        case "network-change":
            self = .networkChange
        case "ptt-sync":
            self = .pttSync
        case "ptt-wake:post-activation-refresh":
            self = .pttWakePostActivationRefresh
        case "receiver-prewarm-request":
            self = .receiverPrewarmRequest
        case "remote-audio-ended-keepalive":
            self = .remoteAudioEndedKeepalive
        case "telemetry-refresh":
            self = .telemetryRefresh
        case "websocket-connected":
            self = .websocketConnected
        default:
            if wireValue.hasPrefix("audio-route-preference:") {
                self = .audioRoutePreference(
                    String(wireValue.dropFirst("audio-route-preference:".count))
                )
            } else if wireValue.hasPrefix("foreground-talk-prewarm-") {
                self = .foregroundTalkPrewarm(
                    String(wireValue.dropFirst("foreground-talk-prewarm-".count))
                )
            } else {
                self = .legacy(wireValue)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ReceiverAudioReadinessReason(wireValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    var description: String { wireValue }

    var wireValue: String {
        switch self {
        case .appBackgroundMediaClosed:
            return "app-background-media-closed"
        case .audioRouteChange:
            return "audio-route-change"
        case .audioRoutePreference(let reason):
            return "audio-route-preference:\(reason)"
        case .backendReconnect:
            return "backend-reconnect"
        case .backendSignalingRecovery:
            return "backend-signaling-recovery"
        case .channelRefresh:
            return "channel-refresh"
        case .directQuicReceiverPrewarm:
            return "direct-quic-receiver-prewarm"
        case .directQuicTransmitPrepare:
            return "direct-quic-transmit-prepare"
        case .foregroundTalkPrewarm(let reason):
            return "foreground-talk-prewarm-\(reason)"
        case .incomingPushForeground:
            return "incoming-push-foreground"
        case .mediaState(let state):
            switch state {
            case .idle:
                return "media-idle"
            case .preparing:
                return "media-preparing"
            case .connected:
                return "media-connected"
            case .failed(let message):
                return "media-failed(\(message))"
            case .closed:
                return "media-closed"
            }
        case .networkChange:
            return "network-change"
        case .pttSync:
            return "ptt-sync"
        case .pttWakePostActivationRefresh:
            return "ptt-wake:post-activation-refresh"
        case .receiverPrewarmRequest:
            return "receiver-prewarm-request"
        case .remoteAudioEndedKeepalive:
            return "remote-audio-ended-keepalive"
        case .telemetryRefresh:
            return "telemetry-refresh"
        case .websocketConnected:
            return "websocket-connected"
        case .legacy(let reason):
            return reason
        }
    }

    var isBackgroundMediaClosure: Bool {
        self == .appBackgroundMediaClosed
    }

    var recoveryPublicationBasis: ReceiverAudioReadinessPublicationBasis? {
        switch self {
        case .backendReconnect, .websocketConnected:
            return .webSocketReconnect
        case .backendSignalingRecovery,
             .channelRefresh,
             .incomingPushForeground,
             .pttWakePostActivationRefresh,
             .receiverPrewarmRequest:
            return .channelRefresh
        default:
            return nil
        }
    }

    var readyPublicationBlocker: String? {
        guard case .mediaState(let state) = self else { return nil }
        switch state {
        case .connected:
            return nil
        case .idle, .preparing, .failed(_), .closed:
            return wireValue
        }
    }
}

struct ReceiverAudioReadinessIntent: Equatable {
    let contactID: UUID
    let contactHandle: String
    let backendChannelID: String
    let remoteUserID: String
    let currentUserID: String
    let deviceID: String
    let isReady: Bool
    let reason: ReceiverAudioReadinessReason
    let telemetry: ConversationParticipantTelemetry?

    var publicationBasis: ReceiverAudioReadinessPublicationBasis {
        if let recoveryBasis = reason.recoveryPublicationBasis {
            switch recoveryBasis {
            case .channelRefresh:
                return .channelRefresh
            case .webSocketReconnect:
                return .webSocketReconnect
            case .lifecycle:
                return .lifecycle
            }
        } else {
            return .lifecycle
        }
    }

    var publishedState: ReceiverAudioReadinessPublication {
        ReceiverAudioReadinessPublication(
            isReady: isReady,
            peerWasRoutable: true,
            basis: publicationBasis,
            telemetry: telemetry
        )
    }

    var suppressedState: ReceiverAudioReadinessPublication {
        ReceiverAudioReadinessPublication(
            isReady: isReady,
            peerWasRoutable: false,
            basis: publicationBasis,
            telemetry: telemetry
        )
    }

    var readyPublicationBlocker: String? {
        guard isReady else { return nil }
        return reason.readyPublicationBlocker
    }

    var hasStableReadyPublicationEvidence: Bool {
        readyPublicationBlocker == nil
    }
}

enum ReceiverAudioReadinessControlState: Equatable {
    case suppressed(ReceiverAudioReadinessPublication)
    case deferred(ReceiverAudioReadinessIntent)
    case published(ReceiverAudioReadinessPublication)

    var cachedPublication: ReceiverAudioReadinessPublication? {
        switch self {
        case .suppressed(let publication), .published(let publication):
            return publication
        case .deferred:
            return nil
        }
    }

    var deferredIntent: ReceiverAudioReadinessIntent? {
        guard case .deferred(let intent) = self else { return nil }
        return intent
    }
}

struct ControlPlaneSessionState: Equatable {
    var receiverAudioReadinessStates: [UUID: ReceiverAudioReadinessControlState] = [:]
    var postWakeRepairContactIDs: Set<UUID> = []

    var localReceiverAudioReadinessPublications: [UUID: ReceiverAudioReadinessPublication] {
        receiverAudioReadinessStates.reduce(into: [:]) { result, entry in
            guard let publication = entry.value.cachedPublication else { return }
            result[entry.key] = publication
        }
    }

    mutating func replaceLocalReceiverAudioReadinessPublications(
        _ publications: [UUID: ReceiverAudioReadinessPublication]
    ) {
        receiverAudioReadinessStates = publications.reduce(into: [:]) { result, entry in
            if entry.value.peerWasRoutable {
                result[entry.key] = .published(entry.value)
            } else {
                result[entry.key] = .suppressed(entry.value)
            }
        }
    }

    mutating func clearCachedReceiverAudioReadinessPublicationsPreservingDeferred() {
        receiverAudioReadinessStates = receiverAudioReadinessStates.compactMapValues { state in
            switch state {
            case .deferred:
                return state
            case .suppressed, .published:
                return nil
            }
        }
    }

    mutating func clearCachedReceiverReadyPublicationsPreservingDeferredAndNotReady() {
        receiverAudioReadinessStates = receiverAudioReadinessStates.compactMapValues { state in
            switch state {
            case .deferred:
                return state
            case .published(let publication) where !publication.isReady:
                return state
            case .suppressed(let publication) where !publication.isReady:
                return state
            case .published, .suppressed:
                return nil
            }
        }
    }

    mutating func clearCachedReceiverReadyPublicationPreservingDeferredAndNotReady(
        contactID: UUID
    ) {
        switch receiverAudioReadinessStates[contactID] {
        case .published(let publication) where !publication.isReady:
            return
        case .suppressed(let publication) where !publication.isReady:
            return
        case .deferred:
            return
        case .published, .suppressed, nil:
            receiverAudioReadinessStates[contactID] = nil
        }
    }
}

enum ControlPlaneEvent: Equatable {
    case reset
    case receiverAudioReadinessSyncRequested(
        ReceiverAudioReadinessIntent,
        peerIsRoutable: Bool,
        webSocketConnected: Bool
    )
    case receiverAudioReadinessPublished(ReceiverAudioReadinessIntent)
    case receiverAudioReadinessDeferred(ReceiverAudioReadinessIntent)
    case receiverAudioReadinessContextUnavailable(contactID: UUID)
    case receiverAudioReadinessEpochAdvanced(contactID: UUID)
    case receiverAudioReadinessCacheCleared(contactID: UUID?)
    case webSocketStateChanged(TurboBackendClient.WebSocketConnectionState)
    case postWakeRepairRequested(contactID: UUID)
    case postWakeRepairFinished(contactID: UUID)
}

enum ControlPlaneEffect: Equatable {
    case deferReceiverAudioReadinessUntilReconnect(ReceiverAudioReadinessIntent)
    case publishReceiverAudioReadiness(ReceiverAudioReadinessIntent)
    case performPostWakeRepair(contactID: UUID)
}

struct ControlPlaneTransition: Equatable {
    var state: ControlPlaneSessionState
    var effects: [ControlPlaneEffect] = []
}

enum ControlPlaneReducer {
    static func reduce(
        state: ControlPlaneSessionState,
        event: ControlPlaneEvent
    ) -> ControlPlaneTransition {
        var nextState = state
        var effects: [ControlPlaneEffect] = []

        switch event {
        case .reset:
            nextState = ControlPlaneSessionState()

        case .receiverAudioReadinessSyncRequested(let intent, let peerIsRoutable, _):
            guard intent.hasStableReadyPublicationEvidence else {
                break
            }

            if !peerIsRoutable {
                if case .published(let publication)? = nextState.receiverAudioReadinessStates[intent.contactID],
                   publication.isReady == intent.isReady {
                    break
                }
                nextState.receiverAudioReadinessStates[intent.contactID] = .suppressed(intent.suppressedState)
                break
            }

            if case .published(let publication)? = nextState.receiverAudioReadinessStates[intent.contactID] {
                if publication == intent.publishedState {
                    break
                }

                if publication.isSemanticallyEquivalent(to: intent.publishedState),
                   !(publication.basis == .channelRefresh
                     && intent.publishedState.basis == .webSocketReconnect),
                   !(publication.basis == .lifecycle
                     && intent.reason == .backendSignalingRecovery) {
                    break
                }
            }

            nextState.receiverAudioReadinessStates[intent.contactID] = .published(intent.publishedState)
            effects.append(.publishReceiverAudioReadiness(intent))

        case .receiverAudioReadinessPublished(let intent):
            nextState.receiverAudioReadinessStates[intent.contactID] = .published(intent.publishedState)

        case .receiverAudioReadinessDeferred(let intent):
            nextState.receiverAudioReadinessStates[intent.contactID] = .deferred(intent)
            effects.append(.deferReceiverAudioReadinessUntilReconnect(intent))

        case .receiverAudioReadinessContextUnavailable(let contactID):
            nextState.receiverAudioReadinessStates[contactID] = nil

        case .receiverAudioReadinessEpochAdvanced(let contactID):
            nextState.receiverAudioReadinessStates[contactID] = nil

        case .receiverAudioReadinessCacheCleared(let contactID):
            if let contactID {
                nextState.clearCachedReceiverReadyPublicationPreservingDeferredAndNotReady(
                    contactID: contactID
                )
            } else {
                nextState.clearCachedReceiverAudioReadinessPublicationsPreservingDeferred()
            }

        case .webSocketStateChanged(let state):
            switch state {
            case .idle:
                nextState.clearCachedReceiverReadyPublicationsPreservingDeferredAndNotReady()
            case .connecting:
                break
            case .connected:
                for deferred in nextState.receiverAudioReadinessStates.values.compactMap(\.deferredIntent) {
                    effects.append(.publishReceiverAudioReadiness(deferred))
                }
            }

        case .postWakeRepairRequested(let contactID):
            guard !nextState.postWakeRepairContactIDs.contains(contactID) else { break }
            nextState.postWakeRepairContactIDs.insert(contactID)
            effects.append(.performPostWakeRepair(contactID: contactID))

        case .postWakeRepairFinished(let contactID):
            nextState.postWakeRepairContactIDs.remove(contactID)
        }

        return ControlPlaneTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class ControlPlaneCoordinator {
    private(set) var state = ControlPlaneSessionState()
    var effectHandler: (@MainActor (ControlPlaneEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: ControlPlaneEvent) {
        let previousState = state
        let transition = ControlPlaneReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
    }

    func handle(_ event: ControlPlaneEvent) async {
        let previousState = state
        let transition = ControlPlaneReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func replaceLocalReceiverAudioReadinessPublications(
        _ publications: [UUID: ReceiverAudioReadinessPublication]
    ) {
        state.replaceLocalReceiverAudioReadinessPublications(publications)
    }

    private func reportTransition(
        previousState: ControlPlaneSessionState,
        event: ControlPlaneEvent,
        transition: ControlPlaneTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "control-plane",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
