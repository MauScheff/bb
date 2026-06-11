import AVFAudio
import Foundation
import Network
import TurboEngine
import UIKit

extension PTTViewModel {
    var conversationParticipantTelemetryRepublishIntervalSeconds: TimeInterval { 5 }
    var conversationParticipantTelemetryMissingRemoteRepublishIntervalSeconds: TimeInterval { 2 }
    var conversationParticipantTelemetryFreshnessSeconds: TimeInterval { 15 }

    func conversationParticipantTelemetry(for contactID: UUID) -> ConversationParticipantTelemetry? {
        conversationParticipantTelemetryByContactID[contactID]
    }

    func freshConversationParticipantTelemetry(
        for contactID: UUID,
        now: Date = Date()
    ) -> ConversationParticipantTelemetry? {
        guard let telemetry = conversationParticipantTelemetryByContactID[contactID],
              let receivedAt = conversationParticipantTelemetryReceivedAtByContactID[contactID],
              now.timeIntervalSince(receivedAt) <= conversationParticipantTelemetryFreshnessSeconds else {
            return nil
        }
        return telemetry
    }

    func currentLocalConversationParticipantTelemetry(includeAudio: Bool) -> ConversationParticipantTelemetry {
        let telemetry = ConversationParticipantTelemetry.current(
            includeAudio: includeAudio,
            networkInterface: localConversationNetworkInterface
        )
        if localConversationParticipantTelemetry != telemetry {
            localConversationParticipantTelemetry = telemetry
        }
        return telemetry
    }

    func applyRemoteConversationParticipantTelemetry(
        _ telemetry: ConversationParticipantTelemetry?,
        for contactID: UUID,
        source: String,
        receivedAt: Date = Date()
    ) {
        guard let telemetry else { return }
        conversationParticipantTelemetryReceivedAtByContactID[contactID] = receivedAt
        guard conversationParticipantTelemetryByContactID[contactID] != telemetry else { return }
        conversationParticipantTelemetryByContactID[contactID] = telemetry
        diagnostics.record(
            .media,
            message: "Updated remote conversation participant telemetry",
            metadata: [
                "contactId": contactID.uuidString,
                "source": source,
                "audioRoute": telemetry.audio?.routeName ?? "none",
                "volumePercent": telemetry.audio.map { String($0.volumePercent) } ?? "none",
                "network": telemetry.connection?.displayName ?? "none",
            ]
        )
    }

