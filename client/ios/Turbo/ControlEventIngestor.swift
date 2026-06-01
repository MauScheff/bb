import Foundation

enum ControlEventSource: String, Codable, Equatable {
    case backendHTTP = "backend-http"
    case backendWebSocket = "backend-websocket"
    case directQuicDataChannel = "direct-quic-data-channel"
    case mediaRelay = "media-relay"
    case pttCallback = "ptt-callback"
    case timer
    case userIntent = "user-intent"
}

enum ControlEventAuthority: String, Codable, Equatable {
    case authoritativeBackendSnapshot = "authoritative-backend-snapshot"
    case authoritativeLocalPTTCallback = "authoritative-local-ptt-callback"
    case peerHint = "peer-hint"
    case transportHint = "transport-hint"
    case timer
    case userIntent = "user-intent"
}

enum ControlEventPayload: Equatable {
    case backendWebSocketSignal(TurboSignalEnvelope)
    case backendCommand(BackendCommandEvent)
    case selectedDirectQuicPrewarmRequested(reason: String)
    case directQuicReceiverPrewarmRequest(DirectQuicReceiverPrewarmPayload)
    case directQuicReceiverPrewarmAck(DirectQuicReceiverPrewarmPayload)
    case directQuicPathClosing(DirectQuicPathClosingPayload)
    case directQuicWarmPong(String?)
    case audioPlaybackStarted(TurboAudioPlaybackStartedPayload)

    var kind: String {
        switch self {
        case .backendWebSocketSignal(let envelope):
            return "websocket:\(envelope.type.rawValue)"
        case .backendCommand(let event):
            switch event {
            case .openFriendRequested:
                return "backend-command:open-friend"
            case .joinRequested:
                return "backend-command:join"
            case .leaveRequested:
                return "backend-command:leave"
            case .operationFinished:
                return "backend-command:operation-finished"
            case .operationFailed:
                return "backend-command:operation-failed"
            case .reset:
                return "backend-command:reset"
            }
        case .selectedDirectQuicPrewarmRequested:
            return "direct-quic:selected-prewarm-request"
        case .directQuicReceiverPrewarmRequest:
            return "direct-quic:receiver-prewarm-request"
        case .directQuicReceiverPrewarmAck:
            return "direct-quic:receiver-prewarm-ack"
        case .directQuicPathClosing:
            return "direct-quic:path-closing"
        case .directQuicWarmPong:
            return "direct-quic:warm-pong"
        case .audioPlaybackStarted:
            return "peer-hint:audio-playback-started"
        }
    }

    func requiresCurrentDirectQuicAttempt(from source: ControlEventSource) -> Bool {
        guard source == .directQuicDataChannel else { return false }
        switch self {
        case .directQuicReceiverPrewarmRequest,
             .directQuicReceiverPrewarmAck,
             .directQuicPathClosing,
             .directQuicWarmPong:
            return true
        case .backendWebSocketSignal,
             .backendCommand,
             .selectedDirectQuicPrewarmRequested,
             .audioPlaybackStarted:
            return false
        }
    }
}

struct ControlEventEnvelope: Equatable {
    let source: ControlEventSource
    let authority: ControlEventAuthority
    let channelID: String?
    let contactID: UUID?
    let localDeviceID: String?
    let remoteDeviceID: String?
    let sessionEpochID: String?
    let attemptID: String?
    let operationID: String?
    let eventID: String?
    let timestamp: Date
    let payload: ControlEventPayload

    var kind: String { payload.kind }

