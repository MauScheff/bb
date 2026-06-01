import Foundation

extension PTTViewModel {
    func ingestBackendWebSocketSignal(_ envelope: TurboSignalEnvelope) async {
        let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id
        await ingestControlEvent(
            .backendWebSocketSignal(
                envelope,
                contactID: contactID
            )
        )
    }

    func ingestBackendCommandEvent(
        _ event: BackendCommandEvent,
        contactID: UUID? = nil,
        channelID: String? = nil
    ) async {
        await ingestControlEvent(
            .backendCommand(
                event,
                contactID: contactID,
                channelID: channelID
            )
        )
    }

    func ingestSelectedContactDirectQuicPrewarm(
        contactID: UUID,
        reason: String
    ) async {
        let contact = contacts.first(where: { $0.id == contactID })
        await ingestControlEvent(
            .selectedDirectQuicPrewarmRequested(
                contactID: contactID,
                channelID: contact?.backendChannelId,
                localDeviceID: backendServices?.deviceID,
                remoteDeviceID: directQuicPeerDeviceID(for: contactID),
                reason: reason
            )
        )
    }

    func ingestDirectQuicReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        await ingestControlEvent(
            .directQuicReceiverPrewarmRequest(
                payload,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID,
                attemptID: attemptID
            )
        )
    }

    func ingestDirectQuicReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        await ingestControlEvent(
            .directQuicReceiverPrewarmAck(
                payload,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID,
                attemptID: attemptID
            )
        )
    }

    func ingestMediaRelayReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID
    ) async {
        await ingestControlEvent(
            .mediaRelayReceiverPrewarmRequest(
                payload,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID
            )
        )
    }

    func ingestMediaRelayReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID
    ) async {
        await ingestControlEvent(
            .mediaRelayReceiverPrewarmAck(
                payload,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID
            )
        )
    }

    func ingestDirectQuicPathClosing(
        _ payload: DirectQuicPathClosingPayload,
        contactID: UUID
    ) async {
        await ingestControlEvent(
            .directQuicPathClosing(
                payload,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID,
                remoteDeviceID: directQuicPeerDeviceID(for: contactID)
            )
        )
    }

    func ingestDirectQuicWarmPong(
        _ pingID: String?,
        contactID: UUID,
        attemptID: String
    ) async {
        await ingestControlEvent(
            .directQuicWarmPong(
                pingID,
                contactID: contactID,
                localDeviceID: backendServices?.deviceID,
                remoteDeviceID: directQuicPeerDeviceID(for: contactID),
                attemptID: attemptID
            )
        )
    }

    func ingestAudioPlaybackStartedAck(
        _ payload: TurboAudioPlaybackStartedPayload,
        contactID: UUID,
        source: ControlEventSource,
        remoteDeviceID: String?,
        attemptID: String? = nil
    ) async {
        await ingestControlEvent(
            .audioPlaybackStarted(
                payload,
                contactID: contactID,
                source: source,
                localDeviceID: backendServices?.deviceID,
                remoteDeviceID: remoteDeviceID,
                attemptID: attemptID
            )
        )
    }

    func ingestControlEvent(_ envelope: ControlEventEnvelope) async {
        refreshControlEventAttemptContext(for: envelope.contactID)
        await controlEventIngestor.handle(.ingest(envelope))
    }

    func runControlEventIngestorEffect(_ effect: ControlEventIngestorEffect) async {
        switch effect {
        case .dispatch(let envelope):
            await dispatchControlEvent(envelope)
        }
    }

    func dispatchControlEvent(_ envelope: ControlEventEnvelope) async {
        guard let contactID = envelope.contactID else {
            switch envelope.payload {
            case .backendWebSocketSignal(let signalEnvelope):
                handleIncomingSignal(signalEnvelope)
            case .backendCommand(let event):
                await backendCommandCoordinator.handle(event)
            case .selectedDirectQuicPrewarmRequested:
                recordIgnoredControlEvent(envelope, reason: .missingContact)
            case .directQuicReceiverPrewarmRequest,
                 .directQuicReceiverPrewarmAck,
                 .directQuicPathClosing,
                 .directQuicWarmPong,
                 .audioPlaybackStarted:
                recordIgnoredControlEvent(envelope, reason: .missingContact)
            }
            return
        }

        switch envelope.payload {
        case .backendWebSocketSignal(let signalEnvelope):
            handleIncomingSignal(signalEnvelope)
        case .backendCommand(let event):
            await backendCommandCoordinator.handle(event)
        case .selectedDirectQuicPrewarmRequested(let reason):
            await maybeStartSelectedContactDirectQuicPrewarm(
                for: contactID,
                reason: reason
            )
        case .directQuicReceiverPrewarmRequest(let payload):
            let attemptID = envelope.attemptID ?? envelope.source.rawValue
            guard !attemptID.isEmpty else {
                recordIgnoredControlEvent(envelope, reason: .missingAttempt)
                return
            }
            await handleIncomingDirectQuicReceiverPrewarmRequest(
                payload,
                contactID: contactID,
                attemptID: attemptID,
                source: envelope.source
            )
        case .directQuicReceiverPrewarmAck(let payload):
            let attemptID = envelope.attemptID ?? envelope.source.rawValue
            guard !attemptID.isEmpty else {
                recordIgnoredControlEvent(envelope, reason: .missingAttempt)
                return
            }
            handleDirectQuicReceiverPrewarmAck(
                payload,
                contactID: contactID,
                attemptID: attemptID,
                source: envelope.source
            )
        case .directQuicPathClosing(let payload):
            await handleIncomingDirectQuicPathClosing(
                payload,
                contactID: contactID,
                attemptID: payload.attemptId
            )
        case .directQuicWarmPong(let pingID):
            guard let attemptID = envelope.attemptID else {
                recordIgnoredControlEvent(envelope, reason: .missingAttempt)
                return
            }
            handleDirectQuicWarmPong(
                pingID,
                contactID: contactID,
                attemptID: attemptID
            )
        case .audioPlaybackStarted(let payload):
            handleAudioPlaybackStartedAck(
                payload,
                contactID: contactID,
                source: envelope.source
            )
        }
    }

    func refreshControlEventAttemptContext(for contactID: UUID?) {
        guard let contactID else { return }
        controlEventIngestor.send(
            .directQuicAttemptUpdated(
                contactID: contactID,
                attemptID: directQuicAttempt(for: contactID)?.attemptId
            )
        )
    }

    func recordIgnoredControlEvent(
        _ envelope: ControlEventEnvelope,
        reason: ControlEventIngestorIgnoredReason
    ) {
        let subsystem: DiagnosticsSubsystem = {
            switch envelope.source {
            case .directQuicDataChannel:
                return .media
            case .backendWebSocket:
                return .websocket
            case .backendHTTP:
                return .backend
            case .mediaRelay:
                return .media
            case .pttCallback:
                return .pushToTalk
            case .timer, .userIntent:
                return .app
            }
        }()
        diagnostics.record(
            subsystem,
            message: "Ignored control event",
            metadata: [
                "kind": envelope.kind,
                "source": envelope.source.rawValue,
                "authority": envelope.authority.rawValue,
                "channelId": envelope.channelID ?? "",
                "contactId": envelope.contactID?.uuidString ?? "",
                "attemptId": envelope.attemptID ?? "",
                "eventId": envelope.eventID ?? "",
                "reason": String(describing: reason),
            ]
        )
    }
}