    func startConversationParticipantTelemetryNetworkMonitor() {
        guard conversationParticipantTelemetryNetworkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interface = ConversationNetworkInterface.from(path: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.localConversationNetworkInterface != interface else { return }
                let previousInterface = self.localConversationNetworkInterface
                self.localConversationNetworkInterface = interface
                await self.handleLocalNetworkPathChanged(
                    to: interface,
                    previous: previousInterface,
                    source: "NWPathMonitor"
                )
                _ = self.currentLocalConversationParticipantTelemetry(includeAudio: self.activeChannelId != nil)
                await self.publishConversationParticipantTelemetryIfNeeded(reason: "network-change")
                await self.syncConversationParticipantTelemetryIfNeeded(reason: .networkChange)
            }
        }
        conversationParticipantTelemetryNetworkMonitor = monitor
        monitor.start(queue: conversationParticipantTelemetryNetworkQueue)
    }

    func handleLocalNetworkPathChanged(
        to interface: ConversationNetworkInterface,
        previous: ConversationNetworkInterface,
        source: String
    ) async {
        let previousGeneration = mediaRuntime.networkPathGeneration
        let generation = mediaRuntime.advanceNetworkPathGeneration()
        diagnostics.record(
            .media,
            message: "Network path changed",
            metadata: [
                "source": source,
                "previousInterface": previous.rawValue,
                "interface": interface.rawValue,
                "previousGeneration": "\(previousGeneration)",
                "networkPathGeneration": "\(generation)",
                "transportPathState": mediaTransportPathState.rawValue,
            ]
        )
        let contactID = selectedContactId ?? activeChannelId
        let directAttempt = contactID.flatMap { mediaRuntime.directQuicUpgrade.attempt(for: $0) }
        let directWasActive =
            directAttempt?.isDirectActive == true
            && mediaRuntime.directQuicProbeController != nil
            && mediaTransportPathState == .direct

        receiveEngineEvent(
            .transport(.networkChanged(engineNetworkInterface(for: interface))),
            source: "network-path-changed:\(source)"
        )

        if directWasActive, interface != .unavailable {
            syncEngineDirectQuicLaneAvailable(
                source: "direct-quic-network-migration"
            )
        }

        guard let contactID else { return }
        if interface != .unavailable,
           mediaRuntime.transportPathState == .fastRelayTcp,
           let key = mediaRuntime.currentMediaRelayConnectionKey(),
           let client = mediaRuntime.existingMediaRelayClient(for: key),
           let contact = contacts.first(where: { $0.id == contactID }),
           contact.backendChannelId == key.sessionID,
           directQuicPeerDeviceID(for: contactID) == key.peerDeviceID {
            scheduleMediaRelayQuicUpgradeProbe(
                contactID: contactID,
                channelID: key.sessionID,
                peerDeviceID: key.peerDeviceID,
                localDeviceID: key.localDeviceID,
                client: client,
                reason: "network-change"
            )
        }

        _ = clearDirectQuicConnectivityBackoffForSelectedNetworkChangeIfNeeded(
            for: contactID,
            generation: generation,
            interface: interface
        )

        if directWasActive, let directAttempt, interface != .unavailable {
            await beginDirectQuicNetworkMigrationLivenessProbe(
                for: contactID,
                attempt: directAttempt,
                generation: generation,
                interface: interface,
                source: source
            )
            return
        }

        if directWasActive, let directAttempt {
            await handleDirectQuicMediaPathLost(
                for: contactID,
                attemptID: directAttempt.attemptId,
                reason: "network-path-changed"
            )
            return
        }

        if currentApplicationState() == .active,
           selectedContactId == contactID,
           interface != .unavailable {
            await maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "network-change"
            )
        }
    }

    func engineNetworkInterface(for interface: ConversationNetworkInterface) -> EngineNetworkInterface {
        switch interface {
        case .cellular:
            return .cellular
        case .unavailable:
            return .offline
        case .wifi, .wired, .other, .unknown:
            return .wifi
        }
    }

    func startConversationParticipantTelemetryPolling() {
        guard conversationParticipantTelemetryPollTask == nil else { return }
        conversationParticipantTelemetryPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                _ = self?.currentLocalConversationParticipantTelemetry(includeAudio: self?.activeChannelId != nil)
                await self?.publishConversationParticipantTelemetryIfNeeded(reason: "poll")
                await self?.syncConversationParticipantTelemetryIfNeeded(reason: .telemetryRefresh)
            }
        }
    }

    func startConversationParticipantTelemetryOutputVolumeObserver(audioSession: AVAudioSession = .sharedInstance()) {
        guard conversationParticipantTelemetryOutputVolumeObservation == nil else { return }
        conversationParticipantTelemetryOutputVolumeObservation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.currentLocalConversationParticipantTelemetry(includeAudio: self.activeChannelId != nil)
                await self.publishConversationParticipantTelemetryIfNeeded(reason: "volume-change")
                await self.syncConversationParticipantTelemetryIfNeeded(reason: .telemetryRefresh)
            }
        }
    }

    func syncConversationParticipantTelemetryIfNeeded(reason: ReceiverAudioReadinessReason) async {
        guard let contactID = activeChannelId else { return }
        let hasPublishedReceiverState = localReceiverAudioReadinessPublications[contactID] != nil
        guard desiredLocalReceiverAudioReadiness(for: contactID) || hasPublishedReceiverState else { return }
        await publishConversationParticipantTelemetryIfNeeded(reason: reason.wireValue)
        await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: reason)
    }

    func publishConversationParticipantTelemetryIfNeeded(reason: String) async {
        guard let contactID = activeChannelId else { return }
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let currentUserID = backend.currentUserID else {
            return
        }

        let telemetry = currentLocalConversationParticipantTelemetry(
            includeAudio: true
        )
        guard telemetry.hasVisibleContext else { return }
        let now = Date()
        let lastPublishedTelemetry = lastPublishedConversationParticipantTelemetryByContactID[contactID]
        let republishInterval = conversationParticipantTelemetryByContactID[contactID] == nil
            ? conversationParticipantTelemetryMissingRemoteRepublishIntervalSeconds
            : conversationParticipantTelemetryRepublishIntervalSeconds
        if lastPublishedTelemetry == telemetry,
           let lastPublishedAt = lastPublishedConversationParticipantTelemetryAtByContactID[contactID],
           now.timeIntervalSince(lastPublishedAt) < republishInterval {
            return
        }
        let payloadTelemetry = telemetry.withLivenessPulse(sentAt: now)
        guard let payloadData = try? JSONEncoder().encode(payloadTelemetry),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return
        }

        let targetDeviceID = receiverAudioReadinessTargetDeviceID(for: contactID)
        do {
            _ = try await backend.sendRuntimeControlSignal(
                TurboSignalEnvelope(
                    type: .conversationParticipantTelemetry,
                    channelId: backendChannelID,
                    fromUserId: currentUserID,
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: targetDeviceID,
                    payload: payload
                )
            )
            lastPublishedConversationParticipantTelemetryByContactID[contactID] = telemetry
            lastPublishedConversationParticipantTelemetryAtByContactID[contactID] = now
            diagnostics.record(
                .media,
                message: "Published conversation participant telemetry over runtime control",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "republished": String(lastPublishedTelemetry == telemetry),
                    "audioRoute": telemetry.audio?.routeName ?? "none",
                    "volumePercent": telemetry.audio.map { String($0.volumePercent) } ?? "none",
                    "network": telemetry.connection?.displayName ?? "none",
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                message: "Failed to publish conversation participant telemetry",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func applyConversationParticipantTelemetryPayload(
        _ payload: String,
        for contactID: UUID,
        source: String
    ) {
        guard let data = payload.data(using: .utf8),
              let telemetry = try? JSONDecoder().decode(ConversationParticipantTelemetry.self, from: data) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Ignored invalid conversation participant telemetry",
                metadata: [
                    "contactId": contactID.uuidString,
                    "source": source,
                    "payloadLength": String(payload.count),
                ]
            )
            return
        }
        applyRemoteConversationParticipantTelemetry(telemetry, for: contactID, source: source)
    }
}