    static func backendWebSocketSignal(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID?,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .backendWebSocket,
            authority: authority(for: envelope.type),
            channelID: envelope.channelId,
            contactID: contactID,
            localDeviceID: envelope.toDeviceId,
            remoteDeviceID: envelope.fromDeviceId,
            sessionEpochID: envelope.sessionId,
            attemptID: directQuicAttemptID(from: envelope),
            operationID: nil,
            eventID: backendWebSocketSignalEventID(from: envelope, contactID: contactID),
            timestamp: timestamp,
            payload: .backendWebSocketSignal(envelope)
        )
    }

    static func directQuicReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        localDeviceID: String?,
        attemptID: String,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .directQuicDataChannel,
            authority: .peerHint,
            channelID: payload.channelId,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: payload.fromDeviceId,
            sessionEpochID: nil,
            attemptID: attemptID,
            operationID: payload.requestId,
            eventID: receiverPrewarmEventID(
                kind: "request",
                contactID: contactID,
                channelID: payload.channelId,
                remoteDeviceID: payload.fromDeviceId,
                requestID: payload.requestId
            ),
            timestamp: timestamp,
            payload: .directQuicReceiverPrewarmRequest(payload)
        )
    }

    static func mediaRelayReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        localDeviceID: String?,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .mediaRelay,
            authority: .peerHint,
            channelID: payload.channelId,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: payload.fromDeviceId,
            sessionEpochID: nil,
            attemptID: payload.directQuicAttemptId,
            operationID: payload.requestId,
            eventID: receiverPrewarmEventID(
                kind: "request",
                contactID: contactID,
                channelID: payload.channelId,
                remoteDeviceID: payload.fromDeviceId,
                requestID: payload.requestId
            ),
            timestamp: timestamp,
            payload: .directQuicReceiverPrewarmRequest(payload)
        )
    }

    static func selectedDirectQuicPrewarmRequested(
        contactID: UUID,
        channelID: String?,
        localDeviceID: String?,
        remoteDeviceID: String?,
        reason: String,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .userIntent,
            authority: .transportHint,
            channelID: channelID,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            sessionEpochID: nil,
            attemptID: nil,
            operationID: nil,
            eventID: nil,
            timestamp: timestamp,
            payload: .selectedDirectQuicPrewarmRequested(reason: reason)
        )
    }

    static func backendCommand(
        _ event: BackendCommandEvent,
        contactID: UUID? = nil,
        channelID: String? = nil,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        let operationID: String? = {
            switch event {
            case .joinRequested(let request):
                return request.operationID
            case .leaveRequested(let request):
                return request.operationID
            case .openFriendRequested, .operationFinished, .operationFailed, .reset:
                return nil
            }
        }()
        return ControlEventEnvelope(
            source: .userIntent,
            authority: .userIntent,
            channelID: channelID,
            contactID: contactID,
            localDeviceID: nil,
            remoteDeviceID: nil,
            sessionEpochID: nil,
            attemptID: nil,
            operationID: operationID,
            eventID: operationID.map { "backend-command:\($0)" },
            timestamp: timestamp,
            payload: .backendCommand(event)
        )
    }

    static func directQuicReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        localDeviceID: String?,
        attemptID: String,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .directQuicDataChannel,
            authority: .peerHint,
            channelID: payload.channelId,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: payload.fromDeviceId,
            sessionEpochID: nil,
            attemptID: attemptID,
            operationID: payload.requestId,
            eventID: receiverPrewarmEventID(
                kind: "ack",
                contactID: contactID,
                channelID: payload.channelId,
                remoteDeviceID: payload.fromDeviceId,
                requestID: payload.requestId
            ),
            timestamp: timestamp,
            payload: .directQuicReceiverPrewarmAck(payload)
        )
    }

    static func mediaRelayReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        localDeviceID: String?,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .mediaRelay,
            authority: .peerHint,
            channelID: payload.channelId,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: payload.fromDeviceId,
            sessionEpochID: nil,
            attemptID: payload.directQuicAttemptId,
            operationID: payload.requestId,
            eventID: receiverPrewarmEventID(
                kind: "ack",
                contactID: contactID,
                channelID: payload.channelId,
                remoteDeviceID: payload.fromDeviceId,
                requestID: payload.requestId
            ),
            timestamp: timestamp,
            payload: .directQuicReceiverPrewarmAck(payload)
        )
    }

    static func directQuicPathClosing(
        _ payload: DirectQuicPathClosingPayload,
        contactID: UUID,
        localDeviceID: String?,
        remoteDeviceID: String?,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .directQuicDataChannel,
            authority: .peerHint,
            channelID: nil,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            sessionEpochID: nil,
            attemptID: payload.attemptId,
            operationID: nil,
            eventID: "direct-quic:path-closing:\(contactID.uuidString):\(payload.attemptId):\(payload.reason)",
            timestamp: timestamp,
            payload: .directQuicPathClosing(payload)
        )
    }

    static func directQuicWarmPong(
        _ pingID: String?,
        contactID: UUID,
        localDeviceID: String?,
        remoteDeviceID: String?,
        attemptID: String,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: .directQuicDataChannel,
            authority: .transportHint,
            channelID: nil,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            sessionEpochID: nil,
            attemptID: attemptID,
            operationID: nil,
            eventID: "direct-quic:warm-pong:\(contactID.uuidString):\(attemptID):\(pingID ?? "none")",
            timestamp: timestamp,
            payload: .directQuicWarmPong(pingID)
        )
    }

    static func audioPlaybackStarted(
        _ payload: TurboAudioPlaybackStartedPayload,
        contactID: UUID,
        source: ControlEventSource,
        localDeviceID: String?,
        remoteDeviceID: String?,
        attemptID: String? = nil,
        timestamp: Date = Date()
    ) -> ControlEventEnvelope {
        ControlEventEnvelope(
            source: source,
            authority: .peerHint,
            channelID: payload.channelId,
            contactID: contactID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID ?? payload.receiverDeviceId,
            sessionEpochID: nil,
            attemptID: attemptID,
            operationID: payload.ackId,
            eventID: audioPlaybackStartedEventID(
                contactID: contactID,
                channelID: payload.channelId,
                senderDeviceID: payload.senderDeviceId,
                receiverDeviceID: payload.receiverDeviceId,
                ackID: payload.ackId
            ),
            timestamp: timestamp,
            payload: .audioPlaybackStarted(payload)
        )
    }

    private static func authority(for signalKind: TurboSignalKind) -> ControlEventAuthority {
        switch signalKind {
        case .receiverReady, .receiverNotReady, .transmitStart, .transmitStop, .audioPlaybackStarted:
            return .peerHint
        case .audioChunk, .offer, .answer, .iceCandidate, .hangup, .directQuicUpgradeRequest:
            return .transportHint
        case .selectedFriendPrewarm, .conversationParticipantTelemetry:
            return .peerHint
        }
    }

    private static func directQuicAttemptID(from envelope: TurboSignalEnvelope) -> String? {
        try? envelope.decodeDirectQuicSignalPayload().attemptId
    }

    private static func backendWebSocketSignalEventID(
        from envelope: TurboSignalEnvelope,
        contactID: UUID?
    ) -> String? {
        switch envelope.type {
        case .selectedFriendPrewarm:
            guard let payload = try? envelope.decodeSelectedFriendPrewarmPayload() else { return nil }
            return selectedFriendPrewarmEventID(
                contactID: contactID,
                channelID: payload.channelId,
                remoteDeviceID: payload.fromDeviceId,
                requestID: payload.requestId
            )
        case .audioPlaybackStarted:
            guard let payload = try? envelope.decodeAudioPlaybackStartedPayload(),
                  let contactID else { return nil }
            return audioPlaybackStartedEventID(
                contactID: contactID,
                channelID: payload.channelId,
                senderDeviceID: payload.senderDeviceId,
                receiverDeviceID: payload.receiverDeviceId,
                ackID: payload.ackId
            )
        case .offer, .answer, .iceCandidate, .hangup, .directQuicUpgradeRequest, .transmitStart, .transmitStop, .audioChunk, .receiverReady, .receiverNotReady, .conversationParticipantTelemetry:
            return nil
        }
    }

    private static func receiverPrewarmEventID(
        kind: String,
        contactID: UUID,
        channelID: String,
        remoteDeviceID: String,
        requestID: String
    ) -> String {
        "peer-hint:receiver-prewarm-\(kind):\(contactID.uuidString):\(channelID):\(remoteDeviceID):\(requestID)"
    }

    private static func selectedFriendPrewarmEventID(
        contactID: UUID?,
        channelID: String,
        remoteDeviceID: String,
        requestID: String
    ) -> String {
        let contactKey = contactID?.uuidString ?? "unknown-contact"
        return "friend-hint:selected-friend-prewarm:\(contactKey):\(channelID):\(remoteDeviceID):\(requestID)"
    }

    private static func audioPlaybackStartedEventID(
        contactID: UUID,
        channelID: String,
        senderDeviceID: String,
        receiverDeviceID: String,
        ackID: String
    ) -> String {
        "peer-hint:audio-playback-started:\(contactID.uuidString):\(channelID):\(senderDeviceID):\(receiverDeviceID):\(ackID)"
    }
}

struct ControlEventIngestorState: Equatable {
    var processedEventIDs: Set<String> = []
    var directQuicAttemptIDsByContactID: [UUID: String] = [:]

    static let initial = ControlEventIngestorState()
}

enum ControlEventIngestorEvent: Equatable {
    case ingest(ControlEventEnvelope)
    case directQuicAttemptUpdated(contactID: UUID, attemptID: String?)
    case reset
}

enum ControlEventIngestorIgnoredReason: Equatable {
    case duplicateEvent(String)
    case missingContact
    case missingAttempt
    case staleDirectQuicAttempt(expected: String?, received: String?)
}

enum ControlEventIngestorEffect: Equatable {
    case dispatch(ControlEventEnvelope)
}

struct ControlEventIngestorTransition: Equatable {
    var state: ControlEventIngestorState
    var effects: [ControlEventIngestorEffect] = []
    var ignoredReason: ControlEventIngestorIgnoredReason?
}

enum ControlEventIngestorReducer {
    static func reduce(
        state: ControlEventIngestorState,
        event: ControlEventIngestorEvent
    ) -> ControlEventIngestorTransition {
        var nextState = state

        switch event {
        case .reset:
            return ControlEventIngestorTransition(state: .initial)

        case .directQuicAttemptUpdated(let contactID, let attemptID):
            if let attemptID {
                nextState.directQuicAttemptIDsByContactID[contactID] = attemptID
            } else {
                nextState.directQuicAttemptIDsByContactID[contactID] = nil
            }
            return ControlEventIngestorTransition(state: nextState)

        case .ingest(let envelope):
            if let eventID = envelope.eventID,
               nextState.processedEventIDs.contains(eventID) {
                return ControlEventIngestorTransition(
                    state: nextState,
                    ignoredReason: .duplicateEvent(eventID)
                )
            }

            if envelope.payload.requiresCurrentDirectQuicAttempt(from: envelope.source) {
                guard let contactID = envelope.contactID else {
                    return ControlEventIngestorTransition(
                        state: nextState,
                        ignoredReason: .missingContact
                    )
                }
                let expectedAttemptID = nextState.directQuicAttemptIDsByContactID[contactID]
                guard let expectedAttemptID else {
                    return ControlEventIngestorTransition(
                        state: nextState,
                        ignoredReason: .missingAttempt
                    )
                }
                guard expectedAttemptID == envelope.attemptID else {
                    return ControlEventIngestorTransition(
                        state: nextState,
                        ignoredReason: .staleDirectQuicAttempt(
                            expected: expectedAttemptID,
                            received: envelope.attemptID
                        )
                    )
                }
            }

            if let eventID = envelope.eventID {
                nextState.processedEventIDs.insert(eventID)
            }

            return ControlEventIngestorTransition(
                state: nextState,
                effects: [.dispatch(envelope)]
            )
        }
    }
}

@MainActor
final class ControlEventIngestor {
    private(set) var state = ControlEventIngestorState.initial
    var effectHandler: (@MainActor (ControlEventIngestorEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?
    var ignoredEventReporter: (@MainActor (ControlEventEnvelope, ControlEventIngestorIgnoredReason) -> Void)?

    func send(_ event: ControlEventIngestorEvent) {
        let previousState = state
        let transition = ControlEventIngestorReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        reportIgnoredEventIfNeeded(event: event, transition: transition)
    }

    func handle(_ event: ControlEventIngestorEvent) async {
        let previousState = state
        let transition = ControlEventIngestorReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        reportIgnoredEventIfNeeded(event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    private func reportIgnoredEventIfNeeded(
        event: ControlEventIngestorEvent,
        transition: ControlEventIngestorTransition
    ) {
        guard case .ingest(let envelope) = event,
              let ignoredReason = transition.ignoredReason else {
            return
        }
        ignoredEventReporter?(envelope, ignoredReason)
    }

    private func reportTransition(
        previousState: ControlEventIngestorState,
        event: ControlEventIngestorEvent,
        transition: ControlEventIngestorTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "control-event-ingestor",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
